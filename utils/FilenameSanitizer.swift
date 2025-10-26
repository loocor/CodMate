import Foundation

func sanitizeFileName(_ s: String, fallback: String, maxLength: Int = 120) -> String {
    var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return fallback }
    // Replace path separators and reserved colon; strip control characters
    let disallowed = CharacterSet(charactersIn: "/:")
        .union(.newlines)
        .union(.controlCharacters)
    text = text.unicodeScalars.map { disallowed.contains($0) ? Character(" ") : Character($0) }
        .reduce(into: String(), { $0.append($1) })
    // Collapse consecutive spaces
    while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { text = fallback }
    // Limit length to keep file names tidy
    if text.count > maxLength {
        let idx = text.index(text.startIndex, offsetBy: maxLength)
        text = String(text[..<idx])
    }
    return text
}

