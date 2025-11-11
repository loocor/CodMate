import AppKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sections: [SessionDaySection] = []
    @Published var searchText: String = "" {
        didSet { scheduleFulltextSearchIfNeeded() }
    }
    @Published var sortOrder: SessionSortOrder = .mostRecent {
        didSet { scheduleFiltersUpdate() }
    }
    @Published var isLoading = false
    @Published var isEnriching = false
    @Published var enrichmentProgress: Int = 0
    @Published var enrichmentTotal: Int = 0
    @Published var errorMessage: String?

    // Title/Comment quick search for the middle list only
    @Published var quickSearchText: String = "" {
        didSet { scheduleFiltersUpdate() }
    }

    // New filter state: supports combined filters
    @Published var selectedPath: String? = nil {
        didSet {
            guard !suppressFilterNotifications, oldValue != selectedPath else { return }
            scheduleFiltersUpdate()
            scheduleFilterRefresh(force: false)
        }
    }
    @Published var selectedDay: Date? = nil {
        didSet {
            guard !suppressFilterNotifications, oldValue != selectedDay else { return }
            invalidateVisibleCountCache()
            scheduleFilterRefresh(force: true)
        }
    }
    @Published var dateDimension: DateDimension = .updated {
        didSet {
            guard !suppressFilterNotifications, oldValue != dateDimension else { return }
            invalidateVisibleCountCache()
            invalidateCalendarCaches()
            enrichmentSnapshots.removeAll()
            if dateDimension == .updated {
                for day in selectedDays {
                    requestCoverageIfNeeded(for: day)
                }
                if let day = selectedDay {
                    requestCoverageIfNeeded(for: day)
                }
            }
            scheduleFiltersUpdate()
            scheduleFilterRefresh(force: true)
        }
    }
    // Multiple day selection support (normalized to startOfDay)
    @Published var selectedDays: Set<Date> = [] {
        didSet {
            guard !suppressFilterNotifications else { return }
            if dateDimension == .updated {
                for day in selectedDays {
                    requestCoverageIfNeeded(for: day)
                }
            }
            invalidateVisibleCountCache()
            scheduleFilterRefresh(force: true)
        }
    }
    @Published var sidebarMonthStart: Date = SessionListViewModel.normalizeMonthStart(Date())

    let preferences: SessionPreferencesStore

    private let indexer: SessionIndexer
    let actions: SessionActions
    var allSessions: [SessionSummary] = [] {
        didSet {
            invalidateVisibleCountCache()
            invalidateCalendarCaches()
            pruneDayCache()
            pruneCoverageCache()
            for session in allSessions {
                _ = dayIndex(for: session)
            }
            // Incremental path tree update based on session cwd diffs
            let newCounts = cwdCounts(for: allSessions)
            let oldCounts = lastPathCounts
            lastPathCounts = newCounts
            pathTreeRefreshTask?.cancel()
            let delta = diffCounts(old: oldCounts, new: newCounts)
            if !delta.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    if let updated = await self.pathTreeStore.applyDelta(delta) {
                        await MainActor.run { self.pathTreeRootPublished = updated }
                    } else {
                        // Fallback to full snapshot rebuild when prefix changes or structure requires it
                        let rebuilt = await self.pathTreeStore.applySnapshot(counts: newCounts)
                        await MainActor.run { self.pathTreeRootPublished = rebuilt }
                    }
                }
            }
            scheduleToolMetricsRefresh()
        }
    }
    private var fulltextMatches: Set<String> = []  // SessionSummary.id set
    private var fulltextTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    var notesStore: SessionNotesStore
    var notesSnapshot: [String: SessionNote] = [:]
    private var canonicalCwdCache: [String: String] = [:]
    private let ripgrepStore = SessionRipgrepStore()
    private var coverageLoadTasks: [String: Task<Void, Never>] = [:]
    private var pendingCoverageMonths: Set<String> = []
    private var toolMetricsTask: Task<Void, Never>?
    private var pendingToolMetricsRefresh = false
    struct SessionDayIndex: Equatable {
        let created: Date
        let updated: Date
        let createdMonthKey: String
        let updatedMonthKey: String
        let createdDay: Int
        let updatedDay: Int
    }
    struct SessionMonthCoverageKey: Hashable, Sendable {
        let sessionID: String
        let monthKey: String
    }
    struct DaySelectionDescriptor: Hashable, Sendable {
        let date: Date
        let monthKey: String
        let day: Int
    }
    private var sessionDayCache: [String: SessionDayIndex] = [:]
    var updatedMonthCoverage: [SessionMonthCoverageKey: Set<Int>] = [:]
    private var directoryMonitor: DirectoryMonitor?
    private var claudeDirectoryMonitor: DirectoryMonitor?
    private var claudeProjectMonitor: DirectoryMonitor?
    private var directoryRefreshTask: Task<Void, Never>?
    private var enrichmentSnapshots: [String: Set<String>] = [:]
    private var suppressFilterNotifications = false
    private var scheduledFilterRefresh: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var filterDebounceTask: Task<Void, Never>?
    private var filterGeneration: UInt64 = 0
    struct VisibleCountKey: Equatable {
        var dimension: DateDimension
        var selectedDay: Date?
        var selectedDays: Set<Date>
        var sessionCount: Int
    }
    var cachedVisibleCount: (key: VisibleCountKey, value: Int)?
    struct ProjectVisibleKey: Equatable {
        var dimension: DateDimension
        var selectedDay: Date?
        var selectedDays: Set<Date>
        var sessionCount: Int
        var membershipVersion: UInt64
    }
    var cachedProjectVisibleCounts: (key: ProjectVisibleKey, value: [String: Int])?
    private var groupedSectionsCache: GroupedSectionsCache?
    struct GroupSessionsKey: Equatable {
        var dimension: DateDimension
        var sortOrder: SessionSortOrder
    }
    struct GroupSessionsDigest: Equatable {
        var count: Int
        var firstId: String?
        var lastId: String?
        var hashValue: Int
    }
    struct GroupedSectionsCache {
        var key: GroupSessionsKey
        var digest: GroupSessionsDigest
        var sections: [SessionDaySection]
    }
    private var codexUsageTask: Task<Void, Never>?
    private var claudeUsageTask: Task<Void, Never>?
    private var pathTreeRefreshTask: Task<Void, Never>?
    private var calendarRefreshTasks: [String: Task<Void, Never>] = [:]
    private let pathTreeStore = PathTreeStore()
    private var lastPathCounts: [String: Int] = [:]
    private let sidebarStatsDebounceNanoseconds: UInt64 = 150_000_000
    private let filterDebounceNanoseconds: UInt64 = 15_000_000
    private var cachedCalendar = Calendar.current
    private var pendingViewUpdate = false
    static let monthFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return df
    }()
    private var currentMonthKey: String?
    private var currentMonthDimension: DateDimension = .updated
    // Quick pulse (cheap file mtime scan) state
    private var quickPulseTask: Task<Void, Never>?
    private var lastQuickPulseAt: Date = .distantPast
    private var fileMTimeCache: [String: Date] = [:]  // session.id -> mtime
    private var lastDisplayedDigest: Int = 0
    @Published var editingSession: SessionSummary? = nil
    @Published var editTitle: String = ""
    @Published var editComment: String = ""
    @Published var globalSessionCount: Int = 0
    @Published private(set) var pathTreeRootPublished: PathTreeNode?
    @Published private var monthCountsCache: [String: [Int: Int]] = [:]  // key: "dim|yyyy-MM"
    @Published private(set) var codexUsageStatus: CodexUsageStatus?
    @Published private(set) var usageSnapshots: [UsageProviderKind: UsageProviderSnapshot] = [:]
    // Live activity indicators
    @Published private(set) var activeUpdatingIDs: Set<String> = []
    @Published private(set) var awaitingFollowupIDs: Set<String> = []

    // Persist Review (Git Changes) panel UI state per session so toggling
    // between Conversation, Terminal and Review preserves context.
    @Published var reviewPanelStates: [String: ReviewPanelState] = [:]

    // Auto-assign: pending intents created when user clicks New
    struct PendingAssignIntent: Identifiable, Sendable, Hashable {
        let id = UUID()
        let projectId: String
        let expectedCwd: String  // canonical path
        let t0: Date
        struct Hints: Sendable, Hashable {
            var model: String?
            var sandbox: String?
            var approval: String?
        }
        let hints: Hints
    }
    var pendingAssignIntents: [PendingAssignIntent] = []
    var intentsCleanupTask: Task<Void, Never>?

    // Targeted incremental refresh hint, set when user triggers New
    struct PendingIncrementalRefreshHint {
        enum Kind { case codexDay(Date), claudeProject(String) }
        let kind: Kind
        let expiresAt: Date
    }
    private var pendingIncrementalHint: PendingIncrementalRefreshHint? = nil

    // Projects
    let configService = CodexConfigService()
    var projectsStore: ProjectsStore
    let claudeProvider = ClaudeSessionProvider()
    private let claudeUsageClient = ClaudeUsageAPIClient()
    @Published var projects: [Project] = []
    var projectCounts: [String: Int] = [:]
    var projectMemberships: [String: String] = [:]
    var projectMembershipsVersion: UInt64 = 0
    @Published var selectedProjectIDs: Set<String> = [] {
        didSet {
            guard !suppressFilterNotifications, oldValue != selectedProjectIDs else { return }
            if !selectedProjectIDs.isEmpty { selectedPath = nil }
            invalidateProjectVisibleCountsCache()
            scheduleFiltersUpdate()
        }
    }
    // Sidebar → Project-level New request when using embedded terminal
    @Published var pendingEmbeddedProjectNew: Project? = nil

    private func pruneDayCache() {
        guard !sessionDayCache.isEmpty else { return }
        let ids = Set(allSessions.map(\.id))
        sessionDayCache = sessionDayCache.filter { ids.contains($0.key) }
    }

    private func pruneCoverageCache() {
        guard !updatedMonthCoverage.isEmpty else { return }
        let ids = Set(allSessions.map(\.id))
        updatedMonthCoverage = updatedMonthCoverage.filter { ids.contains($0.key.sessionID) }
    }

    private func invalidateVisibleCountCache() {
        cachedVisibleCount = nil
        invalidateProjectVisibleCountsCache()
    }

    func invalidateProjectVisibleCountsCache() {
        cachedProjectVisibleCounts = nil
    }

    private func scheduleViewUpdate() {
        if pendingViewUpdate { return }
        pendingViewUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.pendingViewUpdate = false
        }
    }

    private func scheduleApplyFilters() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyFilters()
        }
    }

    func setProjectMemberships(_ memberships: [String: String]) {
        projectMemberships = memberships
        projectMembershipsVersion &+= 1
        invalidateProjectVisibleCountsCache()
    }

    func monthKey(for date: Date) -> String {
        Self.monthFormatter.string(from: date)
    }

    private static func formattedMonthKey(year: Int, month: Int) -> String {
        return String(format: "%04d-%02d", year, month)
    }

    static func makeDayDescriptors(selectedDays: Set<Date>, singleDay: Date?) -> [DaySelectionDescriptor] {
        let calendar = Calendar.current
        let targets: [Date]
        if !selectedDays.isEmpty {
            targets = Array(selectedDays)
        } else if let single = singleDay {
            targets = [single]
        } else {
            targets = []
        }
        return targets.map { date in
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            let monthKey = formattedMonthKey(year: comps.year ?? 0, month: comps.month ?? 0)
            return DaySelectionDescriptor(date: date, monthKey: monthKey, day: comps.day ?? 0)
        }
    }

    func dayIndex(for session: SessionSummary) -> SessionDayIndex {
        let index = buildDayIndex(for: session)
        if let cached = sessionDayCache[session.id], cached == index {
            return cached
        }
        sessionDayCache[session.id] = index
        return index
    }

    private func buildDayIndex(for session: SessionSummary) -> SessionDayIndex {
        let created = cachedCalendar.startOfDay(for: session.startedAt)
        let updatedSource = session.lastUpdatedAt ?? session.startedAt
        let updated = cachedCalendar.startOfDay(for: updatedSource)
        let createdKey = monthKey(for: created)
        let updatedKey = monthKey(for: updated)
        let createdDay = cachedCalendar.component(.day, from: created)
        let updatedDay = cachedCalendar.component(.day, from: updated)
        return SessionDayIndex(
            created: created,
            updated: updated,
            createdMonthKey: createdKey,
            updatedMonthKey: updatedKey,
            createdDay: createdDay,
            updatedDay: updatedDay)
    }

    func dayStart(for session: SessionSummary, dimension: DateDimension) -> Date {
        let index = dayIndex(for: session)
        switch dimension {
        case .created: return index.created
        case .updated: return index.updated
        }
    }

    func matchesDayFilters(_ session: SessionSummary, descriptors: [DaySelectionDescriptor]) -> Bool {
        guard !descriptors.isEmpty else { return true }
        let bucket = dayIndex(for: session)
        return Self.matchesDayDescriptors(
            summary: session,
            bucket: bucket,
            descriptors: descriptors,
            dimension: dateDimension,
            coverage: updatedMonthCoverage,
            calendar: cachedCalendar
        )
    }

    static func normalizeMonthStart(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    func setSidebarMonthStart(_ date: Date) {
        let normalized = Self.normalizeMonthStart(date)
        if normalized == sidebarMonthStart { return }
        sidebarMonthStart = normalized
        _ = calendarCounts(for: normalized, dimension: dateDimension)

        // In Created mode, changing the viewed month requires reloading data
        // since we only load the current month's sessions for efficiency
        if dateDimension == .created {
            scheduleFilterRefresh(force: true)
        }
    }

    var sidebarStateSnapshot: SidebarState {
        SidebarState(
            totalSessionCount: totalSessionCount,
            isLoading: isLoading,
            visibleAllCount: visibleAllCountForDateScope(),
            selectedProjectIDs: selectedProjectIDs,
            selectedDay: selectedDay,
            selectedDays: selectedDays,
            dateDimension: dateDimension,
            monthStart: sidebarMonthStart,
            calendarCounts: calendarCounts(for: sidebarMonthStart, dimension: dateDimension),
            enabledProjectDays: calendarEnabledDaysForSelectedProject(
                monthStart: sidebarMonthStart,
                dimension: dateDimension
            )
        )
    }

    init(
        preferences: SessionPreferencesStore,
        indexer: SessionIndexer = SessionIndexer(),
        actions: SessionActions = SessionActions()
    ) {
        self.preferences = preferences
        self.indexer = indexer
        self.actions = actions
        self.notesStore = SessionNotesStore(notesRoot: preferences.notesRoot)
        // Initialize ProjectsStore using configurable projectsRoot (defaults to ~/.codmate/projects)
        let pr = preferences.projectsRoot
        let p = ProjectsStore.Paths(
            root: pr,
            metadataDir: pr.appendingPathComponent("metadata", isDirectory: true),
            membershipsURL: pr.appendingPathComponent("memberships.json", isDirectory: false)
        )
        self.projectsStore = ProjectsStore(paths: p)
        // Default at startup: All Sessions (no directory filter) + today
        let today = Date()
        let cal = Calendar.current
        suppressFilterNotifications = true
        let start = cal.startOfDay(for: today)
        self.selectedDay = start
        self.selectedDays = [start]
        suppressFilterNotifications = false
        configureDirectoryMonitor()
        configureClaudeDirectoryMonitor()
        Task { await loadProjects() }
        // Observe agent completion notifications to surface in list
        NotificationCenter.default.addObserver(
            forName: .codMateAgentCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["sessionID"] as? String else { return }
            Task { @MainActor in
                self?.awaitingFollowupIDs.insert(id)
            }
        }
        startActivityPruneTicker()
        startIntentsCleanupTicker()
        usageSnapshots[.claude] = UsageProviderSnapshot.placeholder(
            .claude,
            message: "Claude Code usage parsing will arrive in a future update."
        )
    }

    // Immediate apply from UI (e.g., pressing Return in search field)
    func immediateApplyQuickSearch(_ text: String) { quickSearchText = text }

    private var activeRefreshToken = UUID()

    func refreshSessions(force: Bool = false) async {
        scheduledFilterRefresh?.cancel()
        scheduledFilterRefresh = nil
        let token = UUID()
        activeRefreshToken = token
        isLoading = true
        if force {
            invalidateEnrichmentCache(for: selectedDay)
        }
        defer {
            if token == activeRefreshToken {
                isLoading = false
            }
        }

        // Ensure we have access to the sessions directory in sandbox mode
        await ensureSessionsAccess()

        do {
            let scope = currentScope()
            async let codexTask = indexer.refreshSessions(
                root: preferences.sessionsRoot, scope: scope)
            async let claudeTask = claudeProvider.sessions(scope: scope)

            var sessions = try await codexTask
            let claudeSessions = await claudeTask
            if !claudeSessions.isEmpty {
                let existingIDs = Set(sessions.map(\.id))
                let filteredClaude = claudeSessions.filter { !existingIDs.contains($0.id) }
                sessions.append(contentsOf: filteredClaude)
            }
            if !sessions.isEmpty {
                var seen: Set<String> = []
                var unique: [SessionSummary] = []
                unique.reserveCapacity(sessions.count)
                for summary in sessions {
                    if seen.insert(summary.id).inserted {
                        unique.append(summary)
                    }
                }
                sessions = unique
            }

            guard token == activeRefreshToken else { return }
            let previousIDs = Set(allSessions.map { $0.id })
            let notes = await notesStore.all()
            notesSnapshot = notes
            // Refresh projects/memberships snapshot and import legacy mappings if needed
            Task { @MainActor in
                await self.loadProjects()
                await self.importMembershipsFromNotesIfNeeded(notes: notes)
            }
            apply(notes: notes, to: &sessions)
            // Auto-assign on newly appeared sessions matched with pending intents
            let newlyAppeared = sessions.filter { !previousIDs.contains($0.id) }
            if !newlyAppeared.isEmpty {
                for s in newlyAppeared { self.handleAutoAssignIfMatches(s) }
            }
            registerActivityHeartbeat(previous: allSessions, current: sessions)
            allSessions = sessions  // didSet will call invalidateCalendarCaches()
            recomputeProjectCounts()
            rebuildCanonicalCwdCache()
            await computeCalendarCaches()
            scheduleFiltersUpdate()
            startBackgroundEnrichment()
            currentMonthDimension = dateDimension
            currentMonthKey = monthKey(for: selectedDay, dimension: dateDimension)
            Task { await self.refreshGlobalCount() }
            refreshCodexUsageStatus()
            refreshClaudeUsageStatus()
            schedulePathTreeRefresh()
        } catch {
            if token == activeRefreshToken {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func registerActivityHeartbeat(previous: [SessionSummary], current: [SessionSummary]) {
        // Map previous lastUpdated for quick lookup
        var prevMap: [String: Date] = [:]
        for s in previous { if let t = s.lastUpdatedAt { prevMap[s.id] = t } }
        let now = Date()
        for s in current {
            guard let newT = s.lastUpdatedAt else { continue }
            if let oldT = prevMap[s.id], newT > oldT {
                activityHeartbeat[s.id] = now
            }
        }
        recomputeActiveUpdatingIDs()
    }

    private var activityHeartbeat: [String: Date] = [:]
    private var activityPruneTask: Task<Void, Never>?
    private func startActivityPruneTicker() {
        activityPruneTask?.cancel()
        activityPruneTask = Task { [weak self] in
            while !(Task.isCancelled) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.recomputeActiveUpdatingIDs() }
            }
        }
    }

    private func startIntentsCleanupTicker() {
        intentsCleanupTask?.cancel()
        intentsCleanupTask = Task { [weak self] in
            while !(Task.isCancelled) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.pruneExpiredIntents() }
            }
        }
    }

    private func recomputeActiveUpdatingIDs() {
        let cutoff = Date().addingTimeInterval(-3.0)
        activeUpdatingIDs = Set(activityHeartbeat.filter { $0.value > cutoff }.keys)
    }

    func isActivelyUpdating(_ id: String) -> Bool { activeUpdatingIDs.contains(id) }
    func isAwaitingFollowup(_ id: String) -> Bool { awaitingFollowupIDs.contains(id) }

    func clearAwaitingFollowup(_ id: String) {
        awaitingFollowupIDs.remove(id)
    }

    // Cancel ongoing background tasks (fulltext, enrichment, scheduled refreshes, quick pulses).
    // Useful when a heavy modal/sheet is presented and the UI should stay responsive.
    func cancelHeavyWork() {
        fulltextTask?.cancel()
        fulltextTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        filterDebounceTask?.cancel()
        filterDebounceTask = nil
        scheduledFilterRefresh?.cancel()
        scheduledFilterRefresh = nil
        directoryRefreshTask?.cancel()
        directoryRefreshTask = nil
        quickPulseTask?.cancel()
        quickPulseTask = nil
        codexUsageTask?.cancel()
        codexUsageTask = nil
        pathTreeRefreshTask?.cancel()
        pathTreeRefreshTask = nil
        for task in calendarRefreshTasks.values { task.cancel() }
        calendarRefreshTasks.removeAll()
        isEnriching = false
        isLoading = false
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
            await refreshSessions(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSessionsRoot(to newURL: URL) async {
        guard newURL != preferences.sessionsRoot else { return }
        // Save security-scoped bookmark if sandboxed
        SecurityScopedBookmarks.shared.save(url: newURL, for: .sessionsRoot)
        preferences.sessionsRoot = newURL
        await notesStore.updateRoot(to: preferences.notesRoot)
        await indexer.invalidateAll()
        enrichmentSnapshots.removeAll()
        configureDirectoryMonitor()
        await refreshSessions(force: true)
    }

    func updateNotesRoot(to newURL: URL) async {
        guard newURL != preferences.notesRoot else { return }
        SecurityScopedBookmarks.shared.save(url: newURL, for: .notesRoot)
        preferences.notesRoot = newURL
        await notesStore.updateRoot(to: newURL)
        // Reload notes snapshot and re-apply to current sessions
        let notes = await notesStore.all()
        notesSnapshot = notes
        var sessions = allSessions
        apply(notes: notes, to: &sessions)
        allSessions = sessions
        // Avoid publishing during view updates
        scheduleApplyFilters()
    }

    func updateProjectsRoot(to newURL: URL) async {
        guard newURL != preferences.projectsRoot else { return }
        SecurityScopedBookmarks.shared.save(url: newURL, for: .projectsRoot)
        preferences.projectsRoot = newURL
        let p = ProjectsStore.Paths(
            root: newURL,
            metadataDir: newURL.appendingPathComponent("metadata", isDirectory: true),
            membershipsURL: newURL.appendingPathComponent("memberships.json", isDirectory: false)
        )
        self.projectsStore = ProjectsStore(paths: p)
        await loadProjects()
        // Avoid publishing changes during view update; schedule on next runloop tick
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recomputeProjectCounts()
            self.scheduleApplyFilters()
        }
    }

    // Removed: executable path updates – CLI resolution uses PATH

    var totalSessionCount: Int {
        globalSessionCount
    }

    // Expose data for navigation helpers
    func calendarCounts(for monthStart: Date, dimension: DateDimension) -> [Int: Int] {
        let key = cacheKey(monthStart, dimension)
        if let cached = monthCountsCache[key] { return cached }
        let monthKey = Self.monthFormatter.string(from: monthStart)
        let coverage = dimension == .updated ? monthCoverageMap(for: monthKey) : [:]
        let counts = Self.computeMonthCounts(
            sessions: allSessions,
            monthKey: monthKey,
            dimension: dimension,
            dayIndex: sessionDayCache,
            coverage: coverage)
        // Update cache synchronously to avoid race conditions
        monthCountsCache[key] = counts
        currentMonthKey = key
        currentMonthDimension = dimension
        if dimension == .updated {
            triggerCoverageLoad(for: monthStart, dimension: dimension)
        }
        return counts
    }

    func cacheKey(_ monthStart: Date, _ dimension: DateDimension) -> String {
        return dimension.rawValue + "|" + Self.monthFormatter.string(from: monthStart)
    }

    var pathTreeRoot: PathTreeNode? { pathTreeRootPublished }

    func ensurePathTree() {
        if pathTreeRootPublished != nil { return }
        schedulePathTreeRefresh()
    }

    private func schedulePathTreeRefresh() {
        pathTreeRefreshTask?.cancel()
        pathTreeRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pathTreeRefreshTask = nil }
            let counts = self.cwdCounts(for: self.allSessions)
            self.lastPathCounts = counts
            let tree = await self.pathTreeStore.applySnapshot(counts: counts)
            await MainActor.run { self.pathTreeRootPublished = tree }
        }
    }

    private func cwdCounts(for sessions: [SessionSummary]) -> [String: Int] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(sessions.count)
        for s in sessions { counts[s.cwd, default: 0] += 1 }
        return counts
    }

    private func diffCounts(old: [String: Int], new: [String: Int]) -> [String: Int] {
        var delta: [String: Int] = [:]
        let keys = Set(old.keys).union(new.keys)
        for k in keys {
            let d = (new[k] ?? 0) - (old[k] ?? 0)
            if d != 0 { delta[k] = d }
        }
        return delta
    }

    private func scheduleToolMetricsRefresh() {
        if toolMetricsTask != nil {
            pendingToolMetricsRefresh = true
            return
        }
        guard !allSessions.isEmpty else { return }
        pendingToolMetricsRefresh = false
        let sessions = allSessions
        toolMetricsTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let counts = await self.ripgrepStore.toolInvocationCounts(for: sessions)
            await MainActor.run {
                self.applyToolInvocationOverrides(counts)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.toolMetricsTask = nil
                if self.pendingToolMetricsRefresh {
                    self.pendingToolMetricsRefresh = false
                    self.scheduleToolMetricsRefresh()
                }
            }
        }
    }

    @MainActor
    private func applyToolInvocationOverrides(_ counts: [String: Int]) {
        guard !counts.isEmpty else { return }
        var mutated = false
        for idx in allSessions.indices {
            let id = allSessions[idx].id
            if let value = counts[id], allSessions[idx].toolInvocationCount != value {
                allSessions[idx].toolInvocationCount = value
                mutated = true
            }
        }
        guard mutated else { return }
        scheduleApplyFilters()
    }

    private func scheduleCalendarCountsRefresh(
        monthStart: Date,
        dimension: DateDimension,
        skipDebounce: Bool
    ) {
        // Legacy path removed; kept for compatibility if future disk scans are reintroduced.
        // For now, we compute counts synchronously from in-memory sessions.
        let key = cacheKey(monthStart, dimension)
        calendarRefreshTasks[key]?.cancel()
        if !skipDebounce {
            let delay = sidebarStatsDebounceNanoseconds
            calendarRefreshTasks[key] = Task { [weak self] in
                defer { self?.calendarRefreshTasks.removeValue(forKey: key) }
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func triggerCoverageLoad(for monthStart: Date, dimension: DateDimension) {
        guard dimension == .updated else { return }
        let key = cacheKey(monthStart, dimension)
        if coverageLoadTasks[key] != nil {
            pendingCoverageMonths.insert(key)
            return
        }
        let targets = sessionsIntersecting(monthStart: monthStart)
        guard !targets.isEmpty else { return }
        coverageLoadTasks[key] = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let data = await self.ripgrepStore.dayCoverage(for: monthStart, sessions: targets)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.coverageLoadTasks[key]?.cancel()
                self.coverageLoadTasks.removeValue(forKey: key)
                if data.isEmpty {
                    if !targets.isEmpty {
                        self.pendingCoverageMonths.insert(key)
                        self.rebuildMonthCounts(for: monthStart, dimension: dimension)
                    }
                } else {
                    self.applyCoverage(monthStart: monthStart, coverage: data)
                }
                if self.pendingCoverageMonths.remove(key) != nil {
                    self.triggerCoverageLoad(for: monthStart, dimension: dimension)
                }
            }
        }
    }

    private func requestCoverageIfNeeded(for day: Date) {
        guard dateDimension == .updated else { return }
        let monthStart = Self.normalizeMonthStart(day)
        triggerCoverageLoad(for: monthStart, dimension: .updated)
    }

    private func sessionsIntersecting(monthStart: Date) -> [SessionSummary] {
        let calendar = Calendar.current
        guard let monthEnd = calendar.date(byAdding: DateComponents(month: 1), to: monthStart) else {
            return []
        }
        return allSessions.filter { summary in
            let start = summary.startedAt
            let end = summary.lastUpdatedAt ?? summary.startedAt
            return end >= monthStart && start < monthEnd
        }
    }

    @MainActor
    private func applyCoverage(monthStart: Date, coverage: [String: Set<Int>]) {
        guard !coverage.isEmpty else {
            rebuildMonthCounts(for: monthStart, dimension: .updated)
            return
        }
        let monthKey = monthKey(for: monthStart)
        var changed = false
        let validIDs = Set(allSessions.map(\.id))
        for (sessionID, days) in coverage {
            guard validIDs.contains(sessionID) else { continue }
            let key = SessionMonthCoverageKey(sessionID: sessionID, monthKey: monthKey)
            if updatedMonthCoverage[key] != days {
                updatedMonthCoverage[key] = days
                changed = true
            }
        }
        if changed {
            invalidateVisibleCountCache()
        }
        rebuildMonthCounts(for: monthStart, dimension: .updated)
        if changed {
            scheduleApplyFilters()
        } else {
            scheduleViewUpdate()
        }
    }

    private func monthCoverageMap(for monthKey: String) -> [String: Set<Int>] {
        var map: [String: Set<Int>] = [:]
        for (key, days) in updatedMonthCoverage where key.monthKey == monthKey {
            map[key.sessionID] = days
        }
        return map
    }

    private func rebuildMonthCounts(for monthStart: Date, dimension: DateDimension) {
        let key = cacheKey(monthStart, dimension)
        let monthKey = monthKey(for: monthStart)
        let coverage = dimension == .updated ? monthCoverageMap(for: monthKey) : [:]
        let counts = Self.computeMonthCounts(
            sessions: allSessions,
            monthKey: monthKey,
            dimension: dimension,
            dayIndex: sessionDayCache,
            coverage: coverage)
        monthCountsCache[key] = counts
        currentMonthKey = key
        currentMonthDimension = dimension
        scheduleViewUpdate()
    }

    // MARK: - Filter state management

    func setSelectedPath(_ path: String?) {
        if selectedPath == path { return }
        selectedPath = path
    }

    func setSelectedDay(_ day: Date?) {
        let normalized = day.map { Calendar.current.startOfDay(for: $0) }
        if selectedDay == normalized { return }
        suppressFilterNotifications = true
        selectedDay = normalized
        if let d = normalized { selectedDays = [d] } else { selectedDays.removeAll() }

        // In Created mode, when selecting a day, ensure the calendar sidebar shows that month
        // so we only need to load one month's data
        if dateDimension == .created, let d = normalized {
            let newMonthStart = Self.normalizeMonthStart(d)
            if newMonthStart != sidebarMonthStart {
                sidebarMonthStart = newMonthStart
            }
        }

        if let d = normalized {
            requestCoverageIfNeeded(for: d)
        }

        suppressFilterNotifications = false
        // Update UI using next-runloop to avoid publishing during view updates
        scheduleApplyFilters()
        // After coordinated update of selectedDay/selectedDays, trigger a refresh once.
        // Use force=true to ensure scope reload
        scheduleFilterRefresh(force: true)
    }

    // Toggle selection for a specific day (Cmd-click behavior)
    func toggleSelectedDay(_ day: Date) {
        let d = Calendar.current.startOfDay(for: day)
        suppressFilterNotifications = true
        if selectedDays.contains(d) {
            selectedDays.remove(d)
        } else {
            selectedDays.insert(d)
        }
        requestCoverageIfNeeded(for: d)
        // Keep single-selection reflected in selectedDay; otherwise nil
        if selectedDays.count == 1, let only = selectedDays.first {
            selectedDay = only
        } else if selectedDays.isEmpty {
            selectedDay = nil
        } else {
            selectedDay = nil
        }
        suppressFilterNotifications = false
        // Update UI using next-runloop to avoid publishing during view updates
        scheduleApplyFilters()
        scheduleFilterRefresh(force: true)
    }

    func clearAllFilters() {
        suppressFilterNotifications = true
        selectedPath = nil
        selectedDay = nil
        selectedProjectIDs.removeAll()
        suppressFilterNotifications = false
        scheduleFilterRefresh(force: true)
        // Keep searchText unchanged to allow consecutive searches
    }

    // Clear only scope filters (directory and project), keep the date filter intact
    func clearScopeFilters() {
        suppressFilterNotifications = true
        selectedPath = nil
        selectedProjectIDs.removeAll()
        suppressFilterNotifications = false
        scheduleFilterRefresh(force: true)
    }

    private func scheduleFiltersUpdate() {
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { [weak self] in
            guard let self else { return }
            if filterDebounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: filterDebounceNanoseconds)
            }
            self.scheduleApplyFilters()
        }
    }

    func applyFilters() {
        filterTask?.cancel()

        guard !allSessions.isEmpty else {
            filterTask = nil
            sections = []
            return
        }

        filterGeneration &+= 1
        let generation = filterGeneration
        let snapshot = makeFilterSnapshot()

        filterTask = Task { [weak self] in
            guard let self else { return }
            let computeTask = Task.detached(priority: .userInitiated) {
                Self.computeFilteredSections(using: snapshot)
            }
            defer { computeTask.cancel() }
            let result = await computeTask.value
            guard !Task.isCancelled else { return }
            guard self.filterGeneration == generation else { return }
            if !result.newCanonicalEntries.isEmpty {
                self.canonicalCwdCache.merge(result.newCanonicalEntries) { _, new in new }
            }
            let sections = self.sectionsUsingCache(
                result.filteredSessions,
                dimension: snapshot.dateDimension,
                sortOrder: snapshot.sortOrder
            )
            self.sections = sections
            self.filterTask = nil
        }
    }

    private func makeFilterSnapshot() -> FilterSnapshot {
        let pathFilter: FilterSnapshot.PathFilter? = {
            guard let path = selectedPath else { return nil }
            let canonical = Self.canonicalPath(path)
            let prefix = canonical == "/" ? "/" : canonical + "/"
            return .init(canonicalPath: canonical, prefix: prefix)
        }()

        let trimmedSearch = quickSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let quickNeedle = trimmedSearch.isEmpty ? nil : trimmedSearch.lowercased()

        let projectFilter: FilterSnapshot.ProjectFilter? = {
            guard !selectedProjectIDs.isEmpty else { return nil }
            var allowedProjects = Set<String>()
            for pid in selectedProjectIDs {
                allowedProjects.insert(pid)
                allowedProjects.formUnion(collectDescendants(of: pid, in: projects))
            }
            let allowedSources = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
                $0[$1.id] = $1.sources
            }
            return .init(
                memberships: projectMemberships,
                allowedProjects: allowedProjects,
                allowedSourcesByProject: allowedSources
            )
        }()

        var dayIndexMap: [String: SessionDayIndex] = [:]
        dayIndexMap.reserveCapacity(allSessions.count)
        for session in allSessions {
            dayIndexMap[session.id] = dayIndex(for: session)
        }
        let dayDescriptors = Self.makeDayDescriptors(
            selectedDays: selectedDays,
            singleDay: selectedDay
        )

        return FilterSnapshot(
            sessions: allSessions,
            pathFilter: pathFilter,
            projectFilter: projectFilter,
            selectedDays: selectedDays,
            singleDay: selectedDay,
            dateDimension: dateDimension,
            quickSearchNeedle: quickNeedle,
            sortOrder: sortOrder,
            canonicalCache: canonicalCwdCache,
            dayIndex: dayIndexMap,
            dayCoverage: updatedMonthCoverage,
            dayDescriptors: dayDescriptors
        )
    }

    nonisolated private static func computeFilteredSections(using snapshot: FilterSnapshot)
        -> FilterComputationResult
    {
        var filtered = snapshot.sessions
        var canonicalCache = snapshot.canonicalCache
        var newCanonicalEntries: [String: String] = [:]

        if let pathFilter = snapshot.pathFilter {
            var matches: [SessionSummary] = []
            matches.reserveCapacity(filtered.count)
            for summary in filtered {
                let canonical: String
                if let cached = canonicalCache[summary.id] {
                    canonical = cached
                } else {
                    let value = Self.canonicalPath(summary.cwd)
                    canonicalCache[summary.id] = value
                    newCanonicalEntries[summary.id] = value
                    canonical = value
                }
                if canonical == pathFilter.canonicalPath || canonical.hasPrefix(pathFilter.prefix) {
                    matches.append(summary)
                }
            }
            filtered = matches
        }

        if let projectFilter = snapshot.projectFilter {
            let memberships = projectFilter.memberships
            let allowedProjects = projectFilter.allowedProjects
            let allowedSources = projectFilter.allowedSourcesByProject
            var matches: [SessionSummary] = []
            matches.reserveCapacity(filtered.count)
            for summary in filtered {
                guard let assigned = memberships[summary.id], allowedProjects.contains(assigned) else {
                    continue
                }
                let allowedSet = allowedSources[assigned] ?? ProjectSessionSource.allSet
                if allowedSet.contains(summary.source.projectSource) {
                    matches.append(summary)
                }
            }
            filtered = matches
        }

        if !snapshot.dayDescriptors.isEmpty {
            let calendar = Calendar.current
            filtered = filtered.filter { summary in
                let bucket = snapshot.dayIndex[summary.id]
                return Self.matchesDayDescriptors(
                    summary: summary,
                    bucket: bucket,
                    descriptors: snapshot.dayDescriptors,
                    dimension: snapshot.dateDimension,
                    coverage: snapshot.dayCoverage,
                    calendar: calendar
                )
            }
        }

        if let needle = snapshot.quickSearchNeedle {
            filtered = filtered.filter { s in
                if s.effectiveTitle.lowercased().contains(needle) { return true }
                if let c = s.userComment?.lowercased(), c.contains(needle) { return true }
                return false
            }
        }

        filtered = snapshot.sortOrder.sort(filtered, dimension: snapshot.dateDimension)

        return FilterComputationResult(
            filteredSessions: filtered,
            newCanonicalEntries: newCanonicalEntries
        )
    }

    nonisolated private static func matchesDayDescriptors(
        summary: SessionSummary,
        bucket: SessionDayIndex?,
        descriptors: [DaySelectionDescriptor],
        dimension: DateDimension,
        coverage: [SessionMonthCoverageKey: Set<Int>],
        calendar: Calendar
    ) -> Bool {
        guard let bucket else { return false }
        for descriptor in descriptors {
            switch dimension {
            case .created:
                if calendar.isDate(bucket.created, inSameDayAs: descriptor.date) {
                    return true
                }
            case .updated:
                let key = SessionMonthCoverageKey(sessionID: summary.id, monthKey: descriptor.monthKey)
                if let days = coverage[key], days.contains(descriptor.day) {
                    return true
                }
                if calendar.isDate(bucket.updated, inSameDayAs: descriptor.date) {
                    return true
                }
            }
        }
        return false
    }

    private func sectionsUsingCache(
        _ sessions: [SessionSummary],
        dimension: DateDimension,
        sortOrder: SessionSortOrder
    ) -> [SessionDaySection] {
        let key = GroupSessionsKey(dimension: dimension, sortOrder: sortOrder)
        let digest = makeGroupSessionsDigest(for: sessions)
        if let cache = groupedSectionsCache, cache.key == key, cache.digest == digest {
            return cache.sections
        }
        let sections = Self.groupSessions(sessions, dimension: dimension)
        groupedSectionsCache = GroupedSectionsCache(key: key, digest: digest, sections: sections)
        return sections
    }

    private func makeGroupSessionsDigest(for sessions: [SessionSummary]) -> GroupSessionsDigest {
        var hasher = Hasher()
        for session in sessions {
            hasher.combine(session.id)
            hasher.combine(session.startedAt.timeIntervalSinceReferenceDate.bitPattern)
            hasher.combine((session.lastUpdatedAt ?? session.startedAt).timeIntervalSinceReferenceDate.bitPattern)
            hasher.combine(session.duration.bitPattern)
            hasher.combine(session.eventCount)
            // Include user-editable fields to invalidate cache when they change
            hasher.combine(session.userTitle)
            hasher.combine(session.userComment)
        }
        return GroupSessionsDigest(
            count: sessions.count,
            firstId: sessions.first?.id,
            lastId: sessions.last?.id,
            hashValue: hasher.finalize()
        )
    }

    nonisolated private static func referenceDate(for session: SessionSummary, dimension: DateDimension)
        -> Date
    {
        switch dimension {
        case .created: return session.startedAt
        case .updated: return session.lastUpdatedAt ?? session.startedAt
        }
    }

    private struct FilterSnapshot: Sendable {
        struct PathFilter: Sendable {
            let canonicalPath: String
            let prefix: String
        }

        struct ProjectFilter: Sendable {
            let memberships: [String: String]
            let allowedProjects: Set<String>
            let allowedSourcesByProject: [String: Set<ProjectSessionSource>]
        }

        let sessions: [SessionSummary]
        let pathFilter: PathFilter?
        let projectFilter: ProjectFilter?
        let selectedDays: Set<Date>
        let singleDay: Date?
        let dateDimension: DateDimension
        let quickSearchNeedle: String?
        let sortOrder: SessionSortOrder
        let canonicalCache: [String: String]
        let dayIndex: [String: SessionDayIndex]
        let dayCoverage: [SessionMonthCoverageKey: Set<Int>]
        let dayDescriptors: [DaySelectionDescriptor]
    }

    private struct FilterComputationResult: Sendable {
        let filteredSessions: [SessionSummary]
        let newCanonicalEntries: [String: String]
    }

    nonisolated private static func groupSessions(_ sessions: [SessionSummary], dimension: DateDimension)
        -> [SessionDaySection]
    {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var grouped: [Date: [SessionSummary]] = [:]
        for session in sessions {
            // Grouping honors the selected calendar dimension:
            // - Created: group by startedAt
            // - Last Updated: group by lastUpdatedAt (fallback to startedAt)
            let referenceDate: Date = {
                switch dimension {
                case .created: return session.startedAt
                case .updated: return session.lastUpdatedAt ?? session.startedAt
                }
            }()
            let day = calendar.startOfDay(for: referenceDate)
            grouped[day, default: []].append(session)
        }

        return
            grouped
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
        scheduleFiltersUpdate()  // update metadata-only matches quickly
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
                self.scheduleApplyFilters()
            }
        }
    }

    // MARK: - Calendar caches (placeholder for future optimization)
    private func computeCalendarCaches() async {}

    // MARK: - Background enrichment
    private func startBackgroundEnrichment() {
        enrichmentTask?.cancel()
        guard let cacheKey = dayCacheKey(for: selectedDay) else {
            // Should not happen; we now return a synthetic key even when day is nil
            isEnriching = false
            enrichmentProgress = 0
            enrichmentTotal = 0
            return
        }

        // When a day is selected, enrich that day's sessions; otherwise enrich currently displayed ones
        let sessions: [SessionSummary]
        if selectedDay != nil {
            sessions = sessionsForCurrentDay()
        } else {
            sessions = sections.flatMap { $0.sessions }
        }
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
                if s.source == .claude {
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
                    await MainActor.run {
                        var map = Dictionary(
                            uniqueKeysWithValues: self.allSessions.map { ($0.id, $0) })
                        for (id, item) in updatesBuffer {
                            var enriched = item
                            if let note = self.notesSnapshot[id] {
                                enriched.userTitle = note.title
                                enriched.userComment = note.comment
                            }
                            map[id] = enriched
                        }
                        self.allSessions = Array(map.values)
                        self.rebuildCanonicalCwdCache()
                        self.scheduleApplyFilters()
                    }
                    updatesBuffer.removeAll(keepingCapacity: true)
                    lastFlushTime = ContinuousClock.now
                }
                while let result = try await group.next() {
                    if let (id, enriched) = result {
                        updatesBuffer.append((id, enriched))
                        processedCount += 1

                        await MainActor.run {
                            self.enrichmentProgress = processedCount
                        }

                        let now = ContinuousClock.now
                        let elapsed = lastFlushTime.duration(to: now)
                        // Flush if buffer is large (50 items) OR enough time passed (1 second)
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

    private func sessionsForCurrentDay() -> [SessionSummary] {
        guard let day = selectedDay else { return [] }
        let calendar = Calendar.current
        let pathFilter = selectedPath.map(Self.canonicalPath)
        return allSessions.filter { summary in
            let matchesDay: Bool = {
                switch dateDimension {
                case .created:
                    return calendar.isDate(summary.startedAt, inSameDayAs: day)
                case .updated:
                    if let end = summary.lastUpdatedAt {
                        return calendar.isDate(end, inSameDayAs: day)
                    }
                    return calendar.isDate(summary.startedAt, inSameDayAs: day)
                }
            }()
            guard matchesDay else { return false }
            guard let path = pathFilter else { return true }
            let canonical = canonicalCwdCache[summary.id] ?? Self.canonicalPath(summary.cwd)
            return canonical == path || canonical.hasPrefix(path + "/")
        }
    }

    private func rebuildCanonicalCwdCache() {
        canonicalCwdCache = Dictionary(
            uniqueKeysWithValues: allSessions.map {
                ($0.id, Self.canonicalPath($0.cwd))
            })
    }

    nonisolated static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }

    private func currentScope() -> SessionLoadScope {
        switch dateDimension {
        case .created:
            // In Created mode, load the month currently being viewed in the calendar sidebar.
            // This ensures calendar stats show correct counts for the visible month.
            // Day filtering for the middle list happens in applyFilters().
            return .month(sidebarMonthStart)
        case .updated:
            // Updated dimension: load everything since updates can cross month boundaries.
            // Files are organized by creation date on disk, so we need all files to compute
            // updated-time stats correctly.
            return .all
        }
    }

    private func configureDirectoryMonitor() {
        directoryMonitor?.cancel()
        directoryRefreshTask?.cancel()
        let root = preferences.sessionsRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            directoryMonitor = nil
            return
        }
        directoryMonitor = DirectoryMonitor(url: root) { [weak self] in
            Task { @MainActor in
                self?.quickPulse()
                self?.scheduleDirectoryRefresh()
            }
        }
    }

    private func configureClaudeDirectoryMonitor() {
        claudeDirectoryMonitor?.cancel()
        // Default Claude projects root: ~/.claude/projects
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else {
            claudeDirectoryMonitor = nil
            return
        }
        claudeDirectoryMonitor = DirectoryMonitor(url: projects) { [weak self] in
            Task { @MainActor in
                // Only perform targeted incremental refresh when we have a matching hint
                if let hint = self?.pendingIncrementalHint, Date() < (hint.expiresAt) {
                    await self?.refreshIncremental(using: hint)
                }
            }
        }
    }

    private func scheduleDirectoryRefresh() {
        directoryRefreshTask?.cancel()
        directoryRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if let hint = self.pendingIncrementalHint, Date() < hint.expiresAt {
                await self.refreshIncremental(using: hint)
            } else {
                self.enrichmentSnapshots.removeAll()
                await self.refreshSessions(force: true)
            }
        }
    }

    private func invalidateEnrichmentCache(for day: Date?) {
        if let key = dayCacheKey(for: day) {
            enrichmentSnapshots.removeValue(forKey: key)
        }
    }

    private func dayCacheKey(for day: Date?) -> String? {
        let pathKey: String = selectedPath.map(Self.canonicalPath) ?? "*"
        if let day {
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = comps.year, let month = comps.month, let dayComponent = comps.day
            else {
                return nil
            }
            return "\(dateDimension.rawValue)|\(year)-\(month)-\(dayComponent)|\(pathKey)"
        }
        // No day selected (All): use synthetic cache key to avoid re-enriching repeatedly
        return "\(dateDimension.rawValue)|all|\(pathKey)"
    }

    private func scheduleFilterRefresh(force: Bool) {
        scheduledFilterRefresh?.cancel()
        if force {
            sections = []
            isLoading = true
        }
        scheduledFilterRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshSessions(force: force)
            self.scheduledFilterRefresh = nil
        }
    }

    // MARK: - Quick pulse: cheap, low-latency activity tracking via file mtime
    private func quickPulse() {
        let now = Date()
        guard now.timeIntervalSince(lastQuickPulseAt) > 0.4 else { return }
        lastQuickPulseAt = now
        guard !sections.isEmpty else { return }
#if canImport(AppKit)
        guard NSApp?.isActive != false else { return }
#endif
        let displayedSessions = Array(self.sections.flatMap { $0.sessions }.prefix(200))
        guard !displayedSessions.isEmpty else { return }
        // Gate by visible rows digest to avoid scanning when the visible set didn't change
        var hasher = Hasher()
        for s in displayedSessions { hasher.combine(s.id) }
        let digest = hasher.finalize()
        if digest == lastDisplayedDigest { return }
        lastDisplayedDigest = digest
        quickPulseTask?.cancel()
        // Take a snapshot of currently displayed sessions (limit for safety)
        quickPulseTask = Task.detached { [weak self, displayedSessions] in
            guard let self else { return }
            let fm = FileManager.default
            var modified: [String: Date] = [:]
            for s in displayedSessions {
                let path = s.fileURL.path
                if let attrs = try? fm.attributesOfItem(atPath: path),
                    let m = attrs[.modificationDate] as? Date
                {
                    modified[s.id] = m
                }
            }
            let snapshot = modified
            await MainActor.run {
                let now = Date()
                for (id, m) in snapshot {
                    let previous = self.fileMTimeCache[id]
                    self.fileMTimeCache[id] = m
                    if let previous, m > previous {
                        self.activityHeartbeat[id] = now
                    }
                }
                self.recomputeActiveUpdatingIDs()
            }
        }
    }

    private func monthKey(for day: Date?, dimension: DateDimension) -> String? {
        guard let day else { return nil }
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: day)
        guard let year = comps.year, let month = comps.month else { return nil }
        return "\(dimension.rawValue)|\(year)-\(month)"
    }

    // MARK: - Incremental refresh for New
    func setIncrementalHintForCodexToday(window seconds: TimeInterval = 10) {
        let day = Calendar.current.startOfDay(for: Date())
        pendingIncrementalHint = PendingIncrementalRefreshHint(
            kind: .codexDay(day), expiresAt: Date().addingTimeInterval(seconds))
    }

    func setIncrementalHintForClaudeProject(directory: String, window seconds: TimeInterval = 120) {
        let canonical = Self.canonicalPath(directory)
        pendingIncrementalHint = PendingIncrementalRefreshHint(
            kind: .claudeProject(canonical),
            expiresAt: Date().addingTimeInterval(seconds))

        // Point a dedicated monitor at this project's folder to receive events for nested writes.
        // Claude writes session files inside ~/.claude/projects/<encoded-cwd>/, which are not visible
        // to a non-recursive top-level directory watcher.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsRoot = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let encoded = Self.encodeClaudeProjectFolder(from: canonical)
        let projectURL = projectsRoot.appendingPathComponent(encoded, isDirectory: true)
        if FileManager.default.fileExists(atPath: projectURL.path) {
            if let monitor = claudeProjectMonitor {
                monitor.updateURL(projectURL)
            } else {
                claudeProjectMonitor = DirectoryMonitor(url: projectURL) { [weak self] in
                    Task { await self?.refreshIncrementalForClaudeProject(directory: canonical) }
                }
            }
        }
    }

    // Claude project folder encoding mirrors ClaudeSessionProvider.encodeProjectFolder
    private static func encodeClaudeProjectFolder(from cwd: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized.hasSuffix("/") && standardized.count > 1 { standardized.removeLast() }
        var name = standardized.replacingOccurrences(of: ":", with: "-")
        name = name.replacingOccurrences(of: "/", with: "-")
        if !name.hasPrefix("-") { name = "-" + name }
        return name
    }

    private func mergeAndApply(_ subset: [SessionSummary]) {
        guard !subset.isEmpty else { return }
        var map = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
        let previousIDs = Set(allSessions.map { $0.id })
        for var s in subset {
            if let note = notesSnapshot[s.id] {
                s.userTitle = note.title
                s.userComment = note.comment
            }
            map[s.id] = s
            if !previousIDs.contains(s.id) { self.handleAutoAssignIfMatches(s) }
        }
        allSessions = Array(map.values)
        rebuildCanonicalCwdCache()
        scheduleApplyFilters()
        globalSessionCount = allSessions.count
    }

    private func dayOfToday() -> Date { Calendar.current.startOfDay(for: Date()) }

    func refreshIncrementalForNewCodexToday() async {
        do {
            let subset = try await indexer.refreshSessions(
                root: preferences.sessionsRoot, scope: .day(dayOfToday()))
            await MainActor.run { self.mergeAndApply(subset) }
        } catch {
            // Swallow errors for incremental path; full refresh will recover if needed.
        }
    }

    func refreshIncrementalForClaudeProject(directory: String) async {
        let subset = await claudeProvider.sessions(inProjectDirectory: directory)
        await MainActor.run { self.mergeAndApply(subset) }
    }

    private func refreshIncremental(using hint: PendingIncrementalRefreshHint) async {
        switch hint.kind {
        case .codexDay:
            await refreshIncrementalForNewCodexToday()
        case .claudeProject(let dir):
            await refreshIncrementalForClaudeProject(directory: dir)
        }
    }

    nonisolated private static func computeMonthCounts(
        sessions: [SessionSummary],
        monthKey: String,
        dimension: DateDimension,
        dayIndex: [String: SessionDayIndex],
        coverage: [String: Set<Int>] = [:]
    ) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for session in sessions {
            guard let bucket = dayIndex[session.id] else { continue }
            switch dimension {
            case .created:
                guard bucket.createdMonthKey == monthKey else { continue }
                counts[bucket.createdDay, default: 0] += 1
            case .updated:
                guard bucket.updatedMonthKey == monthKey else { continue }
                if let days = coverage[session.id], !days.isEmpty {
                    for day in days { counts[day, default: 0] += 1 }
                } else {
                    counts[bucket.updatedDay, default: 0] += 1
                }
            }
        }
        return counts
    }
}

