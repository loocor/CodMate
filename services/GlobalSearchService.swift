import Foundation

#if canImport(Darwin)
  import Darwin
#endif

actor GlobalSearchService {
  struct Request: Sendable {
    let term: String
    let scope: GlobalSearchScope
    let paths: GlobalSearchPaths
    let maxMatchesPerFile: Int
    let batchSize: Int
    let limit: Int

    init(
      term: String,
      scope: GlobalSearchScope,
      paths: GlobalSearchPaths,
      maxMatchesPerFile: Int = 3,
      batchSize: Int = 12,
      limit: Int = 200
    ) {
      self.term = term
      self.scope = scope.isEmpty ? .all : scope
      self.paths = paths
      self.maxMatchesPerFile = max(maxMatchesPerFile, 1)
      self.batchSize = max(batchSize, 1)
      self.limit = max(limit, 1)
    }
  }

  private let chunkSize = 128 * 1024
  private let snippetRadius = 90
  private let fm = FileManager.default
  private var ripgrepProcess: Process?

  private struct SearchPattern: Sendable {
    let raw: String
    let tokens: [String]
    let ripgrepPattern: String
    let requiresPCRE: Bool

    func score(in text: String) -> Double {
      guard !text.isEmpty else { return 0 }
      if tokens.isEmpty {
        return scoreSingleToken(in: text)
      }
      return scoreMultiToken(in: text)
    }

    private func scoreSingleToken(in text: String) -> Double {
      guard let range = text.range(
        of: raw,
        options: [.caseInsensitive, .diacriticInsensitive]
      ) else { return 0 }
      let offset = text.distance(from: text.startIndex, to: range.lowerBound)
      let anchorBoost = 1.0 / Double(offset + 1)
      return min(1.0, 0.5 + anchorBoost * 0.5)
    }

    private func scoreMultiToken(in text: String) -> Double {
      let lowered = text.lowercased()
      let matches = tokens.compactMap { token -> TokenWindow? in
        guard let range = lowered.range(of: token) else { return nil }
        let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
        let end = lowered.distance(from: lowered.startIndex, to: range.upperBound)
        return TokenWindow(start: start, end: end)
      }
      guard !matches.isEmpty else { return 0 }
      let coverage = Double(matches.count) / Double(tokens.count)
      let minIndex = matches.map(\.start).min() ?? 0
      let maxIndex = matches.map(\.end).max() ?? minIndex
      let span = max(1, maxIndex - minIndex)
      let tightness = Double(matches.count) / Double(span + matches.count)
      var inversions = 0
      for pair in zip(matches, matches.dropFirst()) {
        if pair.1.start < pair.0.start { inversions += 1 }
      }
      let orderScore = 1.0 - (Double(inversions) / Double(max(1, matches.count - 1)))
      let anchor = 1.0 / Double(minIndex + 1)
      let combined = (coverage * 0.35) + (tightness * 0.35) + (orderScore * 0.2) + (anchor * 0.1)
      return min(1.0, max(0.0, combined))
    }

    private struct TokenWindow {
      let start: Int
      let end: Int
    }
  }

  enum RipgrepError: Error {
    case executableMissing
    case failed(String)
  }

  func cancelRipgrep() {
    ripgrepProcess?.terminate()
    ripgrepProcess = nil
  }

  func search(
    request: Request,
    onBatch: @Sendable ([GlobalSearchHit]) async -> Void,
    onProgress: @Sendable (GlobalSearchProgress) async -> Void,
    onCompletion: @Sendable () async -> Void
  ) async {
    let trimmed = request.term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await onCompletion()
      return
    }
    let pattern = buildSearchPattern(for: trimmed)

    let targets = buildTargets(for: request)
    guard !targets.allPaths.isEmpty else {
      await onCompletion()
      return
    }

    do {
      try await runRipgrep(
        pattern: pattern,
        request: request,
        targets: targets,
        onBatch: onBatch,
        onProgress: onProgress
      )
    } catch RipgrepError.executableMissing {
      await onProgress(
        .ripgrep(
          message: "ripgrep not found, falling back to built-in scanner",
          files: 0,
          matches: 0,
          finished: false
        )
      )
      await runFallbackScan(
        pattern: pattern,
        request: request,
        targets: targets,
        onBatch: onBatch
      )
      await onProgress(
        .ripgrep(
          message: "Built-in scan finished",
          files: 0,
          matches: 0,
          finished: true
        )
      )
    } catch {
      await onProgress(
        .ripgrep(
          message: "\(error.localizedDescription)",
          files: 0,
          matches: 0,
          finished: true
        )
      )
    }

    await onCompletion()
  }

  // MARK: - Ripgrep integration

  private struct SearchTargets {
    var sessionRoots: [URL]
    var noteRoot: URL?
    var projectMetadataRoot: URL?

    var allPaths: [URL] {
      var paths = sessionRoots
      if let noteRoot { paths.append(noteRoot) }
      if let projectMetadataRoot { paths.append(projectMetadataRoot) }
      return paths
    }
  }

  private func buildTargets(for request: Request) -> SearchTargets {
    var sessions: [URL] = []
    if request.scope.contains(.sessions) {
      sessions = request.paths.sessionRoots.filter { directoryAccessible($0) }
    }

    var noteRoot: URL? = nil
    if request.scope.contains(.notes),
      let candidate = request.paths.notesRoot?.resolvingSymlinksInPath(),
      directoryAccessible(candidate)
    {
      noteRoot = candidate
    }

    var projectRoot: URL? = nil
    if request.scope.contains(.projects),
      let candidate = request.paths.projectMetadataRoot?.resolvingSymlinksInPath(),
      directoryAccessible(candidate)
    {
      projectRoot = candidate
    }

    return SearchTargets(
      sessionRoots: sessions, noteRoot: noteRoot, projectMetadataRoot: projectRoot)
  }

  private func runRipgrep(
    pattern: SearchPattern,
    request: Request,
    targets: SearchTargets,
    onBatch: @Sendable ([GlobalSearchHit]) async -> Void,
    onProgress: @Sendable (GlobalSearchProgress) async -> Void
  ) async throws {
    let roots = targets.allPaths
    guard !roots.isEmpty else { return }

    var env = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    let existingPath = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"]
    env["PATH"] = [defaultPath, existingPath]
      .compactMap { $0 }
      .joined(separator: ":")

    let process = Process()
    process.environment = env
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var args = [
      "rg",
      "--json",
      "--ignore-case",
      "--hidden",
      "--follow",
      "--no-heading",
      "--color",
      "never",
    ]
    if pattern.requiresPCRE {
      args.append("--pcre2")
    } else {
      args.append("--fixed-strings")
    }
    args.append(pattern.ripgrepPattern)
    args.append(contentsOf: roots.map { $0.path })
    process.arguments = args

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      if (error as NSError).code == ENOENT {
        throw RipgrepError.executableMissing
      }
      throw error
    }

    ripgrepProcess = process

    var pending: [GlobalSearchHit] = []
    var delivered = 0
    var filesProcessed = 0
    var matchesFound = 0
    var cancelled = false
    var terminatedByLimit = false

    await onProgress(
      .ripgrep(
        message: "Searching with ripgrep…",
        files: filesProcessed,
        matches: matchesFound,
        finished: false
      )
    )

    for try await rawLine in stdout.fileHandleForReading.bytes.lines {
      if Task.isCancelled {
        cancelled = true
        process.terminate()
        break
      }
      let line = String(rawLine)
      guard !line.isEmpty else { continue }
      guard
        let event = parseRipgrepEvent(
          from: line,
          request: request,
          targets: targets,
          pattern: pattern
        )
      else { continue }
      switch event {
      case .match(let hit):
        guard delivered < request.limit else {
          terminatedByLimit = true
          process.terminate()
          break
        }
        pending.append(hit)
        delivered += 1
        matchesFound += 1
        if pending.count >= request.batchSize {
          await onBatch(pending)
          pending.removeAll(keepingCapacity: true)
        }
      case .fileEnd:
        filesProcessed += 1
        await onProgress(
          .ripgrep(
            message: "Scanned \(filesProcessed) files",
            files: filesProcessed,
            matches: matchesFound,
            finished: false
          )
        )
      }
    }

    if !pending.isEmpty {
      await onBatch(pending)
    }

    process.waitUntilExit()
    ripgrepProcess = nil

    let normalExit = process.terminationReason == .exit && process.terminationStatus == 0
    if normalExit || cancelled || terminatedByLimit {
      await onProgress(
        .ripgrep(
          message: cancelled
            ? "Search cancelled"
            : (terminatedByLimit ? "Reached result limit" : "Search finished"),
          files: filesProcessed,
          matches: matchesFound,
          finished: true,
          cancelled: cancelled
        )
      )
      return
    }

    let errData = try? stderr.fileHandleForReading.readToEnd()
    let message =
      errData.flatMap { String(data: $0, encoding: .utf8) }
      ?? "ripgrep exit code \(process.terminationStatus)"
    throw RipgrepError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private enum RipgrepParsedEvent {
    case match(GlobalSearchHit)
    case fileEnd
  }

  private func parseRipgrepEvent(
    from line: String,
    request: Request,
    targets: SearchTargets,
    pattern: SearchPattern
  ) -> RipgrepParsedEvent? {
    guard let data = line.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = root["type"] as? String
    else { return nil }

    switch type {
    case "match":
      guard let payload = root["data"] as? [String: Any] else { return nil }
      guard
        let pathDict = payload["path"] as? [String: Any],
        let pathText = pathDict["text"] as? String,
        let linesDict = payload["lines"] as? [String: Any],
        let lineText = linesDict["text"] as? String,
        let submatches = payload["submatches"] as? [[String: Any]],
        let first = submatches.first,
        let start = first["start"] as? Int,
        let end = first["end"] as? Int
      else { return nil }
      guard let kind = classify(path: pathText, request: request, targets: targets) else {
        return nil
      }
      let snippet: GlobalSearchSnippet
      if let range = lineText.rangeFromByteOffsets(start: start, end: end) {
        snippet = GlobalSearchSnippetFactory.snippet(in: lineText, matchRange: range)
      } else {
        snippet = GlobalSearchSnippet(text: lineText.sanitizedSnippetText(), highlightRange: nil)
      }
      let fileURL = URL(fileURLWithPath: pathText)
      switch kind {
      case .session:
        let fallback = fileURL.deletingPathExtension().lastPathComponent
        let lineNumber = payload["line_number"] as? Int ?? 0
        let id = "\(pathText)#\(lineNumber):\(start)"
        let matchScore = Self.combinedScore(for: lineText, pattern: pattern)
        let hit = GlobalSearchHit(
          id: id,
          kind: .session,
          fileURL: fileURL,
          snippet: snippet,
          fallbackTitle: fallback,
          metadataDate: nil,
          score: matchScore
        )
        return .match(hit)
      case .note:
        guard let note = loadNote(at: fileURL) else { return nil }
        let matchScore = Self.combinedScore(
          for: snippet.text,
          pattern: pattern,
          metadataDate: note.updatedAt
        )
        let hit = GlobalSearchHit(
          id: fileURL.path,
          kind: .note,
          fileURL: fileURL,
          snippet: snippet,
          fallbackTitle: note.title ?? note.id,
          note: note,
          metadataDate: note.updatedAt,
          score: matchScore
        )
        return .match(hit)
      case .project:
        guard let projectInfo = loadProject(at: fileURL) else { return nil }
        let matchScore = Self.combinedScore(
          for: snippet.text,
          pattern: pattern,
          metadataDate: projectInfo.updatedAt
        )
        let hit = GlobalSearchHit(
          id: fileURL.path,
          kind: .project,
          fileURL: fileURL,
          snippet: snippet,
          fallbackTitle: projectInfo.project.name,
          project: projectInfo.project,
          metadataDate: projectInfo.updatedAt,
          score: matchScore
        )
        return .match(hit)
      }
    case "end":
      return .fileEnd
    default:
      return nil
    }
  }

  private func classify(path: String, request: Request, targets: SearchTargets)
    -> GlobalSearchResultKind?
  {
    if let noteRoot = targets.noteRoot?.path.normalizedDirectoryPath,
      path.hasPrefix(noteRoot)
    {
      return request.scope.contains(.notes) ? .note : nil
    }
    if let projectRoot = targets.projectMetadataRoot?.path.normalizedDirectoryPath,
      path.hasPrefix(projectRoot)
    {
      return request.scope.contains(.projects) ? .project : nil
    }
    return request.scope.contains(.sessions) ? .session : nil
  }

  // MARK: - Fallback scanner

  private func runFallbackScan(
    pattern: SearchPattern,
    request: Request,
    targets: SearchTargets,
    onBatch: @Sendable ([GlobalSearchHit]) async -> Void
  ) async {
    let workItems = fallbackWorkItems(for: request, targets: targets)
    guard !workItems.isEmpty else { return }

    await withTaskGroup(of: [GlobalSearchHit].self) { group in
      for item in workItems {
        group.addTask { [chunkSize, snippetRadius] in
          if Task.isCancelled { return [] }
          switch item {
          case .session(let url):
            return Self.scanSession(
              url: url,
              pattern: pattern,
              chunkSize: chunkSize,
              snippetRadius: snippetRadius,
              maxMatches: request.maxMatchesPerFile
            )
          case .note(let url):
            return Self.scanNote(url: url, pattern: pattern)
          case .project(let url):
            return Self.scanProject(url: url, pattern: pattern)
          }
        }
      }
      var delivered = 0
      var pending: [GlobalSearchHit] = []
      for await var hits in group {
        if hits.isEmpty { continue }
        let remaining = request.limit - delivered - pending.count
        if remaining <= 0 {
          group.cancelAll()
          break
        }
        if hits.count > remaining { hits = Array(hits.prefix(remaining)) }
        pending.append(contentsOf: hits)
        if pending.count >= request.batchSize {
          delivered += pending.count
          await onBatch(pending)
          pending.removeAll(keepingCapacity: true)
        }
      }
      if !pending.isEmpty {
        await onBatch(pending)
      }
    }
  }

  private enum WorkItem: Hashable {
    case session(URL)
    case note(URL)
    case project(URL)
  }

  private func fallbackWorkItems(for request: Request, targets: SearchTargets) -> [WorkItem] {
    var items: [WorkItem] = []
    var seen = Set<String>()

    if request.scope.contains(.sessions) {
      for root in targets.sessionRoots {
        guard
          let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
          )
        else { continue }
        for case let url as URL in enumerator {
          if url.pathExtension.lowercased() != "jsonl" { continue }
          let path = url.path
          if seen.contains(path) { continue }
          seen.insert(path)
          items.append(.session(url))
        }
      }
    }

    if request.scope.contains(.notes), let noteRoot = targets.noteRoot,
      let enumerator = fm.enumerator(
        at: noteRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    {
      for case let url as URL in enumerator {
        if url.pathExtension.lowercased() != "json" { continue }
        let path = url.path
        if seen.contains(path) { continue }
        seen.insert(path)
        items.append(.note(url))
      }
    }

    if request.scope.contains(.projects), let metaRoot = targets.projectMetadataRoot,
      let enumerator = fm.enumerator(
        at: metaRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    {
      for case let url as URL in enumerator {
        if url.pathExtension.lowercased() != "json" { continue }
        let path = url.path
        if seen.contains(path) { continue }
        seen.insert(path)
        items.append(.project(url))
      }
    }

    return items
  }

  // MARK: - Helpers

  private func directoryAccessible(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
      return false
    }
    return true
  }

  private func loadNote(at url: URL) -> SessionNote? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    return try? decoder.decode(SessionNote.self, from: data)
  }

  private func loadProject(at url: URL) -> (project: Project, updatedAt: Date?)? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let meta = try? decoder.decode(ProjectMeta.self, from: data) else { return nil }
    return (meta.asProject(), meta.updatedAt)
  }

  nonisolated private static func scanSession(
    url: URL,
    pattern: SearchPattern,
    chunkSize: Int,
    snippetRadius: Int,
    maxMatches: Int
  ) -> [GlobalSearchHit] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    var hits: [GlobalSearchHit] = []
    var carry = ""
    let fallback = url.deletingPathExtension().lastPathComponent
    let attributes = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
    let modDate = attributes?.contentModificationDate

    var eofReached = false
    while hits.count < maxMatches && !eofReached {
      if Task.isCancelled { break }
      autoreleasepool {
        guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
          eofReached = true
          return
        }
        guard let string = String(data: chunk, encoding: .utf8) else {
          carry.removeAll(keepingCapacity: false)
          eofReached = true
          return
        }
        let buffer = carry + string
        var searchRange = buffer.startIndex..<buffer.endIndex
        while hits.count < maxMatches,
          let match = findMatchRange(in: buffer, range: searchRange, pattern: pattern)
        {
          let snippet = GlobalSearchSnippetFactory.snippet(
            in: buffer, matchRange: match, radius: snippetRadius)
          let offset = buffer.distance(from: buffer.startIndex, to: match.lowerBound)
          let id = "\(url.path)#\(offset)"
          hits.append(
            GlobalSearchHit(
              id: id,
              kind: .session,
              fileURL: url,
              snippet: snippet,
              fallbackTitle: fallback,
              metadataDate: modDate,
              score: Self.combinedScore(
                for: snippet.text,
                pattern: pattern,
                metadataDate: modDate
              )
            )
          )
          searchRange = match.upperBound..<buffer.endIndex
          if Task.isCancelled { break }
        }
        let keepCount = min(buffer.count, max(pattern.raw.count, snippetRadius))
        carry = String(buffer.suffix(keepCount))
      }
      if eofReached { break }
    }
    return hits
  }

  nonisolated private static func scanNote(url: URL, pattern: SearchPattern) -> [GlobalSearchHit] {
    guard let note = loadNoteStatic(url: url) else { return [] }
    let combined = [note.title, note.comment].compactMap { $0 }.joined(separator: "\n")
    guard let range = findMatchRange(in: combined, pattern: pattern) else { return [] }
    let snippet = GlobalSearchSnippetFactory.snippet(in: combined, matchRange: range)
    return [
      GlobalSearchHit(
        id: url.path,
        kind: .note,
        fileURL: url,
        snippet: snippet,
        fallbackTitle: note.title ?? note.id,
        note: note,
        metadataDate: note.updatedAt,
        score: Self.combinedScore(
          for: snippet.text,
          pattern: pattern,
          metadataDate: note.updatedAt
        )
      )
    ]
  }

  nonisolated private static func loadNoteStatic(url: URL) -> SessionNote? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    return try? decoder.decode(SessionNote.self, from: data)
  }

  nonisolated private static func scanProject(url: URL, pattern: SearchPattern) -> [GlobalSearchHit] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let meta = try? decoder.decode(ProjectMeta.self, from: data) else { return [] }
    let project = meta.asProject()
    let fields = [project.name, project.directory, project.overview, project.instructions]
      .compactMap { $0 }
      .joined(separator: "\n")
    guard let range = findMatchRange(in: fields, pattern: pattern) else { return [] }
    let snippet = GlobalSearchSnippetFactory.snippet(in: fields, matchRange: range)
    return [
      GlobalSearchHit(
        id: url.path,
        kind: .project,
        fileURL: url,
        snippet: snippet,
        fallbackTitle: project.name,
        project: project,
        metadataDate: meta.updatedAt,
        score: Self.combinedScore(
          for: snippet.text,
          pattern: pattern,
          metadataDate: meta.updatedAt
        )
      )
    ]
  }
}

