import Foundation

private enum ClaudeUsageConstants {
    static let blockDuration: TimeInterval = 5 * 60 * 60
    static let defaultHorizon: TimeInterval = -7 * 24 * 60 * 60
}

struct ClaudeUsageAnalyzer {

    private let isoFormatter: ISO8601DateFormatter
    private let fallbackISOFormatter: ISO8601DateFormatter
    private let newline: UInt8 = 0x0A
    private let carriageReturn: UInt8 = 0x0D

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatter = formatter

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        fallbackISOFormatter = fallback
    }

    func buildStatus(
        from sessions: [SessionSummary],
        limit: Int = 48,
        now: Date = Date()
    ) -> ClaudeUsageStatus? {
        guard !sessions.isEmpty else {
            NSLog("[ClaudeUsage] No sessions provided")
            return nil
        }

        let weekInterval = Calendar.current.dateInterval(of: .weekOfYear, for: now)
        let horizon = weekInterval?.start.addingTimeInterval(-ClaudeUsageConstants.blockDuration)
            ?? now.addingTimeInterval(ClaudeUsageConstants.defaultHorizon)

        let entries = collectEntries(from: sessions, limit: limit, horizon: horizon)
        guard !entries.isEmpty else {
            NSLog("[ClaudeUsage] No entries collected from \(sessions.count) sessions")
            return nil
        }

        NSLog("[ClaudeUsage] Collected \(entries.count) entries from \(sessions.count) sessions")

        let blocks = UsageBlockBuilder(entries: entries).build()
        guard let latestBlock = blocks.last else {
            NSLog("[ClaudeUsage] No blocks built")
            return nil
        }

        NSLog("[ClaudeUsage] Built \(blocks.count) blocks, latest: sessionLimit=\(latestBlock.sessionLimitReached), usageReset=\(String(describing: latestBlock.usageLimitReset))")

        let fiveHour = latestSessionUsage(block: latestBlock, now: now)
        let weekly = WeeklyUsageAggregator(blocks: blocks, now: now).summary()
        let weeklyOverride = blocks.last(where: { $0.weeklyLimitReached })
        let weeklyReset = weeklyOverride?.weeklyLimitReset ?? weekly.resetDate

        NSLog("[ClaudeUsage] 5h: \(fiveHour.minutes)min, reset=\(String(describing: fiveHour.resetDate)); Weekly: \(weekly.minutes)min, reset=\(String(describing: weeklyReset))")

        return ClaudeUsageStatus(
            updatedAt: latestBlock.lastActivity,
            modelName: latestBlock.primaryModel,
            contextUsedTokens: latestBlock.totalTokens,
            contextLimitTokens: ClaudeModelContextProvider.contextLimit(for: latestBlock.primaryModel),
            fiveHourUsedMinutes: fiveHour.minutes,
            fiveHourWindowMinutes: ClaudeUsageConstants.blockDuration / 60,
            fiveHourResetAt: fiveHour.resetDate,
            weeklyUsedMinutes: weekly.minutes,
            weeklyWindowMinutes: weekly.windowMinutes,
            weeklyResetAt: weeklyReset
        )
    }

    // MARK: - Entry Collection

    private func collectEntries(
        from sessions: [SessionSummary],
        limit: Int,
        horizon: Date
    ) -> [UsageEntry] {
        var entries: [UsageEntry] = []
        var processed = 0

        for summary in sessions.sorted(by: { ($0.lastUpdatedAt ?? $0.startedAt) > ($1.lastUpdatedAt ?? $1.startedAt) }) {
            guard summary.source.baseKind == .claude else { continue }
            if processed >= limit { break }
            if let last = summary.lastUpdatedAt, last < horizon, !entries.isEmpty {
                break
            }

            guard let data = try? Data(contentsOf: summary.fileURL, options: [.mappedIfSafe]), !data.isEmpty else { continue }
            var fileEntries: [UsageEntry] = []
            var seenKeys: Set<String> = []

            for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
                if slice.last == carriageReturn { slice = slice.dropLast() }
                guard let entry = parseLine(Data(slice), seenKeys: &seenKeys) else { continue }
                guard entry.timestamp >= horizon else { continue }
                fileEntries.append(entry)
            }

            entries.append(contentsOf: fileEntries)
            processed += 1
        }

        entries.sort { $0.timestamp < $1.timestamp }
        return entries
    }

    private func parseLine(_ data: Data, seenKeys: inout Set<String>) -> UsageEntry? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let timestampString = json["timestamp"] as? String else { return nil }
        guard let timestamp = isoFormatter.date(from: timestampString) ?? fallbackISOFormatter.date(from: timestampString) else {
            return nil
        }

        let message = json["message"] as? [String: Any]
        let usage = extractUsageDictionary(from: json, message: message)

        let dedupKey = makeDedupKey(message: message, root: json)
        if let dedupKey {
            if seenKeys.contains(dedupKey) { return nil }
            seenKeys.insert(dedupKey)
        }

        let (limitResetFromMessage, limitKind) = parseLimitResetHint(from: message, timestamp: timestamp)

        var tokens = 0
        if let usage {
            let input = numberValue(in: usage, keys: ["input_tokens", "inputTokens"])
            let cacheCreation = numberValue(in: usage, keys: ["cache_creation_input_tokens", "cacheCreationInputTokens"])
            let cacheRead = numberValue(in: usage, keys: ["cache_read_input_tokens", "cacheReadInputTokens"])
            let output = numberValue(in: usage, keys: ["output_tokens", "outputTokens"])
            tokens = input + cacheCreation + cacheRead + output
        }
        if tokens <= 0, limitKind == nil {
            return nil
        }

        let model = (message?["model"] as? String)
            ?? (json["model"] as? String)
            ?? ((json["metadata"] as? [String: Any])?["model"] as? String)
        let resetDate = limitResetFromMessage ?? parseResetDate(from: json, timestamp: timestamp)

        return UsageEntry(
            timestamp: timestamp,
            tokens: tokens,
            model: model,
            usageLimitReset: resetDate,
            limitKind: limitKind
        )
    }

    private func makeDedupKey(message: [String: Any]?, root: [String: Any]) -> String? {
        if let message, let messageID = message["id"] as? String, !messageID.isEmpty {
            return "msg:\(messageID)"
        }
        if let requestID = root["requestId"] as? String, !requestID.isEmpty {
            return "req:\(requestID)"
        }
        return nil
    }

    private func extractUsageDictionary(from root: [String: Any], message: [String: Any]?) -> [String: Any]? {
        if let usage = message?["usage"] as? [String: Any] { return usage }
        if let usage = root["usage"] as? [String: Any] { return usage }
        if
            let metadata = root["metadata"] as? [String: Any],
            let usage = metadata["usage"] as? [String: Any]
        {
            return usage
        }
        if
            let info = root["info"] as? [String: Any],
            let usage = info["usage"] as? [String: Any]
        {
            return usage
        }
        return nil
    }

    private func numberValue(in dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let number = dict[key] as? NSNumber { return number.intValue }
            if let string = dict[key] as? String, let value = Int(string) { return value }
        }
        return 0
    }

    private func parseResetDate(from json: [String: Any], timestamp: Date) -> Date? {
        if let absolute = json["usage_limit_reset_time"] as? NSNumber {
            return Date(timeIntervalSince1970: absolute.doubleValue)
        }
        if let absolute = json["usageLimitResetTime"] as? NSNumber {
            return Date(timeIntervalSince1970: absolute.doubleValue)
        }
        if let seconds = json["usage_limit_reset_in_seconds"] as? NSNumber {
            return timestamp.addingTimeInterval(seconds.doubleValue)
        }
        if let seconds = json["usageLimitResetSeconds"] as? NSNumber {
            return timestamp.addingTimeInterval(seconds.doubleValue)
        }
        return nil
    }

    private func parseLimitResetHint(from message: [String: Any]?, timestamp: Date) -> (Date?, UsageEntry.LimitKind?) {
        guard
            let message,
            let contents = message["content"] as? [[String: Any]]
        else { return (nil, nil) }

        let text = contents.compactMap { $0["text"] as? String }.joined(separator: " ")
        guard !text.isEmpty else { return (nil, nil) }

        let lower = text.lowercased()
        let kind: UsageEntry.LimitKind?
        if lower.contains("session limit reached") {
            kind = .session
        } else if lower.contains("weekly limit reached") {
            kind = .weekly
        } else {
            kind = nil
        }
        guard let kind else { return (nil, nil) }
        NSLog("[ClaudeUsage] Found limit message: kind=\(kind), text=\(text.prefix(80))")
        let resetDate = parseResetDateHint(from: text, reference: timestamp)
        NSLog("[ClaudeUsage] Parsed reset date: \(String(describing: resetDate))")
        return (resetDate, kind)
    }

    private func parseResetDateHint(from text: String, reference: Date) -> Date? {
        // First, try to extract Unix timestamp (format: |<digits>)
        // This is the most accurate source from Claude Code CLI
        if let unixTimestamp = extractUnixTimestamp(from: text) {
            NSLog("[ClaudeUsage] Extracted Unix timestamp: \(unixTimestamp)")
            return Date(timeIntervalSince1970: TimeInterval(unixTimestamp))
        }

        guard var payload = extractResetPayload(from: text) else { return nil }
        if payload.isEmpty { return nil }

        if let dated = parseMonthBasedReset(payload: payload, reference: reference) {
            return dated
        }

        payload = payload.replacingOccurrences(of: " at ", with: " ")
        payload = payload.replacingOccurrences(of: "  ", with: " ")
        return parseTimeOnlyReset(payload: payload, reference: reference)
    }

    private func extractUnixTimestamp(from text: String) -> Int? {
        // Claude Code CLI embeds Unix timestamp as |<digits>
        // Example: "Session limit reached · resets 3pm … |1731147600"
        let pattern = "\\|(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard let timestampRange = Range(match.range(at: 1), in: text) else { return nil }
        let timestampString = String(text[timestampRange])
        return Int(timestampString)
    }

    private func extractResetPayload(from text: String) -> String? {
        let lower = text.lowercased()
        guard let range = lower.range(of: "resets") else { return nil }
        var payload = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("∙") {
            payload = String(payload.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let idx = payload.firstIndex(of: "(") {
            payload = String(payload[..<idx])
        }
        return payload.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseMonthBasedReset(payload: String, reference: Date) -> Date? {
        NSLog("[ClaudeUsage] parseMonthBasedReset: payload=\"\(payload)\"")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let attempts = [
            "MMM d 'at' h:mma",
            "MMM d 'at' h a",
            "MMM d 'at' ha",
            "MMM d h:mma",
            "MMM d h a",
            "MMM d ha"
        ]
        let year = Calendar.current.component(.year, from: reference)
        let enriched = payload + " \(year)"
        for format in attempts {
            formatter.dateFormat = format + " yyyy"
            if let date = formatter.date(from: enriched) {
                NSLog("[ClaudeUsage] Matched format \"\(format)\", date=\(date)")
                if date < reference,
                   let nextYear = Calendar.current.date(byAdding: .year, value: 1, to: date) {
                    return nextYear
                }
                return date
            }
        }
        NSLog("[ClaudeUsage] No format matched for payload=\"\(payload)\"")
        return nil
    }

    private func parseTimeOnlyReset(payload: String, reference: Date) -> Date? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSLog("[ClaudeUsage] parseTimeOnlyReset: empty payload")
            return nil
        }
        NSLog("[ClaudeUsage] parseTimeOnlyReset: payload=\"\(trimmed)\"")
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: reference)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let lower = trimmed.lowercased()
        let attempts: [String]
        if lower.contains("am") || lower.contains("pm") {
            attempts = ["h:mma", "h.mma", "ha", "hmma"]
        } else if trimmed.contains(":") {
            attempts = ["HH:mm"]
        } else {
            NSLog("[ClaudeUsage] parseTimeOnlyReset: no am/pm or colon found")
            return nil
        }

        for format in attempts {
            formatter.dateFormat = format
            let testString = trimmed.replacingOccurrences(of: " ", with: "")
            if let date = formatter.date(from: testString) {
                let time = calendar.dateComponents([.hour, .minute], from: date)
                components.hour = time.hour
                components.minute = time.minute
                components.second = 0
                if let combined = calendar.date(from: components) {
                    NSLog("[ClaudeUsage] parseTimeOnlyReset: matched format \"\(format)\", combined=\(combined)")
                    if combined <= reference {
                        let next = calendar.date(byAdding: .day, value: 1, to: combined)
                        NSLog("[ClaudeUsage] parseTimeOnlyReset: date in past, adding 1 day -> \(String(describing: next))")
                        return next
                    }
                    return combined
                }
            }
        }
        NSLog("[ClaudeUsage] parseTimeOnlyReset: no format matched")
        return nil
    }
}

