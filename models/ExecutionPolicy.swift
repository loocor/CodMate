import Foundation

enum SandboxMode: String, CaseIterable, Identifiable, Codable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .readOnly: return "read-only"
        case .workspaceWrite: return "workspace-write"
        case .dangerFullAccess: return "danger-full-access"
        }
    }
}

enum ApprovalPolicy: String, CaseIterable, Identifiable, Codable {
    case untrusted
    case onFailure = "on-failure"
    case onRequest = "on-request"
    case never

    var id: String { rawValue }
    var title: String {
        switch self {
        case .untrusted: return "untrusted"
        case .onFailure: return "on-failure"
        case .onRequest: return "on-request"
        case .never: return "never"
        }
    }
}

// Claude Code specific permission mode
enum ClaudePermissionMode: String, CaseIterable, Identifiable, Codable {
    case `default`
    case acceptEdits
    case bypassPermissions
    case plan
    var id: String { rawValue }
}

struct ResumeOptions {
    var sandbox: SandboxMode?
    var approval: ApprovalPolicy?
    var fullAuto: Bool
    var dangerouslyBypass: Bool
    // Claude Code advanced flags (optional)
    var claudeDebug: Bool = false
    var claudeDebugFilter: String? = nil
    var claudeVerbose: Bool = false
    var claudePermissionMode: ClaudePermissionMode? = nil
    var claudeAllowedTools: String? = nil
    var claudeDisallowedTools: String? = nil
    var claudeAddDirs: String? = nil
    var claudeIDE: Bool = false
    var claudeStrictMCP: Bool = false
    var claudeFallbackModel: String? = nil
    var claudeSkipPermissions: Bool = false
    var claudeAllowSkipPermissions: Bool = false
    var claudeAllowUnsandboxedCommands: Bool = false
}

extension ResumeOptions {
    var flagSandboxRaw: String? { sandbox?.rawValue }
    var flagApprovalRaw: String? { approval?.rawValue }
}
