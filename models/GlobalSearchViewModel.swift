import Foundation
#if canImport(Darwin)
  import Darwin
#endif

@MainActor
final class GlobalSearchViewModel: ObservableObject {
  @Published var query: String = "" {
    didSet {
      guard query != oldValue else { return }
      Task { [weak self] in self?.handleQueryChange(oldValue: oldValue) }
    }
  }
  @Published private(set) var results: [GlobalSearchResult] = []
  @Published private(set) var filteredResults: [GlobalSearchResult] = []
  @Published var filter: GlobalSearchFilter = .all {
    didSet {
      guard oldValue != filter else { return }
      Task { [weak self] in
        guard let self else { return }
        self.applyFilter()
        let trimmed = self.trimmedQuery
        guard !trimmed.isEmpty else { return }
        self.restartSearch(term: trimmed)
      }
    }
  }
  @Published var isSearching = false
  @Published var errorMessage: String?
  @Published var hasFocus = false
  @Published var ripgrepProgress: GlobalSearchProgress?
  @Published private(set) var isPanelVisible = false

  var shouldShowPanel: Bool {
    return isPanelVisible
  }

  private let service: GlobalSearchService
  private let preferences: SessionPreferencesStore
  private weak var sessionListViewModel: SessionListViewModel?
  private var searchTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var lastRequestSignature: String = ""
  private let debounceNanoseconds: UInt64 = 220_000_000
  private let maxResults = 160
  private let maxMatchesPerFile = 3
  private let batchSize = 12
  private var seenResultKeys: Set<String> = []
  private var queryVersion: UInt64 = 0

  init(
    service: GlobalSearchService = GlobalSearchService(),
    preferences: SessionPreferencesStore,
    sessionListViewModel: SessionListViewModel?
  ) {
    self.service = service
    self.preferences = preferences
    self.sessionListViewModel = sessionListViewModel
  }

  deinit {
    searchTask?.cancel()
    Task { [service] in await service.cancelRipgrep() }
    debounceTask?.cancel()
  }

  func submit() {
    debounceTask?.cancel()
    let trimmed = trimmedQuery
    guard !trimmed.isEmpty else { return }
    restartSearch(term: trimmed)
  }

  func clearQuery() {
    query = ""
    errorMessage = nil
    cancelActiveSearchTasks()
    debounceTask?.cancel()
    results.removeAll()
    filteredResults.removeAll()
    lastRequestSignature = ""
    ripgrepProgress = nil
    isSearching = false
    seenResultKeys.removeAll()
    queryVersion &+= 1
  }

  func setFocus(_ active: Bool) {
    hasFocus = active
    if active {
      isPanelVisible = true
    }
    if !active, trimmedQuery.isEmpty {
      results.removeAll()
      filteredResults.removeAll()
    }
  }

  func dismissPanel() {
    hasFocus = false
    isPanelVisible = false
  }