extension SessionListViewModel {
    private func apply(
        notes: [String: SessionNote], to sessions: inout [SessionSummary]
    ) {
        for index in sessions.indices {
            if let note = notes[sessions[index].id] {
                sessions[index].userTitle = note.title
                sessions[index].userComment = note.comment
            }
        }
    }

    func refreshGlobalCount() async {
        globalSessionCount = allSessions.count
    }

    /// User-driven refresh for usage status (status capsule tap / Command+R fallback).
    func requestUsageStatusRefresh(for provider: UsageProviderKind) {
        switch provider {
        case .codex:
            refreshCodexUsageStatus()
        case .claude:
            refreshClaudeUsageStatus()
        }
    }

    private func refreshCodexUsageStatus() {
        codexUsageTask?.cancel()
        let candidates = latestCodexSessions(limit: 12)
        guard !candidates.isEmpty else {
            codexUsageStatus = nil
            return
        }

        codexUsageTask = Task { [weak self] in
            guard let self else { return }
            let ripgrepSnapshot = await self.ripgrepStore.latestTokenUsage(in: candidates)
            let snapshot: TokenUsageSnapshot?
            if let ripgrepSnapshot {
                snapshot = ripgrepSnapshot
            } else {
                snapshot = await Task.detached(priority: .utility) {
                    Self.fallbackTokenUsage(from: candidates)
                }.value
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                let codexStatus = snapshot.map { CodexUsageStatus(snapshot: $0) }
                self.codexUsageStatus = codexStatus
                if let codex = codexStatus {
                    self.setUsageSnapshot(.codex, codex.asProviderSnapshot())
                } else {
                    self.setUsageSnapshot(
                        .codex,
                        UsageProviderSnapshot(
                            provider: .codex,
                            title: UsageProviderKind.codex.displayName,
                            availability: .empty,
                            metrics: [],
                            updatedAt: nil,
                            statusMessage: "No Codex sessions found yet."
                        )
                    )
                }
            }
        }
    }

