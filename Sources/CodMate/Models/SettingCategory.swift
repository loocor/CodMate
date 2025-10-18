import Foundation

enum SettingCategory: String, CaseIterable, Identifiable {
  case general
  case terminal
  case command

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .terminal: return "Terminal"
    case .command: return "Command"
    }
  }

  var icon: String {
    switch self {
    case .general: return "gear"
    case .terminal: return "terminal"
    case .command: return "slider.horizontal.3"
    }
  }

  var description: String {
    switch self {
    case .general: return "Basic application settings"
    case .terminal: return "Terminal and resume preferences"
    case .command: return "Command execution policies"
  }
}
}
