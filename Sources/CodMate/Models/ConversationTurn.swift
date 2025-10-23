import Foundation

struct ConversationTurn: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let userMessage: TimelineEvent?
    let outputs: [TimelineEvent]

    var allEvents: [TimelineEvent] {
        var items: [TimelineEvent] = []
        if let userMessage {
            items.append(userMessage)
        }
        items.append(contentsOf: outputs)
        return items
    }

    var actorSummary: String {
        actorSummary(using: "Codex")
    }

    func actorSummary(using assistantName: String) -> String {
        var parts: [String] = []
        if userMessage != nil {
            parts.append("User")
        }
        var seen: Set<TimelineActor> = []
        for event in outputs {
            if seen.insert(event.actor).inserted {
                parts.append(event.actor.displayName(assistantName: assistantName))
            }
        }
        if parts.isEmpty, let first = outputs.first {
            parts.append(first.actor.displayName(assistantName: assistantName))
        }
        return parts.joined(separator: " → ")
    }

    var previewText: String? {
        var snippets: [String] = []
        if let text = userMessage?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            snippets.append(text)
        }
        if let assistantReply = outputs.first(where: { $0.actor == .assistant })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !assistantReply.isEmpty
        {
            snippets.append(assistantReply)
        } else if let other = outputs.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !other.isEmpty
        {
            snippets.append(other)
        }
        guard !snippets.isEmpty else { return nil }
        return snippets.joined(separator: "\n")
    }
}

private extension TimelineActor {
    func displayName(assistantName: String = "Codex") -> String {
        switch self {
        case .user: return "User"
        case .assistant: return assistantName
        case .tool: return "Tool"
        case .info: return "Info"
        }
    }
}

extension Array where Element == ConversationTurn {
    func removingEnvironmentContext() -> [ConversationTurn] {
        compactMap { turn in
            let filteredUser = (turn.userMessage?.title == TimelineEvent.environmentContextTitle)
                ? nil : turn.userMessage
            let filteredOutputs = turn.outputs.filter { $0.title != TimelineEvent.environmentContextTitle }
            if filteredUser == nil && filteredOutputs.isEmpty {
                return nil
            }
            if filteredUser == turn.userMessage && filteredOutputs.count == turn.outputs.count {
                return turn
            }
            return ConversationTurn(
                id: turn.id,
                timestamp: turn.timestamp,
                userMessage: filteredUser,
                outputs: filteredOutputs
            )
        }
    }

    func filtering(visibleKinds: Set<MessageVisibilityKind>) -> [ConversationTurn] {
        compactMap { turn in
            let userAllowed: Bool = {
                guard let u = turn.userMessage else { return false }
                return visibleKinds.contains(event: u)
            }()
            let keptOutputs = turn.outputs.filter { visibleKinds.contains(event: $0) }
            if !userAllowed && keptOutputs.isEmpty { return nil }
            return ConversationTurn(
                id: turn.id,
                timestamp: turn.timestamp,
                userMessage: userAllowed ? turn.userMessage : nil,
                outputs: keptOutputs
            )
        }
    }
}
