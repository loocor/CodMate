import AppKit
import Foundation

#if canImport(SwiftTerm)
    import SwiftTerm

    @MainActor
    final class TerminalSessionManager {
        static let shared = TerminalSessionManager()
        private var views: [String: LocalProcessTerminalView] = [:]
        private var bootstrapped: Set<String> = []

        private init() {}

        func view(for id: String, initialCommands: String, font: NSFont) -> LocalProcessTerminalView
        {
            if let v = views[id] { return v }

            // Ensure SwiftTerm disables OSC 10/11 color query responses for embedded sessions
            setenv("CODEX_DISABLE_COLOR_QUERY", "1", 1)

            let term: LocalProcessTerminalView = CodMateTerminalView(frame: .zero)
            term.font = font
            // Start login shell
            term.startProcess(executable: "/bin/zsh", args: ["-l"])
            views[id] = term

            // Inject commands once
            if !bootstrapped.contains(id) {
                bootstrapped.insert(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    term.send(txt: initialCommands)
                }
            }
            return term
        }

        func stop(id: String) {
            guard let v = views.removeValue(forKey: id) else { return }
            // Politely try to exit the shell; SwiftTerm 1.5.x does not expose a public terminate
            v.send(txt: "exit\n")
            bootstrapped.remove(id)
        }
    }

#endif
