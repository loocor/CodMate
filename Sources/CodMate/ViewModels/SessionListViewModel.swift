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

    // 新的过滤状态：支持组合过滤
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

    // Projects
    private let configService = CodexConfigService()
    @Published private(set) var projects: [Project] = []
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
        // 启动时默认状态：All Sessions（无目录过滤）+ 当天日期
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
            guard let self else { return }
            if let id = note.userInfo?["sessionID"] as? String {
                self.awaitingFollowupIDs.insert(id)
            }
        }
        startActivityPruneTicker()
    }

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
            let notes = await notesStore.all()
            notesSnapshot = notes
            // Refresh projects on each sessions refresh to reflect external edits
            Task { await self.loadProjects() }
            apply(notes: notes, to: &sessions)
            registerActivityHeartbeat(previous: allSessions, current: sessions)
            allSessions = sessions
            rebuildCanonicalCwdCache()
            await computeCalendarCaches()
            applyFilters()
            startBackgroundEnrichment()
            currentMonthDimension = dateDimension
            currentMonthKey = monthKey(for: selectedDay, dimension: dateDimension)
            Task { await self.refreshGlobalCount() }
            // 刷新侧边栏路径树，确保新增文件通过刷新即可出现
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
            if let oldT = prevMap[s.id] {
                if newT > oldT { activityHeartbeat[s.id] = now }
            } else {
                // New in list: treat as recently updated
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

    private func recomputeActiveUpdatingIDs() {
        let cutoff = Date().addingTimeInterval(-3.0)
        activeUpdatingIDs = Set(activityHeartbeat.filter { $0.value > cutoff }.keys)
    }

    func isActivelyUpdating(_ id: String) -> Bool { activeUpdatingIDs.contains(id) }
    func isAwaitingFollowup(_ id: String) -> Bool { awaitingFollowupIDs.contains(id) }

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
        let dir = project.directory
        switch app {
        case .iterm2:
            let cmd = buildNewProjectCLIInvocation(project: project)
            actions.openTerminalViaScheme(.iterm2, directory: dir, command: cmd)
        case .warp:
            actions.openTerminalViaScheme(.warp, directory: dir)
            copyNewProjectCommands(project: project)
        case .terminal:
            _ = actions.openNewProject(project: project, executableURL: preferences.codexExecutableURL, options: preferences.resumeOptions)
        case .none:
            _ = actions.openAppleTerminal(at: dir)
            copyNewProjectCommands(project: project)
        }
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "命令已拷贝，请粘贴到打开的终端") }
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

    // MARK: - 过滤状态管理

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
        // searchText 保持不变，便于连续检索
    }

    private func applyFilters() {
        guard !allSessions.isEmpty else {
            sections = []
            return
        }

        var filtered = allSessions

        // 1. 目录过滤
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

        // 2. 项目过滤（优先显式映射；其次目录推断）
        if let pid = selectedProjectId, let project = projects.first(where: { $0.id == pid }) {
            let projPath = Self.canonicalPath(project.directory)
            let prefix = projPath == "/" ? "/" : projPath + "/"
            filtered = filtered.filter { summary in
                // explicit mapping wins
                if notesSnapshot[summary.id]?.projectId == pid { return true }
                // directory inference when under project directory
                let canonical = canonicalCwdCache[summary.id] ?? Self.canonicalPath(summary.cwd)
                return canonical == projPath || canonical.hasPrefix(prefix)
            }
        }

        // 3. 日期过滤
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

        // 4. 搜索过滤
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            filtered = filtered.filter { summary in
                summary.matches(search: term) || fulltextMatches.contains(summary.id)
            }
        }

        // 5. 排序
        filtered = sortOrder.sort(filtered)

        // 6. 分组
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
            isEnriching = false
            enrichmentProgress = 0
            enrichmentTotal = 0
            return
        }
        let sessions = sessionsForCurrentDay()
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
        // 如果选中了具体日期，根据维度决定加载范围
        if let day = selectedDay {
            switch dateDimension {
            case .created:
                // Created 维度：只加载该日目录下的文件
                return .day(day)
            case .updated:
                // Updated 维度：为确保与日历统计保持一致，统一加载全部文件后再过滤
                return .all
            }
        }
        // 无日期过滤时：加载所有数据
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
        guard let day else { return nil }
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = comps.year, let month = comps.month, let dayComponent = comps.day else {
            return nil
        }
        let pathKey: String
        if let path = selectedPath {
            pathKey = Self.canonicalPath(path)
        } else {
            pathKey = "*"
        }
        return "\(dateDimension.rawValue)|\(year)-\(month)-\(dayComponent)|\(pathKey)"
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
            await MainActor.run {
                let now = Date()
                for (id, m) in modified {
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
        // 获取当前选择的月份
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
            // 验证日期是否属于当前月份
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
        let list = await configService.listProjects()
        await MainActor.run { self.projects = list }
    }

    func setSelectedProject(_ id: String?) {
        selectedProjectId = id
    }

    func assignSessions(to projectId: String?, ids: [String]) async {
        for id in ids { await notesStore.assignProject(id: id, projectId: projectId) }
        let notes = await notesStore.all()
        notesSnapshot = notes
        applyFilters()
    }

    func projectCountsFromNotes() -> [String: Int] {
        var counts: [String: Int] = [:]
        for (_, note) in notesSnapshot {
            if let pid = note.projectId { counts[pid, default: 0] += 1 }
        }
        return counts
    }

    // Helper for views to upsert a project
    func configServiceUpsert(project: Project) async {
        do { try await configService.upsertProject(project) } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
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
