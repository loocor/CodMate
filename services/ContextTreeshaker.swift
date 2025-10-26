import Foundation

struct TreeshakeOptions: Sendable, Equatable {
    var includeReasoning: Bool = false
    var includeToolSummary: Bool = false
    var mergeConsecutiveAssistant: Bool = true
    var maxMessageBytes: Int = 2 * 1024 // 2KB default (faster preview)
    // Optional override for visible message kinds; when nil, caller can inject app-wide defaults.
    var visibleKinds: Set<MessageVisibilityKind>? = nil
}

actor ContextTreeshaker {
    private let loader = SessionTimelineLoader()
    // Simple LRU cache for per-session slim markdown
    private struct Entry { let version: Date?; let optSig: String; let text: String }
    private var cache: [String: Entry] = [:]  // session.id -> entry
    private var lru: [String] = []
    private let capacity = 32

    private func optSignature(_ o: TreeshakeOptions) -> String {
        let kindsSig: String = {
            if let kinds = o.visibleKinds {
                let items = kinds.map { $0.rawValue }.sorted().joined(separator: ",")
                return "vk:[\(items)]"
            } else { return "vk:-" }
        }()
        return "r:\(o.includeReasoning ? 1 : 0);t:\(o.includeToolSummary ? 1 : 0);m:\(o.mergeConsecutiveAssistant ? 1 : 0);b:\(o.maxMessageBytes);\(kindsSig)"
    }

    private func fileVersion(for s: SessionSummary) -> Date? {
        if let t = s.lastUpdatedAt { return t }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: s.fileURL.path)) ?? [:]
        return attrs[.modificationDate] as? Date
    }

    private func lruTouch(_ id: String) {
        if let idx = lru.firstIndex(of: id) { lru.remove(at: idx) }
        lru.insert(id, at: 0)
        if lru.count > capacity, let evict = lru.popLast() { cache.removeValue(forKey: evict) }
    }

    private func slim(for s: SessionSummary, options: TreeshakeOptions) -> String {
        let ver = fileVersion(for: s)
        let sig = optSignature(options)
        if let e = cache[s.id], e.version == ver, e.optSig == sig { lruTouch(s.id); return e.text }

        // Build slim markdown for a single session (no header)
        let turns: [ConversationTurn]
        if let loaded = try? loader.load(url: s.fileURL) {
            if let kinds = options.visibleKinds { turns = loaded.filtering(visibleKinds: kinds) } else { turns = loaded }
        } else { turns = [] }

        var out: [String] = []
        var prevWasAssistant = false
        let allowReasoning = options.includeReasoning && (options.visibleKinds?.contains(.reasoning) ?? true)
        let allowInfoSummary = options.includeToolSummary && (options.visibleKinds?.contains(.infoOther) ?? true)
        for turn in turns {
            if Task.isCancelled { break }
            if let user = turn.userMessage, let text = user.text, !text.isEmpty {
                out.append("**User** · \(user.timestamp)")
                out.append(trim(text, limit: options.maxMessageBytes))
                out.append("")
                prevWasAssistant = false
            }
            // Optional: Reasoning block (if available and allowed)
            if allowReasoning {
                if let r = turn.outputs.last(where: { isReasoning($0) })?.text, !r.isEmpty {
                    out.append("**Reasoning** · \(turn.timestamp)")
                    out.append(trim(r, limit: options.maxMessageBytes))
                    out.append("")
                    prevWasAssistant = false
                }
            }
            var assistantText: String? = nil
            for event in turn.outputs.reversed() {
                if event.actor == .assistant, let t = event.text, !t.isEmpty { assistantText = t; break }
            }
            if let a = assistantText {
                let body = trim(a, limit: options.maxMessageBytes)
                if options.mergeConsecutiveAssistant && prevWasAssistant {
                    if let last = out.last, !last.isEmpty { out[out.count - 1] = last + "\n\n" + body } else { out.append(body) }
                } else {
                    out.append("**Assistant** · \(turn.timestamp)")
                    out.append(body)
                }
                out.append("")
                prevWasAssistant = true
            }
            // Optional: Info/Tool summary (best-effort from remaining info events)
            if allowInfoSummary {
                if let info = turn.outputs.last(where: { isInfoSummary($0) })?.text, !info.isEmpty {
                    out.append("**Info** · \(turn.timestamp)")
                    out.append(trim(info, limit: options.maxMessageBytes))
                    out.append("")
                    prevWasAssistant = false
                }
            }
        }
        let text = out.joined(separator: "\n")
        cache[s.id] = Entry(version: ver, optSig: sig, text: text)
        lruTouch(s.id)
        return text
    }

    func generateMarkdown(for sessions: [SessionSummary], options: TreeshakeOptions = TreeshakeOptions()) -> String {
        let sorted = sessions.sorted { ($0.startedAt) < ($1.startedAt) }
        var out: [String] = []
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let maxTotal = 64 * 1024  // tighter 64KB cap for preview
        var total = 0

        for s in sorted {
            if Task.isCancelled { break }
            let headerTitle = s.effectiveTitle
            let timeText: String = {
                let end = s.lastUpdatedAt ?? s.startedAt
                return df.string(from: end)
            }()
            let header = "# \(headerTitle) · \(timeText)\n\n"
            total += header.utf8.count
            if total > maxTotal { out.append("… [truncated]"); break }
            out.append(header)

            let body = slim(for: s, options: options)
            total += body.utf8.count
            if total > maxTotal {
                // keep tail within limit
                let remaining = max(0, maxTotal - (total - body.utf8.count))
                let clipped = trim(body, limit: remaining)
                out.append(clipped)
                out.append("\n… [truncated]")
                break
            } else {
                out.append(body)
                out.append("\n")
            }
        }

        return out.joined(separator: "")
    }

    private func trim(_ text: String, limit: Int) -> String {
        // Keep within byte limit while respecting Unicode character boundaries
        guard limit > 0 else { return text }
        let totalBytes = text.utf8.count
        guard totalBytes > limit else { return text }

        // Keep head/tail samples to provide surrounding context
        let headBytes = max(512, limit / 4)
        let tailBytes = max(512, limit / 4)
        let headStr = prefixByUTF8(text, maxBytes: headBytes)
        let tailStr = suffixByUTF8(text, maxBytes: tailBytes)
        return headStr + "\n\n… [snip] …\n\n" + tailStr
    }

    // Safe UTF-8 prefix cut at Character boundaries
    private func prefixByUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var used = 0
        var endIndex = text.startIndex
        for ch in text { // Character iteration respects extended grapheme clusters
            let b = String(ch).utf8.count
            if used + b > maxBytes { break }
            used += b
            endIndex = text.index(after: endIndex)
        }
        return String(text[..<endIndex])
    }

    // Safe UTF-8 suffix cut at Character boundaries
    private func suffixByUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var used = 0
        var charCount = 0
        for ch in text.reversed() { // reversed Characters
            let b = String(ch).utf8.count
            if used + b > maxBytes { break }
            used += b
            charCount += 1
        }
        if charCount == 0 { return "" }
        // Take last `charCount` Characters
        var start = text.endIndex
        for _ in 0..<charCount { start = text.index(before: start) }
        return String(text[start...])
    }
}

// MARK: - Helpers
private func isReasoning(_ e: TimelineEvent) -> Bool {
    (e.title?.localizedCaseInsensitiveContains("agent reasoning") ?? false)
}

private func isInfoSummary(_ e: TimelineEvent) -> Bool {
    guard e.actor == .info else { return false }
    if e.title == TimelineEvent.environmentContextTitle { return false }
    let lower = (e.title ?? "").lowercased()
    if lower == "context updated" { return false }
    if lower.contains("agent reasoning") { return false }
    if lower.contains("token usage") { return false }
    return true
}
