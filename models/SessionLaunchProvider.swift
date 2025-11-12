import Foundation

struct SessionLaunchProvider: Identifiable, Hashable, Sendable {
    let sessionSource: SessionSource

    var id: String { sessionSource.launchIdentifier }
}

extension SessionSource {
    var launchIdentifier: String {
        switch self {
        case .codexLocal:
            return "codex-local"
        case .claudeLocal:
            return "claude-local"
        case .codexRemote(let host):
            return "codex-remote-\(host)"
        case .claudeRemote(let host):
            return "claude-remote-\(host)"
        }
    }
}