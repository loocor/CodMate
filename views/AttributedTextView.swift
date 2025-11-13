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
        layoutMgr.wrapEnabled = wrap
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
            // Seed a sensible initial width when wrapping, otherwise container width may be 0
            let initialW = max(1, scroll.contentSize.width)
            container.containerSize = NSSize(width: initialW, height: CGFloat.greatestFiniteMagnitude)
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
                let w = max(1, tv.enclosingScrollView?.contentSize.width ?? tv.bounds.width)
                container.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
            } else {
                tv.isHorizontallyResizable = true
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
            context.coordinator.lastWrap = wrap
            // Propagate to layout manager
            if let lm = tv.layoutManager as? LineNumberLayoutManager { lm.wrapEnabled = wrap }
            // Ensure layout refresh after wrap mode change
            tv.layoutManager?.ensureLayout(for: container)
            tv.needsDisplay = true
        }
        // While staying in the same wrap mode, keep the container width in sync with the visible width
        if wrap {
            let currentW = tv.enclosingScrollView?.contentSize.width ?? tv.bounds.width
            let cw = container.containerSize.width
            if abs(currentW - cw) > 0.5 {
                container.containerSize = NSSize(width: max(1, currentW), height: CGFloat.greatestFiniteMagnitude)
                // Keep layout in sync with container width changes
                tv.layoutManager?.ensureLayout(for: container)
                tv.needsDisplay = true
            }
        }

        // Update font if changed
        if context.coordinator.lastFontSize != fontSize {
            tv.font = preferredFont(size: fontSize)
            context.coordinator.lastFontSize = fontSize
        }

        // Update line number rendering via custom layout manager and inner padding
        if let lm = tv.layoutManager as? LineNumberLayoutManager {
            lm.showsLineNumbers = showLineNumbers
            lm.wrapEnabled = wrap
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
            var diffRightNumbers: [Int?] = []
            var diffLeftNumbers: [Int?] = []
            var diffMaxRight: Int = 0
            var diffMaxLeft: Int = 0
            if isDiff {
                DiffStyler.apply(to: attr)
                // Build mapping from visual lines → right-side (new file) line numbers
                let full = input as NSString
                var mapR: [Int?] = []
                var mapL: [Int?] = []
                mapR.reserveCapacity(nl.count + 1)
                mapL.reserveCapacity(nl.count + 1)
                var currentRight: Int? = nil
                var currentLeft: Int? = nil
                var lineIndex = 0
                full.enumerateSubstrings(in: NSRange(location: 0, length: full.length), options: .byLines) { _, range, _, stop in
                    defer { lineIndex += 1 }
                    guard range.length > 0 else { mapR.append(nil); mapL.append(nil); return }
                    let firstChar = full.substring(with: NSRange(location: range.location, length: 1))
                    // Detect hunk header: @@ -l,ct +r,ct @@
                    if DiffStyler_lineStarts(with: "@@", in: full, at: range) {
                        // Parse left/right starts
                        let lineStr = full.substring(with: range)
                        currentRight = parseRightStart(fromHunkHeader: lineStr)
                        currentLeft = parseLeftStart(fromHunkHeader: lineStr)
                        mapR.append(nil)
                        mapL.append(nil)
                        return
                    }
                    // Ignore file headers
                    if DiffStyler_lineStarts(with: "diff --git", in: full, at: range) || DiffStyler_lineStarts(with: "index ", in: full, at: range) || DiffStyler_lineStarts(with: "+++", in: full, at: range) || DiffStyler_lineStarts(with: "---", in: full, at: range) {
                        mapR.append(nil); mapL.append(nil); return
                    }
                    if firstChar == "+" && !DiffStyler_lineStarts(with: "+++", in: full, at: range) {
                        if let r0 = currentRight { mapR.append(r0); diffMaxRight = max(diffMaxRight, r0); currentRight = r0 + 1 } else { mapR.append(nil) }
                        mapL.append(nil)
                    } else if firstChar == " " {
                        if let r0 = currentRight { mapR.append(r0); diffMaxRight = max(diffMaxRight, r0); currentRight = r0 + 1 } else { mapR.append(nil) }
                        if let l0 = currentLeft { mapL.append(l0); diffMaxLeft = max(diffMaxLeft, l0); currentLeft = l0 + 1 } else { mapL.append(nil) }
                    } else if firstChar == "-" && !DiffStyler_lineStarts(with: "---", in: full, at: range) {
                        if let l0 = currentLeft { mapL.append(l0); diffMaxLeft = max(diffMaxLeft, l0); currentLeft = l0 + 1 } else { mapL.append(nil) }
                        mapR.append(nil)
                    } else {
                        mapR.append(nil)
                        mapL.append(nil)
                    }
                }
                diffRightNumbers = mapR
                diffLeftNumbers = mapL
            } else {
                // Light syntax hints for common formats
                SyntaxStyler.applyLight(to: attr)
            }
            DispatchQueue.main.async {
                storage.setAttributedString(attr)
                tv.textStorage?.setAttributedString(attr)
                if let lm = tv.layoutManager as? LineNumberLayoutManager {
                    lm.newlineOffsets = nl
                    lm.diffMode = isDiff
                    lm.diffRightLineNumbers = diffRightNumbers
                    lm.diffLeftLineNumbers = diffLeftNumbers
                }
                // Dynamic gutter width based on maximum line number digits
                let totalLines = max(1, nl.count + 1)
                let targetMax = isDiff ? max(1, max(diffMaxRight, diffMaxLeft)) : totalLines
                let digits = max(2, String(targetMax).count)
                let sample = String(repeating: "8", count: digits) as NSString
                let numWidth = sample.size(withAttributes: [.font: font]).width
                let gap: CGFloat = 8 // spacing between numbers and text start
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

    // Cached regex patterns (compiled once for performance)
    private static let keywordPattern: NSRegularExpression? = {
        // Common keywords across multiple languages (combined into one regex)
        let keywords = [
            // JavaScript/TypeScript
            "function", "const", "let", "var", "if", "else", "return", "for", "while",
            "import", "export", "class", "extends", "async", "await", "try", "catch",
            // Swift
            "func", "struct", "enum", "protocol", "private", "public", "guard", "defer",
            // Python
            "def", "lambda", "with", "as", "pass", "yield", "raise", "except",
            // Rust
            "fn", "impl", "trait", "mod", "use", "pub", "mut", "unsafe",
            // Go
            "package", "type", "interface", "chan", "go", "range",
            // Common control flow
            "switch", "case", "default", "break", "continue",
            // Common types and values
            "int", "bool", "string", "float", "void",
            "null", "true", "false", "nil", "undefined",
            // YAML/TOML specific
            "yes", "no", "on", "off"
        ]
        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let numberPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b(0x[0-9A-Fa-f]+|\\d+\\.?\\d*)\\b", options: [])
    }()

    static func applyLight(to s: NSMutableAttributedString) {
        let str = s.string as NSString
        let fullString = s.string
        let fullRange = NSRange(location: 0, length: str.length)

        // Color palette (using system colors for auto Light/Dark adaptation)
        let keywordColor = NSColor.systemPink
        let stringColor = NSColor.systemRed
        let commentColor = NSColor.systemGreen
        let numberColor = NSColor.systemPurple

        // 1. Strings (all quote types in one pass)
        highlightStrings(in: s, str: str, color: stringColor)

        // 2. Comments (both // and # in one pass)
        highlightComments(in: s, fullString: fullString, color: commentColor)

        // 3. Keywords (single regex with all keywords combined)
        keywordPattern?.enumerateMatches(in: fullString, range: fullRange) { match, _, _ in
            if let range = match?.range {
                s.addAttribute(.foregroundColor, value: keywordColor, range: range)
            }
        }

        // 4. Numbers (single regex)
        numberPattern?.enumerateMatches(in: fullString, range: fullRange) { match, _, _ in
            if let range = match?.range {
                s.addAttribute(.foregroundColor, value: numberColor, range: range)
            }
        }
    }

    // Highlight strings (all quote types: ", ', `)
    private static func highlightStrings(in s: NSMutableAttributedString, str: NSString, color: NSColor) {
        let quotes: [UInt16] = [34, 39, 96] // ", ', `

        for quote in quotes {
            var idx = 0
            while idx < str.length {
                let c = str.character(at: idx)
                if c == quote {
                    let start = idx
                    idx += 1
                    var escaping = false
                    while idx < str.length {
                        let cc = str.character(at: idx)
                        if cc == 92 { escaping.toggle() } // '\\'
                        else if cc == quote && !escaping { break }
                        else { escaping = false }
                        idx += 1
                    }
                    let end = min(idx + 1, str.length)
                    s.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: end - start))
                }
                idx += 1
            }
        }
    }

    // Highlight comments (//, #, ; for different file formats)
    private static func highlightComments(in s: NSMutableAttributedString, fullString: String, color: NSColor) {
        // Support multiple comment styles:
        // // - C-style (JS, Swift, Rust, Go, etc.)
        // #  - Shell-style (Python, Ruby, YAML, TOML, ENV)
        // ;  - INI-style (INI files)
        let commentStarts = ["//", "#", ";"]

        for commentStart in commentStarts {
            let scanner = Scanner(string: fullString)
            scanner.charactersToBeSkipped = nil
            while !scanner.isAtEnd {
                _ = scanner.scanUpToString(commentStart)
                if scanner.scanString(commentStart) != nil {
                    let start = scanner.currentIndex
                    _ = scanner.scanUpToCharacters(from: .newlines)
                    let end = scanner.currentIndex
                    s.addAttribute(.foregroundColor, value: color, range: NSRange(start..<end, in: fullString))
                }
            }
        }
    }
}

