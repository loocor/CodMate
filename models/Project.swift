import Foundation

struct Project: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var name: String
    var directory: String? // Optional: projects are virtual; directory not required
    var trustLevel: String?
    var overview: String?
    var instructions: String?
    var profileId: String?
    var profile: ProjectProfile?
    var parentId: String?
    var sources: Set<ProjectSessionSource> = Set(ProjectSessionSource.allCases)
}

struct ProjectProfile: Codable, Hashable, Sendable {
    var model: String?
    var sandbox: SandboxMode?
    var approval: ApprovalPolicy?
    var fullAuto: Bool?
    var dangerouslyBypass: Bool?
    // Extra runtime enrichments
    var pathPrepend: [String]?
    var env: [String:String]?
}

enum ProjectSessionSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

extension ProjectSessionSource {
    static var allSet: Set<ProjectSessionSource> { Set(allCases) }

    var sessionSource: SessionSource {
        switch self {
        case .codex: return .codexLocal
        case .claude: return .claudeLocal
        }
    }
}

extension SessionSource {
    var projectSource: ProjectSessionSource {
        switch self {
        case .codexLocal, .codexRemote: return .codex
        case .claudeLocal, .claudeRemote: return .claude
        }
    }

    func friendlyModelName(for raw: String) -> String {
        switch self {
        case .codexLocal, .codexRemote:
            return raw
        case .claudeLocal, .claudeRemote:
            return Self.normalizeClaudeModel(raw)
        }
    }

    private static func normalizeClaudeModel(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("claude-") {
            name.removeFirst("claude-".count)
        }

        if let dash = name.lastIndex(of: "-"), dash != name.startIndex {
            let suffix = name[name.index(after: dash)...]
            if suffix.count == 8, suffix.allSatisfy({ $0.isNumber }) {
                name = String(name[..<dash])
            }
        }

        let parts = name.split(separator: "-")
        guard let head = parts.first else { return raw }
        let tail = parts.dropFirst()
        if !tail.isEmpty, tail.allSatisfy({ $0.allSatisfy({ $0.isNumber }) }) {
            let version = tail.joined(separator: ".")
            return "\(head)-\(version)"
        }
        return name
    }
}
