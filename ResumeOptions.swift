import Foundation

/// Sandbox mode options for CLI execution
enum SandboxMode: String, CaseIterable, Identifiable {
    case none = "none"
    case workspaceRead = "workspace-read"
    case workspaceWrite = "workspace-write"
    case full = "full"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .none: return "None"
        case .workspaceRead: return "Workspace Read"
        case .workspaceWrite: return "Workspace Write"
        case .full: return "Full Sandbox"
        }
    }
}

/// Approval policy for CLI operations
enum ApprovalPolicy: String, CaseIterable, Identifiable {
    case auto = "auto"
    case onRequest = "on-request"
    case manual = "manual"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .onRequest: return "On Request"
        case .manual: return "Manual"
        }
    }
}

/// Options for resuming a session
struct ResumeOptions {
    var sandbox: SandboxMode?
    var approval: ApprovalPolicy?
    var fullAuto: Bool
    var dangerouslyBypass: Bool
    
    init(
        sandbox: SandboxMode? = nil,
        approval: ApprovalPolicy? = nil,
        fullAuto: Bool = false,
        dangerouslyBypass: Bool = false
    ) {
        self.sandbox = sandbox
        self.approval = approval
        self.fullAuto = fullAuto
        self.dangerouslyBypass = dangerouslyBypass
    }
}
