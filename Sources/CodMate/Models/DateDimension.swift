import Foundation

enum DateDimension: String, CaseIterable, Identifiable {
    case created
    case updated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .created: return "创建日期"
        case .updated: return "最后更新"
        }
    }
}

