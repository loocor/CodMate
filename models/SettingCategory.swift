import Foundation

enum SettingCategory: String, CaseIterable, Identifiable {
  case general
  case terminal
  case command
  case providers
  case codex
  case claudeCode
  case dialectics
  case mcpServer
  case about

  // Customize displayed order and allow hiding categories without breaking enums elsewhere.
  static var allCases: [SettingCategory] { [.general, .terminal, .providers, .codex, .claudeCode, .mcpServer, .dialectics, .about] }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .terminal: return "Terminal"
    case .command: return "Command"
    case .providers: return "Providers"
    case .codex: return "Codex"
    case .claudeCode: return "Claude Code"
    case .dialectics: return "Dialectics"
    case .mcpServer: return "MCP Server"
    case .about: return "About"
    }
  }

  var icon: String {
    switch self {
    case .general: return "gear"
    case .terminal: return "terminal"
    case .command: return "slider.horizontal.3"
    case .providers: return "server.rack"
    case .codex: return "sparkles"
    case .dialectics: return "doc.text.magnifyingglass"
    case .claudeCode: return "chevron.left.slash.chevron.right"
    case .mcpServer: return "server.rack"
    case .about: return "info.circle"
    }
  }

  var description: String {
    switch self {
    case .general: return "Basic application settings"
    case .terminal: return "Terminal and resume preferences"
    case .command: return "Command execution policies"
    case .providers: return "Global providers and bindings"
    case .codex: return "Codex CLI configuration"
    case .claudeCode: return "Claude Code configuration"
    case .dialectics: return "Deep diagnostics & reports"
    case .mcpServer: return "Manage Codex MCP integrations"
    case .about: return "App info and project links"
  }
}
}
