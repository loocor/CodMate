import Foundation

enum UsageProviderKind: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    var accentColorName: String {
        switch self {
        case .codex: return "accentColor"
        case .claude: return "purple"
        }
    }
}

struct UsageMetricSnapshot: Identifiable, Equatable {
    enum Kind { case context, fiveHour, weekly, snapshot }

    let id = UUID()
    let kind: Kind
    let label: String
    let usageText: String?
    let percentText: String?
    let progress: Double?
    let resetDate: Date?
    let fallbackWindowMinutes: Int?

    var priorityDate: Date? { resetDate }
}

struct UsageProviderSnapshot: Identifiable, Equatable {
    enum Availability { case ready, empty, comingSoon }

    let id = UUID()
    let provider: UsageProviderKind
    let title: String
    let availability: Availability
    let metrics: [UsageMetricSnapshot]
    let updatedAt: Date?
    let statusMessage: String?

    init(provider: UsageProviderKind,
        title: String,
        availability: Availability,
        metrics: [UsageMetricSnapshot],
        updatedAt: Date?,
        statusMessage: String? = nil)
    {
        self.provider = provider
        self.title = title
        self.availability = availability
        self.metrics = metrics
        self.updatedAt = updatedAt
        self.statusMessage = statusMessage
    }

    var urgentMetric: UsageMetricSnapshot? {
        metrics
            .sorted(by: { a, b in
                switch (a.priorityDate, b.priorityDate) {
                case let (lhs?, rhs?): return lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.kind == .fiveHour
                }
            })
            .first
    }

    static func placeholder(_ provider: UsageProviderKind, message: String) -> UsageProviderSnapshot {
        UsageProviderSnapshot(
            provider: provider,
            title: provider.displayName,
            availability: .comingSoon,
            metrics: [],
            updatedAt: nil,
            statusMessage: message
        )
    }
}
