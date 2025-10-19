import Foundation

struct SessionSummary: Identifiable, Hashable, Sendable, Codable {
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

    // User-provided metadata (rename/comment)
    var userTitle: String? = nil
    var userComment: String? = nil

    var duration: TimeInterval {
        guard let end = endedAt ?? lastUpdatedAt else {
            return 0
        }
        return end.timeIntervalSince(startedAt)
    }

    var displayName: String {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        // Extract session ID from filename like "rollout-2025-10-17T14-11-18-0199f124-8c38-7140-969c-396260d0099c"
        // Keep only the last 5 segments after removing rollout + timestamp (5 parts)
        let components = filename.components(separatedBy: "-")
        if components.count >= 7 {
            // Skip first component (rollout) and next 5 components (timestamp), keep last 5
            let sessionIdComponents = Array(components.dropFirst(6))
            return sessionIdComponents.joined(separator: "-")
        }
        return filename
    }

    // Prefer user-provided title when available
    var effectiveTitle: String { (userTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? displayName }

    var instructionSnippet: String {
        guard let instructions, !instructions.isEmpty else { return "—" }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 220 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 220)
        return "\(trimmed[..<index])…"
    }

    // Prefer user comment (100 chars) when available
    var commentSnippet: String {
        if let s = userComment?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if s.count <= 100 { return s }
            let idx = s.index(s.startIndex, offsetBy: 100)
            return String(s[..<idx]) + "…"
        }
        return instructionSnippet
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
            userTitle ?? "",
            userComment ?? "",
            cliVersion,
            cwd,
            originator,
            instructions ?? "",
            model ?? "",
            approvalPolicy ?? "",
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
        case .mostRecent: return "Most Recent"
        case .longestDuration: return "Duration"
        case .mostActivity: return "Activity"
        case .alphabetical: return "Alphabetical"
        case .largestSize: return "File Size"
        }
    }

    func sort(_ sessions: [SessionSummary]) -> [SessionSummary] {
        switch self {
        case .mostRecent:
            return sessions.sorted {
                ($0.lastUpdatedAt ?? $0.startedAt) > ($1.lastUpdatedAt ?? $1.startedAt)
            }
        case .longestDuration:
            return sessions.sorted { $0.duration > $1.duration }
        case .mostActivity:
            return sessions.sorted {
                if $0.eventCount != $1.eventCount { return $0.eventCount > $1.eventCount }
                let l0 = $0.lastUpdatedAt ?? $0.startedAt
                let l1 = $1.lastUpdatedAt ?? $1.startedAt
                if l0 != l1 { return l0 > l1 }
                return $0.effectiveTitle
                    .localizedCaseInsensitiveCompare($1.effectiveTitle) == .orderedAscending
            }
        case .alphabetical:
            return sessions.sorted {
                let cmp = $0.effectiveTitle.localizedStandardCompare($1.effectiveTitle)
                if cmp == .orderedSame {
                    let l0 = $0.lastUpdatedAt ?? $0.startedAt
                    let l1 = $1.lastUpdatedAt ?? $1.startedAt
                    if l0 != l1 { return l0 > l1 }
                    return $0.id < $1.id
                }
                return cmp == .orderedAscending
            }
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
