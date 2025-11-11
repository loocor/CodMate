import Foundation

struct SessionTimelineLoader {
    private let decoder: JSONDecoder
    private let skippedEventTypes: Set<String> = [
        "reasoning",
        "reasoning_output"
    ]

    init() {
        decoder = FlexibleDecoders.iso8601Flexible()
    }

    func load(url: URL) throws -> [ConversationTurn] {
        let events = try decodeEvents(url: url)
        return group(events: events)
    }

    func turns(from rows: [SessionRow]) -> [ConversationTurn] {
        let events = rows.compactMap { makeEvent(from: $0) }
        return group(events: events)
    }

    private func decodeEvents(url: URL) throws -> [TimelineEvent] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return [] }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        var events: [TimelineEvent] = []
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let row = try? decoder.decode(SessionRow.self, from: Data(slice)) else { continue }
            guard let event = makeEvent(from: row) else { continue }
            events.append(event)
        }
        return events
    }

    private func makeEvent(from row: SessionRow) -> TimelineEvent? {
        switch row.kind {
        case .sessionMeta:
            return nil
        case let .turnContext(payload):
            var parts: [String] = []
            if let model = payload.model { parts.append("model: \(model)") }
            if let ap = payload.approvalPolicy { parts.append("policy: \(ap)") }
            if let cwd = payload.cwd { parts.append("cwd: \(cwd)") }
            if let summary = payload.summary, !summary.isEmpty { parts.append(summary) }
            let text = parts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TimelineEvent(
                id: UUID().uuidString,
                timestamp: row.timestamp,
                actor: .info,
                title: "Context Updated",
                text: text,
                metadata: nil
            )
        case let .eventMessage(payload):
            let type = payload.type.lowercased()
            if skippedEventTypes.contains(type) { return nil }
            if type == "token_count" {
                return makeTokenCountEvent(timestamp: row.timestamp, payload: payload)
            }
            if type == "agent_reasoning" {
                let reasoning = cleanedText(payload.text ?? payload.message ?? "")
                guard !reasoning.isEmpty else { return nil }
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .info,
                    title: "Agent Reasoning",
                    text: reasoning,
                    metadata: nil
                )
            }
            if type == "environment_context" {
                if let env = payload.message ?? payload.text {
                    return makeEnvironmentContextEvent(text: env, timestamp: row.timestamp)
                }
                return nil
            }

            let message = cleanedText(payload.message ?? payload.text ?? "")
            guard !message.isEmpty else { return nil }
            switch type {
            case "user_message":
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .user,
                    title: nil,
                    text: message,
                    metadata: nil
                )
            case "agent_message":
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .assistant,
                    title: nil,
                    text: message,
                    metadata: nil
                )
            default:
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .info,
                    title: payload.type,
                    text: message,
                    metadata: nil
                )
            }
        case let .responseItem(payload):
            let type = payload.type.lowercased()
            if skippedEventTypes.contains(type) || type.contains("function_call") || type.contains("tool_call")
                || type.contains("tool_output")
            {
                return nil
            }

            if type == "message" {
                let text = cleanedText(joinedText(from: payload.content ?? []))
                guard !text.isEmpty else { return nil }
                if payload.role?.lowercased() == "user" {
                    if let environment = makeEnvironmentContextEvent(text: text, timestamp: row.timestamp) {
                        return environment
                    }
                    // event_msg already covers user content; skip to avoid duplicates
                    return nil
                }
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .assistant,
                    title: nil,
                    text: text,
                    metadata: nil
                )
            }

            let summaryText = cleanedText(joinedSummary(from: payload.summary ?? []))
            guard !summaryText.isEmpty else { return nil }
            return TimelineEvent(
                id: UUID().uuidString,
                timestamp: row.timestamp,
                actor: .info,
                title: payload.type,
                text: summaryText,
                metadata: nil
            )
        case .unknown:
            return nil
        }
    }

    private func group(events: [TimelineEvent]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var currentUser: TimelineEvent?
        var pendingOutputs: [TimelineEvent] = []

        // Use a stable, content-agnostic key per turn to preserve UI expansion state
        // across reloads when outputs are appended (commonly the last turn).
        var seenTurnKeys: [String: Int] = [:]

        func stableTurnID(anchor timestamp: Date, hasUser: Bool) -> String {
            let millis = Int(timestamp.timeIntervalSince1970 * 1000)
            let baseKey = "\(millis)-\(hasUser ? "u" : "o")"
            let seq = (seenTurnKeys[baseKey] ?? 0) + 1
            seenTurnKeys[baseKey] = seq
            return "t-\(baseKey)-\(seq)"
        }

        func flushTurn() {
            guard currentUser != nil || !pendingOutputs.isEmpty else { return }
            let timestamp = currentUser?.timestamp ?? pendingOutputs.first?.timestamp ?? Date()
            let id = stableTurnID(anchor: timestamp, hasUser: currentUser != nil)
            let turn = ConversationTurn(
                id: id,
                timestamp: timestamp,
                userMessage: currentUser,
                outputs: pendingOutputs
            )
            turns.append(turn)
            currentUser = nil
            pendingOutputs = []
        }

        let ordered = events.sorted(by: { $0.timestamp < $1.timestamp })
        let deduped = collapseDuplicates(ordered)

        for event in deduped {
            if event.actor == .user {
                flushTurn()
                currentUser = event
            } else {
                pendingOutputs.append(event)
            }
        }
        flushTurn()
        return turns
    }

    private func cleanedText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text
            .replacingOccurrences(of: "<user_instructions>", with: "")
            .replacingOccurrences(of: "</user_instructions>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func joinedText(from blocks: [ResponseContentBlock]) -> String {
        blocks.compactMap { $0.text }.joined(separator: "\n\n")
    }

    private func joinedSummary(from items: [ResponseSummaryItem]) -> String {
        items.compactMap { $0.text }.joined(separator: "\n\n")
    }

    private func collapseDuplicates(_ events: [TimelineEvent]) -> [TimelineEvent] {
        guard !events.isEmpty else { return [] }
        var result: [TimelineEvent] = []
        for event in events {
            if let last = result.last,
                last.actor == event.actor,
                last.title == event.title,
                (last.text ?? "") == (event.text ?? ""),
                normalize(metadata: last.metadata) == normalize(metadata: event.metadata)
            {
                result[result.count - 1] = last.incrementingRepeatCount()
            } else {
                result.append(event)
            }
        }
        return result
    }

    private func normalize(metadata: [String: String]?) -> [String: String] {
        metadata?.filter { !$0.value.isEmpty } ?? [:]
    }

    private func makeEnvironmentContextEvent(text: String, timestamp: Date) -> TimelineEvent? {
        guard let rangeStart = text.range(of: "<environment_context>"),
            let rangeEnd = text.range(of: "</environment_context>")
        else { return nil }
        let inner = text[rangeStart.upperBound..<rangeEnd.lowerBound]
        let regex = try? NSRegularExpression(pattern: "<(\\w+)>\\s*([^<]+?)\\s*</\\1>", options: [])
        var metadata: [String: String] = [:]
        if let regex {
            let nsString = NSString(string: String(inner))
            let matches = regex.matches(in: String(inner), range: NSRange(location: 0, length: nsString.length))
            for match in matches where match.numberOfRanges >= 3 {
                let key = nsString.substring(with: match.range(at: 1))
                var value = nsString.substring(with: match.range(at: 2))
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                metadata[key] = value
            }
        }
        let sortedEntries = metadata.sorted(by: { $0.key < $1.key })
        let textLines = sortedEntries
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        let displayText = textLines.isEmpty ? cleanedText(String(inner)) : textLines
        return TimelineEvent(
            id: UUID().uuidString,
            timestamp: timestamp,
            actor: .info,
            title: TimelineEvent.environmentContextTitle,
            text: displayText.isEmpty ? nil : displayText,
            metadata: metadata.isEmpty ? nil : metadata
        )
    }

    private func makeTokenCountEvent(timestamp: Date, payload: EventMessagePayload) -> TimelineEvent? {
        let infoDict = flatten(json: payload.info)
        let rateDict = flatten(json: payload.rateLimits, prefix: "rate_")
        let combined = infoDict.merging(rateDict) { current, _ in current }
        guard !combined.isEmpty else { return nil }
        return TimelineEvent(
            id: UUID().uuidString,
            timestamp: timestamp,
            actor: .info,
            title: "Token Usage",
            text: nil,
            metadata: combined
        )
    }

    private func flatten(json: JSONValue?, prefix: String = "") -> [String: String] {
        guard let json else { return [:] }
        var result: [String: String] = [:]
        switch json {
        case .string(let value):
            result[prefix.isEmpty ? "value" : prefix] = value
        case .number(let value):
            let key = prefix.isEmpty ? "value" : prefix
            result[key] = String(value)
        case .bool(let value):
            let key = prefix.isEmpty ? "value" : prefix
            result[key] = value ? "true" : "false"
        case .object(let dict):
            for (key, value) in dict {
                let newPrefix = prefix.isEmpty ? key : "\(prefix)\(key.capitalized)"
                result.merge(flatten(json: value, prefix: newPrefix)) { current, _ in current }
            }
        case .array(let array):
            for (index, value) in array.enumerated() {
                let newPrefix = prefix.isEmpty ? "item\(index)" : "\(prefix)\(index)"
                result.merge(flatten(json: value, prefix: newPrefix)) { current, _ in current }
            }
        case .null:
            break
        }
        return result
    }

    func loadInstructions(url: URL) throws -> String? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            if let row = try? decoder.decode(SessionRow.self, from: Data(slice)) {
                if case let .sessionMeta(payload) = row.kind, let instructions = payload.instructions {
                    let cleaned = cleanedText(instructions)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }
        return nil
    }

    func loadEnvironmentContext(url: URL) throws -> EnvironmentContextInfo? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var latest: TimelineEvent?

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let row = try? decoder.decode(SessionRow.self, from: Data(slice)) else { continue }

            switch row.kind {
            case let .eventMessage(payload):
                let type = payload.type.lowercased()
                if type == "environment_context",
                   let envText = payload.message ?? payload.text,
                   let event = makeEnvironmentContextEvent(text: envText, timestamp: row.timestamp)
                {
                    latest = event
                }
            case let .responseItem(payload):
                if payload.type.lowercased() == "message" {
                    let text = joinedText(from: payload.content ?? [])
                    guard text.contains("<environment_context") else { continue }
                    if let event = makeEnvironmentContextEvent(text: text, timestamp: row.timestamp) {
                        latest = event
                    }
                }
            default:
                continue
            }
        }

        guard let event = latest else { return nil }
        let metadataPairs = (event.metadata ?? [:]).sorted(by: { $0.key < $1.key })
        let entries = metadataPairs.map { EnvironmentContextInfo.Entry(key: $0.key, value: $0.value) }
        return EnvironmentContextInfo(
            timestamp: event.timestamp,
            entries: entries,
            rawText: event.text
        )
    }

    func loadLatestTokenUsage(url: URL) throws -> TokenUsageSnapshot? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var latest: TokenUsageSnapshot?

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let row = try? decoder.decode(SessionRow.self, from: Data(slice)) else { continue }
            guard case let .eventMessage(payload) = row.kind else { continue }
            if payload.type.lowercased() == "token_count",
               let snapshot = TokenUsageSnapshotBuilder.build(timestamp: row.timestamp, payload: payload)
            {
                latest = snapshot
            }
        }

        return latest
    }

}

