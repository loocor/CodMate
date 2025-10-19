import Foundation

enum TimelineActor: Hashable {
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
    let repeatCount: Int

    init(
        id: String,
        timestamp: Date,
        actor: TimelineActor,
        title: String?,
        text: String?,
        metadata: [String: String]?,
        repeatCount: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actor = actor
        self.title = title
        self.text = text
        self.metadata = metadata
        self.repeatCount = repeatCount
    }

    func incrementingRepeatCount() -> TimelineEvent {
        TimelineEvent(
            id: id,
            timestamp: timestamp,
            actor: actor,
            title: title,
            text: text,
            metadata: metadata,
            repeatCount: repeatCount + 1
        )
    }
}

extension TimelineEvent {
    static let environmentContextTitle = "Environment Context"
}
