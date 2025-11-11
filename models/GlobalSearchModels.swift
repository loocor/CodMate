import Foundation

struct GlobalSearchSnippet: Hashable, Sendable {
  let text: String
  let highlightRange: Range<Int>?

  init(text: String, highlightRange: Range<Int>? = nil) {
    self.text = text
    self.highlightRange = highlightRange
  }
}

enum GlobalSearchSnippetFactory {
  static func snippet(
    in text: String,
    matchRange: Range<String.Index>,
    radius: Int = 90
  ) -> GlobalSearchSnippet {
    let start = text.index(matchRange.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(matchRange.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
    let snippetRange = start..<end
    let rawSnippet = String(text[snippetRange])
    let highlightStart = text.distance(from: snippetRange.lowerBound, to: matchRange.lowerBound)
    let highlightLength = text.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
    let range = highlightStart..<(highlightStart + highlightLength)
    let sanitized = rawSnippet.sanitizedSnippetText(preserving: range)
    return GlobalSearchSnippet(text: sanitized.text, highlightRange: sanitized.range)
  }
}

enum GlobalSearchResultKind: String, CaseIterable, Identifiable, Sendable {
  case session
  case note
  case project

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .session: return "Sessions"
    case .note: return "Notes"
    case .project: return "Projects"
    }
  }

  var symbolName: String {
    switch self {
    case .session: return "terminal"
    case .note: return "note.text"
    case .project: return "square.grid.2x2"
    }
  }
}

struct GlobalSearchScope: OptionSet, Sendable {
  let rawValue: Int

  static let sessions = GlobalSearchScope(rawValue: 1 << 0)
  static let notes = GlobalSearchScope(rawValue: 1 << 1)
  static let projects = GlobalSearchScope(rawValue: 1 << 2)

  static let all: GlobalSearchScope = [.sessions, .notes, .projects]
}

struct GlobalSearchPaths: Sendable {
  var sessionRoots: [URL]
  var notesRoot: URL?
  var projectsRoot: URL?
  var projectMetadataRoot: URL? {
    projectsRoot?.appendingPathComponent("metadata", isDirectory: true)
  }

  init(sessionRoots: [URL], notesRoot: URL?, projectsRoot: URL?) {
    self.sessionRoots = sessionRoots
    self.notesRoot = notesRoot
    self.projectsRoot = projectsRoot
  }
}

struct GlobalSearchHit: Identifiable, Hashable, Sendable {
  let id: String
  let kind: GlobalSearchResultKind
  let fileURL: URL
  let snippet: GlobalSearchSnippet?
  let fallbackTitle: String
  let note: SessionNote?
  let project: Project?
  let metadataDate: Date?
  let score: Double

  init(
    id: String,
    kind: GlobalSearchResultKind,
    fileURL: URL,
    snippet: GlobalSearchSnippet?,
    fallbackTitle: String,
    note: SessionNote? = nil,
    project: Project? = nil,
    metadataDate: Date? = nil,
    score: Double = 0
  ) {
    self.id = id
    self.kind = kind
    self.fileURL = fileURL
    self.snippet = snippet
    self.fallbackTitle = fallbackTitle
    self.note = note
    self.project = project
    self.metadataDate = metadataDate
    self.score = score
  }
}

struct GlobalSearchResult: Identifiable, Hashable, Sendable {
  let id: String
  let kind: GlobalSearchResultKind
  let fileURL: URL
  let snippet: GlobalSearchSnippet?
  let fallbackTitle: String
  var sessionSummary: SessionSummary?
  var note: SessionNote?
  var project: Project?
  var metadataDate: Date?
  var score: Double

  init(hit: GlobalSearchHit, sessionSummary: SessionSummary? = nil) {
    self.id = hit.id
    self.kind = hit.kind
    self.fileURL = hit.fileURL
    self.snippet = hit.snippet
    self.fallbackTitle = hit.fallbackTitle
    self.sessionSummary = sessionSummary
    self.note = hit.note
    self.project = hit.project
    self.metadataDate = hit.metadataDate
    self.score = hit.score
  }

  init(
    id: String,
    kind: GlobalSearchResultKind,
    fileURL: URL,
    snippet: GlobalSearchSnippet?,
    fallbackTitle: String,
    sessionSummary: SessionSummary?,
    note: SessionNote?,
    project: Project?,
    metadataDate: Date?,
    score: Double
  ) {
    self.id = id
    self.kind = kind
    self.fileURL = fileURL
    self.snippet = snippet
    self.fallbackTitle = fallbackTitle
    self.sessionSummary = sessionSummary
    self.note = note
    self.project = project
    self.metadataDate = metadataDate
    self.score = score
  }

  var displayTitle: String {
    switch kind {
    case .session:
      return sessionSummary?.effectiveTitle ?? fallbackTitle
    case .note:
      let trimmed = note?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let trimmed, !trimmed.isEmpty { return trimmed }
      return fallbackTitle
    case .project:
      let trimmed = project?.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if let trimmed, !trimmed.isEmpty { return trimmed }
      return fallbackTitle
    }
  }

