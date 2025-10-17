import Foundation

enum SessionNavigationItem: Hashable, Identifiable {
    case allSessions
    case calendarDay(Date)     // startOfDay
    case pathPrefix(String)    // absolute directory path prefix

    var id: String {
        switch self {
        case .allSessions:
            return "all"
        case let .calendarDay(day):
            return "day-\(ISO8601DateFormatter().string(from: day))"
        case let .pathPrefix(prefix):
            return "path-\(prefix)"
        }
    }

    var title: String {
        switch self {
        case .allSessions:
            return "全部会话"
        case let .calendarDay(day):
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: day)
        case let .pathPrefix(prefix):
            return URL(fileURLWithPath: prefix, isDirectory: true).lastPathComponent
        }
    }

    var systemImage: String {
        switch self {
        case .allSessions:
            return "tray.full"
        case .calendarDay:
            return "calendar"
        case .pathPrefix:
            return "folder"
        }
    }
}
