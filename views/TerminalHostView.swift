import AppKit
import SwiftUI

#if canImport(SwiftTerm)
    import SwiftTerm

    @MainActor
    struct TerminalHostView: NSViewRepresentable {
        // A unique key for a single embedded terminal instance.
        // Do not reuse across different panes (e.g. Resume vs New).
        let terminalKey: String
        let initialCommands: String
        let font: NSFont
        let isDark: Bool

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            let container = NSView(frame: .zero)
            container.translatesAutoresizingMaskIntoConstraints = false
            attachTerminalIfNeeded(in: container, coordinator: context.coordinator)
            return container
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            attachTerminalIfNeeded(in: nsView, coordinator: context.coordinator)
        }

        private func applyTheme(_ v: LocalProcessTerminalView) {
            // Transparent background for visual integration with surrounding surface.
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.clear.cgColor
            if isDark {
                v.caretColor = NSColor.white
                v.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)
                v.nativeBackgroundColor = .clear
                v.selectedTextBackgroundColor = NSColor(white: 0.3, alpha: 0.6)
            } else {
                v.caretColor = NSColor.black
                v.nativeForegroundColor = NSColor(white: 0.10, alpha: 1.0)
                v.nativeBackgroundColor = .clear
                v.selectedTextBackgroundColor = NSColor(white: 0.7, alpha: 0.4)
            }
        }

        @MainActor
        final class Coordinator: NSObject {
            weak var terminal: LocalProcessTerminalView?
            private var relayoutWork: DispatchWorkItem?
            private let debounceInterval: TimeInterval = 0.12
            weak var container: NSView?
            var overlay: OverlayBar?

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
            // Debounced relayout to stabilize grid/scroll after reattachment or theme/font changes
            func scheduleRelayout(_ view: LocalProcessTerminalView) {
                relayoutWork?.cancel()
                let work = DispatchWorkItem { [weak self, weak view] in
                    guard let self, let v = view else { return }
                    v.needsLayout = true
                    v.layoutSubtreeIfNeeded()
                    v.needsDisplay = true
                    // Reassert visible vertical scroller after layout changes
                    v.disableBuiltInScroller()
                    self.updateOverlay(position: v.scrollPosition, thumb: v.scrollThumbsize)
                }
                relayoutWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
            }

            func updateOverlay(position: Double? = nil, thumb: CGFloat? = nil) {
                guard let container, let overlay else { return }
                if let v = terminal, v.canScroll == false {
                    overlay.isHidden = true
                    return
                }
                let pos = position ?? overlay.position
                let th = max(thumb ?? overlay.thumbProportion, 0.01)
                overlay.position = pos
                overlay.thumbProportion = th
                overlay.isHidden = false
                let inset: CGFloat = 2
                let width: CGFloat = 4
                let H = max(container.bounds.height, 1)
                let barH = max(ceil(H * th), 8)
                let travel = max(H - 2 * inset - barH, 0)
                let y = inset + travel * CGFloat(1.0 - pos)
                let x = container.bounds.width - width - inset
                overlay.frame = CGRect(x: max(0, x), y: max(0, y), width: width, height: barH)
                overlay.needsDisplay = true
            }

        }

        private func attachTerminalIfNeeded(in container: NSView, coordinator: Coordinator) {
            coordinator.container = container

            // Fast-path: if we're already showing this terminal, just refresh theme and return
            if let existing = coordinator.terminal,
               existing.superview === container,
               let existingKey = (existing as? CodMateTerminalView)?.sessionID,
               existingKey == terminalKey {
                // Terminal already attached, just update theme and font if changed
                if existing.font != font {
                    existing.font = font
                }
                applyTheme(existing)
                coordinator.scheduleRelayout(existing)
                return
            }

            // Get or create terminal view from manager (reuses existing if available)
            let v = TerminalSessionManager.shared.view(
                for: terminalKey, initialCommands: initialCommands, font: font)
            applyTheme(v)
            v.disableBuiltInScroller()
            // Freeze grid reflow during live-resize; reflow once at the end to avoid duplicate/garbled text
            v.deferReflowDuringLiveResize = true

            // Detach and reattach if this terminal is in a different container
            if v.superview !== container {
                v.removeFromSuperview()
                v.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(v)
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    v.topAnchor.constraint(equalTo: container.topAnchor),
                    v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
                coordinator.attach(to: v)
                // Install overlay scrollbar once
                if coordinator.overlay == nil {
                    let bar = OverlayBar(frame: .zero)
                    bar.translatesAutoresizingMaskIntoConstraints = true
                    container.addSubview(bar)
                    coordinator.overlay = bar
                }
                // Ensure the embedded terminal gains focus for immediate input
                DispatchQueue.main.async {
                    container.window?.makeFirstResponder(v)
                }
            }
            coordinator.scheduleRelayout(v)
            if let ctv = v as? CodMateTerminalView {
                ctv.onScrolled = { [weak coordinator] pos, thumb in
                    DispatchQueue.main.async {
                        coordinator?.updateOverlay(position: pos, thumb: thumb)
                    }
                }
            }
        }

        // Minimal overlay scrollbar view that never intercepts events
        final class OverlayBar: NSView {
            var position: Double = 0  // 0..1 top->bottom
            var thumbProportion: CGFloat = 0.1
            override var isOpaque: Bool { false }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func draw(_ dirtyRect: NSRect) {
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                let path = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
                path.fill()
            }
        }
    }

#else
    struct TerminalHostView: View {
        let terminalKey: String
        let initialCommands: String
        let font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
        var body: some View { Text("SwiftTerm not available") }
    }
#endif