struct TokenUsageSnapshot: Equatable {
    let timestamp: Date
    let totalTokens: Int?
    let contextWindow: Int?
    let primaryPercent: Double?
    let primaryWindowMinutes: Int?
    let primaryResetAt: Date?
    let secondaryPercent: Double?
    let secondaryWindowMinutes: Int?
    let secondaryResetAt: Date?
}

struct TokenUsageSnapshotBuilder {
    static func build(timestamp: Date, payload: EventMessagePayload) -> TokenUsageSnapshot? {
        let info = payload.info
        let totalTokens = info?.value(forKeyPath: ["last_token_usage", "total_tokens"])?.intValue
            ?? info?.value(forKeyPath: ["total_token_usage", "total_tokens"])?.intValue
        let contextWindow = info?.value(forKeyPath: ["model_context_window"])?.intValue

        let primaryRate = RateWindowSnapshot(json: payload.rateLimits, prefix: "primary", timestamp: timestamp)
        let secondaryRate = RateWindowSnapshot(json: payload.rateLimits, prefix: "secondary", timestamp: timestamp)

        if totalTokens == nil,
           contextWindow == nil,
           primaryRate.isEmpty,
           secondaryRate.isEmpty
        {
            return nil
        }

        return TokenUsageSnapshot(
            timestamp: timestamp,
            totalTokens: totalTokens,
            contextWindow: contextWindow,
            primaryPercent: primaryRate.usedPercent,
            primaryWindowMinutes: primaryRate.windowMinutes,
            primaryResetAt: primaryRate.resetDate,
            secondaryPercent: secondaryRate.usedPercent,
            secondaryWindowMinutes: secondaryRate.windowMinutes,
            secondaryResetAt: secondaryRate.resetDate
        )
    }
}

