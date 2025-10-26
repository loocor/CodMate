import Foundation

enum DateDimension: String, CaseIterable, Identifiable {
    case created
    case updated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .created: return "Created"
        case .updated: return "Last Updated"
        }
    }
}

