import SwiftUI
import AppKit

#if canImport(SwiftTerm)
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    let sessionID: String
    let initialCommands: String
    let font: NSFont
    let isDark: Bool

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let v = TerminalSessionManager.shared.view(for: sessionID, initialCommands: initialCommands, font: font)
        applyTheme(v)
        return v
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if nsView.font !== font { nsView.font = font }
        applyTheme(nsView)
    }

    private func applyTheme(_ v: LocalProcessTerminalView) {
        if isDark {
            v.caretColor = NSColor.white
            v.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)
            v.nativeBackgroundColor = NSColor(white: 0.10, alpha: 1.0)
            v.selectedTextBackgroundColor = NSColor(white: 0.3, alpha: 0.6)
        } else {
            v.caretColor = NSColor.black
            v.nativeForegroundColor = NSColor(white: 0.10, alpha: 1.0)
            v.nativeBackgroundColor = NSColor(white: 0.98, alpha: 1.0)
            v.selectedTextBackgroundColor = NSColor(white: 0.7, alpha: 0.4)
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
