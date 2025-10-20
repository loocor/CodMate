import SwiftUI

struct SessionListColumnView: View {
    let sections: [SessionDaySection]
    @Binding var selection: Set<SessionSummary.ID>
    @Binding var sortOrder: SessionSortOrder
    let isLoading: Bool
    let isEnriching: Bool
    let enrichmentProgress: Int
    let enrichmentTotal: Int
    let onResume: (SessionSummary) -> Void
    let onReveal: (SessionSummary) -> Void
    let onDeleteRequest: (SessionSummary) -> Void
    let onExportMarkdown: (SessionSummary) -> Void
    // running state probe
    var isRunning: ((SessionSummary) -> Bool)? = nil
    // live updating probe (file activity)
    var isUpdating: ((SessionSummary) -> Bool)? = nil
    // awaiting follow-up probe
    var isAwaitingFollowup: ((SessionSummary) -> Bool)? = nil
    // open embedded terminal (Alpha)
    var onOpenEmbedded: ((SessionSummary) -> Void)? = nil
    @EnvironmentObject private var viewModel: SessionListViewModel
    @State private var showNewProjectSheet = false
    @State private var newProjectPrefill: ProjectEditorSheet.Prefill? = nil
    @State private var newProjectAssignIDs: [String] = []
    @State private var lastClickedID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 0)
                .padding(.bottom, 8)

            if isLoading && sections.isEmpty {
                ProgressView("Scanning…")
                    .padding(.vertical)
            }

            List(selection: $selection) {
                if sections.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Sessions", systemImage: "tray",
                        description: Text(
                            "Adjust directories or launch Codex CLI to generate new session logs."))
                } else {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.sessions, id: \.id) { session in
                                SessionListRowView(
                                    summary: session,
                                    isRunning: isRunning?(session) ?? false,
                                    isSelected: selectionContains(session.id),
                                    isUpdating: isUpdating?(session) ?? false,
                                    awaitingFollowup: isAwaitingFollowup?(session) ?? false
                                )
                                .tag(session.id)
                                .contentShape(Rectangle())
                                .onTapGesture { handleClick(on: session) }
                                .onDrag {
                                    let ids: [String]
                                    if selectionContains(session.id) && selection.count > 1 {
                                        ids = Array(selection)
                                    } else {
                                        ids = [session.id]
                                    }
                                    return NSItemProvider(object: ids.joined(separator: "\n") as NSString)
                                }
                                .listRowInsets(EdgeInsets())
                                .contextMenu {
                                    Button {
                                        onResume(session)
                                    } label: {
                                        Label("Resume", systemImage: "play.fill")
                                    }
                                    if let openEmbedded = onOpenEmbedded {
                                        Button {
                                            openEmbedded(session)
                                        } label: {
                                            Label(
                                                "Open Embedded Terminal (Alpha)",
                                                systemImage: "rectangle.badge.plus")
                                        }
                                    }
                                    Divider()
                                    Button {
                                        Task { await viewModel.beginEditing(session: session) }
                                    } label: {
                                        Label("Edit Title & Comment", systemImage: "pencil")
                                    }
                                    // Assign to Project submenu
                                    if !viewModel.projects.isEmpty {
                                        Menu {
                                            Button("New Project…") {
                                                newProjectPrefill = prefillForProject(from: session)
                                                newProjectAssignIDs = [session.id]
                                                showNewProjectSheet = true
                                            }
                                            Divider()
                                            ForEach(viewModel.projects) { p in
                                                Button(p.name.isEmpty ? p.id : p.name) {
                                                    Task { await viewModel.assignSessions(to: p.id, ids: [session.id]) }
                                                }
                                            }
                                        } label: {
                                            Label("Assign to Project…", systemImage: "folder.badge.plus")
                                        }
                                    }
                                    Button {
                                        onReveal(session)
                                    } label: {
                                        Label("Reveal in Finder", systemImage: "folder")
                                    }
                                    Button {
                                        onExportMarkdown(session)
                                    } label: {
                                        Label(
                                            "Export Markdown",
                                            systemImage: "square.and.arrow.down")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        onDeleteRequest(session)
                                    } label: {
                                        Label("Delete Session", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                Spacer()
                                Label(
                                    section.totalDuration.readableFormattedDuration,
                                    systemImage: "clock")
                                Label("\(section.totalEvents)", systemImage: "chart.bar")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
        .sheet(isPresented: $showNewProjectSheet) {
            ProjectEditorSheet(
                isPresented: $showNewProjectSheet,
                mode: .new,
                prefill: newProjectPrefill,
                autoAssignSessionIDs: newProjectAssignIDs
            )
            .environmentObject(viewModel)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("", selection: $sortOrder) {
                ForEach(SessionSortOrder.allCases) { order in
                    Text(order.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .tag(order)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

extension SessionListColumnView {
    func selectionContains(_ id: SessionSummary.ID) -> Bool {
        selection.contains(id)
    }

    private func prefillForProject(from session: SessionSummary) -> ProjectEditorSheet.Prefill {
        let dir = FileManager.default.fileExists(atPath: session.cwd)
        ? session.cwd
        : session.fileURL.deletingLastPathComponent().path
        var name = session.userTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { name = URL(fileURLWithPath: dir, isDirectory: true).lastPathComponent }
        // overview: prefer userComment; fallback instruction snippet
        let overview = (session.userComment?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (session.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { s in
                if s.isEmpty { return nil }
                // limit to ~220 chars to keep it short
                return s.count <= 220 ? s : String(s.prefix(220)) + "…"
            }
        let instructions = session.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProjectEditorSheet.Prefill(
            name: name,
            directory: dir,
            trustLevel: nil,
            overview: overview,
            instructions: instructions,
            profileId: nil
        )
    }

    private func handleClick(on session: SessionSummary) {
        // Determine current modifiers (command/control/shift)
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        let isToggle = mods.contains(.command) || mods.contains(.control)
        let isRange = mods.contains(.shift)
        let id = session.id
        if isRange, let anchor = lastClickedID {
            let flat = sections.flatMap { $0.sessions.map(\.id) }
            if let a = flat.firstIndex(of: anchor), let b = flat.firstIndex(of: id) {
                let lo = min(a, b), hi = max(a, b)
                let rangeIDs = Set(flat[lo...hi])
                selection = rangeIDs
            } else {
                selection = [id]
            }
        } else if isToggle {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            lastClickedID = id
        } else {
            selection = [id]
            lastClickedID = id
        }
    }
}

extension TimeInterval {
    fileprivate var readableFormattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = durationUnits
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: self) ?? "—"
    }

    private var durationUnits: NSCalendar.Unit {
        if self >= 3600 {
            return [.hour, .minute]
        } else if self >= 60 {
            return [.minute, .second]
        }
        return [.second]
    }
}

#Preview {
    // Mock SessionDaySection data
    let mockSections = [
        SessionDaySection(
            id: Date().addingTimeInterval(-86400),  // Yesterday
            title: "Yesterday",
            totalDuration: 7200,  // 2 hours
            totalEvents: 15,
            sessions: [
                SessionSummary(
                    id: "session-1",
                    fileURL: URL(
                        fileURLWithPath: "/Users/developer/.codex/sessions/session-1.json"),
                    fileSizeBytes: 12340,
                    startedAt: Date().addingTimeInterval(-7200),
                    endedAt: Date().addingTimeInterval(-3600),
                    cliVersion: "1.2.3",
                    cwd: "/Users/developer/projects/codmate",
                    originator: "developer",
                    instructions: "Optimize SwiftUI list performance",
                    model: "gpt-4o-mini",
                    approvalPolicy: "auto",
                    userMessageCount: 3,
                    assistantMessageCount: 2,
                    toolInvocationCount: 1,
                    responseCounts: [:],
                    turnContextCount: 5,
                    eventCount: 6,
                    lineCount: 89,
                    lastUpdatedAt: Date().addingTimeInterval(-3600)
                ),
                SessionSummary(
                    id: "session-2",
                    fileURL: URL(
                        fileURLWithPath: "/Users/developer/.codex/sessions/session-2.json"),
                    fileSizeBytes: 8900,
                    startedAt: Date().addingTimeInterval(-10800),
                    endedAt: Date().addingTimeInterval(-9000),
                    cliVersion: "1.2.3",
                    cwd: "/Users/developer/projects/test",
                    originator: "developer",
                    instructions: "Create a to-do app",
                    model: "gpt-4o",
                    approvalPolicy: "manual",
                    userMessageCount: 4,
                    assistantMessageCount: 3,
                    toolInvocationCount: 2,
                    responseCounts: ["reasoning": 1],
                    turnContextCount: 7,
                    eventCount: 9,
                    lineCount: 120,
                    lastUpdatedAt: Date().addingTimeInterval(-9000)
                ),
            ]
        ),
        SessionDaySection(
            id: Date().addingTimeInterval(-172800),  // Day before yesterday
            title: "Dec 15, 2024",
            totalDuration: 5400,  // 1.5 hours
            totalEvents: 12,
            sessions: [
                SessionSummary(
                    id: "session-3",
                    fileURL: URL(
                        fileURLWithPath: "/Users/developer/.codex/sessions/session-3.json"),
                    fileSizeBytes: 15600,
                    startedAt: Date().addingTimeInterval(-172800),
                    endedAt: Date().addingTimeInterval(-158400),
                    cliVersion: "1.2.2",
                    cwd: "/Users/developer/documents",
                    originator: "developer",
                    instructions: "Write technical documentation",
                    model: "gpt-4o-mini",
                    approvalPolicy: "auto",
                    userMessageCount: 6,
                    assistantMessageCount: 5,
                    toolInvocationCount: 3,
                    responseCounts: ["reasoning": 2],
                    turnContextCount: 11,
                    eventCount: 14,
                    lineCount: 200,
                    lastUpdatedAt: Date().addingTimeInterval(-158400)
                )
            ]
        ),
    ]

    return SessionListColumnView(
        sections: mockSections,
        selection: .constant(Set<String>()),
        sortOrder: .constant(.mostRecent),
        isLoading: false,
        isEnriching: false,
        enrichmentProgress: 0,
        enrichmentTotal: 0,
        onResume: { session in print("Resume: \(session.displayName)") },
        onReveal: { session in print("Reveal: \(session.displayName)") },
        onDeleteRequest: { session in print("Delete: \(session.displayName)") },
        onExportMarkdown: { session in print("Export: \(session.displayName)") }
    )
    .frame(width: 500, height: 600)
}

#Preview("Loading State") {
    SessionListColumnView(
        sections: [],
        selection: .constant(Set<String>()),
        sortOrder: .constant(.mostRecent),
        isLoading: true,
        isEnriching: false,
        enrichmentProgress: 0,
        enrichmentTotal: 0,
        onResume: { _ in },
        onReveal: { _ in },
        onDeleteRequest: { _ in },
        onExportMarkdown: { _ in }
    )
    .frame(width: 500, height: 600)
}

#Preview("Empty State") {
    SessionListColumnView(
        sections: [],
        selection: .constant(Set<String>()),
        sortOrder: .constant(.mostRecent),
        isLoading: false,
        isEnriching: false,
        enrichmentProgress: 0,
        enrichmentTotal: 0,
        onResume: { _ in },
        onReveal: { _ in },
        onDeleteRequest: { _ in },
        onExportMarkdown: { _ in }
    )
    .frame(width: 500, height: 600)
}