  func resetSearchState() {
    query = ""
    filter = .all
    results.removeAll()
    filteredResults.removeAll()
    ripgrepProgress = nil
    errorMessage = nil
    isSearching = false
    seenResultKeys.removeAll()
    isPanelVisible = true
    hasFocus = true
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func handleQueryChange(oldValue: String) {
    debounceTask?.cancel()
    let trimmed = trimmedQuery
    guard !trimmed.isEmpty else {
      cancelActiveSearchTasks()
      results.removeAll()
      filteredResults.removeAll()
      errorMessage = nil
      lastRequestSignature = ""
      ripgrepProgress = nil
      isSearching = false
      return
    }

    let versionSnapshot = queryVersion
    debounceTask = Task { [weak self] in
      guard let self else { return }
      if self.queryVersion != versionSnapshot { return }
      if self.debounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: self.debounceNanoseconds)
      }
      if self.queryVersion != versionSnapshot { return }
      if self.trimmedQuery != trimmed { return }
      self.restartSearch(term: trimmed)
    }
  }

  private func restartSearch(term: String) {
    cancelActiveSearchTasks()
    errorMessage = nil
    results.removeAll()
    filteredResults.removeAll()
    isSearching = true
    ripgrepProgress = nil
    seenResultKeys.removeAll()

    let request = makeRequest(term: term)
    let signature = makeSignature(term: term, scope: request.scope)
    lastRequestSignature = signature
    let service = self.service

    let requestSignature = signature
    searchTask = Task { [weak self] in
      guard let self else { return }
      await service.search(
        request: request,
        onBatch: { [weak self] hits in
          guard let self else { return }
          await self.handleBatch(hits, signature: requestSignature)
        },
        onProgress: { [weak self] progress in
          guard let self else { return }
          await self.handleProgress(progress, signature: requestSignature)
        },
        onCompletion: { [weak self] in
          guard let self else { return }
          await self.handleCompletion(signature: requestSignature)
        }
      )
    }
  }

  func cancelBackgroundSearch() {
    cancelActiveSearchTasks()
  }

  private func cancelActiveSearchTasks() {
    searchTask?.cancel()
    searchTask = nil
    Task { [service] in await service.cancelRipgrep() }
  }

  @MainActor
  private func handleBatch(_ hits: [GlobalSearchHit], signature: String) {
    guard lastRequestSignature == signature else { return }
    let hydrated = hydrate(hits: hits)
    let deduped = hydrated.filter { hit in
      let key = dedupeKey(for: hit)
      if seenResultKeys.contains(key) { return false }
      seenResultKeys.insert(key)
      return true
    }
    guard !deduped.isEmpty else { return }
    results.append(contentsOf: deduped)
    sortResults()
    applyFilter()
  }

  @MainActor
  private func handleProgress(_ progress: GlobalSearchProgress, signature: String) {
    guard lastRequestSignature == signature else { return }
    ripgrepProgress = progress
  }

  @MainActor
  private func handleCompletion(signature: String) {
    if lastRequestSignature == signature {
      isSearching = false
    }
    searchTask = nil
  }

  private func dedupeKey(for result: GlobalSearchResult) -> String {
    var components: [String] = [result.kind.rawValue, result.fileURL.path]
    if let snippet = result.snippet?.text.lowercased(), !snippet.isEmpty {
      components.append("snippet:\(snippet)")
    } else if let noteId = result.note?.id {
      components.append("note:\(noteId)")
    } else if let projectId = result.project?.id {
      components.append("project:\(projectId)")
    } else if let sessionId = result.sessionSummary?.id {
      components.append("session:\(sessionId)")
    } else {
      components.append("raw:\(result.id)")
    }
    return components.joined(separator: "|")
  }

  private func hydrate(hits: [GlobalSearchHit]) -> [GlobalSearchResult] {
    guard !hits.isEmpty else { return [] }
    let sessionMap: [String: SessionSummary]
    if let store = sessionListViewModel {
      let snapshot = store.sessionsSnapshot()
      sessionMap = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.fileURL.path, $0) })
    } else {
      sessionMap = [:]
    }
    return hits.map { hit in
      var summary: SessionSummary? = nil
      if hit.kind == .session {
        summary = sessionMap[hit.fileURL.path]
      } else if hit.kind == .note, summary == nil, let noteId = hit.note?.id {
        summary = sessionListViewModel?.sessionSummary(withId: noteId)
      }
      return GlobalSearchResult(hit: hit, sessionSummary: summary)
    }
  }

  private func applyFilter() {
    if filter == .all {
      filteredResults = results
    } else {
      filteredResults = results.filter { $0.kind == filter.kind }
    }
  }

  private func sortResults() {
    results.sort { lhs, rhs in
      if lhs.score == rhs.score {
        return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
      }
      return lhs.score > rhs.score
    }
  }

  private func makeRequest(term: String) -> GlobalSearchService.Request {
    let paths = resolvedPaths()
    let scope = filter.scope
    return GlobalSearchService.Request(
      term: term,
      scope: scope,
      paths: paths,
      maxMatchesPerFile: maxMatchesPerFile,
      batchSize: batchSize,
      limit: maxResults
    )
  }

  private func resolvedPaths() -> GlobalSearchPaths {
    let current = preferences.sessionsRoot
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let defaultRoot = SessionPreferencesStore.defaultSessionsRoot(for: home)
    var sessionRoots: [URL] = [current]
    if defaultRoot != current { sessionRoots.append(defaultRoot) }
    if let claudeRoot = Self.defaultClaudeSessionsRoot(), FileManager.default.fileExists(atPath: claudeRoot.path) {
      if !sessionRoots.contains(claudeRoot) { sessionRoots.append(claudeRoot) }
    }
    return GlobalSearchPaths(
      sessionRoots: sessionRoots,
      notesRoot: preferences.notesRoot,
      projectsRoot: preferences.projectsRoot
    )
  }

  private func makeSignature(term: String, scope: GlobalSearchScope) -> String {
    "\(term.lowercased())|\(scope.rawValue)"
  }

  private static func defaultClaudeSessionsRoot() -> URL? {
    #if canImport(Darwin)
      if let pwDir = getpwuid(getuid())?.pointee.pw_dir {
        let path = String(cString: pwDir)
        return URL(fileURLWithPath: path, isDirectory: true)
          .appendingPathComponent(".claude", isDirectory: true)
          .appendingPathComponent("projects", isDirectory: true)
      }
    #endif
    if let home = ProcessInfo.processInfo.environment["HOME"] {
      return URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("projects", isDirectory: true)
    }
    let fallback = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
    return fallback
  }
}