    nonisolated private static func fallbackTokenUsage(from sessions: [SessionSummary]) -> TokenUsageSnapshot? {
        guard !sessions.isEmpty else { return nil }
        let loader = SessionTimelineLoader()
        for session in sessions {
            if let snapshot = loader.loadLatestTokenUsageWithFallback(url: session.fileURL) {
                return snapshot
            }
        }
        return nil
    }

    private func latestCodexSessions(limit: Int) -> [SessionSummary] {
        let sorted = allSessions
            .filter { $0.source == .codex }
            .sorted { ($0.lastUpdatedAt ?? $0.startedAt) > ($1.lastUpdatedAt ?? $1.startedAt) }
        guard !sorted.isEmpty else { return [] }
        return Array(sorted.prefix(limit))
    }

    private func refreshClaudeUsageStatus() {
        claudeUsageTask?.cancel()
        claudeUsageTask = Task { [weak self] in
            guard let self else { return }
            let client = self.claudeUsageClient
            do {
                let status = try await client.fetchUsageStatus()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.setUsageSnapshot(.claude, status.asProviderSnapshot())
                }
            } catch {
                NSLog("[ClaudeUsage] API fetch failed: \(error)")
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.setUsageSnapshot(
                        .claude,
                        UsageProviderSnapshot(
                            provider: .claude,
                            title: UsageProviderKind.claude.displayName,
                            availability: .empty,
                            metrics: [],
                            updatedAt: nil,
                            statusMessage: Self.claudeUsageErrorMessage(from: error),
                            requiresReauth: Self.claudeUsageRequiresReauth(error: error)
                        )
                    )
                }
            }
        }
    }

    private static func claudeUsageRequiresReauth(error: Error) -> Bool {
        guard let clientError = error as? ClaudeUsageAPIClient.ClientError else {
            return false
        }
        switch clientError {
        case .credentialNotFound, .credentialExpired, .malformedCredential, .missingAccessToken:
            return true
        case .requestFailed(let code):
            return code == 401
        case .keychainAccessRestricted:
            return true
        case .emptyResponse, .decodingFailed:
            return false
        }
    }

    private static func claudeUsageErrorMessage(from error: Error) -> String {
        if let clientError = error as? ClaudeUsageAPIClient.ClientError {
            switch clientError {
            case .credentialNotFound:
                return "Sign in to Claude Code once to enable usage data."
            case .keychainAccessRestricted(let status):
                return "Allow CodMate to access \"Claude Code-credentials\" in Keychain (status \(status))."
            case .malformedCredential, .missingAccessToken:
                return "Claude Code credential looks invalid. Try signing out/in again."
            case .credentialExpired:
                return "Claude Code credential expired. Please sign in again."
            case .requestFailed(let code):
                if code == 401 {
                    return "Claude usage request failed (HTTP 401). Allow CodMate to access the \"Claude Code…-credentials\" entry in Keychain, then refresh."
                }
                return "Claude usage request failed (HTTP \(code))."
            case .emptyResponse, .decodingFailed:
                return "Claude usage data could not be decoded."
            }
        }
        return "Claude usage data is unavailable."
    }

    private func setUsageSnapshot(_ provider: UsageProviderKind, _ new: UsageProviderSnapshot) {
        if let old = usageSnapshots[provider], Self.usageSnapshotCoreEqual(old, new) {
            return
        }
        usageSnapshots[provider] = new
    }

    private static func usageSnapshotCoreEqual(_ a: UsageProviderSnapshot, _ b: UsageProviderSnapshot) -> Bool {
        if a.availability != b.availability { return false }
        let au = a.updatedAt?.timeIntervalSinceReferenceDate
        let bu = b.updatedAt?.timeIntervalSinceReferenceDate
        if au != bu { return false }
        let ap = a.urgentMetric()?.progress
        let bp = b.urgentMetric()?.progress
        if ap != bp { return false }
        let ar = a.urgentMetric()?.resetDate?.timeIntervalSinceReferenceDate
        let br = b.urgentMetric()?.resetDate?.timeIntervalSinceReferenceDate
        return ar == br
    }

    // MARK: - Sandbox Permission Helpers
    
    /// Ensure we have access to sessions directories in sandbox mode
    private func ensureSessionsAccess() async {
        guard SecurityScopedBookmarks.shared.isSandboxed else { return }
        
        // Check if sessions root path is under a known required directory
        let sessionsPath = preferences.sessionsRoot.path
        let realHome = getRealUserHome()
        let normalizedPath = sessionsPath.replacingOccurrences(of: "~", with: realHome)
        
        // Try to start access for Codex directory if sessions root is under ~/.codex
        if normalizedPath.hasPrefix(realHome + "/.codex") {
            SandboxPermissionsManager.shared.startAccessingIfAuthorized(directory: .codexSessions)
        }
        
        // Try to start access for Claude directory if needed
        SandboxPermissionsManager.shared.startAccessingIfAuthorized(directory: .claudeSessions)
        
        // Try to start access for CodMate directory if needed
        SandboxPermissionsManager.shared.startAccessingIfAuthorized(directory: .codmateData)
    }
    
    /// Get the real user home directory (not sandbox container)
    private func getRealUserHome() -> String {
        if let homeDir = getpwuid(getuid())?.pointee.pw_dir {
            return String(cString: homeDir)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        }
        return NSHomeDirectory()
    }

    func timeline(for summary: SessionSummary) async -> [ConversationTurn] {
        if summary.source == .claude {
            return await claudeProvider.timeline(for: summary) ?? []
        }
        let loader = SessionTimelineLoader()
        return (try? loader.load(url: summary.fileURL)) ?? []
    }

    func ripgrepDiagnostics() async -> SessionRipgrepStore.Diagnostics {
        await ripgrepStore.diagnostics()
    }

    func rebuildRipgrepIndexes() async {
        coverageLoadTasks.values.forEach { $0.cancel() }
        coverageLoadTasks.removeAll()
        toolMetricsTask?.cancel()
        await ripgrepStore.resetAll()
        updatedMonthCoverage.removeAll()
        monthCountsCache.removeAll()
        scheduleViewUpdate()
        scheduleToolMetricsRefresh()
        if dateDimension == .updated {
            triggerCoverageLoad(for: sidebarMonthStart, dimension: dateDimension)
        }
        scheduleApplyFilters()
    }

    // Invalidate all cached monthly counts; next access will recompute
    func invalidateCalendarCaches() {
        monthCountsCache.removeAll()
        scheduleViewUpdate()
    }

}

// MARK: - Auto Title / Overview
