import Foundation

struct Project: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var directory: String
    var trustLevel: String?
    var overview: String?
    var instructions: String?
    var profileId: String?
}

