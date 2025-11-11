import Foundation

/// Service responsible for background enrichment of session summaries
@MainActor
final class SessionEnrichmentService {
    private let indexer: SessionIndexer
    private let claudeProvider: ClaudeSessionProvider

    private var enrichmentTask: Task<Void, Never>?
    private var enrichmentSnapshots: [String: Set<String>] = [:]

    var isEnriching = false
    var enrichmentProgress: Int = 0
    var enrichmentTotal: Int = 0

    init(indexer: SessionIndexer, claudeProvider: ClaudeSessionProvider) {
        self.indexer = indexer
        self.claudeProvider = claudeProvider
    }

    func startEnrichment(
        sessions: [SessionSummary],
        cacheKey: String,
        notesSnapshot: [String: SessionNote],
        onUpdate: @escaping ([SessionSummary]) -> Void
    ) {
        enrichmentTask?.cancel()

        let currentIDs = Set(sessions.map(\.id))
        if let cached = enrichmentSnapshots[cacheKey], cached == currentIDs {
            isEnriching = false
            enrichmentProgress = 0
            enrichmentTotal = 0
            return
        }

        if sessions.isEmpty {
            isEnriching = false
            enrichmentProgress = 0
            enrichmentTotal = 0
            enrichmentSnapshots[cacheKey] = currentIDs
            return
        }

        enrichmentTask = Task { [weak self] in
            guard let self else { return }

            await MainActor.run {
                self.isEnriching = true
                self.enrichmentProgress = 0
                self.enrichmentTotal = sessions.count
            }

            let concurrency = max(2, ProcessInfo.processInfo.processorCount / 2)
            try? await withThrowingTaskGroup(of: (String, SessionSummary)?.self) { group in
                var iterator = sessions.makeIterator()
                var processedCount = 0

                func addNext(_ n: Int) {
                    for _ in 0..<n {
                        guard let s = iterator.next() else { return }
                        group.addTask { [weak self] in
                            guard let self else { return nil }
                            if s.source.baseKind == .claude {
                                if let enriched = await self.claudeProvider.enrich(summary: s) {
                                    return (s.id, enriched)
                                }
                                return (s.id, s)
                            } else if let enriched = try await self.indexer.enrich(url: s.fileURL) {
                                return (s.id, enriched)
                            }
                            return (s.id, s)
                        }
                    }
                }

                addNext(concurrency)
                var updatesBuffer: [(String, SessionSummary)] = []
                var lastFlushTime = ContinuousClock.now

                func flush() async {
                    guard !updatesBuffer.isEmpty else { return }
                    var enrichedSessions = sessions
                    var map = Dictionary(uniqueKeysWithValues: enrichedSessions.map { ($0.id, $0) })
                    for (id, item) in updatesBuffer {
                        var enriched = item
                        if let note = notesSnapshot[id] {
                            enriched.userTitle = note.title
                            enriched.userComment = note.comment
                        }
                        map[id] = enriched
                    }
                    let newEnrichedSessions = Array(map.values)
                    enrichedSessions = newEnrichedSessions
                    await MainActor.run {
                        onUpdate(newEnrichedSessions)
                    }
                    updatesBuffer.removeAll(keepingCapacity: true)
                    lastFlushTime = ContinuousClock.now
                }

                while let result = try await group.next() {
                    if let (_, enriched) = result {
                        updatesBuffer.append((enriched.id, enriched))
                        processedCount += 1

                        await MainActor.run {
                            self.enrichmentProgress = processedCount
                        }

                        let now = ContinuousClock.now
                        let elapsed = lastFlushTime.duration(to: now)
                        if updatesBuffer.count >= 50 || elapsed.components.seconds >= 1 {
                            await flush()
                        }
                    }
                    addNext(1)
                }
                await flush()

                await MainActor.run {
                    self.isEnriching = false
                    self.enrichmentProgress = 0
                    self.enrichmentTotal = 0
                    self.enrichmentSnapshots[cacheKey] = currentIDs
                }
            }
        }
    }

    func cancel() {
        enrichmentTask?.cancel()
        enrichmentTask = nil
        isEnriching = false
    }

    func invalidateCache(for key: String) {
        enrichmentSnapshots.removeValue(forKey: key)
    }

    func clearAllCaches() {
        enrichmentSnapshots.removeAll()
    }
}