fileprivate struct TokenUsageFallbackParser {
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func loadLatest(url: URL) -> TokenUsageSnapshot? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var latest: TokenUsageSnapshot?

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard let snapshot = parseLine(Data(slice)) else { continue }
            latest = snapshot
        }

        return latest
    }

    private func parseLine(_ data: Data) -> TokenUsageSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let type = (payload["type"] as? String)?.lowercased(),
              type == "token_count",
              let timestampString = json["timestamp"] as? String,
              let timestamp = isoFormatter.date(from: timestampString) ?? ISO8601DateFormatter().date(from: timestampString)
        else {
            return nil
        }

        let info = payload["info"] as? [String: Any]
        let rateLimits = payload["rate_limits"] as? [String: Any]
        let totalTokens = TokenUsageValueParser.int(TokenUsageValueParser.value(in: info, keyPath: ["total_token_usage", "total_tokens"]))
        let contextWindow = TokenUsageValueParser.int(info?["model_context_window"])
        let primary = RateLimitComponents(json: rateLimits, prefix: "primary", timestamp: timestamp)
        let secondary = RateLimitComponents(json: rateLimits, prefix: "secondary", timestamp: timestamp)

        if totalTokens == nil,
           contextWindow == nil,
           primary.isEmpty,
           secondary.isEmpty
        {
            return nil
        }

        return TokenUsageSnapshot(
            timestamp: timestamp,
            totalTokens: totalTokens,
            contextWindow: contextWindow,
            primaryPercent: primary.usedPercent,
            primaryWindowMinutes: primary.windowMinutes,
            primaryResetAt: primary.resetDate,
            secondaryPercent: secondary.usedPercent,
            secondaryWindowMinutes: secondary.windowMinutes,
            secondaryResetAt: secondary.resetDate
        )
    }
}