// MARK: - Usage Entry

private struct UsageEntry {
    enum LimitKind { case session, weekly }

    let timestamp: Date
    let tokens: Int
    let model: String?
    let usageLimitReset: Date?
    let limitKind: LimitKind?
}

// MARK: - Usage Blocks

private struct UsageBlock {
    let startTime: Date
    let lastActivity: Date
    let totalTokens: Int
    let models: Set<String>
    let usageLimitReset: Date?
    let sessionLimitReached: Bool
    let weeklyLimitReset: Date?
    let weeklyLimitReached: Bool

    private static let blockDuration = ClaudeUsageConstants.blockDuration

    var primaryModel: String? {
        guard !models.isEmpty else { return nil }
        return models.sorted().first
    }

    var usedMinutes: Double {
        let blockEnd = startTime.addingTimeInterval(Self.blockDuration)
        let effectiveEnd = min(blockEnd, lastActivity)
        return max(0, effectiveEnd.timeIntervalSince(startTime) / 60)
    }

    var resetDate: Date {
        usageLimitReset ?? startTime.addingTimeInterval(Self.blockDuration)
    }

    var activeInterval: DateInterval {
        let end = min(startTime.addingTimeInterval(Self.blockDuration), lastActivity)
        return DateInterval(start: startTime, end: max(startTime, end))
    }
}

