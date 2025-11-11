import Foundation

enum SettingCategory: String, CaseIterable, Identifiable {
  case general
  case terminal
  case command
  case providers
  case codex
  case remoteHosts
  case gitReview
  case claudeCode
  case dialectics
  case mcpServer
  case about

  // Customize displayed order and allow hiding categories without breaking enums elsewhere.
  static var allCases: [SettingCategory] { [.general, .terminal, .providers, .gitReview, .mcpServer, .codex, .remoteHosts, .claudeCode, .dialectics, .about] }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .terminal: return "Terminal"
    case .command: return "Command"
    case .providers: return "Providers"
    case .codex: return "Codex"
    case .remoteHosts: return "Remote Hosts"
    case .gitReview: return "Git Review"
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
    case .remoteHosts: return "antenna.radiowaves.left.and.right"
    case .dialectics: return "doc.text.magnifyingglass"
    case .gitReview: return "square.and.pencil"
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
    case .remoteHosts: return "Remote SSH host configuration"
    case .gitReview: return "Git changes viewer and commit generation"
    case .claudeCode: return "Claude Code configuration"
    case .dialectics: return "Deep diagnostics & reports"
    case .mcpServer: return "Manage Codex MCP integrations"
    case .about: return "App info and project links"
  }
}
}
