import SwiftUI
import AppKit

// High-performance NSTextView wrapper with optional line numbers, wrapping and simple diff/syntax colors.
struct AttributedTextView: NSViewRepresentable {
    final class Coordinator {
        var lastText: String = ""
        var lastIsDiff: Bool = false
        var lastWrap: Bool = true
        var lastFontSize: CGFloat = 12
        var textStorage = NSTextStorage()
    }

    var text: String
    var isDiff: Bool
    var wrap: Bool
    var showLineNumbers: Bool
    var fontSize: CGFloat = 12

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let layoutMgr = LineNumberLayoutManager()
        layoutMgr.showsLineNumbers = showLineNumbers
        context.coordinator.textStorage.addLayoutManager(layoutMgr)
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = wrap
        container.heightTracksTextView = false
        layoutMgr.addTextContainer(container)

        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.drawsBackground = false
        // Use inner lineFragmentPadding as gutter to keep drawing inside container clip
        let gutterWidth: CGFloat = showLineNumbers ? 44 : 6
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.textContainer?.lineFragmentPadding = gutterWidth
        tv.linkTextAttributes = [:]
        tv.font = preferredFont(size: fontSize)
        tv.allowsUndo = false
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]

        if !wrap {
            tv.isHorizontallyResizable = true
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else {
            tv.isHorizontallyResizable = false
        }

        scroll.documentView = tv
        layoutMgr.textView = tv

        // Seed content
        apply(text: text, isDiff: isDiff, wrap: wrap, tv: tv, storage: context.coordinator.textStorage, coordinator: context.coordinator)
        context.coordinator.lastText = text
        context.coordinator.lastIsDiff = isDiff
        context.coordinator.lastWrap = wrap
        context.coordinator.lastFontSize = fontSize
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView,
              let container = tv.textContainer else { return }

        // Update wrapping
        if context.coordinator.lastWrap != wrap {
            container.widthTracksTextView = wrap
            if wrap {
                tv.isHorizontallyResizable = false
                // Ensure container follows current view width to lay out lines
                let w = max(1, tv.bounds.width)
                container.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
            } else {
                tv.isHorizontallyResizable = true
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
            context.coordinator.lastWrap = wrap
        }

        // Update font if changed
        if context.coordinator.lastFontSize != fontSize {
            tv.font = preferredFont(size: fontSize)
            context.coordinator.lastFontSize = fontSize
        }

        // Update line number rendering via custom layout manager and inner padding
        if let lm = tv.layoutManager as? LineNumberLayoutManager {
            lm.showsLineNumbers = showLineNumbers
        }
        let gutterWidth2: CGFloat = showLineNumbers ? 44 : 6
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.textContainer?.lineFragmentPadding = gutterWidth2

        // Update content only when changed to avoid re-layout cost
        if text != context.coordinator.lastText || isDiff != context.coordinator.lastIsDiff {
            apply(text: text, isDiff: isDiff, wrap: wrap, tv: tv, storage: context.coordinator.textStorage, coordinator: context.coordinator)
            context.coordinator.lastText = text
            context.coordinator.lastIsDiff = isDiff
        }
    }

    private func preferredFont(size: CGFloat) -> NSFont {
        let candidates = [
            "JetBrains Mono", "JetBrainsMono-Regular", "JetBrains Mono NL",
            "SF Mono", "Menlo"
        ]
        for name in candidates { if let f = NSFont(name: name, size: size) { return f } }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func apply(text: String, isDiff: Bool, wrap: Bool, tv: NSTextView, storage: NSTextStorage, coordinator: Coordinator) {
        // Build attributed string off-main to keep UI snappy
        let input = text
        let font = preferredFont(size: fontSize)
        DispatchQueue.global(qos: .userInitiated).async {
            let attr = NSMutableAttributedString(string: input, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ])
            // Precompute newline UTF-16 offsets for fast line-number lookup
            let ns = input as NSString
            var nl: [Int] = []
            nl.reserveCapacity(1024)
            let len = ns.length
            if len > 0 {
                // Use getCharacters buffer for speed
                let buf = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
                ns.getCharacters(buf, range: NSRange(location: 0, length: len))
                for i in 0..<len { if buf[i] == 10 { nl.append(i) } }
                buf.deallocate()
            }
            if isDiff {
                DiffStyler.apply(to: attr)
            } else {
                // Light syntax hints for common formats
                SyntaxStyler.applyLight(to: attr)
            }
            DispatchQueue.main.async {
                storage.setAttributedString(attr)
                tv.textStorage?.setAttributedString(attr)
                if let lm = tv.layoutManager as? LineNumberLayoutManager {
                    lm.newlineOffsets = nl
                }
                // Dynamic gutter width based on maximum line number digits
                let totalLines = max(1, nl.count + 1)
                let digits = max(2, String(totalLines).count)
                let sample = String(repeating: "8", count: digits) as NSString
                let numWidth = sample.size(withAttributes: [.font: font]).width
                let gap: CGFloat = 3 // spacing between numbers and separator
                let leftPad: CGFloat = 5 // inner left padding inside gutter
                let minGutter: CGFloat = 36
                let gutter = max(minGutter, ceil(numWidth + gap + leftPad))
                tv.textContainer?.lineFragmentPadding = gutter
                tv.needsDisplay = true
                tv.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
    }
}

private enum DiffStyler {
    static func apply(to s: NSMutableAttributedString) {
        let full = s.string as NSString
        full.enumerateSubstrings(in: NSRange(location: 0, length: full.length), options: .byLines) { _, range, _, _ in
            guard range.length > 0 else { return }
            let first = full.substring(with: NSRange(location: range.location, length: 1))
            let bg: NSColor?
            let fg: NSColor?
            if first == "+" && !lineStarts(with: "+++", in: full, at: range) {
                bg = NSColor.systemGreen.withAlphaComponent(0.12); fg = nil
            } else if first == "-" && !lineStarts(with: "---", in: full, at: range) {
                bg = NSColor.systemRed.withAlphaComponent(0.12); fg = nil
            } else if lineStarts(with: "@@", in: full, at: range) {
                bg = NSColor.systemBlue.withAlphaComponent(0.08); fg = NSColor.systemBlue
            } else if lineStarts(with: "diff --git", in: full, at: range) || lineStarts(with: "index ", in: full, at: range) || lineStarts(with: "+++", in: full, at: range) || lineStarts(with: "---", in: full, at: range) {
                bg = NSColor.quaternaryLabelColor.withAlphaComponent(0.12); fg = NSColor.secondaryLabelColor
            } else {
                bg = nil; fg = nil
            }
            var attrs: [NSAttributedString.Key: Any] = [:]
            if let bg { attrs[.backgroundColor] = bg }
            if let fg { attrs[.foregroundColor] = fg }
            if !attrs.isEmpty { s.addAttributes(attrs, range: range) }
        }
    }
    private static func lineStarts(with prefix: String, in str: NSString, at range: NSRange) -> Bool {
        if str.length >= range.location + prefix.count {
            return str.substring(with: NSRange(location: range.location, length: prefix.count)) == prefix
        }
        return false
    }
}

private enum SyntaxStyler {
    static func applyLight(to s: NSMutableAttributedString) {
        // Extremely light heuristics for JSON/YAML/Swift/Markdown
        let str = s.string as NSString
        let commentColor = NSColor.systemGreen
        // JSON strings
        var idx = 0
        while idx < str.length {
            let c = str.character(at: idx)
            if c == 34 { // '"'
                let start = idx
                idx += 1; var escaping = false
                while idx < str.length {
                    let cc = str.character(at: idx)
                    if cc == 92 { escaping.toggle() } // '\\'
                    else if cc == 34 && !escaping { break }
                    else { escaping = false }
                    idx += 1
                }
                let end = min(idx+1, str.length)
                s.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: NSRange(location: start, length: end-start))
            }
            idx += 1
        }
        // Single-line comments (Swift/C/JS)
        let scanner = Scanner(string: s.string)
        scanner.charactersToBeSkipped = nil
        while !scanner.isAtEnd {
            _ = scanner.scanUpToString("//")
            if scanner.scanString("//") != nil {
                let start = scanner.currentIndex
                _ = scanner.scanUpToCharacters(from: .newlines)
                let end = scanner.currentIndex
                s.addAttribute(.foregroundColor, value: commentColor, range: NSRange(start..<end, in: s.string))
            }
        }
    }
}

// Custom layout manager draws line numbers within left inset (no separate ruler).
final class LineNumberLayoutManager: NSLayoutManager {
    var showsLineNumbers: Bool = true
    weak var textView: NSTextView?
    private let numberColor = NSColor.secondaryLabelColor
    // UTF-16 offsets of "\n" in the current textStorage string
    var newlineOffsets: [Int] = []

    func lineNumberFor(charIndex idx: Int) -> Int {
        if newlineOffsets.isEmpty { return 1 }
        var lo = 0, hi = newlineOffsets.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if newlineOffsets[mid] < idx { lo = mid + 1 } else { hi = mid }
        }
        return lo + 1 // lines start at 1
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textView = textView, let container = textView.textContainer else { return }

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        if showsLineNumbers {
            // Draw gutter strictly inside container: [origin.x, origin.x + padding)
            let padding = textView.textContainer?.lineFragmentPadding ?? 0
            let gutterRect = NSRect(
                x: origin.x,
                y: visibleRect.minY,
                width: max(0, padding),
                height: visibleRect.height
            )
            (textView.backgroundColor).setFill()
            NSBezierPath(rect: gutterRect).fill()
            // No separator line (to reduce draw cost and match Xcode style)
        }

        guard showsLineNumbers else { return }
        // Convert view rect to container coordinates for querying glyphs
        let containerRect = NSRect(x: visibleRect.origin.x - origin.x,
                                   y: visibleRect.origin.y - origin.y,
                                   width: visibleRect.width,
                                   height: visibleRect.height)
        let glyphRange = self.glyphRange(forBoundingRect: containerRect, in: container)
        var lineNumber = 1
        if glyphRange.location > 0 {
            let preChars = self.characterRange(forGlyphRange: NSRange(location: 0, length: glyphRange.location), actualGlyphRange: nil)
            lineNumber = lineNumberFor(charIndex: preChars.upperBound)
        }

        var glyphIndex = glyphRange.location
        while glyphIndex < glyphRange.upperBound {
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = self.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange, withoutAdditionalLayout: true)
            let y = origin.y + lineRect.minY
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: numberColor
            ]
            let num = "\(lineNumber)" as NSString
            let size = num.size(withAttributes: attrs)
            let padding = textView.textContainer?.lineFragmentPadding ?? 0
            let gap: CGFloat = 3 // spacing between numbers and text start
            let x = origin.x + padding - gap - size.width
            num.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            lineNumber += 1
            glyphIndex = lineGlyphRange.upperBound
        }
    }
}
