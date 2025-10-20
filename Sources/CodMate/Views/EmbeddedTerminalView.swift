import AppKit
import CoreText
import SwiftUI

#if canImport(SwiftTerm)
    import SwiftTerm

    @MainActor
    final class EmbeddedTerminalCoordinator: NSObject {
        private let initialCommands: String
        private var appearanceObserver: NSKeyValueObservation?

        init(initialCommands: String) { self.initialCommands = initialCommands }

        // Intentionally no TerminalViewDelegate conformance to avoid version mismatches

        fileprivate func bootstrap(_ view: LocalProcessTerminalView) {
            // Apply initial theme based on current appearance
            updateTheme(for: view, appearance: NSApp.effectiveAppearance)

            // Observe appearance changes via KVO on the view's effectiveAppearance
            appearanceObserver = view.observe(\.effectiveAppearance, options: [.new]) {
                [weak self] termView, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.updateTheme(for: termView, appearance: termView.effectiveAppearance)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                view.send(txt: self.initialCommands)
            }
        }

        private func updateTheme(for view: LocalProcessTerminalView, appearance: NSAppearance) {
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            if isDark {
                // Dark theme
                view.caretColor = NSColor.white
                view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)
                view.nativeBackgroundColor = NSColor(white: 0.1, alpha: 1.0)
                view.selectedTextBackgroundColor = NSColor(white: 0.3, alpha: 0.6)
            } else {
                // Light theme
                view.caretColor = NSColor.black
                view.nativeForegroundColor = NSColor(white: 0.1, alpha: 1.0)
                view.nativeBackgroundColor = NSColor(white: 0.98, alpha: 1.0)
                view.selectedTextBackgroundColor = NSColor(white: 0.7, alpha: 0.4)
            }
        }

        deinit {
            appearanceObserver?.invalidate()
        }
    }

    struct EmbeddedTerminalView: NSViewRepresentable {
        let initialCommands: String
        @Environment(\.colorScheme) private var colorScheme

        func makeCoordinator() -> EmbeddedTerminalCoordinator {
            .init(initialCommands: initialCommands)
        }

        func makeNSView(context: Context) -> LocalProcessTerminalView {
            let term = LocalProcessTerminalView(frame: .zero)
            let font = makeTerminalFont(size: 12)
            term.font = font
            term.startProcess(executable: "/bin/zsh", args: ["-l"])
            context.coordinator.bootstrap(term)
            return term
        }

        func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
            // Theme will be updated automatically via appearance observer in coordinator
        }
    }

    /// Returns a font suitable for terminal display; prefers CJK-capable monospace
    private func makeTerminalFont(size: CGFloat) -> NSFont {
        // Prefer CJK-capable monospaced fonts that handle double-width correctly
        let preferredMonoCandidates = [
            "Sarasa Mono SC",  // CJK monospace
            "Sarasa Term SC",
            "LXGW WenKai Mono",
            "Noto Sans Mono CJK SC",
            "NotoSansMonoCJKsc-Regular",
            "JetBrainsMonoNL Nerd Font Mono",
            "JetBrainsMono Nerd Font Mono",
            "SF Mono",
            "Menlo",
        ]

        for name in preferredMonoCandidates {
            if let f = NSFont(name: name, size: size), fontHasCJKGlyphs(f) {
                return f
            }
        }

        // Fallback to system mono if it has CJK
        let sysMono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if fontHasCJKGlyphs(sysMono) { return sysMono }

        // Last resort: use PingFang SC if nothing else, to ensure readable Chinese
        if let pf = NSFont(name: "PingFangSC-Regular", size: size)
            ?? NSFont(name: "PingFang SC", size: size)
        {
            return pf
        }
        return sysMono
    }

    private func fontHasCJKGlyphs(_ font: NSFont) -> Bool {
        let samples = "CJK width test"
        let ctFont = font as CTFont
        for scalar in samples.unicodeScalars {
            var ch = UniChar(scalar.value)
            var glyph: CGGlyph = 0
            let ok = withUnsafePointer(to: &ch) { cPtr -> Bool in
                withUnsafeMutablePointer(to: &glyph) { gPtr -> Bool in
                    CTFontGetGlyphsForCharacters(ctFont, cPtr, gPtr, 1)
                }
            }
            if !ok || glyph == 0 { return false }
        }
        return true
    }

#else

    struct EmbeddedTerminalView: View {
        let initialCommands: String
        var body: some View {
            VStack(spacing: 12) {
                Text("Embedded terminal unavailable")
                    .font(.headline)
                Text("Add the SwiftTerm package to enable the in‑app terminal.")
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(initialCommands)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)
                }

                HStack(spacing: 12) {
                    Button("Copy Commands") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(initialCommands, forType: .string)
                        Task {
                            await SystemNotifier.shared.notify(
                                title: "CodMate", body: "Commands copied")
                        }
                    }
                    Button("Open Terminal") {
                        if #available(macOS 10.15, *) {
                            let terminalURL = NSWorkspace.shared.urlForApplication(
                                withBundleIdentifier: "com.apple.Terminal")
                            if let url = terminalURL {
                                NSWorkspace.shared.open(
                                    url, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
                            }
                        } else {
                            NSWorkspace.shared.launchApplication(
                                withBundleIdentifier: "com.apple.Terminal", options: [],
                                additionalEventParamDescriptor: nil, launchIdentifier: nil)
                        }
                    }
                }
            }
            .padding()
        }
    }

#endif
