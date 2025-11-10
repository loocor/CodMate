import Foundation

/// Lightweight heuristic to detect "turn complete" style events from terminal output.
/// Only used for embedded terminal sessions; external Terminal/TTY paths still rely on `notify` bridge.
struct EmbeddedNotifySniffer {
    /// Returns a short message if the provided line(s) suggest the agent just completed a turn.
    static func sniff(line: String) -> String? {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        // Common variants seen across TUI implementations
        let needles = [
            "agent turn complete",
            "turn complete",
            "agent completed",
            "run complete",
            "session complete",
        ]
        for n in needles {
            if lower.contains(n) { return "Turn complete" }
        }
        return nil
    }

    static func sniff(lines: [String]) -> String? {
        for l in lines.reversed() { if let m = sniff(line: l) { return m } }
        return nil
    }
}
