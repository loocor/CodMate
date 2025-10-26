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

// MARK: - Message visibility kinds and helpers
enum MessageVisibilityKind: String, CaseIterable, Identifiable {
    case user
    case assistant
    case tool
    case syncing        // turn context updates
    case environment    // environment context blocks
    case reasoning      // agent reasoning summaries
    case tokenUsage     // token usage counters
    case infoOther      // other info messages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tool: return "Tool"
        case .syncing: return "Syncing"
        case .environment: return "Environment Context"
        case .reasoning: return "Reasoning"
        case .tokenUsage: return "Token Usage"
        case .infoOther: return "Other Info"
        }
    }
}

extension MessageVisibilityKind {
    static let timelineDefault: Set<MessageVisibilityKind> = [
        .user, .assistant, .tool, .syncing, .reasoning, .tokenUsage, .infoOther
        // environment context is shown in its dedicated section by default
    ]

    static let markdownDefault: Set<MessageVisibilityKind> = [
        .user, .assistant
    ]
}

extension Set where Element == MessageVisibilityKind {
    func contains(event: TimelineEvent) -> Bool {
        switch event.actor {
        case .user: return contains(.user)
        case .assistant: return contains(.assistant)
        case .tool: return contains(.tool)
        case .info:
            if event.title == TimelineEvent.environmentContextTitle { return contains(.environment) }

            let lower = (event.title ?? "").lowercased()
            if lower.contains("agent reasoning") || lower == "agent reasoning" { return contains(.reasoning) }
            if lower.contains("token usage") { return contains(.tokenUsage) }
            if lower == "context updated" { return contains(.syncing) }
            return contains(.infoOther)
        }
    }
}
