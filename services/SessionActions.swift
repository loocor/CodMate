import AppKit
import Foundation

struct ProcessResult {
    let output: String
}

enum SessionActionError: LocalizedError {
    case executableNotFound(URL)
    case resumeFailed(output: String)
    case deletionFailed(URL)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let url):
            return "Executable codex CLI not found: \(url.path)"
        case .resumeFailed(let output):
            return "Failed to resume session: \(output)"
        case .deletionFailed(let url):
            return "Failed to move file to Trash: \(url.path)"
        }
    }
}

struct SessionActions {
    let fileManager: FileManager = .default
    let codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)


}
