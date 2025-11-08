import Foundation

struct SidebarState: Equatable {
    var totalSessionCount: Int
    var isLoading: Bool
    var visibleAllCount: Int
    var selectedProjectIDs: Set<String>
    var selectedDay: Date?
    var selectedDays: Set<Date>
    var dateDimension: DateDimension
    var monthStart: Date
    var calendarCounts: [Int: Int]
    var enabledProjectDays: Set<Int>?
}

struct SidebarActions {
    var selectAllProjects: () -> Void
    var requestNewProject: () -> Void
    var setDateDimension: (DateDimension) -> Void
    var setMonthStart: (Date) -> Void
    var setSelectedDay: (Date?) -> Void
    var toggleSelectedDay: (Date) -> Void
}
