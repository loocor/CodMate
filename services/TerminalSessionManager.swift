import AppKit
import Foundation

#if canImport(SwiftTerm)
    import SwiftTerm

    @MainActor
    final class TerminalSessionManager {
        static let shared = TerminalSessionManager()
        // Keyed by terminalKey (not session id). Allows multiple panes per session.
        private var views: [String: LocalProcessTerminalView] = [:]
        private var bootstrapped: Set<String> = []
        private var lastUsedAt: [String: Date] = [:]
        private var nudgedSlash: Set<String> = []

        private init() {}

        func view(for terminalKey: String, initialCommands: String, font: NSFont)
            -> LocalProcessTerminalView
        {
            if let v = views[terminalKey] {
                lastUsedAt[terminalKey] = Date()
                // Ensure layout refresh when the view is reattached
                v.needsLayout = true
                v.needsDisplay = true
                return v
            }

            // Ensure SwiftTerm disables OSC 10/11 color query responses for embedded sessions
            setenv("CODEX_DISABLE_COLOR_QUERY", "1", 1)

            let term: LocalProcessTerminalView = CodMateTerminalView(frame: .zero)
            term.font = font
            term.translatesAutoresizingMaskIntoConstraints = false
            // Start login shell
            term.startProcess(executable: "/bin/zsh", args: ["-l"])
            views[terminalKey] = term
            lastUsedAt[terminalKey] = Date()

            // Inject commands once
            if !bootstrapped.contains(terminalKey) {
                bootstrapped.insert(terminalKey)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    term.send(txt: initialCommands)
                }
            }
            return term
        }

        func stop(key: String) {
            guard let v = views.removeValue(forKey: key) else { return }
            // Politely try to exit the shell; SwiftTerm 1.5.x does not expose a public terminate
            v.send(txt: "exit\n")
            bootstrapped.remove(key)
            lastUsedAt.removeValue(forKey: key)
            nudgedSlash.remove(key)
        }

        func stopAll(withPrefix prefix: String) {
            let keys = views.keys.filter { $0.hasPrefix(prefix) }
            for k in keys { stop(key: k) }
        }

        // Best-effort pruning when too many panes exist. Does not stop the most recently used key.
        func pruneLRU(keepingMostRecent keep: Int) {
            let sorted = lastUsedAt.sorted(by: { $0.value > $1.value }).map { $0.key }
            guard sorted.count > keep else { return }
            for k in sorted.dropFirst(keep) { stop(key: k) }
        }

        // Rename a running terminal key without restarting the underlying process/view.
        // Useful when a "new" session is created from an anchor and we learn the final session id later.
        func rekey(from oldKey: String, to newKey: String) {
            guard oldKey != newKey else { return }
            guard let view = views.removeValue(forKey: oldKey) else { return }
            // If destination exists, stop the old one to avoid duplicate shells
            if let existing = views.removeValue(forKey: newKey) {
                existing.send(txt: "exit\n")
            }
            views[newKey] = view
            let now = Date()
            lastUsedAt[newKey] = now
            lastUsedAt.removeValue(forKey: oldKey)
            // Transfer bootstrap mark so initial commands won't be re-injected for the new key
            if bootstrapped.contains(oldKey) {
                bootstrapped.remove(oldKey)
                bootstrapped.insert(newKey)
            }
            if nudgedSlash.contains(oldKey) {
                nudgedSlash.remove(oldKey)
            }
        }

        /// Schedules a tiny "/" then backspace keystroke to nudge Codex to redraw cleanly after resume.
        /// This helps clear any residual artifacts without changing shell state.
        func scheduleSlashNudge(forKey key: String, delay: TimeInterval = 1.0) {
            if nudgedSlash.contains(key) { return }
            nudgedSlash.insert(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, let v = self.views[key] else { return }
                v.send(txt: "/\u{7F}")
            }
        }
    }

#endif
