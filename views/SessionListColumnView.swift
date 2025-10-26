import AppKit
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
    // open embedded terminal
    var onOpenEmbedded: ((SessionSummary) -> Void)? = nil
    // notify which item is the user's primary (last clicked) for detail focus
    var onPrimarySelect: ((SessionSummary) -> Void)? = nil
    @EnvironmentObject private var viewModel: SessionListViewModel
    @State private var showNewProjectSheet = false
    @State private var newProjectPrefill: ProjectEditorSheet.Prefill? = nil
    @State private var newProjectAssignIDs: [String] = []
    @State private var lastClickedID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 8)
                .padding(.top, 0)
                .padding(.bottom, 8)

            if isLoading && sections.isEmpty {
                ProgressView("Scanning…")
                    .padding(.vertical)
            }

            if sections.isEmpty && !isLoading {
                // Center the empty state within the middle column area.
                VStack {
                    Spacer(minLength: 12)
                    ContentUnavailableView(
                        "No Sessions", systemImage: "tray",
                        description: Text(
                            "Adjust directories or launch Codex CLI to generate new session logs."))
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.sessions, id: \.id) { session in
                                SessionListRowView(
                                    summary: session,
                                    isRunning: isRunning?(session) ?? false,
                                    isSelected: selectionContains(session.id),
                                    isUpdating: isUpdating?(session) ?? false,
                                    awaitingFollowup: isAwaitingFollowup?(session) ?? false,
                                    inProject: viewModel.projectIdForSession(session.id) != nil,
                                    projectTip: projectTip(for: session)
                                )
                                .tag(session.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    selection = [session.id]
                                    onPrimarySelect?(session)
                                    Task { await viewModel.beginEditing(session: session) }
                                }
                                .onTapGesture { handleClick(on: session) }
                                .onDrag {
                                    let ids: [String]
                                    if selectionContains(session.id) && selection.count > 1 {
                                        ids = Array(selection)
                                    } else {
                                        ids = [session.id]
                                    }
                                    return NSItemProvider(
                                        object: ids.joined(separator: "\n") as NSString)
                                }
                                .listRowInsets(EdgeInsets())
                                .contextMenu {
                                    if session.source == .codex {
                                        Button { onResume(session) } label: {
                                            Label("Resume", systemImage: "play.fill")
                                        }
                                        if let openEmbedded = onOpenEmbedded {
                                            Button { openEmbedded(session) } label: {
                                                Label("Open Embedded Terminal", systemImage: "rectangle.badge.plus")
                                            }
                                        }
                                    }
                                    Divider()
                                    Button { Task { await viewModel.beginEditing(session: session) } } label: {
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
                                    Button { onReveal(session) } label: {
                                        Label("Reveal in Finder", systemImage: "folder")
                                    }
                                    Button { onExportMarkdown(session) } label: {
                                        Label("Export Markdown", systemImage: "square.and.arrow.down")
                                    }
                                    Divider()
                                    Button(role: .destructive) { onDeleteRequest(session) } label: {
                                        Label("Delete Session", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                Spacer()
                                Label(section.totalDuration.readableFormattedDuration, systemImage: "clock")
                                Label("\(section.totalEvents)", systemImage: "chart.bar")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
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
        VStack(alignment: .leading, spacing: 8) {
            // Full-width quick search (title/comment) using native SearchField for unified chrome
            SearchField(
                "Search title or comment",
                text: $viewModel.quickSearchText,
                onSubmit: { text in viewModel.immediateApplyQuickSearch(text) }
            )
            .frame(maxWidth: .infinity)

            EqualWidthSegmentedControl(
                items: Array(SessionSortOrder.allCases),
                selection: $sortOrder,
                title: { $0.title }
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

extension SessionListColumnView {
    func selectionContains(_ id: SessionSummary.ID) -> Bool {
        selection.contains(id)
    }

    private func projectTip(for session: SessionSummary) -> String? {
        guard let pid = viewModel.projectIdForSession(session.id),
            let p = viewModel.projects.first(where: { $0.id == pid })
        else { return nil }
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? p.id : name
        let raw = (p.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return display }
        let snippet = raw.count > 20 ? String(raw.prefix(20)) + "…" : raw
        return display + "\n" + snippet
    }

    private func prefillForProject(from session: SessionSummary) -> ProjectEditorSheet.Prefill {
        let dir =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd
            : session.fileURL.deletingLastPathComponent().path
        var name = session.userTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { name = URL(fileURLWithPath: dir, isDirectory: true).lastPathComponent }
        // overview: prefer userComment; fallback instruction snippet
        let overview =
            (session.userComment?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            }
            ?? (session.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                s in
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
}

// Native NSSearchField wrapper to get unified macOS search field chrome
private struct SearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: ((String) -> Void)? = nil

    init(_ placeholder: String, text: Binding<String>, onSubmit: ((String) -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        // Avoid premature submit during IME composition; we handle Return/Escape in delegate instead
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        // Do not steal initial focus; if the system puts focus here, drop it back to window
        DispatchQueue.main.async {
            if let win = field.window,
                win.firstResponder === field || win.firstResponder === field.currentEditor()
            {
                win.makeFirstResponder(nil)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        // Avoid programmatic writes while user is editing (prevents breaking IME composition)
        if let editor = nsView.currentEditor(), nsView.window?.firstResponder === editor { return }
        if nsView.stringValue != text { nsView.stringValue = text }
        if nsView.placeholderString != placeholder { nsView.placeholderString = placeholder }
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        @MainActor
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            // Skip updates while IME is composing (marked text present)
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            parent.text = field.stringValue
        }

        @MainActor
        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            let value = sender.stringValue
            parent.text = value
            parent.onSubmit?(value)
        }

        // Intercept Return/Escape; respect IME composition
        @MainActor
        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            // If composing with IME, let the editor handle the key (do not submit)
            if textView.hasMarkedText() { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let value = textView.string
                parent.text = value
                parent.onSubmit?(value)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.text = ""
                parent.onSubmit?("")
                return true
            }
            return false
        }
    }
}

// MARK: - Equal-width segmented control backed by NSSegmentedControl
private struct EqualWidthSegmentedControl<Item: Identifiable & Hashable>: NSViewRepresentable {
    let items: [Item]
    @Binding var selection: Item
    var title: (Item) -> String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let control = NSSegmentedControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        rebuildSegments(control)
        if #available(macOS 13.0, *) { control.segmentDistribution = .fillEqually }

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.control = control
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let control = context.coordinator.control else { return }
        if control.segmentCount != items.count { rebuildSegments(control) }
        // Update labels if needed
        for (i, it) in items.enumerated() { control.setLabel(title(it), forSegment: i) }
        // Selection
        if let idx = items.firstIndex(of: selection) { control.selectedSegment = idx }
        else { control.selectedSegment = -1 }
        if #available(macOS 13.0, *) {
            control.segmentDistribution = .fillEqually
        } else {
            // Fallback: try to equalize manually
            if let superWidth = control.superview?.bounds.width {
                let width = max(60.0, superWidth / CGFloat(max(1, items.count)))
                for i in 0..<control.segmentCount { control.setWidth(width, forSegment: i) }
            }
        }
    }

    private func rebuildSegments(_ control: NSSegmentedControl) {
        control.segmentCount = items.count
        for (i, it) in items.enumerated() {
            control.setLabel(title(it), forSegment: i)
        }
    }

    final class Coordinator: NSObject {
        weak var control: NSSegmentedControl?
        var parent: EqualWidthSegmentedControl
        init(_ parent: EqualWidthSegmentedControl) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            let idx = sender.selectedSegment
            guard idx >= 0 && idx < parent.items.count else { return }
            parent.selection = parent.items[idx]
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
                    activeDuration: nil,
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
                    lastUpdatedAt: Date().addingTimeInterval(-3600),
                    source: .codex
                ),
                SessionSummary(
                    id: "session-2",
                    fileURL: URL(
                        fileURLWithPath: "/Users/developer/.codex/sessions/session-2.json"),
                    fileSizeBytes: 8900,
                    startedAt: Date().addingTimeInterval(-10800),
                    endedAt: Date().addingTimeInterval(-9000),
                    activeDuration: nil,
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
                    lastUpdatedAt: Date().addingTimeInterval(-9000),
                    source: .codex
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
                    activeDuration: nil,
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
                    lastUpdatedAt: Date().addingTimeInterval(-158400),
                    source: .codex
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
