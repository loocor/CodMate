import AppKit
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
    @Published var isEnriching = false
    @Published var enrichmentProgress: Int = 0
    @Published var enrichmentTotal: Int = 0
    @Published var errorMessage: String?

    // Title/Comment quick search for the middle list only
    @Published var quickSearchText: String = "" {
        didSet { applyFilters() }
    }

    // New filter state: supports combined filters
    @Published var selectedPath: String? = nil {
        didSet {
            guard !suppressFilterNotifications, oldValue != selectedPath else { return }
            applyFilters()
            scheduleFilterRefresh(force: false)
        }
    }
    @Published var selectedDay: Date? = nil {
        didSet {
            guard !suppressFilterNotifications, oldValue != selectedDay else { return }
            scheduleFilterRefresh(force: true)
        }
    }
    @Published var dateDimension: DateDimension = .updated {
        didSet {
            guard !suppressFilterNotifications, oldValue != dateDimension else { return }
            enrichmentSnapshots.removeAll()
            // Update UI immediately with current dataset under new dimension.
            applyFilters()
            scheduleFilterRefresh(force: true)
        }
    }
    // Multiple day selection support (normalized to startOfDay)
    @Published var selectedDays: Set<Date> = [] {
        didSet {
            guard !suppressFilterNotifications else { return }
            scheduleFilterRefresh(force: true)
        }
    }

    let preferences: SessionPreferencesStore

    private let indexer: SessionIndexer
    let actions: SessionActions
    var allSessions: [SessionSummary] = []
    private var fulltextMatches: Set<String> = []  // SessionSummary.id set
    private var fulltextTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    var notesStore: SessionNotesStore
    var notesSnapshot: [String: SessionNote] = [:]
    private var canonicalCwdCache: [String: String] = [:]
    private var directoryMonitor: DirectoryMonitor?
    private var claudeDirectoryMonitor: DirectoryMonitor?
    private var claudeProjectMonitor: DirectoryMonitor?
    private var directoryRefreshTask: Task<Void, Never>?
    private var enrichmentSnapshots: [String: Set<String>] = [:]
    private var suppressFilterNotifications = false
    private var scheduledFilterRefresh: Task<Void, Never>?
    private var currentMonthKey: String?
    private var currentMonthDimension: DateDimension = .updated
    // Quick pulse (cheap file mtime scan) state
    private var quickPulseTask: Task<Void, Never>?
    private var lastQuickPulseAt: Date = .distantPast
    private var fileMTimeCache: [String: Date] = [:]  // session.id -> mtime
    @Published var editingSession: SessionSummary? = nil
    @Published var editTitle: String = ""
    @Published var editComment: String = ""
    @Published var globalSessionCount: Int = 0
    @Published private(set) var pathTreeRootPublished: PathTreeNode?
    @Published private var monthCountsCache: [String: [Int: Int]] = [:]  // key: "dim|yyyy-MM"
    // Live activity indicators
    @Published private(set) var activeUpdatingIDs: Set<String> = []
    @Published private(set) var awaitingFollowupIDs: Set<String> = []

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
    @Published var projects: [Project] = []
    var projectCounts: [String: Int] = [:]
    var projectMemberships: [String: String] = [:]
    @Published var selectedProjectId: String? = nil {
        didSet {
            guard !suppressFilterNotifications, oldValue != selectedProjectId else { return }
            // Switch off directory filter when a project is selected
            if selectedProjectId != nil { selectedPath = nil }
            applyFilters()
        }
    }
    // Sidebar → Project-level New request when using embedded terminal
    @Published var pendingEmbeddedProjectNew: Project? = nil

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
            allSessions = sessions
            recomputeProjectCounts()
            rebuildCanonicalCwdCache()
            invalidateCalendarCaches()
            await computeCalendarCaches()
            applyFilters()
            startBackgroundEnrichment()
            currentMonthDimension = dateDimension
            currentMonthKey = monthKey(for: selectedDay, dimension: dateDimension)
            Task { await self.refreshGlobalCount() }
            // Refresh path tree to ensure newly created files appear via refresh
            Task {
                async let codex = indexer.collectCWDCounts(root: preferences.sessionsRoot)
                async let claude = claudeProvider.collectCWDCounts()
                var counts = await codex
                let claudeCounts = await claude
                for (key, value) in claudeCounts {
                    counts[key, default: 0] += value
                }
                let tree = counts.buildPathTreeFromCounts()
                await MainActor.run { self.pathTreeRootPublished = tree }
            }
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
        scheduledFilterRefresh?.cancel()
        scheduledFilterRefresh = nil
        directoryRefreshTask?.cancel()
        directoryRefreshTask = nil
        quickPulseTask?.cancel()
        quickPulseTask = nil
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
        preferences.sessionsRoot = newURL
        await notesStore.updateRoot(to: preferences.notesRoot)
        await indexer.invalidateAll()
        enrichmentSnapshots.removeAll()
        configureDirectoryMonitor()
        await refreshSessions(force: true)
    }

    func updateNotesRoot(to newURL: URL) async {
        guard newURL != preferences.notesRoot else { return }
        preferences.notesRoot = newURL
        await notesStore.updateRoot(to: newURL)
        // Reload notes snapshot and re-apply to current sessions
        let notes = await notesStore.all()
        notesSnapshot = notes
        var sessions = allSessions
        apply(notes: notes, to: &sessions)
        allSessions = sessions
        applyFilters()
    }

    func updateProjectsRoot(to newURL: URL) async {
        guard newURL != preferences.projectsRoot else { return }
        preferences.projectsRoot = newURL
        let p = ProjectsStore.Paths(
            root: newURL,
            metadataDir: newURL.appendingPathComponent("metadata", isDirectory: true),
            membershipsURL: newURL.appendingPathComponent("memberships.json", isDirectory: false)
        )
        self.projectsStore = ProjectsStore(paths: p)
        await loadProjects()
        recomputeProjectCounts()
        applyFilters()
    }

    // Removed: executable path updates – CLI resolution uses PATH

    var totalSessionCount: Int {
        globalSessionCount
    }

    // Expose data for navigation helpers
    func calendarCounts(for monthStart: Date, dimension: DateDimension) -> [Int: Int] {
        let key = cacheKey(monthStart, dimension)
        if let cached = monthCountsCache[key] { return cached }
        if currentMonthDimension == dimension,
            let currentKey = currentMonthKey,
            currentKey == key
        {
            let counts = countsForLoadedMonth(dimension: dimension)
            monthCountsCache[key] = counts
            // In Created mode, the currently loaded dataset may only contain a
            // single day (scope = .day). Schedule a background full-month scan
            // to replace the approximation so other days populate correctly.
            if dimension == .created {
                Task { [monthStart, dimension] in
                    let precise = await indexer.computeCalendarCounts(
                        root: preferences.sessionsRoot, monthStart: monthStart, dimension: dimension)
                    Task { @MainActor in
                        self.monthCountsCache[self.cacheKey(monthStart, dimension)] = precise
                    }
                }
            }
            return counts
        }
        Task { [monthStart, dimension] in
            let counts = await indexer.computeCalendarCounts(
                root: preferences.sessionsRoot, monthStart: monthStart, dimension: dimension)
            await MainActor.run {
                self.monthCountsCache[self.cacheKey(monthStart, dimension)] = counts
            }
        }
        return [:]
    }

    func cacheKey(_ monthStart: Date, _ dimension: DateDimension) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return dimension.rawValue + "|" + df.string(from: monthStart)
    }

    var pathTreeRoot: PathTreeNode? { pathTreeRootPublished }

    func ensurePathTree() {
        if pathTreeRootPublished != nil { return }
        Task {
            async let codex = indexer.collectCWDCounts(root: preferences.sessionsRoot)
            async let claude = claudeProvider.collectCWDCounts()
            var counts = await codex
            let claudeCounts = await claude
            for (key, value) in claudeCounts {
                counts[key, default: 0] += value
            }
            let tree = counts.buildPathTreeFromCounts()
            await MainActor.run { self.pathTreeRootPublished = tree }
        }
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
        suppressFilterNotifications = false
        // Update UI immediately using existing dataset; then load correct scope.
        applyFilters()
        // After coordinated update of selectedDay/selectedDays, trigger a refresh once.
        // Use force=true to ensure scope reload (created uses .day; updated uses .all).
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
        // Keep single-selection reflected in selectedDay; otherwise nil
        if selectedDays.count == 1, let only = selectedDays.first {
            selectedDay = only
        } else if selectedDays.isEmpty {
            selectedDay = nil
        } else {
            selectedDay = nil
        }
        suppressFilterNotifications = false
        // Update UI immediately using existing dataset; then load correct scope.
        applyFilters()
        scheduleFilterRefresh(force: true)
    }

    func clearAllFilters() {
        suppressFilterNotifications = true
        selectedPath = nil
        selectedDay = nil
        selectedProjectId = nil
        suppressFilterNotifications = false
        scheduleFilterRefresh(force: true)
        // Keep searchText unchanged to allow consecutive searches
    }

    // Clear only scope filters (directory and project), keep the date filter intact
    func clearScopeFilters() {
        suppressFilterNotifications = true
        selectedPath = nil
        selectedProjectId = nil
        suppressFilterNotifications = false
        scheduleFilterRefresh(force: true)
    }

    func applyFilters() {
        guard !allSessions.isEmpty else {
            sections = []
            return
        }

        var filtered = allSessions

        // 1. Directory filter
        if let path = selectedPath {
            let canonicalSelected = Self.canonicalPath(path)
            let prefix = canonicalSelected == "/" ? "/" : canonicalSelected + "/"
            filtered = filtered.filter { summary in
                let canonical: String
                if let cached = canonicalCwdCache[summary.id] {
                    canonical = cached
                } else {
                    let value = Self.canonicalPath(summary.cwd)
                    canonicalCwdCache[summary.id] = value
                    canonical = value
                }
                if canonical == canonicalSelected { return true }
                return canonical.hasPrefix(prefix)
            }
        }

        // 2. Project filter (based on ProjectsStore explicit mapping)
        if let pid = selectedProjectId {
            let memberships = projectMemberships
            // include descendants of selected project
            let descendants = Set(self.collectDescendants(of: pid, in: self.projects))
            let allowedSourcesByProject = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
                $0[$1.id] = $1.sources
            }
            filtered = filtered.filter { summary in
                guard let assigned = memberships[summary.id] else { return false }
                guard assigned == pid || descendants.contains(assigned) else { return false }
                let allowed = allowedSourcesByProject[assigned] ?? ProjectSessionSource.allSet
                return allowed.contains(summary.source.projectSource)
            }
        }

        // 3. Date filter (supports multiple selected days)
        let cal = Calendar.current
        if !selectedDays.isEmpty {
            filtered = filtered.filter { sess in
                let ref: Date =
                    (dateDimension == .created)
                    ? sess.startedAt : (sess.lastUpdatedAt ?? sess.startedAt)
                for d in selectedDays { if cal.isDate(ref, inSameDayAs: d) { return true } }
                return false
            }
        } else if let day = selectedDay {
            filtered = filtered.filter { sess in
                switch dateDimension {
                case .created:
                    return cal.isDate(sess.startedAt, inSameDayAs: day)
                case .updated:
                    if let end = sess.lastUpdatedAt { return cal.isDate(end, inSameDayAs: day) }
                    return cal.isDate(sess.startedAt, inSameDayAs: day)
                }
            }
        }

        // 4. Quick search (title/comment only, lightweight)
        let q = quickSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let needle = q.lowercased()
            filtered = filtered.filter { s in
                if s.effectiveTitle.lowercased().contains(needle) { return true }
                if let c = s.userComment?.lowercased(), c.contains(needle) { return true }
                return false
            }
        }

        // 5. Sorting (dimension-aware for Recent)
        filtered = sortOrder.sort(filtered, dimension: dateDimension)

        // 6. Grouping
        sections = Self.groupSessions(filtered, dimension: dateDimension)
    }

    private static func groupSessions(_ sessions: [SessionSummary], dimension: DateDimension)
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
        applyFilters()  // still update with metadata-only matches quickly
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
                        self.applyFilters()
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

    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }

    private func currentScope() -> SessionLoadScope {
        // If a specific date is selected, decide load scope by dimension
        if let day = selectedDay {
            switch dateDimension {
            case .created:
                // Created dimension: only load files of the given day
                return .day(day)
            case .updated:
                // Updated dimension: load everything and then filter to match calendar stats
                return .all
            }
        }
        // No date filter: load all
        return .all
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
        quickPulseTask?.cancel()
        // Take a snapshot of currently displayed sessions (limit for safety)
        let displayed = self.sections.flatMap { $0.sessions }.prefix(200)
        quickPulseTask = Task.detached { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            var modified: [String: Date] = [:]
            for s in displayed {
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
        applyFilters()
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

    private func countsForLoadedMonth(dimension: DateDimension) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        let calendar = Calendar.current
        // Get the currently selected month (prefer single selectedDay; otherwise empty)
        guard let selectedDay = selectedDay else { return [:] }
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: selectedDay))!

        for session in allSessions {
            let referenceDate: Date
            switch dimension {
            case .created:
                referenceDate = session.startedAt
            case .updated:
                referenceDate = session.lastUpdatedAt ?? session.startedAt
            }
            // Verify the date is within the current month
            guard calendar.isDate(referenceDate, equalTo: monthStart, toGranularity: .month) else {
                continue
            }
            let day = calendar.component(.day, from: referenceDate)
            counts[day, default: 0] += 1
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
        async let codex = indexer.countAllSessions(root: preferences.sessionsRoot)
        async let claude = claudeProvider.countAllSessions()
        let total = await codex + claude
        await MainActor.run { self.globalSessionCount = total }
    }



    func timeline(for summary: SessionSummary) async -> [ConversationTurn] {
        if summary.source == .claude {
            return await claudeProvider.timeline(for: summary) ?? []
        }
        let loader = SessionTimelineLoader()
        return (try? loader.load(url: summary.fileURL)) ?? []
    }

    // Invalidate all cached monthly counts; next access will recompute
    func invalidateCalendarCaches() {
        monthCountsCache.removeAll()
        objectWillChange.send()
    }

}

// MARK: - Auto Title / Overview
