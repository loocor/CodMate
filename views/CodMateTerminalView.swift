import AppKit
import Foundation

#if canImport(SwiftTerm)
    import SwiftTerm

    /// A thin subclass to add image-paste support without modifying SwiftTerm.
    /// Behavior:
    /// - If the pasteboard contains an image reference (and no plain string), simulate Ctrl+V so the CLI can handle it.
    /// - Otherwise, fall back to SwiftTerm's default text paste.
    final class CodMateTerminalView: LocalProcessTerminalView {
        private var keyMonitor: Any?
        override var isOpaque: Bool { false }
        // Lightweight scroll listener for overlay scrollbar in the host view
        var onScrolled: ((Double, CGFloat) -> Void)?
        // Session identifier used to attribute OSC 777 notifications to a list row
        var sessionID: String?

        private let processDispatchQueue = DispatchQueue(
            label: "io.codmate.terminal.process", qos: .userInitiated)
        private var pendingChunks: [[UInt8]] = []
        private var pendingFlushWork: DispatchWorkItem?
        private let flushInterval: TimeInterval = 0.002
        private let maxBatchChunks = 32
        private let immediateFlushThresholdBytes = 96
        private let typingFlushWindow: TimeInterval = 0.08
        private let typingChunkSoftLimit = 512
        private var lastTypingAt: TimeInterval = 0
        private let dragTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("public.url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ]

        deinit {}

        override func makeLocalProcess() -> LocalProcess {
            LocalProcess(delegate: self, dispatchQueue: processDispatchQueue)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                wantsLayer = true
                layer?.backgroundColor = NSColor.clear.cgColor
                installKeyMonitorIfNeeded()
                registerForDraggedTypes(dragTypes)
            } else if let m = keyMonitor {
                NSEvent.removeMonitor(m)
                keyMonitor = nil
                unregisterDraggedTypes()
            }
        }

        private func markTypingEvent() {
            lastTypingAt = CFAbsoluteTimeGetCurrent()
        }

        override func send(source: TerminalView, data: ArraySlice<UInt8>) {
            markTypingEvent()
            super.send(source: source, data: data)
        }

        override func paste(_ sender: Any) {
            let pb = NSPasteboard.general

            let hasImage = pasteboardHasImage(pb)
            let pastedString = pb.string(forType: .string)

            // If clipboard contains an image, prefer image paste for Codex (simulate Ctrl+V)
            if hasImage {
                self.send(txt: "\u{16}")
                return
            }
            // Otherwise, fallback to default text paste
            if let s = pastedString, !s.isEmpty {
                super.paste(sender)
            } else {
                super.paste(sender)
            }
        }

        // Intercept copy to sanitize CJK spacing artifacts introduced by rendering hacks.
        // This cleans spaces between adjacent CJK or fullwidth characters so the
        // pasted text looks natural. Example to fix: "其 它 完 成 项 （ 回 顾 ）".
        override func copy(_ sender: Any) {
            super.copy(sender)
            let pb = NSPasteboard.general
            guard let s = pb.string(forType: .string), !s.isEmpty else { return }
            let cleaned = Self.cleanCJKInterWordSpaces(in: s)
            if cleaned != s {
                pb.clearContents()
                pb.setString(cleaned, forType: .string)
            }
        }

        private static func cleanCJKInterWordSpaces(in s: String) -> String {
            // Remove only the spaces that appear between two CJK/fullwidth characters.
            // Keep all other whitespace intact.
            func isCJKOrFullwidth(_ u: UnicodeScalar) -> Bool {
                switch u.value {
                case 0x3400...0x4DBF,  // CJK Ext A
                    0x4E00...0x9FFF,  // CJK Unified
                    0xF900...0xFAFF,  // CJK Compatibility Ideographs
                    0x3040...0x309F,  // Hiragana
                    0x30A0...0x30FF,  // Katakana
                    0xAC00...0xD7AF,  // Hangul
                    0x3000...0x303F,  // CJK Symbols and Punctuation
                    0xFF00...0xFFEF:  // Halfwidth and Fullwidth Forms
                    return true
                default:
                    return false
                }
            }
            func isStripSpace(_ u: UnicodeScalar) -> Bool {
                switch u.value {
                case 0x0020,  // space
                    0x00A0,  // NBSP
                    0x2000...0x200A,  // En/Em/Thin spaces
                    0x202F,  // Narrow no-break space
                    0x205F,  // Medium mathematical space
                    0x3000:  // Ideographic space (fullwidth)
                    return true
                default:
                    return false
                }
            }

            let scalars = Array(s.unicodeScalars)
            if scalars.isEmpty { return s }
            var out: [UnicodeScalar] = []
            out.reserveCapacity(scalars.count)
            var i = 0
            while i < scalars.count {
                let u = scalars[i]
                if isStripSpace(u) {
                    // Look at closest non-space neighbors
                    var prev = i - 1
                    while prev >= 0 && isStripSpace(scalars[prev]) { prev -= 1 }
                    var next = i + 1
                    while next < scalars.count && isStripSpace(scalars[next]) { next += 1 }
                    if prev >= 0 && next < scalars.count && isCJKOrFullwidth(scalars[prev])
                        && isCJKOrFullwidth(scalars[next])
                    {
                        // Skip the entire run of spaces inserted between CJK characters
                        i = next
                        continue
                    } else {
                        // Not between two CJK chars; keep a single ASCII space and collapse the run
                        out.append(UnicodeScalar(0x20)!)
                        i += 1
                        while i < scalars.count && isStripSpace(scalars[i]) { i += 1 }
                        continue
                    }
                }
                out.append(u)
                i += 1
            }
            return String(String.UnicodeScalarView(out))
        }

        private func installKeyMonitorIfNeeded() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
                [weak self] event in
                guard let self = self else { return event }
                // Only intercept when this view is the active first responder
                guard self.window?.firstResponder === self else { return event }

                // Handle Shift/Option + Return as newline (kitty CSI-u with modifiers)
                let isReturnKey =
                    (event.keyCode == 36 /* Return */) || (event.keyCode == 76 /* Keypad Enter */)
                if isReturnKey {
                    let hasShift = event.modifierFlags.contains(.shift)
                    let hasAlt = event.modifierFlags.contains(.option)
                    if hasShift || hasAlt {
                        // Kitty keyboard protocol: CSI 13;<mod>u
                        // Mod values (xterm-style): 2=Shift, 3=Alt, 4=Shift+Alt
                        let mod: Int = (hasShift && hasAlt) ? 4 : (hasAlt ? 3 : 2)
                        let seq = "\u{1B}[13;\(mod)u"
                        self.send(txt: seq)
                        return nil  // swallow original key event
                    }
                }
                return event
            }
        }

        // TerminalViewDelegate: capture normalized scroll updates for overlay
        override public func scrolled(source: TerminalView, position: Double) {
            onScrolled?(position, self.scrollThumbsize)
        }

        override func dataReceived(slice: ArraySlice<UInt8>) {
            if Thread.isMainThread {
                forwardDataReceived(slice: slice)
                return
            }
            enqueueChunk(Array(slice))
        }

        private func enqueueChunk(_ chunk: [UInt8]) {
            if shouldFlushImmediately(for: chunk) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.forwardDataReceived(slice: chunk[...])
                }
                return
            }
            pendingChunks.append(chunk)
            if pendingChunks.count >= maxBatchChunks {
                flushPendingChunks()
            } else {
                scheduleFlush()
            }
        }

        private func shouldFlushImmediately(for chunk: [UInt8]) -> Bool {
            if pendingChunks.isEmpty && chunk.count <= immediateFlushThresholdBytes {
                return true
            }
            if chunk.count <= typingChunkSoftLimit {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastTypingAt <= typingFlushWindow {
                    return true
                }
            }
            return false
        }

        private func scheduleFlush() {
            guard pendingFlushWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.flushPendingChunks()
            }
            pendingFlushWork = work
            processDispatchQueue.asyncAfter(deadline: .now() + flushInterval, execute: work)
        }

        private func flushPendingChunks() {
            pendingFlushWork?.cancel()
            pendingFlushWork = nil
            guard !pendingChunks.isEmpty else { return }
            let chunks = pendingChunks
            pendingChunks.removeAll(keepingCapacity: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for chunk in chunks {
                    self.forwardDataReceived(slice: chunk[...])
                }
            }
        }

        private func forwardDataReceived(slice: ArraySlice<UInt8>) {
            super.dataReceived(slice: slice)
        }

        // TerminalDelegate notification hook: handle OSC 777 notifications emitted by the TUI/CLI.
        public func notify(source: Terminal, title: String, body: String) {
            Task { @MainActor in
                await SystemNotifier.shared.notify(title: title, body: body)
                if let sid = sessionID {
                    // Treat any OSC 777 notification as an end-of-turn signal for embedded sessions.
                    // This avoids schema/keyword mismatches between different TUIs.
                    await SystemNotifier.shared.notifyAgentCompleted(sessionID: sid, message: body)
                    // Heal focus/paint occasionally left odd by full‑screen TUIs exiting.
                    // 1) Ensure this view regains first responder
                    self.window?.makeFirstResponder(self)
                    // 2) Nudge the terminal to redraw without altering shell state
                    #if canImport(SwiftTerm)
                        TerminalSessionManager.shared.scheduleSlashNudge(forKey: sid, delay: 0.15)
                    #endif
                }
            }
        }

        private static func looksLikeCompletion(title: String, body: String) -> Bool { true }

        private func pasteboardHasImage(_ pb: NSPasteboard) -> Bool {
            if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
                return true
            }
            if let types = pb.types {
                if types.contains(.png) || types.contains(.tiff) || types.contains(.pdf) {
                    return true
                }
            }
            if let urls = pb.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] {
                return urls.contains(where: { isImageFile($0) })
            }
            return false
        }

        private func isImageFile(_ url: URL) -> Bool {
            let exts = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp"]
            return exts.contains(url.pathExtension.lowercased())
        }

        // No-op for now: path injection fallback removed in favor of Ctrl+V simulation.

        override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            let id = sessionID ?? ""
            let action: () -> Void = { [weak self] in
                guard let self else { return }
                self.finalizeProcessTermination(source: source, exitCode: exitCode, sessionID: id)
            }
            if Thread.isMainThread {
                action()
            } else {
                DispatchQueue.main.async(execute: action)
            }
        }

        private func finalizeProcessTermination(
            source: LocalProcess,
            exitCode: Int32?,
            sessionID: String
        ) {
            super.processTerminated(source, exitCode: exitCode)
            NotificationCenter.default.post(
                name: .codMateTerminalExited,
                object: nil,
                userInfo: ["sessionID": sessionID, "exitCode": exitCode as Any]
            )
        }

        // MARK: - Drag & Drop
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            return canAcceptDraggedFiles(sender.draggingPasteboard) ? .copy : []
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            return canAcceptDraggedFiles(sender.draggingPasteboard)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            let urls = extractFileURLs(from: pb)
            guard !urls.isEmpty else { return false }
            insertPaths(urls)
            return true
        }

        private func canAcceptDraggedFiles(_ pb: NSPasteboard) -> Bool {
            return !extractFileURLs(from: pb).isEmpty
        }

        private func extractFileURLs(from pb: NSPasteboard) -> [URL] {
            if let objs = pb.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !objs.isEmpty {
                return objs
            }
            if let list = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
                as? [String], !list.isEmpty
            {
                return list.map { URL(fileURLWithPath: $0) }
            }
            if let str = pb.string(forType: .fileURL),
               let url = URL(string: str), url.isFileURL
            {
                return [url]
            }
            return []
        }

        private func insertPaths(_ urls: [URL]) {
            let escaped = urls.map { shellEscapedPath($0.path) }
            guard !escaped.isEmpty else { return }
            let text = escaped.joined(separator: " ") + " "
            send(txt: text)
        }

        private func shellEscapedPath(_ path: String) -> String {
            if path.isEmpty { return "''" }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/.-_"))
            let needsQuotes = path.rangeOfCharacter(from: allowed.inverted) != nil
            var output = path.replacingOccurrences(of: "'", with: "'\\''")
            if needsQuotes {
                output = "'\(output)'"
            }
            return output
        }
    }
#endif
