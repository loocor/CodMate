import Foundation

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sections: [SessionDaySection] = []
    @Published var searchText: String = "" {
        didSet { scheduleFulltextSearchIfNeeded() }
    }
    @Published var sortOrder: SessionSortOrder = .mostRecent {
        didSet { applyFilters() }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var navigationSelection: SessionNavigationItem { didSet { applyFilters() } }
    @Published var dateDimension: DateDimension = .updated { didSet { applyFilters() } }
    let preferences: SessionPreferencesStore

    private let indexer: SessionIndexer
    private let actions: SessionActions
    private var allSessions: [SessionSummary] = []
    private var fulltextMatches: Set<String> = [] // SessionSummary.id set
    private var fulltextTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    @Published var globalSessionCount: Int = 0
    @Published private(set) var pathTreeRootPublished: PathTreeNode?
    private var monthCountsCache: [String: [Int: Int]] = [:] // key: "dim|yyyy-MM"

    init(
        preferences: SessionPreferencesStore,
        indexer: SessionIndexer = SessionIndexer(),
        actions: SessionActions = SessionActions()
    ) {
        self.preferences = preferences
        self.indexer = indexer
        self.actions = actions
        
        // 默认选中今天的日期
        let today = Calendar.current.startOfDay(for: Date())
        self.navigationSelection = .calendarDay(today)
    }

    func refreshSessions() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let scope = currentScope()
            let sessions = try await indexer.refreshSessions(root: preferences.sessionsRoot, scope: scope)
            allSessions = sessions
            await computeCalendarCaches()
            applyFilters()
            startBackgroundEnrichment()
            Task { await self.refreshGlobalCount() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume(session: SessionSummary) async -> Result<ProcessResult, Error> {
        do {
            let result = try await actions.resume(session: session, executableURL: preferences.codexExecutableURL)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    func reveal(session: SessionSummary) {
        actions.revealInFinder(session: session)
    }

    func delete(summaries: [SessionSummary]) async {
        do {
            try actions.delete(summaries: summaries)
            for summary in summaries {
                await indexer.invalidate(url: summary.fileURL)
            }
            await refreshSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSessionsRoot(to newURL: URL) async {
        guard newURL != preferences.sessionsRoot else { return }
        preferences.sessionsRoot = newURL
        await indexer.invalidateAll()
        await refreshSessions()
    }

    func updateExecutablePath(to newURL: URL) {
        preferences.codexExecutableURL = newURL
    }

    var totalSessionCount: Int {
        globalSessionCount
    }

    // Expose data for navigation helpers
    func calendarCounts(for monthStart: Date, dimension: DateDimension) -> [Int: Int] {
        let key = cacheKey(monthStart, dimension)
        if let cached = monthCountsCache[key] { return cached }
        Task { [monthStart, dimension] in
            let counts = await indexer.computeCalendarCounts(root: preferences.sessionsRoot, monthStart: monthStart, dimension: dimension)
            await MainActor.run {
                self.monthCountsCache[self.cacheKey(monthStart, dimension)] = counts
                self.objectWillChange.send()
            }
        }
        return [:]
    }

    var pathTreeRoot: PathTreeNode? { pathTreeRootPublished }

    func ensurePathTree() {
        if pathTreeRootPublished != nil { return }
        Task {
            let counts = await indexer.collectCWDCounts(root: preferences.sessionsRoot)
            let tree = counts.buildPathTreeFromCounts()
            await MainActor.run { self.pathTreeRootPublished = tree }
        }
    }

    private func applyFilters() {
        guard !allSessions.isEmpty else {
            sections = []
            return
        }

        var filtered = allSessions
        switch navigationSelection {
        case .allSessions:
            break
        case let .calendarDay(day):
            filtered = filtered.filter { sess in
                let cal = Calendar.current
                switch dateDimension {
                case .created:
                    return cal.isDate(sess.startedAt, inSameDayAs: day)
                case .updated:
                    if let end = sess.lastUpdatedAt { return cal.isDate(end, inSameDayAs: day) }
                    return cal.isDate(sess.startedAt, inSameDayAs: day)
                }
            }
        case let .pathPrefix(prefix):
            filtered = filtered.filter { $0.cwd.hasPrefix(prefix) }
        }

        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            filtered = filtered.filter { summary in
                summary.matches(search: term) || fulltextMatches.contains(summary.id)
            }
        }
        filtered = sortOrder.sort(filtered)

        sections = Self.groupSessions(filtered)
    }

    private static func groupSessions(_ sessions: [SessionSummary]) -> [SessionDaySection] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var grouped: [Date: [SessionSummary]] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            grouped[day, default: []].append(session)
        }

        return grouped
            .sorted(by: { $0.key > $1.key })
            .map { day, sessions in
                let totalDuration = sessions.reduce(into: 0.0) { $0 += $1.duration }
                let totalEvents = sessions.reduce(0) { $0 + $1.eventCount }
                let title: String
                if calendar.isDateInToday(day) {
                    title = "Today"
                } else if calendar.isDateInYesterday(day) {
                    title = "Yesterday"
                } else {
                    title = formatter.string(from: day)
                }
                return SessionDaySection(
                    id: day,
                    title: title,
                    totalDuration: totalDuration,
                    totalEvents: totalEvents,
                    sessions: sessions
                )
            }
    }

    // MARK: - Fulltext search

    private func scheduleFulltextSearchIfNeeded() {
        applyFilters() // still update with metadata-only matches quickly
        fulltextTask?.cancel()
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            fulltextMatches.removeAll()
            return
        }
        fulltextTask = Task { [allSessions] in
            // naive full-scan
            var matched = Set<String>()
            for s in allSessions {
                if Task.isCancelled { return }
                if await indexer.fileContains(url: s.fileURL, term: term) {
                    matched.insert(s.id)
                }
            }
            await MainActor.run {
                self.fulltextMatches = matched
                self.applyFilters()
            }
        }
    }

    // MARK: - Calendar caches (placeholder for future optimization)
    private func computeCalendarCaches() async { }

    // MARK: - Background enrichment
    private func startBackgroundEnrichment() {
        enrichmentTask?.cancel()
        let sessions = allSessions // snapshot
        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            let concurrency = max(2, ProcessInfo.processInfo.processorCount / 2)
            try? await withThrowingTaskGroup(of: (String, SessionSummary)?.self) { group in
                var iterator = sessions.makeIterator()
                func addNext(_ n: Int) {
                    for _ in 0..<n {
                        guard let s = iterator.next() else { return }
                        group.addTask { [weak self] in
                            guard let self else { return nil }
                            if let enriched = try await self.indexer.enrich(url: s.fileURL) {
                                return (s.id, enriched)
                            }
                            return nil
                        }
                    }
                }
                addNext(concurrency)
                var updatesBuffer: [(String, SessionSummary)] = []
                func flush() async {
                    guard !updatesBuffer.isEmpty else { return }
                    await MainActor.run {
                        var map = Dictionary(uniqueKeysWithValues: self.allSessions.map { ($0.id, $0) })
                        for (id, item) in updatesBuffer { map[id] = item }
                        self.allSessions = Array(map.values)
                        self.applyFilters()
                    }
                    updatesBuffer.removeAll(keepingCapacity: true)
                }
                while let result = try await group.next() {
                    if let (id, enriched) = result {
                        updatesBuffer.append((id, enriched))
                        if updatesBuffer.count >= 10 { await flush() }
                    }
                    addNext(1)
                }
                await flush()
            }
        }
    }

    private func currentScope() -> SessionLoadScope {
        switch navigationSelection {
        case .allSessions:
            return .today
        case let .calendarDay(day):
            return .day(day)
        case .pathPrefix:
            return .today
        }
    }
}

extension SessionListViewModel {
    func refreshGlobalCount() async {
        let count = await indexer.countAllSessions(root: preferences.sessionsRoot)
        await MainActor.run { self.globalSessionCount = count }
    }
}

private extension SessionListViewModel {
    func cacheKey(_ monthStart: Date, _ dimension: DateDimension) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM"; return dimension.rawValue + "|" + df.string(from: monthStart)
    }
}
