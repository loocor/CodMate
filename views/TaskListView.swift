import SwiftUI
#if os(macOS)
import AppKit
#endif

/// TaskListView: Displays tasks and sessions in Tasks mode, maintaining the original session list appearance
struct TaskListView: View {
    @ObservedObject var viewModel: SessionListViewModel
    @ObservedObject var workspaceVM: ProjectWorkspaceViewModel
    @Binding var selection: Set<SessionSummary.ID>

    let onResume: (SessionSummary) -> Void
    let onReveal: (SessionSummary) -> Void
    let onDeleteRequest: (SessionSummary) -> Void
    let onExportMarkdown: (SessionSummary) -> Void
    var isRunning: ((SessionSummary) -> Bool)? = nil
    var isUpdating: ((SessionSummary) -> Bool)? = nil
    var isAwaitingFollowup: ((SessionSummary) -> Bool)? = nil
    var onPrimarySelect: ((SessionSummary) -> Void)? = nil

    @State private var showNewTaskSheet = false
    @State private var newTaskTitle = ""
    @State private var newTaskDescription = ""
    @State private var editingTask: CodMateTask? = nil
    @State private var draggedSession: SessionSummary? = nil
    @State private var taskToDelete: CodMateTask? = nil
    @State private var showDeleteConfirmation = false
    @State private var lastClickedID: SessionSummary.ID? = nil
    @State private var pendingMove: PendingSessionMove? = nil

    private var currentProjectId: String? {
        viewModel.selectedProjectIDs.first
    }

    private struct PendingSessionMove: Identifiable {
        let id = UUID()
        let session: SessionSummary
        let fromTask: CodMateTask
        let toTask: CodMateTask
    }

