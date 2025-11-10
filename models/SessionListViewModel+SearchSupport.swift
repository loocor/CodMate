import Foundation

@MainActor
extension SessionListViewModel {
  func sessionsSnapshot() -> [SessionSummary] { allSessions }

  func sessionSummary(withId id: String) -> SessionSummary? {
    allSessions.first { $0.id == id }
  }

  func sessionSummary(forFileURL url: URL) -> SessionSummary? {
    allSessions.first { $0.fileURL == url }
  }
}
