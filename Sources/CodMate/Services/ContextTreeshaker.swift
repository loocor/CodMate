import Foundation

struct TreeshakeOptions: Sendable, Equatable {
    var includeReasoning: Bool = false
    var includeToolSummary: Bool = false
    var mergeConsecutiveAssistant: Bool = true
    var maxMessageBytes: Int = 8 * 1024 // 8KB default
}

actor ContextTreeshaker {
    private let loader = SessionTimelineLoader()
    // Simple LRU cache for per-session slim markdown
    private struct Entry { let version: Date?; let optSig: String; let text: String }
    private var cache: [String: Entry] = [:]  // session.id -> entry
    private var lru: [String] = []
    private let capacity = 32

    private func optSignature(_ o: TreeshakeOptions) -> String {
        "r:\(o.includeReasoning ? 1 : 0);t:\(o.includeToolSummary ? 1 : 0);m:\(o.mergeConsecutiveAssistant ? 1 : 0);b:\(o.maxMessageBytes)"
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
        if let loaded = try? loader.load(url: s.fileURL) { turns = loaded } else { turns = [] }

        var out: [String] = []
        var prevWasAssistant = false
        for turn in turns {
            if Task.isCancelled { break }
            if let user = turn.userMessage, let text = user.text, !text.isEmpty {
                out.append("**User** · \(user.timestamp)")
                out.append(trim(text, limit: options.maxMessageBytes))
                out.append("")
                prevWasAssistant = false
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
        guard limit > 0 else { return text }
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        // keep head/tail samples (25% head, 25% tail)
        let headLen = max(512, limit / 4)
        let tailLen = max(512, limit / 4)
        let head = bytes.prefix(headLen)
        let tail = bytes.suffix(tailLen)
        let headStr = String(decoding: head, as: UTF8.self)
        let tailStr = String(decoding: tail, as: UTF8.self)
        return headStr + "\n\n… [snip] …\n\n" + tailStr
    }
}
