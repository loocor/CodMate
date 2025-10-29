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
                // If the cached terminal's process died, drop it and recreate to avoid a dead view
                if v.process?.running == true {
                    lastUsedAt[terminalKey] = Date()
                    v.needsLayout = true
                    v.needsDisplay = true
                    return v
                } else {
                    views.removeValue(forKey: terminalKey)
                    bootstrapped.remove(terminalKey)
                }
            }

            // Ensure SwiftTerm disables OSC 10/11 color query responses for embedded sessions
            setenv("CODEX_DISABLE_COLOR_QUERY", "1", 1)

            let term: LocalProcessTerminalView = CodMateTerminalView(frame: .zero)
            term.font = font
            term.translatesAutoresizingMaskIntoConstraints = false
            // Start login shell
            term.startProcess(executable: "/bin/zsh", args: ["-l"])
            if let ctv = term as? CodMateTerminalView { ctv.sessionID = terminalKey }
            views[terminalKey] = term
            lastUsedAt[terminalKey] = Date()

            // Inject commands once – when the grid is ready (avoid tiny cols causing wrap)
            if !bootstrapped.contains(terminalKey) {
                bootstrapped.insert(terminalKey)
                injectInitialCommandsOnce(key: terminalKey, term: term, payload: initialCommands)
            }
            return term
        }

        func stop(key: String) {
            guard let v = views.removeValue(forKey: key) else { return }
            // Prefer a hard terminate to ensure no lingering PTY state
            v.terminate()
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
                existing.terminate()
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

        // Intentionally no global "copy-all" API exposed; large clipboard operations can be costly.

        /// Sends raw text to the running terminal identified by key, if present.
        /// Does not append a newline; callers control execution semantics.
        func send(to key: String, text: String) {
            guard let v = views[key] else { return }
            v.send(txt: text)
        }

        /// Sends a command and appends a carriage return (CR) to execute it immediately.
        /// Uses a single send call to avoid timing issues where the return
        /// could be processed before the command text by the PTY.
        func execute(key: String, command: String) {
            guard let v = views[key] else { return }
            // Terminals typically treat Return as CR (\r, 0x0D), not LF (\n, 0x0A).
            // Some shells might ignore a bare LF for execution. Always ensure a CR is sent.
            let needsCR = !(command.hasSuffix("\r") || command.hasSuffix("\n"))
            if needsCR {
                v.send(txt: command)
                v.send([13]) // CR
            } else if command.hasSuffix("\n") {
                // Replace trailing LF with CR to emulate Return key precisely.
                let trimmed = String(command.dropLast())
                v.send(txt: trimmed)
                v.send([13])
            } else {
                // Already has CR
                v.send(txt: command)
            }
        }

        /// Attempts to focus the terminal view to receive keyboard input.
        func focus(key: String) {
            guard let v = views[key] else { return }
            v.window?.makeFirstResponder(v)
        }

        /// Clears screen and scrollback similar to Cmd+K in Terminal.
        /// Achieved by executing: printf '\e[3J'; clear
        func clear(key: String) {
            guard let _ = views[key] else { return }
            let seq = "printf '\u{001B}[3J'; clear\n"
            send(to: key, text: seq)
        }

        // Waits for a reasonable terminal size before injecting the initial commands to avoid
        // the appearance of 1–2 column widths and "typing" artifacts.
        private func injectInitialCommandsOnce(key: String, term: LocalProcessTerminalView, payload: String) {
            let maxTries = 30
            let interval: TimeInterval = 0.05
            func ready() -> Bool {
                guard term.window != nil else { return false }
                let cols = (term.getTerminal()).cols
                let w = term.bounds.width
                return cols >= 40 && w >= 80
            }
            func attempt(_ n: Int) {
                if ready() {
                    // Send atomically (with newline) to reduce perceived "typing"
                    let text = payload.hasSuffix("\n") ? payload : (payload + "\n")
                    term.send(txt: text)
                } else if n < maxTries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                        attempt(n + 1)
                    }
                } else {
                    // Fallback: inject anyway after timeout
                    let text = payload.hasSuffix("\n") ? payload : (payload + "\n")
                    term.send(txt: text)
                }
            }
            DispatchQueue.main.async { attempt(0) }
        }
    }

#endif