  var detailLine: String? {
    switch kind {
    case .session:
      guard let summary = sessionSummary else { return fileURL.deletingPathExtension().lastPathComponent }
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      formatter.timeStyle = .short
      let timestamp = formatter.string(from: summary.lastUpdatedAt ?? summary.startedAt)
      return "Updated · \(timestamp)"
    case .note:
      if let updated = note?.updatedAt {
        let formatter = RelativeDateTimeFormatter()
        let rel = formatter.localizedString(for: updated, relativeTo: Date())
        return "Note · \(rel)"
      }
      return "Note"
    case .project:
      if let dir = project?.directory { return dir }
      return "Project"
    }
  }
}

enum GlobalSearchFilter: Hashable, CaseIterable, Identifiable {
  case all
  case notes
  case projects
  case sessions

  static var allCases: [GlobalSearchFilter] { [.all, .notes, .projects, .sessions] }

  var id: String { title }

  var title: String {
    switch self {
    case .all: return "All"
    case .sessions: return "Sessions"
    case .notes: return "Notes"
    case .projects: return "Projects"
    }
  }

  var scope: GlobalSearchScope {
    switch self {
    case .all: return .all
    case .sessions: return [.sessions]
    case .notes: return [.notes]
    case .projects: return [.projects]
    }
  }
}

enum GlobalSearchPanelStyle: String, CaseIterable, Identifiable, Sendable {
  case floating
  case popover

  var id: String { rawValue }

  var title: String {
    switch self {
    case .floating: return "Floating"
    case .popover: return "Popover"
    }
  }
}

extension GlobalSearchFilter {
  var kind: GlobalSearchResultKind? {
    switch self {
    case .all: return nil
    case .sessions: return .session
    case .notes: return .note
    case .projects: return .project
    }
  }
}

struct GlobalSearchProgress: Equatable, Hashable, Sendable {
  enum Phase: String, Sendable { case ripgrep }
  var phase: Phase
  var filesProcessed: Int
  var matchesFound: Int
  var message: String
  var isFinished: Bool
  var isCancelled: Bool

  static func ripgrep(message: String, files: Int, matches: Int, finished: Bool, cancelled: Bool = false)
    -> GlobalSearchProgress
  {
    GlobalSearchProgress(
      phase: .ripgrep,
      filesProcessed: files,
      matchesFound: matches,
      message: message,
      isFinished: finished,
      isCancelled: cancelled
    )
  }
}

extension String {
  func rangeFromByteOffsets(start: Int, end: Int) -> Range<String.Index>? {
    guard start >= 0, end >= start else { return nil }
    guard
      let lowerUTF8 = utf8.index(utf8.startIndex, offsetBy: start, limitedBy: utf8.endIndex),
      let upperUTF8 = utf8.index(utf8.startIndex, offsetBy: end, limitedBy: utf8.endIndex),
      let lower = String.Index(lowerUTF8, within: self),
      let upper = String.Index(upperUTF8, within: self)
    else { return nil }
    return lower..<upper
  }

  fileprivate func collapsingWhitespace() -> String {
    var result = ""
    result.reserveCapacity(count)
    var pendingSpace = false
    for character in self {
      if character.isWhitespace {
        pendingSpace = true
        continue
      }
      if pendingSpace, !result.isEmpty {
        result.append(" ")
      }
      pendingSpace = false
      result.append(character)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func sanitizedSnippetText() -> String {
    sanitizedSnippetText(preserving: nil).text
  }

  func sanitizedSnippetText(preserving range: Range<Int>?) -> (text: String, range: Range<Int>?) {
    let characters = Array(self)
    var mapping = Array(repeating: 0, count: characters.count + 1)
    var sanitizedIndex = 0
    var idx = 0
    var result = ""
    var pendingSpace = false
    var skipNextLiteral = false

    while idx < characters.count {
      mapping[idx] = sanitizedIndex
      let char = characters[idx]
      if skipNextLiteral {
        skipNextLiteral = false
        pendingSpace = true
        idx += 1
        continue
      }
      if char.isWhitespace {
        pendingSpace = true
        idx += 1
        continue
      }
      if char == "\\", idx + 1 < characters.count {
        let next = characters[idx + 1]
        if next == "n" || next == "r" || next == "t" {
          pendingSpace = true
          skipNextLiteral = true
          idx += 1
          continue
        }
      }
      if pendingSpace && !result.isEmpty {
        result.append(" ")
        sanitizedIndex += 1
        pendingSpace = false
      }
      result.append(char)
      sanitizedIndex += 1
      idx += 1
    }
    mapping[characters.count] = sanitizedIndex

    let sanitizedRange = range.flatMap { original -> Range<Int>? in
      guard original.lowerBound < mapping.count, original.upperBound < mapping.count else {
        return nil
      }
      let lower = mapping[original.lowerBound]
      let upper = mapping[original.upperBound]
      guard lower <= upper else { return nil }
      return lower..<upper
    }
    return (result, sanitizedRange)
  }
}
