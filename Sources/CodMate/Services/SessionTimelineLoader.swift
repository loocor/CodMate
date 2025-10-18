import Foundation

struct SessionTimelineLoader {
    private let decoder: JSONDecoder
    private let skippedEventTypes: Set<String> = [
        "reasoning",
        "reasoning_output"
    ]

    init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(url: URL) throws -> [ConversationTurn] {
        let events = try decodeEvents(url: url)
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

        func flushTurn() {
            guard currentUser != nil || !pendingOutputs.isEmpty else { return }
            let timestamp = currentUser?.timestamp ?? pendingOutputs.first?.timestamp ?? Date()
            let turn = ConversationTurn(
                id: UUID().uuidString,
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
            for match in matches {
                if match.numberOfRanges >= 3 {
                    let key = nsString.substring(with: match.range(at: 1))
                    var value = nsString.substring(with: match.range(at: 2))
                    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    metadata[key] = value
                }
            }
        }
        let textLines = metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        return TimelineEvent(
            id: UUID().uuidString,
            timestamp: timestamp,
            actor: .info,
            title: "Environment Context",
            text: textLines.isEmpty ? nil : textLines,
            metadata: metadata.isEmpty ? nil : metadata
        )
    }

    private func makeTokenCountEvent(timestamp: Date, payload: EventMessagePayload) -> TimelineEvent? {
        let infoDict = flatten(json: payload.info)
        let rateDict = flatten(json: payload.rateLimits, prefix: "rate_")
        let combined = infoDict.merging(rateDict) { current, _ in current }
        guard !combined.isEmpty else { return nil }
        let text = combined.sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        return TimelineEvent(
            id: UUID().uuidString,
            timestamp: timestamp,
            actor: .info,
            title: "Token Usage",
            text: text,
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
}
