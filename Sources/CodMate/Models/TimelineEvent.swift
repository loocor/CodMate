import Foundation

enum TimelineActor {
    case user
    case assistant
    case tool
    case info
}

struct TimelineEvent: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let actor: TimelineActor
    let title: String?
    let text: String?
    let metadata: [String: String]?
}

