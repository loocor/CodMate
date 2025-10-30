import Foundation

actor ClaudeSessionProvider {
    private let parser = ClaudeSessionParser()
    private let fileManager: FileManager
    private let root: URL?
    // Best-effort cache: sessionId -> canonical file URL (updated on scans)
    private var canonicalURLById: [String: URL] = [:]

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

        // Gather all parsed summaries then dedupe by sessionId,
        // preferring canonical filenames and newer/longer files.
        var bestById: [String: SessionSummary] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let fileSize = resolveFileSize(for: url)
            guard let parsed = parser.parse(at: url, fileSize: fileSize) else { continue }
            let s = parsed.summary
            guard matches(scope: scope, summary: s) else { continue }

            if let existing = bestById[s.id] {
                let pick = prefer(lhs: existing, rhs: s)
                bestById[s.id] = pick
            } else {
                bestById[s.id] = s
            }
        }

        // Update canonical map for later fallbacks
        for (_, s) in bestById { canonicalURLById[s.id] = s.fileURL }
        return Array(bestById.values)
    }

    /// Load only the sessions under a specific project directory (e.g. ~/.claude/projects/-Users-loocor-GitHub-CodMate)
    /// Directory should be the original project cwd; it will be encoded to Claude's folder name.
    func sessions(inProjectDirectory directory: String) -> [SessionSummary] {
        guard let root else { return [] }
        let folder = encodeProjectFolder(from: directory)
        let projectURL = root.appendingPathComponent(folder, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var results: [SessionSummary] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let fileSize = resolveFileSize(for: url)
            guard let parsed = parser.parse(at: url, fileSize: fileSize) else { continue }
            results.append(parsed.summary)
        }
        return results
    }

    private func encodeProjectFolder(from cwd: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized.hasSuffix("/") && standardized.count > 1 { standardized.removeLast() }
        var name = standardized.replacingOccurrences(of: ":", with: "-")
        name = name.replacingOccurrences(of: "/", with: "-")
        if !name.hasPrefix("-") { name = "-" + name }
        return name
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
        guard summary.source == .claude else { return summary }
        // Parse using canonical file path when available
        let url = resolveCanonicalURL(for: summary)
        guard let parsed = parser.parse(at: url) else { return nil }
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
            source: .claude
        )
    }

    func timeline(for summary: SessionSummary) -> [ConversationTurn]? {
        guard summary.source == .claude else { return nil }
        let url = resolveCanonicalURL(for: summary)
        guard let parsed = parser.parse(at: url) else { return nil }
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

    // MARK: - Canonical resolution and dedupe helpers

    /// Prefer canonical filename and more complete/updated files for the same session ID.
    /// Heuristics:
    /// - Prefer non "agent-" filenames over "agent-" (agent is an early placeholder)
    /// - If both non-agent, pick the one with later lastUpdated or larger file size
    private func prefer(lhs: SessionSummary, rhs: SessionSummary) -> SessionSummary {
        if lhs.id != rhs.id { return lhs } // shouldn't happen, but keep lhs
        let isAgentL = lhs.fileURL.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
        let isAgentR = rhs.fileURL.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
        if isAgentL != isAgentR { return isAgentL ? rhs : lhs }
        // Both same class; prefer newer lastUpdated, then larger size
        let lt = lhs.lastUpdatedAt ?? lhs.startedAt
        let rt = rhs.lastUpdatedAt ?? rhs.startedAt
        if lt != rt { return lt > rt ? lhs : rhs }
        let ls = lhs.fileSizeBytes ?? 0
        let rs = rhs.fileSizeBytes ?? 0
        if ls != rs { return ls > rs ? lhs : rhs }
        // Stable fallback: lexical by filename to reduce churn
        return lhs.fileURL.lastPathComponent < rhs.fileURL.lastPathComponent ? lhs : rhs
    }

    /// Resolve a stable file URL for a session summary. Handles cases where the
    /// initial file was "agent-*.jsonl" and later renamed to canonical UUID or
    /// rollout-named files. Falls back to summary.fileURL if nothing better is found.
    private func resolveCanonicalURL(for summary: SessionSummary) -> URL {
        // 1) If file exists and is readable, use it.
        if fileManager.fileExists(atPath: summary.fileURL.path) {
            return summary.fileURL
        }
        // 2) Return cached mapping if available
        if let cached = canonicalURLById[summary.id], fileManager.fileExists(atPath: cached.path) {
            return cached
        }
        // 3) Probe sibling files under the project folder for a better match
        let dir = summary.fileURL.deletingLastPathComponent()
        if let best = findSibling(bySessionId: summary.id, inDirectory: dir) {
            canonicalURLById[summary.id] = best
            return best
        }
        // 4) As a last resort, scan the entire Claude root
        if let root, let best = findSibling(bySessionId: summary.id, inDirectory: root) {
            canonicalURLById[summary.id] = best
            return best
        }
        return summary.fileURL
    }

    /// Find a file in the given directory tree that belongs to the sessionId,
    /// preferring non-agent names and newest mtime.
    private func findSibling(bySessionId sessionId: String, inDirectory base: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }

        var candidates: [(url: URL, mtime: Date, isAgent: Bool)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            // Quick filename check: many canonical files include the sessionId directly
            let name = url.deletingPathExtension().lastPathComponent
            if name.contains(sessionId) {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((url, mtime, name.hasPrefix("agent-")))
                continue
            }
            // As a fallback, peek the sessionId from file contents (cheap prefix scan)
            if let sid = parser.fastSessionId(at: url), sid == sessionId {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((url, mtime, name.hasPrefix("agent-")))
            }
        }
        guard !candidates.isEmpty else { return nil }
        // Prefer non-agent, then newest mtime
        candidates.sort { a, b in
            if a.isAgent != b.isAgent { return !a.isAgent } // non-agent first
            if a.mtime != b.mtime { return a.mtime > b.mtime }
            return a.url.lastPathComponent < b.url.lastPathComponent
        }
        return candidates.first?.url
    }
}