extension GlobalSearchScope {
  fileprivate func contains(kind: GlobalSearchResultKind) -> Bool {
    switch kind {
    case .session: return contains(.sessions)
    case .note: return contains(.notes)
    case .project: return contains(.projects)
    }
  }
}

extension String {
  fileprivate var normalizedDirectoryPath: String {
    if hasSuffix("/") { return self }
    return self + "/"
  }
}

// MARK: - Search pattern helpers

extension GlobalSearchService {
  private func buildSearchPattern(for term: String) -> SearchPattern {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split { $0.isWhitespace }
      .map { String($0) }
      .filter { !$0.isEmpty }
    if parts.count <= 1 {
      return SearchPattern(raw: trimmed, tokens: [], ripgrepPattern: trimmed, requiresPCRE: false)
    }
    let escaped = parts.map { NSRegularExpression.escapedPattern(for: $0) }
    let regex = escaped.map { "(?=.*\($0))" }.joined() + ".*"
    return SearchPattern(
      raw: trimmed,
      tokens: parts.map { $0.lowercased() },
      ripgrepPattern: regex,
      requiresPCRE: true
    )
  }

  private static func findMatchRange(
    in text: String,
    pattern: SearchPattern
  ) -> Range<String.Index>? {
    return findMatchRange(in: text, range: text.startIndex..<text.endIndex, pattern: pattern)
  }

  private static func findMatchRange(
    in text: String,
    range: Range<String.Index>,
    pattern: SearchPattern
  ) -> Range<String.Index>? {
    if pattern.tokens.isEmpty {
      return text.range(
        of: pattern.raw,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: range
      )
    }
    let lowered = text.lowercased()
    guard pattern.tokens.allSatisfy({ lowered.contains($0) }) else { return nil }
    if let first = pattern.tokens.first {
      return text.range(
        of: first,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: range
      )
    }
    return nil
  }

  private static func combinedScore(
    for text: String,
    pattern: SearchPattern,
    metadataDate: Date? = nil,
    positionalBoost: Double = 0
  ) -> Double {
    var score = pattern.score(in: text)
    if let metadataDate {
      score += recencyBoost(for: metadataDate)
    }
    return score + positionalBoost
  }

  private static func recencyBoost(for date: Date) -> Double {
    let elapsed = max(0, Date().timeIntervalSince(date))
    let days = elapsed / 86_400
    let normalized = max(0, 1 - min(1, days / 30))
    return normalized * 0.25
  }
}
