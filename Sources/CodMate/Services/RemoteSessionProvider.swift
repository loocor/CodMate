import Foundation

actor RemoteSessionProvider {
    private let hostResolver: SSHConfigResolver
    private let mirror: RemoteSessionMirror
    private let indexer: SessionIndexer
    private let parser = ClaudeSessionParser()
    private let fileManager: FileManager

    init(
        hostResolver: SSHConfigResolver = SSHConfigResolver(),
        mirror: RemoteSessionMirror = RemoteSessionMirror(),
        indexer: SessionIndexer = SessionIndexer(),
        fileManager: FileManager = .default
    ) {
        self.hostResolver = hostResolver
        self.mirror = mirror
        self.indexer = indexer
        self.fileManager = fileManager
    }

    func codexSessions(scope: SessionLoadScope, enabledHosts: Set<String>) async -> [SessionSummary] {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return [] }
        return await fetchCodexSessions(scope: scope, hosts: hosts)
    }

    func claudeSessions(scope: SessionLoadScope, enabledHosts: Set<String>) async -> [SessionSummary] {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return [] }
        return await fetchClaudeSessions(scope: scope, hosts: hosts)
    }

    func collectCWDAggregates(kind: RemoteSessionKind, enabledHosts: Set<String>) async -> [String: Int] {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        for host in hosts {
            do {
                let outcome = try await mirror.ensureMirror(
                    host: host,
                    kind: kind,
                    scope: .all
                )
                switch kind {
                case .codex:
                    let counts = try await collectCodexCounts(localRoot: outcome.localRoot)
                    for (key, value) in counts {
                        result[key, default: 0] += value
                    }
                case .claude:
                    let counts = collectClaudeCounts(localRoot: outcome.localRoot)
                    for (key, value) in counts {
                        result[key, default: 0] += value
                    }
                }
            } catch {
                continue
            }
        }
        return result
    }

    func countSessions(kind: RemoteSessionKind, enabledHosts: Set<String>) async -> Int {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return 0 }
        var total = 0
        for host in hosts {
            do {
                let outcome = try await mirror.ensureMirror(
                    host: host,
                    kind: kind,
                    scope: .all
                )
                switch kind {
                case .codex:
                    let enumerator = fileManager.enumerator(
                        at: outcome.localRoot,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                    while let url = enumerator?.nextObject() as? URL {
                        if url.pathExtension.lowercased() == "jsonl" { total += 1 }
                    }
                case .claude:
                    let enumerator = fileManager.enumerator(
                        at: outcome.localRoot,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                    while let url = enumerator?.nextObject() as? URL {
                        if url.pathExtension.lowercased() == "jsonl" { total += 1 }
                    }
                }
            } catch {
                continue
            }
        }
        return total
    }

    // MARK: - Private helpers

    private func fetchCodexSessions(scope: SessionLoadScope, hosts: [SSHHost]) async -> [SessionSummary] {
        var aggregate: [SessionSummary] = []
        for host in hosts {
            do {
                let outcome = try await mirror.ensureMirror(
                    host: host,
                    kind: .codex,
                    scope: scope
                )
                let summaries = try await indexer.refreshSessions(
                    root: outcome.localRoot,
                    scope: scope
                )
                for summary in summaries {
                    guard let metadata = outcome.fileMap[summary.fileURL] else { continue }
                    let remoteSource: SessionSource = .codexRemote(host: host.alias)
                    aggregate.append(
                        summary.withRemoteMetadata(
                            source: remoteSource,
                            remotePath: metadata.remotePath
                        )
                    )
                }
            } catch {
                continue
            }
        }
        return aggregate
    }

    private func fetchClaudeSessions(scope: SessionLoadScope, hosts: [SSHHost]) async -> [SessionSummary] {
        var aggregate: [SessionSummary] = []
        for host in hosts {
            do {
                let outcome = try await mirror.ensureMirror(
                    host: host,
                    kind: .claude,
                    scope: scope
                )
                let sessions = loadClaudeSessions(
                    at: outcome.localRoot,
                    scope: scope,
                    host: host.alias,
                    fileMap: outcome.fileMap
                )
                aggregate.append(contentsOf: sessions)
            } catch {
                continue
            }
        }
        return aggregate
    }

    private func collectCodexCounts(localRoot: URL) async throws -> [String: Int] {
        let counts = await indexer.collectCWDCounts(root: localRoot)
        return counts
    }

    private func collectClaudeCounts(localRoot: URL) -> [String: Int] {
        guard let enumerator = fileManager.enumerator(
            at: localRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }
        var counts: [String: Int] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            if let parsed = parser.parse(at: url) {
                counts[parsed.summary.cwd, default: 0] += 1
            }
        }
        return counts
    }

    private func loadClaudeSessions(
        at root: URL,
        scope: SessionLoadScope,
        host: String,
        fileMap: [URL: RemoteMirrorOutcome.MirroredFile]
    ) -> [SessionSummary] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var sessions: [SessionSummary] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let fileSize = resolveFileSize(for: url)
            guard let parsed = parser.parse(at: url, fileSize: fileSize) else { continue }
            guard matches(scope: scope, summary: parsed.summary) else { continue }
            guard let metadata = fileMap[url] else { continue }
            sessions.append(
                parsed.summary.withRemoteMetadata(
                    source: .claudeRemote(host: host),
                    remotePath: metadata.remotePath
                )
            )
        }
        return sessions
    }

    private func filteredHosts(_ enabledHosts: Set<String>) -> [SSHHost] {
        guard !enabledHosts.isEmpty else { return [] }
        let enabledLowercased = Set(enabledHosts.map { $0.lowercased() })
        return hostResolver.resolvedHosts().filter { enabledLowercased.contains($0.alias.lowercased()) }
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
