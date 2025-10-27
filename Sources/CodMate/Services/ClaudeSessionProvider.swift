import Foundation

actor ClaudeSessionProvider {
    private let parser = ClaudeSessionParser()
    private let fileManager: FileManager
    private let root: URL?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        let projects = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        root = fileManager.fileExists(atPath: projects.path) ? projects : nil
    }

    func sessions(scope: SessionLoadScope) -> [SessionSummary] {
        guard let root else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var results: [SessionSummary] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let fileSize = resolveFileSize(for: url)
            guard let parsed = parser.parse(at: url, fileSize: fileSize) else { continue }
            if matches(scope: scope, summary: parsed.summary) {
                results.append(parsed.summary)
            }
        }
        return results
    }

    func countAllSessions() -> Int {
        guard let root else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return 0 }
        var total = 0
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            total += 1
        }
        return total
    }

    func collectCWDCounts() -> [String: Int] {
        guard let root else { return [:] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [:] }

        var counts: [String: Int] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            if let parsed = parser.parse(at: url, fileSize: resolveFileSize(for: url)) {
                counts[parsed.summary.cwd, default: 0] += 1
            }
        }
        return counts
    }

    func enrich(summary: SessionSummary) -> SessionSummary? {
        guard summary.source.baseKind == .claude else { return summary }
        guard let parsed = parser.parse(at: summary.fileURL) else { return nil }
        let loader = SessionTimelineLoader()
        let turns = loader.turns(from: parsed.rows)
        let activeDuration = computeActiveDuration(turns: turns)

        return SessionSummary(
            id: parsed.summary.id,
            fileURL: parsed.summary.fileURL,
            fileSizeBytes: parsed.summary.fileSizeBytes,
            startedAt: parsed.summary.startedAt,
            endedAt: parsed.summary.endedAt,
            activeDuration: activeDuration,
            cliVersion: parsed.summary.cliVersion,
            cwd: parsed.summary.cwd,
            originator: parsed.summary.originator,
            instructions: parsed.summary.instructions,
            model: parsed.summary.model,
            approvalPolicy: parsed.summary.approvalPolicy,
            userMessageCount: parsed.summary.userMessageCount,
            assistantMessageCount: parsed.summary.assistantMessageCount,
            toolInvocationCount: parsed.summary.toolInvocationCount,
            responseCounts: parsed.summary.responseCounts,
            turnContextCount: parsed.summary.turnContextCount,
            eventCount: parsed.summary.eventCount,
            lineCount: parsed.summary.lineCount,
            lastUpdatedAt: parsed.summary.lastUpdatedAt,
            source: summary.source,
            remotePath: summary.remotePath
        )
    }

    func timeline(for summary: SessionSummary) -> [ConversationTurn]? {
        guard summary.source.baseKind == .claude else { return nil }
        guard let parsed = parser.parse(at: summary.fileURL) else { return nil }
        let loader = SessionTimelineLoader()
        return loader.turns(from: parsed.rows)
    }

    private func matches(scope: SessionLoadScope, summary: SessionSummary) -> Bool {
        let calendar = Calendar.current
        let referenceDates = [
            summary.startedAt,
            summary.lastUpdatedAt ?? summary.startedAt
        ]
        switch scope {
        case .all:
            return true
        case .today:
            return referenceDates.contains(where: { calendar.isDateInToday($0) })
        case .day(let day):
            return referenceDates.contains(where: { calendar.isDate($0, inSameDayAs: day) })
        case .month(let date):
            return referenceDates.contains {
                calendar.isDate($0, equalTo: date, toGranularity: .month)
            }
        }
    }

    private func computeActiveDuration(turns: [ConversationTurn]) -> TimeInterval? {
        guard !turns.isEmpty else { return nil }
        let filtered = turns.removingEnvironmentContext()
        guard !filtered.isEmpty else { return nil }
        var total: TimeInterval = 0
        for turn in filtered {
            let start = turn.userMessage?.timestamp ?? turn.outputs.first?.timestamp
            guard let s = start, let end = turn.outputs.last?.timestamp else { continue }
            let delta = end.timeIntervalSince(s)
            if delta > 0 { total += delta }
        }
        return total
    }

    private func resolveFileSize(for url: URL) -> UInt64? {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return UInt64(size)
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let number = attributes[.size] as? NSNumber {
            return number.uint64Value
        }
        return nil
    }
}
