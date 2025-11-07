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
        guard !sessions.isEmpty else { return nil }

        let weekInterval = Calendar.current.dateInterval(of: .weekOfYear, for: now)
        let horizon = weekInterval?.start.addingTimeInterval(-ClaudeUsageConstants.blockDuration)
            ?? now.addingTimeInterval(ClaudeUsageConstants.defaultHorizon)

        let entries = collectEntries(from: sessions, limit: limit, horizon: horizon)
        guard !entries.isEmpty else { return nil }

        let blocks = UsageBlockBuilder(entries: entries).build()
        guard let latestBlock = blocks.last else { return nil }

        let weekly = WeeklyUsageAggregator(blocks: blocks, now: now).summary()

        return ClaudeUsageStatus(
            updatedAt: latestBlock.lastActivity,
            modelName: latestBlock.primaryModel,
            contextUsedTokens: latestBlock.totalTokens,
            contextLimitTokens: ClaudeModelContextProvider.contextLimit(for: latestBlock.primaryModel),
            fiveHourUsedMinutes: latestBlock.usedMinutes,
            fiveHourWindowMinutes: ClaudeUsageConstants.blockDuration / 60,
            fiveHourResetAt: latestBlock.resetDate,
            weeklyUsedMinutes: weekly.minutes,
            weeklyWindowMinutes: weekly.windowMinutes,
            weeklyResetAt: weekly.resetDate
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
            guard summary.source == .claude else { continue }
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

        guard let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let dedupKey = makeDedupKey(message: message, root: json)
        if let dedupKey {
            if seenKeys.contains(dedupKey) { return nil }
            seenKeys.insert(dedupKey)
        }

        let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheCreation = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
        let tokens = input + cacheCreation + cacheRead
        guard tokens > 0 else { return nil }

        let model = message["model"] as? String
        let resetDate = parseResetDate(from: json, timestamp: timestamp)

        return UsageEntry(
            timestamp: timestamp,
            tokens: tokens,
            model: model,
            usageLimitReset: resetDate
        )
    }

    private func makeDedupKey(message: [String: Any], root: [String: Any]) -> String? {
        if let messageID = message["id"] as? String, !messageID.isEmpty {
            return "msg:\(messageID)"
        }
        if let requestID = root["requestId"] as? String, !requestID.isEmpty {
            return "req:\(requestID)"
        }
        return nil
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
}

// MARK: - Usage Entry

private struct UsageEntry {
    let timestamp: Date
    let tokens: Int
    let model: String?
    let usageLimitReset: Date?
}

// MARK: - Usage Blocks

private struct UsageBlock {
    let startTime: Date
    let lastActivity: Date
    let totalTokens: Int
    let models: Set<String>
    let usageLimitReset: Date?

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
            let usageReset = currentEntries.last(where: { $0.usageLimitReset != nil })?.usageLimitReset
            let block = UsageBlock(
                startTime: currentEntries.first!.timestamp,
                lastActivity: currentEntries.last!.timestamp,
                totalTokens: tokens,
                models: models,
                usageLimitReset: usageReset
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
                continue
            }

            let exceedsBlock = entry.timestamp.timeIntervalSince(blockStart) > blockDuration
            let gapTooLarge = entry.timestamp.timeIntervalSince(lastTimestamp) > blockDuration

            if exceedsBlock || gapTooLarge {
                finalize()
                blockStart = entry.timestamp
            }

            currentEntries.append(entry)
            lastTimestamp = entry.timestamp
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
