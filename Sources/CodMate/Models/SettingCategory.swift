import Foundation

enum SettingCategory: String, CaseIterable, Identifiable {
  case general
  case terminal
  case command
  case mcpServer
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .terminal: return "Terminal"
    case .command: return "Command"
    case .mcpServer: return "MCP Server"
    case .about: return "About"
    }
  }

  var icon: String {
    switch self {
    case .general: return "gear"
    case .terminal: return "terminal"
    case .command: return "slider.horizontal.3"
    case .mcpServer: return "server.rack"
    case .about: return "info.circle"
    }
  }

  var description: String {
    switch self {
    case .general: return "Basic application settings"
    case .terminal: return "Terminal and resume preferences"
    case .command: return "Command execution policies"
    case .mcpServer: return "Manage Codex MCP integrations"
    case .about: return "App info and project links"
  }
}
}
