import Foundation

enum SettingCategory: String, CaseIterable, Identifiable {
  case general
  case terminal
  case llm
  case advanced

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .terminal: return "Terminal"
    case .llm: return "LLM"
    case .advanced: return "Advanced"
    }
  }

  var icon: String {
    switch self {
    case .general: return "gear"
    case .terminal: return "terminal"
    case .llm: return "brain"
    case .advanced: return "slider.horizontal.3"
    }
  }

  var description: String {
    switch self {
    case .general: return "Basic application settings"
    case .terminal: return "Terminal and resume preferences"
    case .llm: return "AI model configuration"
    case .advanced: return "Advanced options and debugging"
    }
  }
}
