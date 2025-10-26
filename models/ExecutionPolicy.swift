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

struct ResumeOptions {
    var sandbox: SandboxMode?
    var approval: ApprovalPolicy?
    var fullAuto: Bool
    var dangerouslyBypass: Bool
}

extension ResumeOptions {
    var flagSandboxRaw: String? { sandbox?.rawValue }
    var flagApprovalRaw: String? { approval?.rawValue }
}