private struct UsageBlockBuilder {
    let entries: [UsageEntry]

    func build() -> [UsageBlock] {
        guard !entries.isEmpty else { return [] }

        var blocks: [UsageBlock] = []
        var currentEntries: [UsageEntry] = []
        var blockStart: Date = entries[0].timestamp
        var lastTimestamp: Date = entries[0].timestamp

        func finalize() {
            guard !currentEntries.isEmpty else { return }
            let tokens = currentEntries.reduce(0) { $0 + $1.tokens }
            let models = Set(currentEntries.compactMap(\.model))
            let sessionLimitReached = currentEntries.contains { $0.limitKind == .session }
            let usageReset: Date? = {
                if sessionLimitReached {
                    return currentEntries.last { entry in
                        entry.limitKind == .session && entry.usageLimitReset != nil
                    }?.usageLimitReset ?? currentEntries.last(where: { $0.usageLimitReset != nil })?.usageLimitReset
                }
                return currentEntries.last(where: { $0.usageLimitReset != nil })?.usageLimitReset
            }()
        let block = UsageBlock(
            startTime: currentEntries.first!.timestamp,
            lastActivity: currentEntries.last!.timestamp,
            totalTokens: tokens,
            models: models,
            usageLimitReset: usageReset,
            sessionLimitReached: sessionLimitReached,
            weeklyLimitReset: currentEntries.last(where: { $0.limitKind == .weekly && $0.usageLimitReset != nil })?.usageLimitReset,
            weeklyLimitReached: currentEntries.contains { $0.limitKind == .weekly }
        )
            blocks.append(block)
            currentEntries.removeAll(keepingCapacity: true)
        }

        let blockDuration = ClaudeUsageConstants.blockDuration

        for entry in entries {
            if currentEntries.isEmpty {
                blockStart = entry.timestamp
                currentEntries.append(entry)
                lastTimestamp = entry.timestamp
                if entry.limitKind == .session {
                    finalize()
                }
                continue
            }

            let exceedsBlock = entry.timestamp.timeIntervalSince(blockStart) > blockDuration
            let gapTooLarge = entry.timestamp.timeIntervalSince(lastTimestamp) > blockDuration

            if exceedsBlock || gapTooLarge {
                finalize()
                blockStart = entry.timestamp
                lastTimestamp = entry.timestamp
                currentEntries.append(entry)
                if entry.limitKind == .session {
                    finalize()
                }
                continue
            }

            currentEntries.append(entry)
            lastTimestamp = entry.timestamp

            if entry.limitKind == .session {
                finalize()
            }
        }

        finalize()
        return blocks
    }
}

