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
            guard oldValue != selectedPath else { return }
            applyFilters()
        }
    }
    @Published var selectedDay: Date? = nil {
        didSet {
            // 日期改变：仅当跨月且使用 updated 维度时才触发重载，减少频繁解析
            if oldValue != selectedDay {
                let cal = Calendar.current
                if dateDimension == .updated,
                    let oldDay = oldValue,
                    let newDay = selectedDay,
                    cal.isDate(oldDay, equalTo: newDay, toGranularity: .month)
                {
                    // 同一月份内切换（updated 维度）无需重载，直接过滤
                    applyFilters()
                } else {
                    Task { await refreshSessions() }
                }
            }
        }
    }
    @Published var dateDimension: DateDimension = .updated {
        didSet {
            // 维度改变会影响 scope（created vs updated），需要重新加载
            if oldValue != dateDimension {
                Task { await refreshSessions() }
            }
        }
    }

    let preferences: SessionPreferencesStore

    private let indexer: SessionIndexer
    private let actions: SessionActions
    private var allSessions: [SessionSummary] = []
    private var fulltextMatches: Set<String> = []  // SessionSummary.id set
    private var fulltextTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private let notesStore = SessionNotesStore()
    private var notesSnapshot: [String: SessionNotesStore.SessionNote] = [:]
    private var canonicalCwdCache: [String: String] = [:]
    @Published var editingSession: SessionSummary? = nil
    @Published var editTitle: String = ""
    @Published var editComment: String = ""
    @Published var globalSessionCount: Int = 0
    @Published private(set) var pathTreeRootPublished: PathTreeNode?
    @Published private var monthCountsCache: [String: [Int: Int]] = [:]  // key: "dim|yyyy-MM"

    init(
        preferences: SessionPreferencesStore,
        indexer: SessionIndexer = SessionIndexer(),
        actions: SessionActions = SessionActions()
    ) {
        self.preferences = preferences
        self.indexer = indexer
        self.actions = actions
        // 启动时默认状态：All Sessions（无目录过滤）+ 当天日期
        let today = Date()
        let cal = Calendar.current
        self.selectedDay = cal.startOfDay(for: today)
    }

    func refreshSessions() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let scope = currentScope()
            var sessions = try await indexer.refreshSessions(
                root: preferences.sessionsRoot, scope: scope)
            let notes = await notesStore.all()
            notesSnapshot = notes
            apply(notes: notes, to: &sessions)
            allSessions = sessions
            rebuildCanonicalCwdCache()
            await computeCalendarCaches()
            applyFilters()
            startBackgroundEnrichment()
            Task { await self.refreshGlobalCount() }
            // 刷新侧边栏路径树，确保新增文件通过刷新即可出现
            Task {
                let counts = await indexer.collectCWDCounts(root: preferences.sessionsRoot)
                let tree = counts.buildPathTreeFromCounts()
                await MainActor.run { self.pathTreeRootPublished = tree }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
        notesSnapshot[session.id] = SessionNotesStore.SessionNote(
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
        selectedPath = path
    }

    func setSelectedDay(_ day: Date?) {
        selectedDay = day
    }

    func clearAllFilters() {
        selectedPath = nil
        selectedDay = nil
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

        // 2. 日期过滤
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

        // 3. 搜索过滤
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            filtered = filtered.filter { summary in
                summary.matches(search: term) || fulltextMatches.contains(summary.id)
            }
        }

        // 4. 排序
        filtered = sortOrder.sort(filtered)

        // 5. 分组
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
        let sessions = allSessions  // snapshot
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
                }
            }
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
                // Updated 维度：需要加载整个月的数据，因为文件可能在其他日期目录
                // 然后在 applyFilters 中根据 lastUpdatedAt 过滤
                return .month(day)
            }
        }
        // 无日期过滤时：加载所有数据
        return .all
    }
}

extension SessionListViewModel {
    private func apply(
        notes: [String: SessionNotesStore.SessionNote], to sessions: inout [SessionSummary]
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
}

extension SessionListViewModel {
    fileprivate func cacheKey(_ monthStart: Date, _ dimension: DateDimension) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return dimension.rawValue + "|" + df.string(from: monthStart)
    }
}
