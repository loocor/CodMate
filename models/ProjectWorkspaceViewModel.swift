import Foundation
import SwiftUI

@MainActor
class ProjectWorkspaceViewModel: ObservableObject {
    @Published var selectedMode: ProjectWorkspaceMode = .tasks
    @Published var tasks: [CodMateTask] = []

    private let tasksStore: TasksStore
    private let sessionListViewModel: SessionListViewModel

    init(tasksStore: TasksStore = TasksStore(), sessionListViewModel: SessionListViewModel) {
        self.tasksStore = tasksStore
        self.sessionListViewModel = sessionListViewModel
    }

    // MARK: - Task Management

    func loadTasks(for projectId: String) async {
        let loaded = await tasksStore.listTasks(for: projectId)
        await MainActor.run {
            self.tasks = loaded
        }
    }

    func createTask(title: String, description: String?, projectId: String) async {
        let task = CodMateTask(
            title: title,
            description: description,
            projectId: projectId
        )
        await tasksStore.upsertTask(task)
        await loadTasks(for: projectId)
    }

    func updateTask(_ task: CodMateTask) async {
        // Enforce 0/1 membership: a session can belong to at most one task
        var normalized = task
        // Deduplicate session IDs within this task
        let uniqueIds = Array(Set(normalized.sessionIds))
        normalized.sessionIds = uniqueIds

        let projectId = normalized.projectId
        let idsSet = Set(uniqueIds)

        // Remove these sessions from all other tasks in the same project
        for var other in tasks where other.id != normalized.id && other.projectId == projectId {
            let filtered = other.sessionIds.filter { !idsSet.contains($0) }
            if filtered != other.sessionIds {
                other.sessionIds = filtered
                await tasksStore.upsertTask(other)
            }
        }

        await tasksStore.upsertTask(normalized)
        await loadTasks(for: projectId)
    }

    func deleteTask(_ taskId: UUID, projectId: String) async {
        await tasksStore.deleteTask(id: taskId)
        await loadTasks(for: projectId)
    }

    func assignSessionsToTask(_ sessionIds: [String], taskId: UUID?) async {
        await tasksStore.assignSessions(sessionIds, to: taskId)
        // Reload tasks to reflect the changes
        if let task = tasks.first(where: { $0.id == taskId }) {
            await loadTasks(for: task.projectId)
        }
    }

    func addContextToTask(_ item: ContextItem, taskId: UUID) async {
        await tasksStore.addContextItem(item, to: taskId)
        if let task = tasks.first(where: { $0.id == taskId }) {
            await loadTasks(for: task.projectId)
        }
    }

    func removeContextFromTask(_ contextId: UUID, taskId: UUID) async {
        await tasksStore.removeContextItem(id: contextId, from: taskId)
        if let task = tasks.first(where: { $0.id == taskId }) {
            await loadTasks(for: task.projectId)
        }
    }

    // MARK: - Task With Sessions

    func enrichTasksWithSessions() -> [TaskWithSessions] {
        let allSessions = sessionListViewModel.allSessions
        return tasks.map { task in
            let sessions = allSessions.filter { task.sessionIds.contains($0.id) }
            // Keep session ordering consistent with the main list
            // by reusing the current sort order.
            let sorted = sessionListViewModel.sortOrder.sort(sessions)
            return TaskWithSessions(task: task, sessions: sorted)
        }
    }

    func getSessionsForTask(_ taskId: UUID) -> [SessionSummary] {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return [] }
        let allSessions = sessionListViewModel.allSessions
        return allSessions.filter { task.sessionIds.contains($0.id) }
    }

    // MARK: - Overview Statistics

    func getProjectStatistics(for projectId: String) -> ProjectStatistics {
        let projectSessions = sessionListViewModel.allSessions.filter { session in
            sessionListViewModel.projectIdForSession(session.id) == projectId
        }

        let totalDuration = projectSessions.reduce(0) { $0 + $1.duration }
        let totalTokens = projectSessions.reduce(0) { $0 + $1.turnContextCount }
        let totalEvents = projectSessions.reduce(0) { $0 + $1.eventCount }

        let projectTasks = tasks.filter { $0.projectId == projectId }
        let completedTasks = projectTasks.filter { $0.status == .completed }.count
        let inProgressTasks = projectTasks.filter { $0.status == .inProgress }.count
        let pendingTasks = projectTasks.filter { $0.status == .pending }.count

        return ProjectStatistics(
            totalSessions: projectSessions.count,
            totalTasks: projectTasks.count,
            completedTasks: completedTasks,
            inProgressTasks: inProgressTasks,
            pendingTasks: pendingTasks,
            totalDuration: totalDuration,
            totalTokens: totalTokens,
            totalEvents: totalEvents
        )
    }
}

struct ProjectStatistics {
    let totalSessions: Int
    let totalTasks: Int
    let completedTasks: Int
    let inProgressTasks: Int
    let pendingTasks: Int
    let totalDuration: TimeInterval
    let totalTokens: Int
    let totalEvents: Int

    var taskCompletionRate: Double {
        guard totalTasks > 0 else { return 0 }
        return Double(completedTasks) / Double(totalTasks)
    }

    var averageSessionDuration: TimeInterval {
        guard totalSessions > 0 else { return 0 }
        return totalDuration / Double(totalSessions)
    }

    var averageTokensPerSession: Double {
        guard totalSessions > 0 else { return 0 }
        return Double(totalTokens) / Double(totalSessions)
    }
}