// MARK: - Weekly Aggregation

private struct WeeklyUsageAggregator {
    let blocks: [UsageBlock]
    let now: Date

    func summary() -> (minutes: Double, windowMinutes: Double, resetDate: Date?) {
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: now) else {
            return (0, 7 * 24 * 60, nil)
        }

        var totalMinutes: Double = 0
        for block in blocks {
            if let overlap = block.activeInterval.intersection(with: interval) {
                totalMinutes += overlap.duration / 60
            }
        }

        return (
            minutes: totalMinutes,
            windowMinutes: interval.duration / 60,
            resetDate: interval.end
        )
    }
}

// MARK: - Latest Session (5-hour window) Aggregation

private func latestSessionUsage(block: UsageBlock, now: Date) -> (minutes: Double, resetDate: Date?) {
    let duration = ClaudeUsageConstants.blockDuration
    let windowEnd = block.startTime.addingTimeInterval(duration)

    if block.sessionLimitReached {
        let reset = block.usageLimitReset ?? windowEnd
        if reset <= now {
            return (minutes: 0, resetDate: nil)
        }
        return (
            minutes: duration / 60,
            resetDate: reset
        )
    }

    guard windowEnd > now else { return (0, nil) }

    let usedSeconds = min(now, windowEnd).timeIntervalSince(block.startTime)
    let minutes = max(0, usedSeconds) / 60

    let candidateReset = block.usageLimitReset
    let resetDate: Date?
    if let candidateReset, candidateReset > now {
        resetDate = candidateReset
    } else if windowEnd > now {
        resetDate = windowEnd
    } else {
        resetDate = nil
    }

    return (minutes: minutes, resetDate: resetDate)
}

// MARK: - Context Limit Resolution

enum ClaudeModelContextProvider {
    private static let highCapacityModels: [String] = [
        "claude-sonnet-4-20250514",
        "claude-sonnet-4",
        "claude-sonnet-4@20250514"
    ]

    private static let lowCapacityModels: [String] = [
        "claude-instant-v1",
        "claude-v1",
        "claude-v2",
        "claude-2"
    ]

    static func contextLimit(for modelName: String?) -> Int? {
        guard let model = modelName?.lowercased() else { return nil }
        if highCapacityModels.contains(where: { model.contains($0) }) {
            return 1_000_000
        }
        if lowCapacityModels.contains(where: { model.contains($0) }) {
            return 100_000
        }
        return 200_000
    }
}
