import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    let apply: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                apply(window)
            } else {
                // Try again on next runloop if window not yet attached
                DispatchQueue.main.async { [weak view] in
                    if let w = view?.window { apply(w) }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

