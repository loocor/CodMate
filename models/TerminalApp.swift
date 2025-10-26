import Foundation

enum TerminalApp: String, CaseIterable, Identifiable {
    case none
    case terminal  // Apple Terminal
    case iterm2
    case warp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .warp: return "Warp"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .none: return nil
        case .terminal: return "com.apple.Terminal"
        case .iterm2: return "com.googlecode.iterm2"
        case .warp: return "dev.warp.Warp"
        }
    }
}

