import Foundation

enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case archived

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .archived: return "Archived"
        }
    }

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        }
    }
}

enum ContextType: String, Codable, Sendable {
    case userMarked = "user_marked"
    case autoSuggested = "auto_suggested"
}

struct ContextItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var content: String
    var sourceSessionId: String
    var sourceMessageId: String?
    var addedAt: Date
    var type: ContextType

    init(
        id: UUID = UUID(),
        content: String,
        sourceSessionId: String,
        sourceMessageId: String? = nil,
        addedAt: Date = Date(),
        type: ContextType = .userMarked
    ) {
        self.id = id
        self.content = content
        self.sourceSessionId = sourceSessionId
        self.sourceMessageId = sourceMessageId
        self.addedAt = addedAt
        self.type = type
    }
}

struct CodMateTask: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var title: String
    var description: String?
    var projectId: String
    var createdAt: Date
    var updatedAt: Date

    // Shared context
    var sharedContext: [ContextItem]
    var agentsConfig: String? // Reference to Agents.md sections
    var memoryItems: [String] // Memory item IDs

    // Contained sessions
    var sessionIds: [String]

    // Metadata
    var status: TaskStatus
    var tags: [String]

    init(
        id: UUID = UUID(),
        title: String,
        description: String? = nil,
        projectId: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sharedContext: [ContextItem] = [],
        agentsConfig: String? = nil,
        memoryItems: [String] = [],
        sessionIds: [String] = [],
        status: TaskStatus = .pending,
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.projectId = projectId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sharedContext = sharedContext
        self.agentsConfig = agentsConfig
        self.memoryItems = memoryItems
        self.sessionIds = sessionIds
        self.status = status
        self.tags = tags
    }

    var effectiveTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Task" : trimmed
    }

    var effectiveDescription: String? {
        guard let desc = description else { return nil }
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func matches(search term: String) -> Bool {
        guard !term.isEmpty else { return true }
        let needle = term.lowercased()
        let haystack = [
            title,
            description ?? "",
            tags.joined(separator: " "),
            agentsConfig ?? ""
        ].map { $0.lowercased() }

        return haystack.contains(where: { $0.contains(needle) })
    }
}

// CodMateTask with enriched session summaries for display
struct TaskWithSessions: Identifiable, Hashable {
    let task: CodMateTask
    let sessions: [SessionSummary]

    var id: UUID { task.id }

    var totalDuration: TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    var totalTokens: Int {
        sessions.reduce(0) { $0 + $1.turnContextCount }
    }

    var lastActivityDate: Date {
        let sessionDates = sessions.compactMap { $0.lastUpdatedAt ?? $0.startedAt }
        return sessionDates.max() ?? task.updatedAt
    }
}