    var body: some View {
        VStack(spacing: 0) {
            let enrichedTasks = workspaceVM.enrichTasksWithSessions()
            let assignedSessionIds = Set(enrichedTasks.flatMap { $0.task.sessionIds })

            // Use the same sections from viewModel, but render tasks inline
            List(selection: $selection) {
                ForEach(viewModel.sections) { section in
                    Section {
                        ForEach(enrichedSessionsForSection(section,
                                                           enrichedTasks: enrichedTasks,
                                                           assignedSessionIds: assignedSessionIds),
                                id: \.id) { item in
                            switch item {
                            case .taskHeader(let taskWithSessions):
                                taskRow(taskWithSessions)
                            case .taskSession(let taskWithSessions, let session):
                                sessionRow(session, parentTask: taskWithSessions.task)
                            case .session(let session):
                                sessionRow(session)
                            }
                        }
                    } header: {
                        sectionHeader(for: section)
                    }
                }
            }
            .padding(.horizontal, -2)
            .listStyle(.inset)
        }
        .sheet(isPresented: $showNewTaskSheet) {
            if let projectId = currentProjectId {
                NewTaskSheet(
                    projectId: projectId,
                    title: $newTaskTitle,
                    description: $newTaskDescription,
                    onCreate: {
                        Task {
                            await workspaceVM.createTask(
                                title: newTaskTitle,
                                description: newTaskDescription,
                                projectId: projectId
                            )
                            newTaskTitle = ""
                            newTaskDescription = ""
                            showNewTaskSheet = false
                        }
                    },
                    onCancel: {
                        showNewTaskSheet = false
                    }
                )
            }
        }
        .sheet(item: $editingTask) { task in
            EditTaskSheet(
                task: task,
                onSave: { updatedTask in
                    Task {
                        await workspaceVM.updateTask(updatedTask)
                        editingTask = nil
                    }
                },
                onCancel: {
                    editingTask = nil
                }
            )
        }
        .task {
            if let projectId = currentProjectId {
                await workspaceVM.loadTasks(for: projectId)
            }
        }
        .confirmationDialog(
            "Delete Task",
            isPresented: $showDeleteConfirmation,
            presenting: taskToDelete
        ) { task in
            Button("Delete", role: .destructive) {
                Task {
                    if let projectId = currentProjectId {
                        await workspaceVM.deleteTask(task.id, projectId: projectId)
                    }
                    taskToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                taskToDelete = nil
            }
        } message: { task in
            Text("Delete \"\(task.effectiveTitle)\"? This will not delete the associated sessions, only remove the task container.")
        }
        .confirmationDialog(
            "Move Session to Another Task?",
            isPresented: Binding(
                get: { pendingMove != nil },
                set: { if !$0 { pendingMove = nil } }
            ),
            presenting: pendingMove
        ) { move in
            Button("Move") {
                guard let projectId = currentProjectId else {
                    pendingMove = nil
                    return
                }
                Task {
                    // Move session by updating target task; ProjectWorkspaceViewModel
                    // will enforce 0/1 membership across tasks.
                    var updatedTarget = move.toTask
                    if !updatedTarget.sessionIds.contains(move.session.id) {
                        updatedTarget.sessionIds.append(move.session.id)
                        await workspaceVM.updateTask(updatedTarget)
                    }
                    pendingMove = nil
                    // Reload tasks for current project to reflect latest state
                    await workspaceVM.loadTasks(for: projectId)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingMove = nil
            }
        } message: { move in
            Text(
                "Move \"\(move.session.effectiveTitle)\" from \"\(move.fromTask.effectiveTitle)\" to \"\(move.toTask.effectiveTitle)\"?"
            )
        }
    }

    // MARK: - Data Enrichment

    enum SessionOrTask: Identifiable {
        case taskHeader(TaskWithSessions)
        case taskSession(TaskWithSessions, SessionSummary)
        case session(SessionSummary)

        var id: String {
            switch self {
            case .taskHeader(let t): return "task-header-\(t.id.uuidString)"
            case .taskSession(let t, let s): return "task-session-\(t.id.uuidString)-\(s.id)"
            case .session(let s): return "session-\(s.id)"
            }
        }
    }

    private func enrichedSessionsForSection(
        _ section: SessionDaySection,
        enrichedTasks: [TaskWithSessions],
        assignedSessionIds: Set<String>
    ) -> [SessionOrTask] {
        guard !enrichedTasks.isEmpty else {
            return section.sessions.map { .session($0) }
        }

        let sectionSessionIDs = Set(section.sessions.map(\.id))

        // Build per-task sessions limited to this section
        var taskSectionSessions: [UUID: [SessionSummary]] = [:]
        var tasksInSection: [TaskWithSessions] = []
        for task in enrichedTasks {
            let inSection = task.sessions.filter { sectionSessionIDs.contains($0.id) }
            if !inSection.isEmpty {
                tasksInSection.append(task)
                taskSectionSessions[task.task.id] = inSection
            }
        }
        guard !tasksInSection.isEmpty else {
            // No tasks in this section; fall back to standalone sessions only.
            return section.sessions.map { .session($0) }
        }

        // Sort tasks according to current sort order, using aggregated metrics
        let sortedTasks: [TaskWithSessions] = {
            switch viewModel.sortOrder {
            case .mostRecent:
                // Use the latest timestamp among this section's sessions, respecting date dimension
                let dim = viewModel.dateDimension
                return tasksInSection.sorted { lhs, rhs in
                    let ls = taskSectionSessions[lhs.task.id] ?? []
                    let rs = taskSectionSessions[rhs.task.id] ?? []
                    func key(_ s: SessionSummary) -> Date {
                        switch dim {
                        case .created: return s.startedAt
                        case .updated: return s.lastUpdatedAt ?? s.startedAt
                        }
                    }
                    let lDate = ls.map(key).max() ?? .distantPast
                    let rDate = rs.map(key).max() ?? .distantPast
                    return lDate > rDate
                }

            case .longestDuration:
                // Aggregate total duration for this section's sessions
                return tasksInSection.sorted { lhs, rhs in
                    let lDur = (taskSectionSessions[lhs.task.id] ?? []).reduce(0) { $0 + $1.duration }
                    let rDur = (taskSectionSessions[rhs.task.id] ?? []).reduce(0) { $0 + $1.duration }
                    if lDur != rDur { return lDur > rDur }
                    // Tie-breaker: most recent activity
                    let lDate = (taskSectionSessions[lhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max() ?? .distantPast
                    let rDate = (taskSectionSessions[rhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max() ?? .distantPast
                    return lDate > rDate
                }

            case .mostActivity:
                // Aggregate total event count
                return tasksInSection.sorted { lhs, rhs in
                    let lEvents = (taskSectionSessions[lhs.task.id] ?? []).reduce(0) { $0 + $1.eventCount }
                    let rEvents = (taskSectionSessions[rhs.task.id] ?? []).reduce(0) { $0 + $1.eventCount }
                    if lEvents != rEvents { return lEvents > rEvents }
                    let lDate = (taskSectionSessions[lhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max() ?? .distantPast
                    let rDate = (taskSectionSessions[rhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max() ?? .distantPast
                    if lDate != rDate { return lDate > rDate }
                    return lhs.task.effectiveTitle.localizedCaseInsensitiveCompare(rhs.task.effectiveTitle) == .orderedAscending
                }

            case .alphabetical:
                return tasksInSection.sorted { lhs, rhs in
                    let cmp = lhs.task.effectiveTitle.localizedStandardCompare(rhs.task.effectiveTitle)
                    if cmp == .orderedSame {
                        let lDate = (taskSectionSessions[lhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max() ?? .distantPast
                        let rDate = (taskSectionSessions[rhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max() ?? .distantPast
                        if lDate != rDate { return lDate > rDate }
                        return lhs.task.id.uuidString < rhs.task.id.uuidString
                    }
                    return cmp == .orderedAscending
                }

            case .largestSize:
                // Approximate size by total file size across this section's sessions
                return tasksInSection.sorted { lhs, rhs in
                    func totalSize(for task: TaskWithSessions) -> UInt64 {
                        (taskSectionSessions[task.task.id] ?? []).reduce(0) { acc, s in
                            acc + (s.fileSizeBytes ?? 0)
                        }
                    }
                    let lSize = totalSize(for: lhs)
                    let rSize = totalSize(for: rhs)
                    if lSize != rSize { return lSize > rSize }
                    let lDate = (taskSectionSessions[lhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max() ?? .distantPast
                    let rDate = (taskSectionSessions[rhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max() ?? .distantPast
                    return lDate > rDate
                }
            }
        }()

        var result: [SessionOrTask] = []

        // For each task (in sorted order), add a header row and then its sessions that belong to this section
        for task in sortedTasks {
            result.append(.taskHeader(task))
            if let sectionSessions = taskSectionSessions[task.task.id] {
                for session in sectionSessions {
                    result.append(.taskSession(task, session))
                }
            }
        }

        // Add standalone sessions (not assigned to any task), preserving existing section order
        for session in section.sessions where !assignedSessionIds.contains(session.id) {
            result.append(.session(session))
        }

        return result
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(for section: SessionDaySection) -> some View {
        HStack {
            Text(section.title)
            Spacer()
            Label(readableFormattedDuration(section.totalDuration), systemImage: "clock")
            Label("\(section.totalEvents)", systemImage: "chart.bar")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: - Task Row

    @ViewBuilder
    private func taskRow(_ taskWithSessions: TaskWithSessions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Task header - using same visual style as SessionListRowView
            HStack(alignment: .top, spacing: 12) {
                // Left icon — purely visual
                let container = RoundedRectangle(cornerRadius: 9, style: .continuous)
                ZStack {
                    container
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.08), radius: 1.5, x: 0, y: 1)
                    container
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)

                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 32, height: 32)
                .help("Task")

                // Content area
                VStack(alignment: .leading, spacing: 4) {
                    // Title with status icon
                    HStack(spacing: 6) {
                        Text(taskWithSessions.task.effectiveTitle)
                            .font(.headline)
                            .lineLimit(1)

                        Image(systemName: taskWithSessions.task.status.icon)
                            .font(.caption)
                            .foregroundColor(statusColor(taskWithSessions.task.status))
                    }

                    // Metadata row
                    HStack(spacing: 8) {
                        Text(taskWithSessions.task.updatedAt.formatted(date: .numeric, time: .shortened))
                            .layoutPriority(1)
                        Text(formatDuration(taskWithSessions.totalDuration))
                            .layoutPriority(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    // Description if available
                    if let description = taskWithSessions.task.effectiveDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    // Metrics
                    HStack(spacing: 8) {
                        metric(icon: "doc.text", value: taskWithSessions.sessions.count)
                        metric(icon: "clock", value: Int(taskWithSessions.totalDuration / 60))
                        if taskWithSessions.totalTokens > 0 {
                            metric(icon: "circle.grid.cross", value: taskWithSessions.totalTokens)
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.vertical, 8)
            .overlay(alignment: .topTrailing) {
                // Top-right action button: only one glyph (…, no extra arrow)
                Button {
                    editingTask = taskWithSessions.task
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 8)
                .padding(.top, 8)
            }
            .onDrop(of: [.text], delegate: TaskDropDelegate(
                task: taskWithSessions.task,
                draggedSession: $draggedSession,
                workspaceVM: workspaceVM,
                onRequestMove: handleMoveRequest
            ))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editingTask = taskWithSessions.task
            }
            .contextMenu {
                Button("Edit Task") {
                    editingTask = taskWithSessions.task
                }
                Divider()
                Button("Delete Task", role: .destructive) {
                    taskToDelete = taskWithSessions.task
                    showDeleteConfirmation = true
                }
            }

        }
    }

    // MARK: - Session Row

    @ViewBuilder
    private func sessionRow(_ session: SessionSummary, parentTask: CodMateTask? = nil) -> some View {
        EquatableSessionListRow(
            summary: session,
            isRunning: isRunning?(session) ?? false,
            isSelected: selection.contains(session.id),
            isUpdating: isUpdating?(session) ?? false,
            awaitingFollowup: isAwaitingFollowup?(session) ?? false,
            inProject: viewModel.projectIdForSession(session.id) != nil,
            projectTip: projectTip(for: session),
            inTaskContainer: parentTask != nil
        )
        .tag(session.id)
        .contentShape(Rectangle())
        .padding(.leading, parentTask != nil ? 44 : 0)
        .onTapGesture(count: 2) {
            selection = [session.id]
            onPrimarySelect?(session)
            Task {
                await viewModel.beginEditing(session: session)
            }
        }
        .onTapGesture {
            handleClick(on: session)
        }
        .contextMenu {
            Button("Resume") { onResume(session) }
            Button("Reveal in Finder") { onReveal(session) }
            Button("Export as Markdown") { onExportMarkdown(session) }
            if parentTask != nil {
                Divider()
                Button("Remove from Task") {
                    Task {
                        guard let task = parentTask else { return }
                        var updatedTask = task
                        updatedTask.sessionIds.removeAll { $0 == session.id }
                        await viewModel.workspaceVM?.updateTask(updatedTask)
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { onDeleteRequest(session) }
        }
        .onDrag {
            self.draggedSession = session
            return NSItemProvider(object: session.id as NSString)
        }
        .onDrop(of: [.text], delegate: SessionDropDelegate(
            session: session,
            draggedSession: $draggedSession,
            workspaceVM: workspaceVM,
            currentProjectId: currentProjectId
        ))
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Helpers

    @ViewBuilder
    private func metric(icon: String, value: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
            Text("\(value)")
        }
    }

    private func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .pending: return .gray
        case .inProgress: return .blue
        case .completed: return .green
        case .archived: return .orange
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "—"
    }

    private func readableFormattedDuration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        if interval >= 3600 {
            formatter.allowedUnits = [.hour, .minute]
        } else if interval >= 60 {
            formatter.allowedUnits = [.minute, .second]
        } else {
            formatter.allowedUnits = [.second]
        }
        return formatter.string(from: interval) ?? "—"
    }

    private func projectTip(for session: SessionSummary) -> String? {
        guard let pid = viewModel.projectIdForSession(session.id),
              let p = viewModel.projects.first(where: { $0.id == pid }) else { return nil }
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? p.id : name
        let raw = (p.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return display }
        let snippet = raw.count > 20 ? String(raw.prefix(20)) + "…" : raw
        return display + "\n" + snippet
    }

    private func handleClick(on session: SessionSummary) {
        #if os(macOS)
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        let isToggle = mods.contains(.command) || mods.contains(.control)
        let isRange = mods.contains(.shift)
        #else
        let isToggle = false
        let isRange = false
        #endif
        let id = session.id
        if isRange, let anchor = lastClickedID {
            let flat = viewModel.sections.flatMap { $0.sessions.map(\.id) }
            if let a = flat.firstIndex(of: anchor), let b = flat.firstIndex(of: id) {
                let lo = min(a, b)
                let hi = max(a, b)
                let rangeIDs = Set(flat[lo...hi])
                selection = rangeIDs
            } else {
                selection = [id]
            }
            onPrimarySelect?(session)
        } else if isToggle {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            lastClickedID = id
            onPrimarySelect?(session)
        } else {
            selection = [id]
            lastClickedID = id
            onPrimarySelect?(session)
        }
    }

    private func handleMoveRequest(session: SessionSummary, fromTask: CodMateTask, toTask: CodMateTask) {
        pendingMove = PendingSessionMove(session: session, fromTask: fromTask, toTask: toTask)
    }
}

// MARK: - New Task Sheet
struct NewTaskSheet: View {
    let projectId: String
    @Binding var title: String
    @Binding var description: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Task")
                .font(.title2)
                .fontWeight(.bold)

            TextField("Task Title", text: $title)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Description (Optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $description)
                    .frame(height: 100)
                    .border(Color.gray.opacity(0.3), width: 1)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Edit Task Sheet
struct EditTaskSheet: View {
    let task: CodMateTask
    @State private var title: String
    @State private var description: String
    @State private var status: TaskStatus
    let onSave: (CodMateTask) -> Void
    let onCancel: () -> Void

    init(task: CodMateTask, onSave: @escaping (CodMateTask) -> Void, onCancel: @escaping () -> Void) {
        self.task = task
        self._title = State(initialValue: task.title)
        self._description = State(initialValue: task.description ?? "")
        self._status = State(initialValue: task.status)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Task")
                .font(.title2)
                .fontWeight(.bold)

            TextField("Task Title", text: $title)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $description)
                    .frame(height: 100)
                    .border(Color.gray.opacity(0.3), width: 1)
            }

            Picker("Status", selection: $status) {
                ForEach(TaskStatus.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    var updated = task
                    updated.title = title
                    updated.description = description.isEmpty ? nil : description
                    updated.status = status
                    onSave(updated)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Drop Delegates

/// Drop delegate for dropping a session onto another session (creates a new task)
struct SessionDropDelegate: DropDelegate {
    let session: SessionSummary
    @Binding var draggedSession: SessionSummary?
    let workspaceVM: ProjectWorkspaceViewModel
    let currentProjectId: String?

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedSession = draggedSession,
              draggedSession.id != session.id,
              let projectId = currentProjectId else {
            return false
        }

        // Only allow creating a new task when both sessions are currently unassigned
        let draggedTaskId = workspaceVM.tasks.first(where: { $0.sessionIds.contains(draggedSession.id) })?.id
        let targetTaskId = workspaceVM.tasks.first(where: { $0.sessionIds.contains(session.id) })?.id
        guard draggedTaskId == nil, targetTaskId == nil else {
            self.draggedSession = nil
            return false
        }

        // Create a new task with both unassigned sessions
        Task {
            let taskTitle = "Task: \(draggedSession.displayName) + \(session.displayName)"
            await workspaceVM.createTask(
                title: taskTitle,
                description: nil,
                projectId: projectId
            )

            // Find the newly created task (it will be the first one)
            if let newTask = workspaceVM.tasks.first {
                // Add both sessions to the task
                var updatedTask = newTask
                updatedTask.sessionIds = [draggedSession.id, session.id]
                await workspaceVM.updateTask(updatedTask)
            }
        }

        self.draggedSession = nil
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = draggedSession,
              dragged.id != session.id else { return false }

        let draggedTaskId = workspaceVM.tasks.first(where: { $0.sessionIds.contains(dragged.id) })?.id
        let targetTaskId = workspaceVM.tasks.first(where: { $0.sessionIds.contains(session.id) })?.id

        // Only allow drop when both sessions are not yet assigned to any task
        return draggedTaskId == nil && targetTaskId == nil
    }
}

/// Drop delegate for dropping a session onto a task (adds session to task)
struct TaskDropDelegate: DropDelegate {
    let task: CodMateTask
    @Binding var draggedSession: SessionSummary?
    let workspaceVM: ProjectWorkspaceViewModel
    let onRequestMove: (SessionSummary, CodMateTask, CodMateTask) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedSession = draggedSession else {
            return false
        }

        let draggedTask = workspaceVM.tasks.first(where: { $0.sessionIds.contains(draggedSession.id) })

        if let fromTask = draggedTask {
            // If already in this task, do nothing
            guard fromTask.id != task.id else {
                self.draggedSession = nil
                return false
            }
            // Request a confirmed move from fromTask → task
            DispatchQueue.main.async {
                onRequestMove(draggedSession, fromTask, task)
            }
            self.draggedSession = nil
            return true
        } else {
            // Add unassigned session to this task
            Task {
                var updatedTask = task
                if !updatedTask.sessionIds.contains(draggedSession.id) {
                    updatedTask.sessionIds.append(draggedSession.id)
                    await workspaceVM.updateTask(updatedTask)
                }
            }

            self.draggedSession = nil
            return true
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedSession = draggedSession else { return false }
        let draggedTask = workspaceVM.tasks.first(where: { $0.sessionIds.contains(draggedSession.id) })
        // Allow drop if session is unassigned or belongs to a different task
        return draggedTask == nil || draggedTask?.id != task.id
    }
}
