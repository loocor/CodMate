import AppKit

enum TerminalFontResolver {
    // Candidate order: prefer CJK-capable monospace fonts before system defaults
    private static let preferredMonoCandidates = [
        "Sarasa Mono SC", "Sarasa Term SC",
        "LXGW WenKai Mono",
        "Noto Sans Mono CJK SC", "NotoSansMonoCJKsc-Regular",
        "JetBrains Mono", "JetBrainsMono-Regular", "JetBrains Mono NL",
        "JetBrainsMonoNL Nerd Font Mono", "JetBrainsMono Nerd Font Mono",
        "SF Mono", "Menlo",
    ]

    static func resolvedFont(name: String, size: CGFloat) -> NSFont {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let explicit = NSFont(name: trimmed, size: size) {
            return explicit
        }
        for candidate in preferredMonoCandidates {
            if let font = NSFont(name: candidate, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
