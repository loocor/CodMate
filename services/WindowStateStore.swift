import Foundation

/// Persists and restores the main window state across app launches
@MainActor
final class WindowStateStore: ObservableObject {
    private let defaults: UserDefaults

    private struct Keys {
        static let selectedProjectIDs = "codmate.window.selectedProjectIDs"
        static let selectedDay = "codmate.window.selectedDay"
        static let selectedDays = "codmate.window.selectedDays"
        static let projectWorkspaceMode = "codmate.window.projectWorkspaceMode"
        static let selectedSessionIDs = "codmate.window.selectedSessionIDs"
        static let selectionPrimaryId = "codmate.window.selectionPrimaryId"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Save State

    func saveProjectSelection(_ projectIDs: Set<String>) {
        let array = Array(projectIDs)
        defaults.set(array, forKey: Keys.selectedProjectIDs)
    }

    func saveCalendarSelection(selectedDay: Date?, selectedDays: Set<Date>) {
        if let day = selectedDay {
            defaults.set(day.timeIntervalSinceReferenceDate, forKey: Keys.selectedDay)
        } else {
            defaults.removeObject(forKey: Keys.selectedDay)
        }

        let intervals = selectedDays.map { $0.timeIntervalSinceReferenceDate }
        defaults.set(intervals, forKey: Keys.selectedDays)
    }

    func saveWorkspaceMode(_ mode: ProjectWorkspaceMode) {
        defaults.set(mode.rawValue, forKey: Keys.projectWorkspaceMode)
    }

    func saveSessionSelection(selectedIDs: Set<SessionSummary.ID>, primaryId: SessionSummary.ID?) {
        let array = Array(selectedIDs)
        defaults.set(array, forKey: Keys.selectedSessionIDs)

        if let primary = primaryId {
            defaults.set(primary, forKey: Keys.selectionPrimaryId)
        } else {
            defaults.removeObject(forKey: Keys.selectionPrimaryId)
        }
    }

    // MARK: - Restore State

    func restoreProjectSelection() -> Set<String> {
        guard let array = defaults.array(forKey: Keys.selectedProjectIDs) as? [String] else {
            return []
        }
        return Set(array)
    }

    func restoreCalendarSelection() -> (selectedDay: Date?, selectedDays: Set<Date>) {
        let selectedDay: Date? = {
            let interval = defaults.double(forKey: Keys.selectedDay)
            guard interval != 0 else { return nil }
            return Date(timeIntervalSinceReferenceDate: interval)
        }()

        let selectedDays: Set<Date> = {
            guard let intervals = defaults.array(forKey: Keys.selectedDays) as? [TimeInterval] else {
                return []
            }
            return Set(intervals.map { Date(timeIntervalSinceReferenceDate: $0) })
        }()

        return (selectedDay, selectedDays)
    }

    func restoreWorkspaceMode() -> ProjectWorkspaceMode {
        guard let rawValue = defaults.string(forKey: Keys.projectWorkspaceMode),
              let mode = ProjectWorkspaceMode(rawValue: rawValue) else {
            return .tasks // default
        }
        return mode
    }

    func restoreSessionSelection() -> (selectedIDs: Set<SessionSummary.ID>, primaryId: SessionSummary.ID?) {
        let selectedIDs: Set<SessionSummary.ID> = {
            guard let array = defaults.array(forKey: Keys.selectedSessionIDs) as? [String] else {
                return []
            }
            return Set(array)
        }()

        let primaryId = defaults.string(forKey: Keys.selectionPrimaryId)

        return (selectedIDs, primaryId)
    }

    // MARK: - Clear State

    func clearAll() {
        defaults.removeObject(forKey: Keys.selectedProjectIDs)
        defaults.removeObject(forKey: Keys.selectedDay)
        defaults.removeObject(forKey: Keys.selectedDays)
        defaults.removeObject(forKey: Keys.projectWorkspaceMode)
        defaults.removeObject(forKey: Keys.selectedSessionIDs)
        defaults.removeObject(forKey: Keys.selectionPrimaryId)
    }
}
