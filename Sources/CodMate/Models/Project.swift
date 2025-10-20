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
