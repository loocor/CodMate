import Foundation

struct SessionSummary: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let fileURL: URL
    let fileSizeBytes: UInt64?
    let startedAt: Date
    let endedAt: Date?
    // Sum of actual active conversation segments (user → Codex),
    // computed from grouped timeline turns during enrichment.
    // Nil until enriched; falls back to (endedAt - startedAt) in UI when nil.
    let activeDuration: TimeInterval?
    let cliVersion: String
    let cwd: String
    let originator: String
    let instructions: String?
    let model: String?
    let approvalPolicy: String?
    let userMessageCount: Int
    let assistantMessageCount: Int
    var toolInvocationCount: Int
    let responseCounts: [String: Int]
    let turnContextCount: Int
    let eventCount: Int
    let lineCount: Int
    let lastUpdatedAt: Date?
    let source: SessionSource

    // User-provided metadata (rename/comment)
    var userTitle: String? = nil
    var userComment: String? = nil

    var duration: TimeInterval {
        if let activeDuration { return activeDuration }
        guard let end = endedAt ?? lastUpdatedAt else { return 0 }
        return end.timeIntervalSince(startedAt)
    }

    var displayName: String {
        let filename = fileURL.deletingPathExtension().lastPathComponent

        // Handle new format: agent-6afec743 -> extract agentId from filename
        if filename.hasPrefix("agent-") {
            // Use the agentId portion from filename to distinguish between parallel agents
            let agentId = String(filename.dropFirst("agent-".count))
            if !agentId.isEmpty {
                return "agent-\(agentId)"
            }
            // Fallback to sessionId if agentId extraction failed
            return id
        }

        // Handle old UUID format: ed5f5b12-a30b-4c86-b3ff-5bcf5dba65c0 -> use as is
        if filename.components(separatedBy: "-").count == 5 &&
           filename.count == 36 &&
           UUID(uuidString: filename) != nil {
            return filename
        }

        // Handle rollout format: "rollout-2025-10-17T14-11-18-0199f124-8c38-7140-969c-396260d0099c"
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

    var displayModel: String? {
        guard let model else { return nil }
        return source.friendlyModelName(for: model)
    }

    var fileSizeDisplay: String {
        guard let bytes = resolvedFileSizeBytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    var resolvedFileSizeBytes: UInt64? {
        if let fileSizeBytes { return fileSizeBytes }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let number = attributes[.size] as? NSNumber
        {
            return number.uint64Value
        }
        return nil
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

extension SessionSummary {
    func overridingSource(_ newSource: SessionSource) -> SessionSummary {
        if newSource == source { return self }
        // Cross-provider new session should NOT inherit provider-specific model names.
        // Drop model when switching source to avoid leaking e.g. GPT-5 to Claude or vice versa.
        return SessionSummary(
            id: id,
            fileURL: fileURL,
            fileSizeBytes: fileSizeBytes,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDuration: activeDuration,
            cliVersion: cliVersion,
            cwd: cwd,
            originator: originator,
            instructions: instructions,
            model: nil,
            approvalPolicy: approvalPolicy,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            toolInvocationCount: toolInvocationCount,
            responseCounts: responseCounts,
            turnContextCount: turnContextCount,
            eventCount: eventCount,
            lineCount: lineCount,
            lastUpdatedAt: lastUpdatedAt,
            source: newSource,
            userTitle: userTitle,
            userComment: userComment
        )
    }
}

enum SessionSortOrder: String, CaseIterable, Identifiable, Sendable {
    case mostRecent
    case longestDuration
    case mostActivity
    case alphabetical
    case largestSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostRecent: return "Recent"
        case .longestDuration: return "Duration"
        case .mostActivity: return "Activity"
        case .alphabetical: return "Name"
        case .largestSize: return "Size"
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

    // Dimension-aware sorting variant used by the middle list. For "Recent",
    // order by created vs. last-updated depending on the calendar mode; other
    // sort orders fall back to the default behavior above.
    func sort(_ sessions: [SessionSummary], dimension: DateDimension) -> [SessionSummary] {
        switch self {
        case .mostRecent:
            let key: (SessionSummary) -> Date = {
                switch dimension {
                case .created: return $0.startedAt
                case .updated: return $0.lastUpdatedAt ?? $0.startedAt
                }
            }
            return sessions.sorted { key($0) > key($1) }
        default:
            return sort(sessions)
        }
    }
}

struct SessionDaySection: Identifiable, Hashable, Sendable {
    let id: Date
    let title: String
    let totalDuration: TimeInterval
    let totalEvents: Int
    let sessions: [SessionSummary]
}

enum SessionSource: String, Codable, Sendable {
    case codex
    case claude
}
