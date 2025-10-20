import Foundation
import AppKit

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
            scheduleFilterRefresh(force: true)
        }
    }

    let preferences: SessionPreferencesStore

    private let indexer: SessionIndexer
    private let actions: SessionActions
    private var allSessions: [SessionSummary] = []
    private var fulltextMatches: Set<String> = []  // SessionSummary.id set
    private var fulltextTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var notesStore: SessionNotesStore
    private var notesSnapshot: [String: SessionNote] = [:]
    private var canonicalCwdCache: [String: String] = [:]
    private var directoryMonitor: DirectoryMonitor?
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
        let expectedCwd: String // canonical path
        let t0: Date
        struct Hints: Sendable, Hashable { var model: String?; var sandbox: String?; var approval: String? }
        let hints: Hints
    }
    private var pendingAssignIntents: [PendingAssignIntent] = []
    private var intentsCleanupTask: Task<Void, Never>?

    // Projects
    private let configService = CodexConfigService()
    private let projectsStore = ProjectsStore()
    @Published private(set) var projects: [Project] = []
    private var projectCounts: [String: Int] = [:]
    private var projectMemberships: [String: String] = [:]
    @Published var selectedProjectId: String? = nil {
        didSet {
            guard !suppressFilterNotifications, oldValue != selectedProjectId else { return }
            // Switch off directory filter when a project is selected
            if selectedProjectId != nil { selectedPath = nil }
            applyFilters()
        }
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
        // Default at startup: All Sessions (no directory filter) + today
        let today = Date()
        let cal = Calendar.current
        suppressFilterNotifications = true
        self.selectedDay = cal.startOfDay(for: today)
        suppressFilterNotifications = false
        configureDirectoryMonitor()
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
            var sessions = try await indexer.refreshSessions(
                root: preferences.sessionsRoot, scope: scope)
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
            rebuildCanonicalCwdCache()
            await computeCalendarCaches()
            applyFilters()
            // Auto Title/Overview for newly appeared sessions without user notes
            if !newlyAppeared.isEmpty {
                for s in newlyAppeared { await self.tryAutoNote(for: s) }
            }
            startBackgroundEnrichment()
            currentMonthDimension = dateDimension
            currentMonthKey = monthKey(for: selectedDay, dimension: dateDimension)
            Task { await self.refreshGlobalCount() }
            // Refresh path tree to ensure newly created files appear via refresh
            Task {
                let counts = await indexer.collectCWDCounts(root: preferences.sessionsRoot)
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

    // Cancel ongoing background tasks (fulltext, enrichment, scheduled refreshes, quick pulses).
    // Useful when a heavy modal/sheet is presented and the UI should stay responsive.
    func cancelHeavyWork() {
        fulltextTask?.cancel(); fulltextTask = nil
        enrichmentTask?.cancel(); enrichmentTask = nil
        scheduledFilterRefresh?.cancel(); scheduledFilterRefresh = nil
        directoryRefreshTask?.cancel(); directoryRefreshTask = nil
        quickPulseTask?.cancel(); quickPulseTask = nil
        isEnriching = false
        isLoading = false
    }

    func resume(session: SessionSummary) async -> Result<ProcessResult, Error> {
        do {
            let result = try await actions.resume(
                session: session,
                executableURL: preferences.codexExecutableURL,
                options: preferences.resumeOptions)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    func copyResumeCommands(session: SessionSummary) {
        actions.copyResumeCommands(
            session: session,
            executableURL: preferences.codexExecutableURL,
            options: preferences.resumeOptions,
            simplifiedForExternal: true
        )
    }

    func openInTerminal(session: SessionSummary) -> Bool {
        actions.openInTerminal(
            session: session, executableURL: preferences.codexExecutableURL,
            options: preferences.resumeOptions)
    }

    func buildResumeCommands(session: SessionSummary) -> String {
        actions.buildResumeCommandLines(
            session: session,
            executableURL: preferences.codexExecutableURL,
            options: preferences.resumeOptions
        )
    }

    func buildExternalResumeCommands(session: SessionSummary) -> String {
        actions.buildExternalResumeCommands(
            session: session,
            executableURL: preferences.codexExecutableURL,
            options: preferences.resumeOptions
        )
    }

    func buildResumeCLIInvocation(session: SessionSummary) -> String {
        let execPath =
            actions.resolveExecutableURL(preferred: preferences.codexExecutableURL)?.path
            ?? preferences.codexExecutableURL.path
        return actions.buildResumeCLIInvocation(
            session: session,
            executablePath: execPath,
            options: preferences.resumeOptions
        )
    }

    func copyNewSessionCommands(session: SessionSummary) {
        actions.copyNewSessionCommands(
            session: session,
            executableURL: preferences.codexExecutableURL,
            options: preferences.resumeOptions
        )
    }

    func buildNewSessionCLIInvocation(session: SessionSummary) -> String {
        actions.buildNewSessionCLIInvocation(
            session: session,
            options: preferences.resumeOptions
        )
    }

    func openNewSession(session: SessionSummary) {
        _ = actions.openNewSession(
            session: session,
            executableURL: preferences.codexExecutableURL,
            options: preferences.resumeOptions
        )
    }

    // MARK: - Project-level new session
    func buildNewProjectCLIInvocation(project: Project) -> String {
        actions.buildNewProjectCLIInvocation(project: project, options: preferences.resumeOptions)
    }

    func copyNewProjectCommands(project: Project) {
        actions.copyNewProjectCommands(project: project, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions)
    }

    func openNewSession(project: Project) {
        // Respect preferred external app setting
        let app = preferences.defaultResumeExternalApp
        let dirOpt = project.directory
        // Record auto-assign intent for project-level new
        recordIntentForProjectNew(project: project)
        switch app {
        case .iterm2:
            let cmd = buildNewProjectCLIInvocation(project: project)
            actions.openTerminalViaScheme(.iterm2, directory: dirOpt, command: cmd)
        case .warp:
            actions.openTerminalViaScheme(.warp, directory: dirOpt)
            copyNewProjectCommands(project: project)
        case .terminal:
            _ = actions.openNewProject(project: project, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions)
        case .none:
            let fallback = dirOpt ?? NSHomeDirectory()
            _ = actions.openAppleTerminal(at: fallback)
            copyNewProjectCommands(project: project)
        }
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Paste it in the opened terminal.") }
    }

    // MARK: - New (detail) respecting Project Profile
    func buildNewSessionCLIInvocationRespectingProject(session: SessionSummary) -> String {
        if let pid = projectIdForSession(session.id), let p = projects.first(where: { $0.id == pid }), (p.profile != nil || (p.profileId?.isEmpty == false)) {
            return actions.buildNewSessionUsingProjectProfileCLIInvocation(session: session, project: p, options: preferences.resumeOptions)
        }
        return actions.buildNewSessionCLIInvocation(session: session, options: preferences.resumeOptions)
    }

    func buildNewSessionCLIInvocationRespectingProject(session: SessionSummary, initialPrompt: String) -> String {
        if let pid = projectIdForSession(session.id), let p = projects.first(where: { $0.id == pid }), (p.profile != nil || (p.profileId?.isEmpty == false)) {
            return actions.buildNewSessionUsingProjectProfileCLIInvocation(session: session, project: p, options: preferences.resumeOptions, initialPrompt: initialPrompt)
        }
        return actions.buildNewSessionCLIInvocation(session: session, options: preferences.resumeOptions, initialPrompt: initialPrompt)
    }

    func copyNewSessionCommandsRespectingProject(session: SessionSummary) {
        if let pid = projectIdForSession(session.id), let p = projects.first(where: { $0.id == pid }), (p.profile != nil || (p.profileId?.isEmpty == false)) {
            actions.copyNewSessionUsingProjectProfileCommands(session: session, project: p, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions)
        } else {
            actions.copyNewSessionCommands(session: session, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions)
        }
    }

    func copyNewSessionCommandsRespectingProject(session: SessionSummary, initialPrompt: String) {
        if let pid = projectIdForSession(session.id), let p = projects.first(where: { $0.id == pid }), (p.profile != nil || (p.profileId?.isEmpty == false)) {
            actions.copyNewSessionUsingProjectProfileCommands(session: session, project: p, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions, initialPrompt: initialPrompt)
        } else {
            let cmd = actions.buildNewSessionCLIInvocation(session: session, options: preferences.resumeOptions, initialPrompt: initialPrompt)
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
        }
    }

    func openNewSessionRespectingProject(session: SessionSummary) {
        if let pid = projectIdForSession(session.id), let p = projects.first(where: { $0.id == pid }), (p.profile != nil || (p.profileId?.isEmpty == false)) {
            _ = actions.openNewSessionUsingProjectProfile(session: session, project: p, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions)
        } else {
            _ = actions.openNewSession(session: session, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions)
        }
    }

    func openNewSessionRespectingProject(session: SessionSummary, initialPrompt: String) {
        if let pid = projectIdForSession(session.id), let p = projects.first(where: { $0.id == pid }), (p.profile != nil || (p.profileId?.isEmpty == false)) {
            _ = actions.openNewSessionUsingProjectProfile(session: session, project: p, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions, initialPrompt: initialPrompt)
        } else {
            // Terminal-only variant is not implemented for non-project case; open generic new then user pastes.
            _ = actions.openNewSession(session: session, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions)
        }
    }

    // MARK: - Project lookup helpers
    func projectIdForSession(_ id: String) -> String? {
        projectMemberships[id]
    }

    func projectForId(_ id: String) async -> Project? {
        await projectsStore.getProject(id: id)
    }

    func copyRealResumeCommand(session: SessionSummary) {
        actions.copyRealResumeInvocation(
            session: session,
            executableURL: preferences.codexExecutableURL,
            options: preferences.resumeOptions
        )
    }

    func openWarpLaunch(session: SessionSummary) {
        _ = actions.openWarpLaunchConfig(session: session, options: preferences.resumeOptions)
    }

    func openPreferredTerminal(app: TerminalApp) {
        actions.openTerminalApp(app)
    }

    func openPreferredTerminalViaScheme(app: TerminalApp, directory: String, command: String? = nil)
    {
        actions.openTerminalViaScheme(app, directory: directory, command: command)
    }

    func openAppleTerminal(at directory: String) -> Bool {
        actions.openAppleTerminal(at: directory)
    }

    // MARK: - Rename / Comment
    func beginEditing(session: SessionSummary) async {
        editingSession = session
        if let note = await notesStore.note(for: session.id) {
            editTitle = note.title ?? ""
            editComment = note.comment ?? ""
        } else {
            editTitle = session.userTitle ?? ""
            editComment = session.userComment ?? ""
        }
    }

    func saveEdits() async {
        guard let session = editingSession else { return }
        let titleValue = editTitle.isEmpty ? nil : editTitle
        let commentValue = editComment.isEmpty ? nil : editComment
        await notesStore.upsert(id: session.id, title: titleValue, comment: commentValue)
        notesSnapshot[session.id] = SessionNote(
            id: session.id, title: titleValue, comment: commentValue, updatedAt: Date())
        var map = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
        if var s = map[session.id] {
            s.userTitle = titleValue
            s.userComment = commentValue
            map[session.id] = s
        }
        allSessions = Array(map.values)
        applyFilters()
        cancelEdits()
    }

    func cancelEdits() {
        editingSession = nil
        editTitle = ""
        editComment = ""
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
        if currentMonthDimension == dimension,
            let currentKey = currentMonthKey,
            currentKey == key
        {
            let counts = countsForLoadedMonth(dimension: dimension)
            monthCountsCache[key] = counts
            return counts
        }
        Task { [monthStart, dimension] in
            let counts = await indexer.computeCalendarCounts(
                root: preferences.sessionsRoot, monthStart: monthStart, dimension: dimension)
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

    // MARK: - Filter state management

    func setSelectedPath(_ path: String?) {
        if selectedPath == path { return }
        selectedPath = path
    }

    func setSelectedDay(_ day: Date?) {
        let normalized = day.map { Calendar.current.startOfDay(for: $0) }
        if selectedDay == normalized { return }
        selectedDay = normalized
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

    private func applyFilters() {
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
            filtered = filtered.filter { summary in
                guard let assigned = memberships[summary.id] else { return false }
                return assigned == pid || descendants.contains(assigned)
            }
        }

        // 3. Date filter
        if let day = selectedDay {
            filtered = filtered.filter { sess in
                let cal = Calendar.current
                switch dateDimension {
                case .created:
                    return cal.isDate(sess.startedAt, inSameDayAs: day)
                case .updated:
                    if let end = sess.lastUpdatedAt {
                        return cal.isDate(end, inSameDayAs: day)
                    }
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

        // 5. Sorting
        filtered = sortOrder.sort(filtered)

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
            // Always group by creation date (startedAt), regardless of dimension
            // The dimension only affects filtering, not grouping
            let referenceDate = session.startedAt
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
                            if let enriched = try await self.indexer.enrich(url: s.fileURL) {
                                return (s.id, enriched)
                            }
                            return nil
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

    private static func canonicalPath(_ path: String) -> String {
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

    private func scheduleDirectoryRefresh() {
        directoryRefreshTask?.cancel()
        directoryRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.enrichmentSnapshots.removeAll()
            await self.refreshSessions(force: true)
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
            guard let year = comps.year, let month = comps.month, let dayComponent = comps.day else {
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

    private func countsForLoadedMonth(dimension: DateDimension) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        let calendar = Calendar.current
        // Get the currently selected month
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
        let count = await indexer.countAllSessions(root: preferences.sessionsRoot)
        await MainActor.run { self.globalSessionCount = count }
    }

    // MARK: - Projects
    func loadProjects() async {
        var list = await projectsStore.listProjects()
        if list.isEmpty {
            let cfg = await configService.listProjects()
            if !cfg.isEmpty {
                for p in cfg { await projectsStore.upsertProject(p) }
                list = await projectsStore.listProjects()
            }
        }
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projects = list
            self.projectCounts = counts
            self.projectMemberships = memberships
        }
    }

    func setSelectedProject(_ id: String?) {
        selectedProjectId = id
    }

    func assignSessions(to projectId: String?, ids: [String]) async {
        await projectsStore.assign(sessionIds: ids, to: projectId)
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projectCounts = counts
            self.projectMemberships = memberships
        }
        applyFilters()
    }

    func projectCountsFromStore() -> [String: Int] { projectCounts }

    // Visible counts per project considering only current dateDimension/selectedDay.
    // Ignores search text and project selection to give a global sense under the date scope.
    func visibleProjectCountsForDateScope() -> [String: Int] {
        var visible: [String: Int] = [:]
        let cal = Calendar.current
        for s in allSessions {
            // Date filter
            if let day = selectedDay {
                let refDate: Date = {
                    switch dateDimension {
                    case .created: return s.startedAt
                    case .updated: return s.lastUpdatedAt ?? s.startedAt
                    }
                }()
                if !cal.isDate(refDate, inSameDayAs: day) { continue }
            }
            if let pid = projectMemberships[s.id] {
                visible[pid, default: 0] += 1
            }
        }
        return visible
    }

    // Aggregated counts including subtree for display (visible/total)
    func projectCountsDisplay() -> [String: (visible: Int, total: Int)] {
        let directVisible = visibleProjectCountsForDateScope()
        let directTotal = projectCounts
        // Build children index
        var children: [String: [String]] = [:]
        for p in projects {
            if let parent = p.parentId { children[parent, default: []].append(p.id) }
        }
        // DFS to sum subtree counts
        func aggregate(for id: String, using map: inout [String: (Int, Int)]) -> (Int, Int) {
            if let cached = map[id] { return cached }
            var v = directVisible[id] ?? 0
            var t = directTotal[id] ?? 0
            for c in (children[id] ?? []) {
                let (cv, ct) = aggregate(for: c, using: &map)
                v += cv; t += ct
            }
            map[id] = (v, t)
            return (v, t)
        }
        var memo: [String: (Int, Int)] = [:]
        var out: [String: (visible: Int, total: Int)] = [:]
        for p in projects {
            let (v, t) = aggregate(for: p.id, using: &memo)
            out[p.id] = (v, t)
        }
        return out
    }

    // All-row visible count under current date scope (ignores project/path/search filters)
    func visibleAllCountForDateScope() -> Int {
        let cal = Calendar.current
        var count = 0
        for s in allSessions {
            if let day = selectedDay {
                let ref: Date = (dateDimension == .created) ? s.startedAt : (s.lastUpdatedAt ?? s.startedAt)
                if !cal.isDate(ref, inSameDayAs: day) { continue }
            }
            count += 1
        }
        return count
    }

    // Project upsert/delete with config sync
    func createOrUpdateProject(_ project: Project) async {
        await projectsStore.upsertProject(project)
        await loadProjects()
    }

    func deleteProject(id: String) async {
        await projectsStore.deleteProject(id: id)
        await loadProjects()
        if selectedProjectId == id { selectedProjectId = nil }
        applyFilters()
    }

    // Delete project and all descendants
    func deleteProjectCascade(id: String) async {
        let list = await projectsStore.listProjects()
        let ids = collectDescendants(of: id, in: list) + [id]
        for pid in ids { await projectsStore.deleteProject(id: pid) }
        await loadProjects()
        if let sel = selectedProjectId, ids.contains(sel) { selectedProjectId = nil }
        applyFilters()
    }

    // Delete project and move its direct children to top level (keep grandchildren nested)
    func deleteProjectMoveChildrenUp(id: String) async {
        let list = await projectsStore.listProjects()
        for p in list where p.parentId == id {
            var moved = p
            moved.parentId = nil
            await projectsStore.upsertProject(moved)
        }
        await projectsStore.deleteProject(id: id)
        await loadProjects()
        if selectedProjectId == id { selectedProjectId = nil }
        applyFilters()
    }

    private func collectDescendants(of id: String, in list: [Project]) -> [String] {
        var result: [String] = []
        func dfs(_ pid: String) {
            for p in list where p.parentId == pid {
                result.append(p.id)
                dfs(p.id)
            }
        }
        dfs(id)
        return result
    }

    // Import memberships from notes.projectId one-time when store is empty
    private func importMembershipsFromNotesIfNeeded(notes: [String: SessionNote]) async {
        let existing = await projectsStore.membershipsSnapshot()
        if !existing.isEmpty { return }
        var buckets: [String: [String]] = [:] // pid -> [sid]
        for (sid, n) in notes { if let pid = n.projectId { buckets[pid, default: []].append(sid) } }
        guard !buckets.isEmpty else { return }
        for (pid, sids) in buckets { await projectsStore.assign(sessionIds: sids, to: pid) }
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projectCounts = counts
            self.projectMemberships = memberships
        }
    }
}

extension SessionListViewModel {
    fileprivate func cacheKey(_ monthStart: Date, _ dimension: DateDimension) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return dimension.rawValue + "|" + df.string(from: monthStart)
    }
}

// MARK: - Auto assign intents + matcher
extension SessionListViewModel {
    private func pruneExpiredIntents() {
        let now = Date()
        pendingAssignIntents.removeAll { now.timeIntervalSince($0.t0) > 60 }
    }

    private func recordIntent(projectId: String, expectedCwd: String, hints: PendingAssignIntent.Hints) {
        if !preferences.autoAssignNewToSameProject { return }
        let canonical = Self.canonicalPath(expectedCwd)
        pendingAssignIntents.append(PendingAssignIntent(projectId: projectId, expectedCwd: canonical, t0: Date(), hints: hints))
        pruneExpiredIntents()
    }

    func recordIntentForDetailNew(anchor: SessionSummary) {
        guard let pid = projectIdForSession(anchor.id) else { return }
        let hints = PendingAssignIntent.Hints(
            model: anchor.model,
            sandbox: preferences.resumeOptions.flagSandboxRaw,
            approval: preferences.resumeOptions.flagApprovalRaw
        )
        recordIntent(projectId: pid, expectedCwd: anchor.cwd, hints: hints)
    }

    func recordIntentForProjectNew(project: Project) {
        let expected = (project.directory?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let hints = PendingAssignIntent.Hints(
            model: project.profile?.model,
            sandbox: project.profile?.sandbox?.rawValue ?? preferences.resumeOptions.flagSandboxRaw,
            approval: project.profile?.approval?.rawValue ?? preferences.resumeOptions.flagApprovalRaw
        )
        recordIntent(projectId: project.id, expectedCwd: expected, hints: hints)
    }

    private func handleAutoAssignIfMatches(_ s: SessionSummary) {
        guard !pendingAssignIntents.isEmpty else { return }
        let canonical = Self.canonicalPath(s.cwd)
        let candidates = pendingAssignIntents.filter { intent in
            guard canonical == intent.expectedCwd else { return false }
            let windowStart = intent.t0.addingTimeInterval(-2)
            let windowEnd = intent.t0.addingTimeInterval(60)
            return s.startedAt >= windowStart && s.startedAt <= windowEnd
        }
        guard !candidates.isEmpty else { return }
        struct Scored { let intent: PendingAssignIntent; let score: Int; let timeAbs: TimeInterval }
        var scored: [Scored] = []
        for it in candidates {
            var score = 0
            if let m = it.hints.model, let sm = s.model, !m.isEmpty, m == sm { score += 1 }
            if let a = it.hints.approval, let sa = s.approvalPolicy, !a.isEmpty, a == sa { score += 1 }
            let timeAbs = abs(s.startedAt.timeIntervalSince(it.t0))
            scored.append(Scored(intent: it, score: score, timeAbs: timeAbs))
        }
        guard let best = scored.max(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.timeAbs > rhs.timeAbs
        }) else { return }
        let topScore = best.score
        let topTime = best.timeAbs
        let dupCount = scored.filter { $0.score == topScore && abs($0.timeAbs - topTime) < 0.001 }.count
        if dupCount > 1 {
            Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Assign to \(best.intent.projectId)?") }
            return
        }
        Task {
            await projectsStore.assign(sessionIds: [s.id], to: best.intent.projectId)
            let counts = await projectsStore.counts()
            let memberships = await projectsStore.membershipsSnapshot()
            await MainActor.run {
                self.projectCounts = counts
                self.projectMemberships = memberships
                self.applyFilters()
            }
            await SystemNotifier.shared.notify(title: "CodMate", body: "Assigned to \(best.intent.projectId)")
        }
        pendingAssignIntents.removeAll { $0.id == best.intent.id }
    }
}

// MARK: - Auto Title / Overview
extension SessionListViewModel {
    private func tryAutoNote(for s: SessionSummary) async {
        if let note = notesSnapshot[s.id] { if (note.title?.isEmpty == false) || (note.comment?.isEmpty == false) { return } }
        // Only for very recent sessions to avoid mass backfill on first load
        if Date().timeIntervalSince(s.startedAt) > 120 { return }
        let title = AutoText.suggestTitle(from: s.fileURL, cwdFallback: s.cwd)
        let overview = AutoText.suggestOverview(from: s.fileURL, cwdFallback: s.cwd)
        if title == nil && overview == nil { return }
        await notesStore.upsert(id: s.id, title: title, comment: overview)
        notesSnapshot[s.id] = SessionNote(id: s.id, title: title, comment: overview, projectId: nil, profileId: nil, updatedAt: Date())
        var map = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
        if var ex = map[s.id] {
            if ex.userTitle == nil { ex.userTitle = title }
            if ex.userComment == nil { ex.userComment = overview }
            map[s.id] = ex
        }
        allSessions = Array(map.values)
        applyFilters()
    }

    func regenerateAutoTitleAndOverview(for s: SessionSummary, overwrite: Bool = false) async {
        let existing = await notesStore.note(for: s.id)
        if !overwrite {
            if let e = existing, (e.title?.isEmpty == false || e.comment?.isEmpty == false) { return }
        }
        let title = AutoText.suggestTitle(from: s.fileURL, cwdFallback: s.cwd)
        let overview = AutoText.suggestOverview(from: s.fileURL, cwdFallback: s.cwd)
        if title == nil && overview == nil { return }
        await notesStore.upsert(id: s.id, title: title, comment: overview)
        notesSnapshot[s.id] = SessionNote(id: s.id, title: title, comment: overview, projectId: existing?.projectId, profileId: existing?.profileId, updatedAt: Date())
        var map = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
        if var ex = map[s.id] { ex.userTitle = title; ex.userComment = overview; map[s.id] = ex }
        allSessions = Array(map.values)
        applyFilters()
    }
}

// MARK: - AutoText (pure helpers)
fileprivate enum AutoText {
    static func suggestTitle(from url: URL, cwdFallback: String) -> String? {
        guard let head = fastHeadUserText(url: url) ?? fastHeadAnyNaturalSentence(url: url) else {
            let base = URL(fileURLWithPath: cwdFallback, isDirectory: true).lastPathComponent
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            return base.isEmpty ? nil : base + "-" + df.string(from: Date())
        }
        let cleaned = cleanInline(head)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return clampTitle(trimmed)
    }

    static func suggestOverview(from url: URL, cwdFallback: String) -> String? {
        guard let text = fastHeadUserText(url: url) ?? fastHeadAnyNaturalSentence(url: url) else {
            return nil
        }
        let cleaned = cleanBlock(text)
        let para = firstParagraph(from: cleaned)
        let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return clampOverview(trimmed)
    }

    // MARK: Fast head extraction (~400 lines)
    private static func fastHeadUserText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A, cr: UInt8 = 0x0D
        var count = 0
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == cr { slice = slice.dropLast() }
            if slice.isEmpty { continue }
            if count >= 400 { break }
            if let row = try? dec.decode(SessionRow.self, from: Data(slice)) {
                switch row.kind {
                case .eventMessage(let p):
                    if p.type.lowercased() == "user_message" {
                        let t = (p.message ?? p.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { return t }
                    }
                case .responseItem(let p):
                    if p.type.lowercased() == "message", (p.role?.lowercased() == "user") == true {
                        if let blocks = p.content { return blocks.compactMap { $0.text }.joined(separator: "\n\n") }
                    }
                default: break
                }
            }
            count += 1
        }
        return nil
    }

    private static func fastHeadAnyNaturalSentence(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A, cr: UInt8 = 0x0D
        var count = 0
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == cr { slice = slice.dropLast() }
            if slice.isEmpty { continue }
            if count >= 400 { break }
            if let row = try? dec.decode(SessionRow.self, from: Data(slice)) {
                switch row.kind {
                case .eventMessage(let p):
                    let raw = (p.message ?? p.text ?? "")
                    let t = cleanBlock(raw)
                    if let sent = firstNaturalSentence(from: t) { return sent }
                case .responseItem(let p):
                    if p.type.lowercased() == "message" {
                        let raw = (p.content ?? []).compactMap { $0.text }.joined(separator: "\n\n")
                        let t = cleanBlock(raw)
                        if let sent = firstNaturalSentence(from: t) { return sent }
                    }
                default: break
                }
            }
            count += 1
        }
        return nil
    }

    // MARK: Cleaners
    private static func cleanBlock(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = s
        out = out.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"`[^`]+`"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\(([^\)]+)\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n---\n", with: " ")
        return out
    }

    private static func cleanInline(_ s: String) -> String {
        let loweredPrefixes = ["please", "could you", "can you", "how to", "need to", "i need", "help "]
        let chinesePrefixes = ["请", "需要", "能否", "如何", "麻烦", "把", "帮我"]
        var text = cleanBlock(s).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        for p in loweredPrefixes {
            if lower.hasPrefix(p + " ") || lower == p {
                text = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        for p in chinesePrefixes {
            if text.hasPrefix(p) {
                text = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return text
    }

    private static func firstParagraph(from s: String) -> String {
        let parts = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return parts.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? s
    }

    private static func firstNaturalSentence(from s: String) -> String? {
        let cleaned = cleanBlock(s)
        let separators = CharacterSet(charactersIn: ".!?。！？\n")
        let parts = cleaned.components(separatedBy: separators)
        for part in parts {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 4 { return t }
        }
        return nil
    }

    private static func clampTitle(_ s: String) -> String {
        let isCJK = s.unicodeScalars.contains { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) || ($0.value >= 0x3400 && $0.value <= 0x4DBF) }
        let maxLen = isCJK ? 16 : 28
        if s.count <= maxLen { return s }
        let idx = s.index(s.startIndex, offsetBy: maxLen)
        return String(s[..<idx]) + "…"
    }

    private static func clampOverview(_ s: String) -> String {
        let maxLen = 200
        if s.count <= maxLen { return s }
        let idx = s.index(s.startIndex, offsetBy: maxLen)
        return String(s[..<idx]) + "…"
    }
}
