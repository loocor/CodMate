import Foundation

enum ProjectWorkspaceMode: String, Codable, Hashable, CaseIterable {
    case overview
    case tasks
    case sessions  // For "Other" - manage unassigned sessions
    case review
    case agents
    case memory
    case settings
}
