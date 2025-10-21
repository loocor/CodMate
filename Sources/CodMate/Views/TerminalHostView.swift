import AppKit
import SwiftUI

#if canImport(SwiftTerm)
    import SwiftTerm

    @MainActor
    struct TerminalHostView: NSViewRepresentable {
        let sessionID: String
        let initialCommands: String
        let font: NSFont
        let isDark: Bool

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> LocalProcessTerminalView {
            let v = TerminalSessionManager.shared.view(
                for: sessionID, initialCommands: initialCommands, font: font)
            // Attach context menu: Copy / Paste / Select All
            context.coordinator.attach(to: v)
            applyTheme(v)
            return v
        }

        func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
            if nsView.font !== font { nsView.font = font }
            applyTheme(nsView)
        }

        private func applyTheme(_ v: LocalProcessTerminalView) {
            // Transparent background; let parent container decide backdrop.
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.clear.cgColor
            v.nativeBackgroundColor = .clear
            if isDark {
                v.caretColor = NSColor.white
                v.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)
                v.selectedTextBackgroundColor = NSColor(white: 0.3, alpha: 0.45)
            } else {
                v.caretColor = NSColor.black
                v.nativeForegroundColor = NSColor(white: 0.10, alpha: 1.0)
                v.selectedTextBackgroundColor = NSColor(white: 0.7, alpha: 0.35)
            }
        }

        @MainActor
        final class Coordinator: NSObject {
            weak var terminal: LocalProcessTerminalView?

            func attach(to view: LocalProcessTerminalView) {
                self.terminal = view
                view.menu = makeMenu()
            }

            private func makeMenu() -> NSMenu {
                let m = NSMenu()
                let copy = NSMenuItem(
                    title: "Copy", action: #selector(copyAction(_:)), keyEquivalent: "")
                copy.target = self
                let paste = NSMenuItem(
                    title: "Paste", action: #selector(pasteAction(_:)), keyEquivalent: "")
                paste.target = self
                let selectAll = NSMenuItem(
                    title: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "")
                selectAll.target = self
                m.items = [copy, paste, NSMenuItem.separator(), selectAll]
                return m
            }

            @objc func copyAction(_ sender: Any?) {
                guard let term = terminal else { return }
                // Delegate copy to the view; our subclass sanitizes the pasteboard.
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: term, from: sender) { return }
                NSSound.beep()
            }

            @objc func pasteAction(_ sender: Any?) {
                guard let term = terminal else { return }
                let pb = NSPasteboard.general
                if let s = pb.string(forType: .string), !s.isEmpty {
                    term.send(txt: s)
                }
            }

            @objc func selectAllAction(_ sender: Any?) {
                guard let term = terminal else { return }
                _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: term, from: sender)
            }
        }
    }

#else
    struct TerminalHostView: View {
        let sessionID: String
        let initialCommands: String
        let font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
        var body: some View { Text("SwiftTerm not available") }
    }
#endif