// Custom layout manager draws line numbers within left inset (no separate ruler).
final class LineNumberLayoutManager: NSLayoutManager {
    var showsLineNumbers: Bool = true
    weak var textView: NSTextView?
    private let numberColor = NSColor.secondaryLabelColor
    private let deletionNumberColor = NSColor.systemRed
    var wrapEnabled: Bool = false
    // UTF-16 offsets of "\n" in the current textStorage string
    var newlineOffsets: [Int] = []
    // Diff mode line-number mapping (visual line index → side line numbers)
    var diffMode: Bool = false
    var diffRightLineNumbers: [Int?] = []
    var diffLeftLineNumbers: [Int?] = []

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
        }

        guard showsLineNumbers else { return }
        // Convert view rect to container coordinates for querying glyphs
        let containerRect = NSRect(x: visibleRect.origin.x - origin.x,
                                   y: visibleRect.origin.y - origin.y,
                                   width: visibleRect.width,
                                   height: visibleRect.height)
        let glyphRange = self.glyphRange(forBoundingRect: containerRect, in: container)
        var lastDrawnLogicalLine: Int? = nil
        self.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            let y = origin.y + usedRect.minY
            // Determine logical line index for this visual fragment
            let charRange = self.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            let logicalLine = self.lineNumberFor(charIndex: charRange.location)
            let idx = logicalLine - 1
            let rightVal = (self.diffMode && idx >= 0 && idx < self.diffRightLineNumbers.count) ? self.diffRightLineNumbers[idx] : nil
            let leftVal = (self.diffMode && idx >= 0 && idx < self.diffLeftLineNumbers.count) ? self.diffLeftLineNumbers[idx] : nil
            let isDeletion = self.diffMode && leftVal != nil && rightVal == nil
            let drawColor = isDeletion ? self.deletionNumberColor : self.numberColor
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: drawColor
            ]
            let shouldDrawThisFragment: Bool = {
                if self.wrapEnabled {
                    // In wrap mode, draw the number for every visual fragment to avoid gaps
                    return true
                } else {
                    // In non-wrap mode, draw once per visible logical line
                    return lastDrawnLogicalLine != logicalLine
                }
            }()
            let numString: String = {
                if !shouldDrawThisFragment { return "" }
                if self.diffMode {
                    if isDeletion, let l = leftVal { return String(l) }
                    if let r = rightVal { return String(r) }
                    return ""
                }
                return String(logicalLine)
            }()
            guard !numString.isEmpty else { return }
            let num = numString as NSString
            let size = num.size(withAttributes: attrs)
            let padding = textView.textContainer?.lineFragmentPadding ?? 0
            let gap: CGFloat = 8 // spacing between numbers and text start
            let x = origin.x + padding - gap - size.width
            num.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            lastDrawnLogicalLine = logicalLine
        }
    }

    private func isAtLineStart(charIndex: Int) -> Bool {
        if charIndex == 0 { return true }
        // Binary search for (charIndex - 1) in newlineOffsets
        var lo = 0, hi = newlineOffsets.count
        let target = charIndex - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            let v = newlineOffsets[mid]
            if v == target { return true }
            if v < target { lo = mid + 1 } else { hi = mid }
        }
        return false
    }
}

// MARK: - Helpers for diff parsing
private func DiffStyler_lineStarts(with prefix: String, in str: NSString, at range: NSRange) -> Bool {
    if str.length >= range.location + prefix.count {
        return str.substring(with: NSRange(location: range.location, length: prefix.count)) == prefix
    }
    return false
}

private func parseRightStart(fromHunkHeader header: String) -> Int? {
    // Example: @@ -10,7 +12,9 @@ or @@ -10 +12 @@
    // Extract the +<num> portion
    guard let plusRange = header.range(of: "+") else { return nil }
    var digits = ""
    var idx = plusRange.upperBound
    while idx < header.endIndex {
        let ch = header[idx]
        if ch.isNumber { digits.append(ch) } else { break }
        idx = header.index(after: idx)
    }
    return Int(digits)
}

private func parseLeftStart(fromHunkHeader header: String) -> Int? {
    // Extract the -<num> portion from a hunk header
    guard let dashRange = header.range(of: "-") else { return nil }
    var digits = ""
    var idx = header.index(after: dashRange.lowerBound)
    while idx < header.endIndex {
        let ch = header[idx]
        if ch.isNumber { digits.append(ch) } else { break }
        idx = header.index(after: idx)
    }
    return Int(digits)
}
