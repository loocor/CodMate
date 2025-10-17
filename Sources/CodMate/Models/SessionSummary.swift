import Foundation

struct SessionSummary: Identifiable, Hashable, Sendable {
    let id: String
    let fileURL: URL
    let fileSizeBytes: UInt64?
    let startedAt: Date
    let endedAt: Date?
    let cliVersion: String
    let cwd: String
    let originator: String
    let instructions: String?
    let model: String?
    let approvalPolicy: String?
    let userMessageCount: Int
    let assistantMessageCount: Int
    let toolInvocationCount: Int
    let responseCounts: [String: Int]
    let turnContextCount: Int
    let eventCount: Int
    let lineCount: Int
    let lastUpdatedAt: Date?

    var duration: TimeInterval {
        guard let end = endedAt ?? lastUpdatedAt else {
            return 0
        }
        return end.timeIntervalSince(startedAt)
    }

    var displayName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    var instructionSnippet: String {
        guard let instructions, !instructions.isEmpty else { return "—" }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 220 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 220)
        return "\(trimmed[..<index])…"
    }

    var readableDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "—"
    }

    var fileSizeDisplay: String {
        guard let fileSizeBytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSizeBytes))
    }

    func matches(search term: String) -> Bool {
        guard !term.isEmpty else { return true }
        let haystack = [
            id,
            displayName,
            cliVersion,
            cwd,
            originator,
            instructions ?? "",
            model ?? "",
            approvalPolicy ?? ""
        ].map { $0.lowercased() }

        let needle = term.lowercased()
        return haystack.contains { $0.contains(needle) }
    }
}

enum SessionSortOrder: String, CaseIterable, Identifiable {
    case mostRecent
    case longestDuration
    case mostActivity
    case alphabetical
    case largestSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostRecent: return "最近更新"
        case .longestDuration: return "持续时间"
        case .mostActivity: return "交互次数"
        case .alphabetical: return "名称排序"
        case .largestSize: return "文件大小"
        }
    }

    func sort(_ sessions: [SessionSummary]) -> [SessionSummary] {
        switch self {
        case .mostRecent:
            return sessions.sorted { ($0.lastUpdatedAt ?? $0.startedAt) > ($1.lastUpdatedAt ?? $1.startedAt) }
        case .longestDuration:
            return sessions.sorted { $0.duration > $1.duration }
        case .mostActivity:
            return sessions.sorted { $0.eventCount > $1.eventCount }
        case .alphabetical:
            return sessions.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .largestSize:
            return sessions.sorted { ($0.fileSizeBytes ?? 0) > ($1.fileSizeBytes ?? 0) }
        }
    }
}

struct SessionDaySection: Identifiable, Hashable {
    let id: Date
    let title: String
    let totalDuration: TimeInterval
    let totalEvents: Int
    let sessions: [SessionSummary]
}