extension SessionTimelineLoader {
    func loadLatestTokenUsageWithFallback(url: URL) -> TokenUsageSnapshot? {
        if let snapshot = try? loadLatestTokenUsage(url: url) {
            return snapshot
        }
        return TokenUsageFallbackParser().loadLatest(url: url)
    }
}

private struct RateLimitComponents {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetDate: Date?

    var isEmpty: Bool { usedPercent == nil && windowMinutes == nil && resetDate == nil }

    init(json: [String: Any]?, prefix: String, timestamp: Date) {
        if let nested = json?[prefix] as? [String: Any] {
            parse(values: nested, timestamp: timestamp)
            return
        }

        guard let json else { return }
        var extracted: [String: Any] = [:]
        extracted["used_percent"] = json["\(prefix)_used_percent"]
        extracted["window_minutes"] = json["\(prefix)_window_minutes"]
        extracted["resets_in_seconds"] = json["\(prefix)_resets_in_seconds"]
        extracted["resets_at"] = json["\(prefix)_resets_at"]
        parse(values: extracted, timestamp: timestamp)
    }

    private mutating func parse(values: [String: Any], timestamp: Date) {
        usedPercent = TokenUsageValueParser.double(values["used_percent"])
        windowMinutes = TokenUsageValueParser.int(values["window_minutes"])
        if let resetsAt = TokenUsageValueParser.double(values["resets_at"]) {
            resetDate = Date(timeIntervalSince1970: resetsAt)
        } else if let resetsInSeconds = TokenUsageValueParser.double(values["resets_in_seconds"]) {
            resetDate = timestamp.addingTimeInterval(resetsInSeconds)
        }
    }
}

private enum TokenUsageValueParser {
    static func value(in root: Any?, keyPath: [String]) -> Any? {
        var current = root
        for key in keyPath {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}

private struct RateWindowSnapshot {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsInSeconds: Double?
    var resetDate: Date? {
        guard let resetsInSeconds, let referenceTimestamp else { return nil }
        return referenceTimestamp.addingTimeInterval(resetsInSeconds)
    }

    private let referenceTimestamp: Date?

    init(json: JSONValue?, prefix: String, timestamp: Date) {
        referenceTimestamp = timestamp
        guard let json else { return }
        guard case let .object(dict) = json else { return }

        if let nested = dict[prefix] {
            usedPercent = nested.value(forKeyPath: ["used_percent"])?.doubleValue
            windowMinutes = nested.value(forKeyPath: ["window_minutes"])?.intValue
            resetsInSeconds = nested.value(forKeyPath: ["resets_in_seconds"])?.doubleValue
        } else {
            usedPercent = dict["\(prefix)_used_percent"]?.doubleValue
            windowMinutes = dict["\(prefix)_window_minutes"]?.intValue
            resetsInSeconds = dict["\(prefix)_resets_in_seconds"]?.doubleValue
        }
    }

    var isEmpty: Bool {
        usedPercent == nil && windowMinutes == nil && resetsInSeconds == nil
    }
}

private extension JSONValue {
    func value(forKeyPath path: [String]) -> JSONValue? {
        guard !path.isEmpty else { return self }
        var current: JSONValue = self
        for key in path {
            guard case let .object(dict) = current, let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let string):
            return Double(string)
        case .bool(let bool):
            return bool ? 1 : 0
        default:
            return nil
        }
    }

    var intValue: Int? {
        if case let .number(value) = self {
            return Int(value)
        }
        if case let .string(string) = self {
            return Int(string)
        }
        return nil
    }
}
