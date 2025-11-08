import Foundation

enum TerminalCursorStyleOption: String, CaseIterable, Identifiable, Codable, Hashable {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blinkBlock: return "Blinking Block"
        case .steadyBlock: return "Steady Block"
        case .blinkUnderline: return "Blinking Underline"
        case .steadyUnderline: return "Steady Underline"
        case .blinkBar: return "Blinking Bar"
        case .steadyBar: return "Steady Bar"
        }
    }
}

#if canImport(SwiftTerm)
import SwiftTerm

extension TerminalCursorStyleOption {
    var cursorStyleValue: CursorStyle {
        switch self {
        case .blinkBlock: return .blinkBlock
        case .steadyBlock: return .steadyBlock
        case .blinkUnderline: return .blinkUnderline
        case .steadyUnderline: return .steadyUnderline
        case .blinkBar: return .blinkBar
        case .steadyBar: return .steadyBar
        }
    }

    var steadyCursorStyleValue: CursorStyle {
        switch self {
        case .blinkBlock, .steadyBlock: return .steadyBlock
        case .blinkUnderline, .steadyUnderline: return .steadyUnderline
        case .blinkBar, .steadyBar: return .steadyBar
        }
    }
}
#endif
