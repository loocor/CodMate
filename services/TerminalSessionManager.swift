import AppKit
import Foundation
import Darwin

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
                    NSLog("📺 [TerminalSessionManager] Process died for key %@, recreating", terminalKey)
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
            NSLog("📺 [TerminalSessionManager] Created terminal for key %@, PID: %d", terminalKey, term.process?.shellPid ?? -1)

            // Inject commands once – when the grid is ready (avoid tiny cols causing wrap)
            if !bootstrapped.contains(terminalKey) {
                bootstrapped.insert(terminalKey)
                injectInitialCommandsOnce(key: terminalKey, term: term, payload: initialCommands)
            }
            return term
        }

        func stop(key: String, sync: Bool = false) {
            guard let v = views.removeValue(forKey: key) else {
                return
            }

            // Multi-stage termination to ensure all processes (codex/claude and descendants) are cleaned up

            // CRITICAL: Save PID BEFORE calling terminate() which clears it!
            let pid: pid_t
            let hasRunningProcess: Bool

            if let proc = v.process, proc.running {
                pid = proc.shellPid
                hasRunningProcess = pid > 0
            } else {
                pid = 0
                hasRunningProcess = false
            }

            if hasRunningProcess {
                // Stage 1: Send signals BEFORE closing PTY
                let pgid = getpgid(pid)
                NSLog("🛑 [TerminalSessionManager] Stopping session %@: PID=%d PGID=%d", key, pid, pgid)

                if pgid > 0 && pgid != getpgrp() {
                    // Send SIGTERM to entire process group (negative pgid)
                    _ = kill(-pgid, SIGTERM)
                } else if pgid <= 0 {
                    // Fallback: if getpgid failed, try direct pid
                    _ = kill(pid, SIGTERM)
                }

                // Stage 2: Now close PTY (this sends SIGHUP)
                v.terminate()

                // Stage 3: Wait and force kill if needed
                let killProcess = {
                        // Wait up to 300ms for graceful exit (shorter for faster response)
                        let deadline = Date().addingTimeInterval(0.3)
                        var exited = false

                        while Date() < deadline && !exited {
                            // Check if process still exists (kill with signal 0)
                            if kill(pid, 0) != 0 && errno == ESRCH {
                                exited = true
                                break
                            }
                            usleep(30_000) // 30ms
                        }

                        // If still alive, force kill immediately and aggressively
                        if !exited {
                            let currentPgid = getpgid(pid)

                            // Kill the entire process group with SIGKILL
                            if currentPgid > 0 && currentPgid != getpgrp() {
                                _ = kill(-currentPgid, SIGKILL)
                            }

                            // Also direct kill to the shell PID
                            _ = kill(pid, SIGKILL)

                            // Find and kill all children of this process
                            self.killProcessTree(rootPid: pid)

                            // Wait a bit for SIGKILL to take effect
                            usleep(150_000) // 150ms

                            // Final check and reap
                            var status: Int32 = 0
                            waitpid(pid, &status, WNOHANG)
                        }

                        // Mark process as terminated in LocalProcess
                        if let proc = v.process {
                            proc.markAsTerminated()
                        }
                    }

                if sync {
                    // Synchronous execution: block until process is killed
                    killProcess()
                } else {
                    // Asynchronous execution: for UI responsiveness
                    DispatchQueue.global(qos: .userInitiated).async {
                        killProcess()
                    }
                }
            } else {
                // No running process, just close PTY
                v.terminate()
            }

            bootstrapped.remove(key)
            lastUsedAt.removeValue(forKey: key)
            nudgedSlash.remove(key)
        }

        /// Aggressively kill a process tree by finding and killing all descendants
        /// Uses sysctl for fast, non-blocking process tree query
        private func killProcessTree(rootPid: pid_t) {
            // Use sysctl to get all process info - much faster than spawning ps
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var length: size_t = 0

            // First call to get the size
            guard sysctl(&name, u_int(name.count), nil, &length, nil, 0) == 0 else {
                kill(rootPid, SIGKILL)
                return
            }

            // Allocate buffer and get the actual data
            let count = length / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

            guard sysctl(&name, u_int(name.count), &procs, &length, nil, 0) == 0 else {
                kill(rootPid, SIGKILL)
                return
            }

            let actualCount = length / MemoryLayout<kinfo_proc>.stride

            // Build process tree
            var children: [pid_t: [pid_t]] = [:]

            for i in 0..<actualCount {
                let proc = procs[i]
                let pid = proc.kp_proc.p_pid
                let ppid = proc.kp_eproc.e_ppid

                children[ppid, default: []].append(pid)
            }

            // Recursively kill all descendants
            var toKill: [pid_t] = [rootPid]
            var visited: Set<pid_t> = []
            var killCount = 0

            while !toKill.isEmpty {
                let pid = toKill.removeFirst()
                guard !visited.contains(pid) else { continue }
                visited.insert(pid)

                // Kill this process
                kill(pid, SIGKILL)
                killCount += 1

                // Add children to queue
                if let childPids = children[pid] {
                    toKill.append(contentsOf: childPids)
                }
            }

            if killCount > 1 {
                NSLog("   🌳 Killed process tree: %d processes", killCount)
            }
        }

        /// Helper to check if a process is actually running
        func isProcessRunning(pid: pid_t) -> Bool {
            guard pid > 0 else { return false }
            // kill with signal 0 checks if process exists without sending a signal
            return kill(pid, 0) == 0 || errno != ESRCH
        }

        /// Check if a shell has active child processes (like codex, claude, etc.)
        /// Returns true only if there are running children, false if shell is idle
        /// Uses sysctl for fast, non-blocking process tree query
        private func hasActiveChildren(shellPid: pid_t) -> Bool {
            guard shellPid > 0 else { return false }

            // Use sysctl to get all process info - much faster than spawning ps
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var length: size_t = 0

            // First call to get the size
            guard sysctl(&name, u_int(name.count), nil, &length, nil, 0) == 0 else {
                return true // Conservative: assume children exist on error
            }

            // Allocate buffer and get the actual data
            let count = length / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

            guard sysctl(&name, u_int(name.count), &procs, &length, nil, 0) == 0 else {
                return true // Conservative: assume children exist on error
            }

            // Count actual processes returned (length may have changed)
            let actualCount = length / MemoryLayout<kinfo_proc>.stride

            // Look for any child process of our shell
            for i in 0..<actualCount {
                let proc = procs[i]
                let ppid = proc.kp_eproc.e_ppid
                let status = proc.kp_proc.p_stat

                // Found a child of our shell
                if ppid == shellPid {
                    // Check process status:
                    // SIDL=1 (being created), SRUN=2 (runnable), SSLEEP=3 (sleeping),
                    // SSTOP=4 (stopped), SZOMB=5 (zombie)

                    // Ignore zombies (already dead) and stopped processes
                    if status == SZOMB || status == SSTOP {
                        continue
                    }

                    return true
                }
            }

            return false
        }

        /// Check if terminal has running process (for confirmation dialog)
        /// Returns true only if there are active programs (codex, claude, etc.) running
        /// Returns false if just an idle shell waiting for input
        func hasRunningProcess(key: String) -> Bool {
            guard let v = views[key], let proc = v.process else { return false }
            guard proc.running && isProcessRunning(pid: proc.shellPid) else { return false }

            // Shell exists, but check if it has active children
            return hasActiveChildren(shellPid: proc.shellPid)
        }

        /// Check if any terminal session has a running process
        func hasAnyRunningProcesses() -> Bool {
            for (_, view) in views {
                if let proc = view.process, proc.running, isProcessRunning(pid: proc.shellPid) {
                    if hasActiveChildren(shellPid: proc.shellPid) {
                        return true
                    }
                }
            }
            return false
        }

        func stopAll(withPrefix prefix: String, sync: Bool = false) {
            let keys = views.keys.filter { $0.hasPrefix(prefix) }
            for k in keys { stop(key: k, sync: sync) }
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
