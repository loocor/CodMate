import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: SessionListViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection = Set<SessionSummary.ID>()
    @State private var selectionPrimaryId: SessionSummary.ID? = nil
    @State private var lastSelectionSnapshot = Set<SessionSummary.ID>()
    @State private var isPerformingAction = false
    @State private var deleteConfirmationPresented = false
    @State private var alertState: AlertState?
    @State private var selectingSessionsRoot = false
    // Track which sessions are running in embedded terminal
    @State private var runningSessionIDs = Set<SessionSummary.ID>()
    @State private var isDetailMaximized = false
    @State private var isListHidden = false
    @SceneStorage("cm.sidebarHidden") private var storeSidebarHidden: Bool = false
    @SceneStorage("cm.listHidden") private var storeListHidden: Bool = false
    @State private var showNewWithContext = false
    // When starting embedded sessions, record the initial command lines per-session
    @State private var embeddedInitialCommands: [SessionSummary.ID: String] = [:]
    // Confirm stopping a running embedded terminal
    private struct ConfirmStopState: Identifiable { let id = UUID(); let sessionId: String }
    @State private var confirmStopState: ConfirmStopState? = nil
    // Prompt picker state for embedded terminal quick-insert
    @State private var showPromptPicker = false
    @State private var promptQuery = ""
    // Debounced query to keep filtering cheap on main thread
    @State private var throttledPromptQuery = ""
    @State private var promptDebounceTask: Task<Void, Never>? = nil
    private struct SourcedPrompt: Identifiable, Hashable {
        let id = UUID()
        enum Source: Hashable { case project, user, builtin }
        var prompt: PresetPromptsStore.Prompt
        var source: Source
        var label: String { prompt.label }
        var command: String { prompt.command }

        // Custom Hashable implementation to hash based on content, not UUID
        func hash(into hasher: inout Hasher) {
            hasher.combine(prompt)
            hasher.combine(source)
        }

        static func == (lhs: SourcedPrompt, rhs: SourcedPrompt) -> Bool {
            lhs.prompt == rhs.prompt && lhs.source == rhs.source
        }
    }
    @State private var loadedPrompts: [SourcedPrompt] = []
    @State private var hoveredPromptKey: String? = nil
    private func promptKey(_ p: SourcedPrompt) -> String { p.command }
    private func canDelete(_ p: SourcedPrompt) -> Bool { true }
    @State private var pendingDelete: SourcedPrompt? = nil
    // Build highlighted text where matches of `query` are tinted; non-matches use the provided base color
    private func highlightedText(_ text: String, query: String, base: Color = .primary) -> Text {
        guard !query.isEmpty else { 
            let baseText = Text(text).foregroundStyle(base)
            return baseText
        }
        
        var result = Text("")
        var searchStart = text.startIndex
        let end = text.endIndex
        
        while searchStart < end, let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<end) {
            if r.lowerBound > searchStart {
                let prefix = String(text[searchStart..<r.lowerBound])
                let prefixText = Text(prefix).foregroundStyle(base)
                result = result + prefixText
            }
            
            let match = String(text[r])
            let matchText = Text(match).foregroundStyle(.tint)
            result = result + matchText
            
            searchStart = r.upperBound
        }
        
        if searchStart < end {
            let tail = String(text[searchStart..<end])
            let tailText = Text(tail).foregroundStyle(base)
            result = result + tailText
        }
        
        return result
    }
    private func builtinPrompts() -> [PresetPromptsStore.Prompt] {
        [
            .init(label: "git status", command: "git status"),
            .init(label: "git pull --rebase --autostash", command: "git pull --rebase --autostash"),
            .init(label: "rg -n TODO", command: "rg -n TODO"),
            .init(label: "swift build", command: "swift build"),
            .init(label: "swift test", command: "swift test"),
        ]
    }
    @State private var showReviewMode = false
    // Track pending rekey for embedded New so we can move the PTY to the real new session id
    struct PendingEmbeddedRekey {
        let anchorId: String
        let expectedCwd: String
        let t0: Date
        let selectOnSuccess: Bool
    }
    @State private var pendingEmbeddedRekeys: [PendingEmbeddedRekey] = []
    // Provide a simple font chooser that prefers CJK-capable monospace
    private func makeTerminalFont(size: CGFloat) -> NSFont {
        #if canImport(SwiftTerm)
            let candidates = [
                "Sarasa Mono SC", "Sarasa Term SC",
                "LXGW WenKai Mono",
                "Noto Sans Mono CJK SC", "NotoSansMonoCJKsc-Regular",
                "JetBrains Mono", "JetBrainsMono-Regular", "JetBrains Mono NL",
                "JetBrainsMonoNL Nerd Font Mono", "JetBrainsMono Nerd Font Mono",
                "SF Mono", "Menlo",
            ]
            for name in candidates { if let f = NSFont(name: name, size: size) { return f } }
        #endif
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    init(viewModel: SessionListViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        GeometryReader { geometry in
            navigationSplitView(geometry: geometry)
        }
    }

    private func navigationSplitView(geometry: GeometryProxy) -> some View {
        let sidebarMaxWidth = geometry.size.width * 0.25
        
        // Persist column visibility and list hidden across app focus changes
        // Use SceneStorage to remember the last-toggle states
        // Keys live with the main window scene and survive view re-creation
        _ = storeSidebarHidden // access to retain storage in scope
        _ = storeListHidden

        let baseView = NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent(sidebarMaxWidth: sidebarMaxWidth)
        } content: {
            listContent
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.prominentDetail)
        .onAppear { applyVisibilityFromStorage(animated: false) }
        
        let viewWithTasks = applyTaskAndChangeModifiers(to: baseView)
        let viewWithNotifications = applyNotificationModifiers(to: viewWithTasks)
        let finalView = applyDialogsAndAlerts(to: viewWithNotifications)
        
        return finalView
    }
    
    private func applyTaskAndChangeModifiers<V: View>(to view: V) -> some View {
        view
            .task {
                await viewModel.refreshSessions(force: true)
            }
            .onChange(of: viewModel.sections) { _, _ in
                normalizeSelection()
                reconcilePendingEmbeddedRekeys()
            }
            .onChange(of: selection) { _, newSel in
                // Enforce: the middle list should always have one selected item
                normalizeSelection()
                // Track primary selection id (last explicitly added id)
                let added = newSel.subtracting(lastSelectionSnapshot)
                if let justAdded = added.first { selectionPrimaryId = justAdded }
                // If primary got removed, choose a stable fallback
                if let primary = selectionPrimaryId, !newSel.contains(primary) {
                    selectionPrimaryId = newSel.first
                }
                lastSelectionSnapshot = newSel
            }
            .onChange(of: viewModel.errorMessage) { _, message in
                guard let message else { return }
                alertState = AlertState(title: "Operation Failed", message: message)
                viewModel.errorMessage = nil
            }
            .onChange(of: viewModel.pendingEmbeddedProjectNew) { _, project in
                guard let project else { return }
                // Start an embedded terminal for project-level New
                startEmbeddedNewForProject(project)
                // Clear one-shot request
                viewModel.pendingEmbeddedProjectNew = nil
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    refreshToolbarContent
                }
            }
    }
    
    private func applyNotificationModifiers<V: View>(to view: V) -> some View {
        view
            // Fallback event bus: react to embedded New for project even if binding changes are coalesced
            .onReceive(NotificationCenter.default.publisher(for: .codMateStartEmbeddedNewProject)) { note in
                if let pid = note.userInfo?["projectId"] as? String,
                   let project = viewModel.projects.first(where: { $0.id == pid }) {
                    startEmbeddedNewForProject(project)
                }
            }
            // Toggle sidebar visibility via global shortcut (Cmd+1)
            .onReceive(NotificationCenter.default.publisher(for: .codMateToggleSidebar)) { _ in
                toggleSidebarVisibility()
            }
            // Toggle middle list visibility via global shortcut (Cmd+2)
            .onReceive(NotificationCenter.default.publisher(for: .codMateToggleList)) { _ in
                toggleListVisibility()
            }
    }
    
    private func applyDialogsAndAlerts<V: View>(to view: V) -> some View {
        view
            // Confirm stopping a running embedded session (place before any .alert modifiers)
            .confirmationDialog(
                "Stop running session?",
                isPresented: Binding<Bool>(
                    get: { confirmStopState != nil },
                    set: { if !$0 { confirmStopState = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Stop", role: .destructive) {
                    if let st = confirmStopState {
                        stopEmbedded(forID: st.sessionId)
                        confirmStopState = nil
                    }
                }
                Button("Cancel", role: .cancel) { confirmStopState = nil }
            } message: {
                Text("The embedded terminal appears to be running. Stopping now will terminate the current Codex/Claude task.")
            }
            .alert(item: $alertState) { state in
                Alert(
                    title: Text(state.title),
                    message: Text(state.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(
                "Delete selected sessions?", isPresented: $deleteConfirmationPresented,
                presenting: Array(selection)
            ) { ids in
                Button("Cancel", role: .cancel) {}
                Button("Move to Trash", role: .destructive) {
                    deleteSelections(ids: ids)
                }
            } message: { _ in
                Text("Session files will be moved to Trash and can be restored in Finder.")
            }
            .fileImporter(
                isPresented: $selectingSessionsRoot,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderSelection(result: result, update: viewModel.updateSessionsRoot)
            }
            // Removed CLI chooser; rely entirely on PATH for CLI resolution
    }

    private func sidebarContent(sidebarMaxWidth: CGFloat) -> some View {
        SessionNavigationView(
            totalCount: viewModel.totalSessionCount,
            isLoading: viewModel.isLoading
        )
        .environmentObject(viewModel)
        .navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)
    }

    private var listContent: some View {
        SessionListColumnView(
            sections: viewModel.sections,
            selection: $selection,
            sortOrder: $viewModel.sortOrder,
            isLoading: viewModel.isLoading,
            isEnriching: viewModel.isEnriching,
            enrichmentProgress: viewModel.enrichmentProgress,
            enrichmentTotal: viewModel.enrichmentTotal,
            onResume: resumeFromList,
            onReveal: { viewModel.reveal(session: $0) },
            onDeleteRequest: handleDeleteRequest,
            onExportMarkdown: exportMarkdownForSession,
            isRunning: { runningSessionIDs.contains($0.id) },
            isUpdating: { viewModel.isActivelyUpdating($0.id) },
            isAwaitingFollowup: { viewModel.isAwaitingFollowup($0.id) },
            onPrimarySelect: { s in selectionPrimaryId = s.id }
        )
        .id(isListHidden ? "list-hidden" : "list-shown")
        .environmentObject(viewModel)
        .navigationSplitViewColumnWidth(
            min: isListHidden ? 0 : 360,
            ideal: isListHidden ? 0 : 420,
            max: isListHidden ? 0 : 480
        )
        // Rely on columnWidth for size; avoid separate frame/opacity animations
        .allowsHitTesting(!isListHidden)
        .sheet(item: $viewModel.editingSession, onDismiss: { viewModel.cancelEdits() }) { _ in
            EditSessionMetaView(viewModel: viewModel)
        }
        .sheet(isPresented: $showNewWithContext) {
            if let focused = focusedSummary {
                NewWithContextSheet(isPresented: $showNewWithContext, anchor: focused)
                    .environmentObject(viewModel)
            }
        }
    }

    private var refreshToolbarContent: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.refreshSessions(force: true) }
            } label: {
                if viewModel.isEnriching {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh session index")
            .disabled(viewModel.isEnriching || viewModel.isLoading)
        }
        .padding(.horizontal, 4)
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailActionBar
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            // Keep detail visually anchored; avoid animating with list hide/show
            mainDetailContent
                .animation(nil, value: isListHidden)
        }
    }

    private var mainDetailContent: some View {
        Group {
            // Priority 1: Review mode should take precedence over terminal views
            if showReviewMode, let focused = focusedSummary, let ws = focusedSummary.map({ workingDirectory(for: $0) }) {
                // Full review mode: occupy the whole detail area
                // Bind per-session review panel state so UI is preserved while toggling.
                GitChangesPanel(
                    workingDirectory: URL(fileURLWithPath: ws, isDirectory: true),
                    presentation: .full,
                    preferences: viewModel.preferences,
                    savedState: Binding<ReviewPanelState>(
                        get: { viewModel.reviewPanelStates[focused.id] ?? ReviewPanelState() },
                        set: { viewModel.reviewPanelStates[focused.id] = $0 }
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else if let anchorId = fallbackRunningAnchorId() {
                // Virtual anchor terminal for new session
                TerminalHostView(
                    terminalKey: anchorId,
                    initialCommands: embeddedInitialCommands[anchorId] ?? "",
                    font: makeTerminalFont(size: 12),
                    isDark: colorScheme == .dark
                )
                .id(anchorId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            } else if let focused = focusedSummary, runningSessionIDs.contains(focused.id) {
                // Real session with running terminal
                TerminalHostView(
                    terminalKey: focused.id,
                    initialCommands: embeddedInitialCommands[focused.id]
                        ?? viewModel.buildResumeCommands(session: focused),
                    font: makeTerminalFont(size: 12),
                    isDark: colorScheme == .dark
                )
                .id(focused.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            } else if let focused = focusedSummary {
                // Normal session detail view
                SessionDetailView(
                    summary: focused,
                    isProcessing: isPerformingAction,
                    onResume: {
                        guard let current = focusedSummary else { return }
                        if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                            startEmbedded(for: current)
                        } else {
                            openPreferredExternal(for: current)
                        }
                    },
                    onReveal: {
                        guard let current = focusedSummary else { return }
                        viewModel.reveal(session: current)
                    },
                    onDelete: presentDeleteConfirmation,
                    columnVisibility: $columnVisibility
                )
                .environmentObject(viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                placeholder
            }
        }
    }

    private var detailActionBar: some View {
        HStack(spacing: 12) {
            // Check if we're showing a virtual anchor (new session)
            let hasRunningAnchor = fallbackRunningAnchorId() != nil

            if hasRunningAnchor {
                // Show generic title for new session terminal, with a subtle note
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Session")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Appears in list after first message")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let focused = focusedSummary {
                HStack(spacing: 6) {
                    Text(focused.effectiveTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Button(action: { Task { await viewModel.beginEditing(session: focused) } }) {
                        Image(systemName: "pencil")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename / Add Comment")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            HStack(spacing: 8) {
                let focused = focusedSummary
                let isFocusedRunning = focused.map { runningSessionIDs.contains($0.id) } ?? false
                let hasRunningAnchor = fallbackRunningAnchorId() != nil

                if !isFocusedRunning && !hasRunningAnchor {
                Menu {
                    if let focused = focusedSummary {
                        Button {
                            showNewWithContext = true
                        } label: {
                            Label("New With Context…", systemImage: "text.append")
                        }

                        let providers = viewModel.allowedSources(for: focused)
                        if !providers.isEmpty {
                            Divider()
                            ForEach(providers, id: \.self) { provider in
                                let sessionSource = provider.sessionSource
                                Menu {
                                    Button {
                                        guard let current = focusedSummary else { return }
                                        launchNewSession(
                                            for: current, using: sessionSource, style: .preferred)
                                    } label: {
                                        Label("Use Preferred Launch", systemImage: "gearshape")
                                    }
                                    Button {
                                        guard let current = focusedSummary else { return }
                                        launchNewSession(
                                            for: current, using: sessionSource, style: .terminal)
                                    } label: {
                                        Label("Open in Terminal", systemImage: "terminal")
                                    }
                                    Button {
                                        guard let current = focusedSummary else { return }
                                        launchNewSession(
                                            for: current, using: sessionSource, style: .iterm)
                                    } label: {
                                        Label("Open in iTerm2", systemImage: "app.fill")
                                    }
                                    Button {
                                        guard let current = focusedSummary else { return }
                                        launchNewSession(
                                            for: current, using: sessionSource, style: .warp)
                                    } label: {
                                        Label("Open in Warp", systemImage: "app.gift.fill")
                                    }
                                    if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                                        Button {
                                            guard let current = focusedSummary else { return }
                                            launchNewSession(
                                                for: current, using: sessionSource, style: .embedded
                                            )
                                        } label: {
                                            Label(
                                                "Open Embedded Terminal",
                                                systemImage: "rectangle.badge.plus")
                                        }
                                    }
                                } label: {
                                    providerMenuLabel(prefix: "New", source: sessionSource)
                                }
                            }
                        }
                    } else {
                        Text("Select a session to start a new conversation")
                    }
                } label: {
                    if let focused {
                        sourceButtonLabel(
                            title: "New \(focused.source.branding.displayName)",
                            source: focused.source
                        )
                    } else {
                        Label("New", systemImage: "plus")
                    }
                } primaryAction: {
                    guard let current = focusedSummary else { return }
                    launchNewSession(for: current, using: current.source, style: .preferred)
                }
                .disabled(isPerformingAction || focused == nil)
                .help(
                    focused.map { "Start a new \($0.source.branding.displayName) session" }
                        ?? "Select a session to start new conversations"
                )
                .menuStyle(.borderedButton)
                .controlSize(.small)
                }

                if !isFocusedRunning && !hasRunningAnchor {
                Menu {
                    if focusedSummary != nil {
                        Button {
                            guard let current = focusedSummary else { return }
                            viewModel.copyResumeCommandsRespectingProject(session: current)
                            _ = viewModel.openAppleTerminal(at: workingDirectory(for: current))
                            Task {
                                await SystemNotifier.shared.notify(
                                    title: "CodMate",
                                    body: "Command copied. Paste it in the opened terminal.")
                            }
                        } label: {
                            Label("Open in Terminal", systemImage: "terminal")
                        }

                        Button {
                            guard let current = focusedSummary else { return }
                            let dir = workingDirectory(for: current)
                            let cmd = viewModel.buildResumeCLIInvocationRespectingProject(
                                session: current)
                            viewModel.openPreferredTerminalViaScheme(
                                app: .iterm2, directory: dir, command: cmd)
                        } label: {
                            Label("Open in iTerm2", systemImage: "app.fill")
                        }

                        Button {
                            guard let current = focusedSummary else { return }
                            viewModel.copyResumeCommandsRespectingProject(session: current)
                            viewModel.openPreferredTerminalViaScheme(
                                app: .warp, directory: workingDirectory(for: current))
                            Task {
                                await SystemNotifier.shared.notify(
                                    title: "CodMate",
                                    body: "Command copied. Paste it in the opened terminal.")
                            }
                        } label: {
                            Label("Open in Warp", systemImage: "app.gift.fill")
                        }

                        if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                            Button {
                                guard let current = focusedSummary else { return }
                                startEmbedded(for: current)
                            } label: {
                                Label("Open Embedded Terminal", systemImage: "rectangle.badge.plus")
                            }
                        }
                    } else {
                        Text("Select a session to resume")
                    }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                } primaryAction: {
                    guard let current = focusedSummary else { return }
                    if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                        startEmbedded(for: current)
                    } else {
                        openPreferredExternal(for: current)
                    }
                }
                .disabled(isPerformingAction || focused == nil)
                .help(
                    focused.map { "Resume \($0.source.branding.displayName) session" }
                        ?? "Select a session to resume"
                )
                .menuStyle(.borderedButton)
                .controlSize(.small)
                }

                // Dynamic file size (show only when embedded terminal is active for a real session)
                if let focused = focusedSummary, isFocusedRunning {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        LiveFileSizeText(url: focused.fileURL)
                    }
                }

                Button { if let focused = focusedSummary { viewModel.reveal(session: focused) } } label: { Image(systemName: "finder") }
                .disabled(focusedSummary == nil)
                .help("Reveal in Finder")

                // Toggle Review Mode (full-area Changes) as a pressed/unpressed button
                Toggle(isOn: $showReviewMode) {
                    Image(systemName: "arrow.triangle.branch")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(focusedSummary == nil)
                .help("Toggle Review Mode")

                if let focused = focusedSummary, runningSessionIDs.contains(focused.id) {
                    // Prompts picker: searchable quick insert into embedded terminal input
                    Button {
                        showPromptPicker.toggle()
                    } label: {
                        Image(systemName: "text.magnifyingglass")
                    }
                    .help("Insert preset command…")
                    .popover(isPresented: $showPromptPicker, arrowEdge: .top) {
                        VStack(spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Preset Commands")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    // Provide a tiny default template
                                    let template = loadedPrompts.isEmpty
                                        ? [
                                            SourcedPrompt(prompt: PresetPromptsStore.Prompt(label: "git status", command: "git status"), source: .builtin),
                                            SourcedPrompt(prompt: PresetPromptsStore.Prompt(label: "swift build", command: "swift build"), source: .builtin),
                                        ].map { $0.prompt }
                                        : loadedPrompts.map { $0.prompt }
                                    let cwd = focusedSummary?.cwd
                                    Task { await PresetPromptsStore.shared.openOrCreatePreferredFile(for: cwd, withTemplate: template) }
                                } label: {
                                    Image(systemName: "wrench.and.screwdriver")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Manage Prompts")
                            }
                            TextField("Search prompts", text: $promptQuery)
                                .textFieldStyle(.roundedBorder)
                            let q = throttledPromptQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                            let filtered = loadedPrompts.filter { item in
                                guard !q.isEmpty else { return true }
                                return item.label.localizedCaseInsensitiveContains(q)
                                    || item.command.localizedCaseInsensitiveContains(q)
                            }
                            let exactExists: Bool = {
                                let q = throttledPromptQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !q.isEmpty else { return true }
                                return loadedPrompts.contains(where: { $0.label == q || $0.command == q })
                            }()
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    // Add-new row if query non-empty and no exact match
                                    if !throttledPromptQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !exactExists {
                                        Button {
                                            let q = throttledPromptQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                                            guard let focused = focusedSummary else { return }
                                            Task {
                                                _ = await PresetPromptsStore.shared.add(
                                                    prompt: .init(label: q, command: q),
                                                    for: focused.cwd
                                                )
                                                let items = await PresetPromptsStore.shared.load(for: focused.cwd)
                                                let sourcedItems = items.map { SourcedPrompt(prompt: $0, source: .project) }
                                                await MainActor.run {
                                                    self.loadedPrompts = sourcedItems
                                                    // Close popover first to restore terminal focus cleanly
                                                    self.promptQuery = ""
                                                    self.showPromptPicker = false
                                                }
                                                #if canImport(SwiftTerm)
                                                    // After the popover closes, focus and insert on the main thread
                                                    await MainActor.run {
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                                            TerminalSessionManager.shared.focus(key: focused.id)
                                                            TerminalSessionManager.shared.send(to: focused.id, text: q)
                                                        }
                                                    }
                                                #endif
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "plus.circle")
                                                Text("Add \(throttledPromptQuery)")
                                                    .lineLimit(1)
                                                Spacer(minLength: 0)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 6)
                                        Divider()
                                    }
                                    if filtered.isEmpty {
                                        Text("No matches")
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .padding(.vertical, 12)
                                    } else {
                                        let maxShown = 200
                                        let shown = Array(filtered.prefix(maxShown))
                                        ForEach(shown, id: \.self) { item in
                                            Button {
                                                // Close and reset query first to avoid focus conflicts
                                                let textToInsert = item.command
                                                promptQuery = ""
                                                showPromptPicker = false
                                                #if canImport(SwiftTerm)
                                                    // Focus and insert after a short delay on main queue
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                                        TerminalSessionManager.shared.focus(key: focused.id)
                                                        TerminalSessionManager.shared.send(to: focused.id, text: textToInsert)
                                                    }
                                                #endif
                                            } label: {
                                                HStack(spacing: 8) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        highlightedText(item.label, query: q, base: .primary)
                                                            .font(.system(.body))
                                                            .lineLimit(1)
                                                        if item.command != item.label {
                                                            highlightedText(item.command, query: q, base: .secondary)
                                                                .font(.system(.caption, design: .monospaced))
                                                                .lineLimit(1)
                                                        }
                                                    }
                                                    Spacer(minLength: 0)
                                                    if canDelete(item) {
                                                        Button {
                                                            pendingDelete = item
                                                        } label: {
                                                            Image(systemName: "trash")
                                                                .symbolVariant(.circle)
                                                        }
                                                        .buttonStyle(.borderless)
                                                        .controlSize(.small)
                                                        .help("Delete prompt")
                                                        .opacity(hoveredPromptKey == promptKey(item) ? 1.0 : 0.0)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                            }
                                            // Accessibility: announce label + command for the row
                                            .accessibilityLabel(Text("\(item.label) \(item.command)"))
                                            .onHover { hovering in hoveredPromptKey = hovering ? promptKey(item) : nil }
                                            .buttonStyle(.plain)
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 6)
                                            Divider()
                                        }
                                        if filtered.count > maxShown {
                                            Text("Showing first \(maxShown) results — refine search to see more")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 4)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                            // Footer intentionally empty for compact layout
                        }
                        .padding(12)
                        .frame(width: 360, height: 280)
                    }
                    .onChange(of: showPromptPicker) { _, isOpen in
                        guard isOpen, let focused = focusedSummary else { return }
                        Task {
                            let projectOnly = await PresetPromptsStore.shared.loadProjectOnly(for: focused.cwd)
                            let userOnly = await PresetPromptsStore.shared.loadUserOnly()
                            let hidden = await PresetPromptsStore.shared.loadHidden(for: focused.cwd)
                            var seen = Set<String>()
                            var result: [SourcedPrompt] = []
                            for p in projectOnly { if seen.insert(p.command).inserted { result.append(.init(prompt: p, source: .project)) } }
                            for p in userOnly { if seen.insert(p.command).inserted { result.append(.init(prompt: p, source: .user)) } }
                            for b in builtinPrompts() {
                                guard !hidden.contains(b.command) else { continue }
                                if seen.insert(b.command).inserted { result.append(.init(prompt: b, source: .builtin)) }
                            }
                            loadedPrompts = result
                        }
                        throttledPromptQuery = promptQuery
                    }
                    // Debounce search query updates to keep filtering snappy on large lists
                    .onChange(of: promptQuery) { _, newValue in
                        promptDebounceTask?.cancel()
                        let value = newValue
                        promptDebounceTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            throttledPromptQuery = value
                        }
                    }
                    .alert(item: $pendingDelete, content: { item in
                        Alert(
                            title: Text("Delete Prompt"),
                            message: Text("Delete ‘\(item.label)’? This cannot be undone."),
                            primaryButton: .destructive(Text("Delete"), action: {
                                guard let focused = focusedSummary else { return }
                                Task {
                                    let location: PresetPromptsStore.PromptLocation = (item.source == .project) ? .project : (item.source == .user ? .user : .builtin)
                                    _ = await PresetPromptsStore.shared.delete(prompt: item.prompt, location: location, workingDirectory: focused.cwd)
                                    // reload current list
                                    let projectOnly = await PresetPromptsStore.shared.loadProjectOnly(for: focused.cwd)
                                    let userOnly = await PresetPromptsStore.shared.loadUserOnly()
                                    let hidden = await PresetPromptsStore.shared.loadHidden(for: focused.cwd)
                                    var seen = Set<String>()
                                    var result: [SourcedPrompt] = []
                                    for p in projectOnly { if seen.insert(p.command).inserted { result.append(.init(prompt: p, source: .project)) } }
                                    for p in userOnly { if seen.insert(p.command).inserted { result.append(.init(prompt: p, source: .user)) } }
                                    for b in builtinPrompts() {
                                        guard !hidden.contains(b.command) else { continue }
                                        if seen.insert(b.command).inserted { result.append(.init(prompt: b, source: .builtin)) }
                                    }
                                    await MainActor.run { loadedPrompts = result }
                                }
                            }),
                            secondaryButton: .cancel({ pendingDelete = nil })
                        )
                    })
                }

                if let focused = focusedSummary, runningSessionIDs.contains(focused.id) {
                    // Place the return button at the far right by making it the last item
                    Button { requestStopEmbedded(forID: focused.id) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Return to history")
                } else if let anchor = fallbackRunningAnchorId() {
                    Button { requestStopEmbedded(forID: anchor) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Return to history")
                } else {
                    let canExport = (focusedSummary?.eventCount ?? 0) > 0 && !viewModel.isLoading
                    Button {
                        exportMarkdownForFocused()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(!canExport)
                    .help("Export Markdown")
                }

                if !isFocusedRunning && !hasRunningAnchor {
                    Button(role: .destructive) {
                        presentDeleteConfirmation()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selection.isEmpty || isPerformingAction)
                    .help("Delete")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var focusedSummary: SessionSummary? {
        guard !selection.isEmpty else {
            return viewModel.sections.first?.sessions.first
        }
        let all = summaryLookup
        if let pid = selectionPrimaryId, selection.contains(pid), let s = all[pid] {
            return s
        }
        return
            selection
            .compactMap { all[$0] }
            .sorted { lhs, rhs in
                (lhs.lastUpdatedAt ?? lhs.startedAt) > (rhs.lastUpdatedAt ?? rhs.startedAt)
            }
            .first
    }

    private var summaryLookup: [SessionSummary.ID: SessionSummary] {
        Dictionary(
            uniqueKeysWithValues: viewModel.sections
                .flatMap(\.sessions)
                .map { ($0.id, $0) })
    }

    private func normalizeSelection() {
        let orderedIDs = viewModel.sections.flatMap { $0.sessions.map(\.id) }
        let validIDs = Set(orderedIDs)
        let original = selection
        selection.formIntersection(validIDs)
        if selection.isEmpty, let first = orderedIDs.first {
            selection.insert(first)
        }
        // Avoid unnecessary churn if nothing changed
        if selection == original { return }
    }

    private func resumeFromList(_ session: SessionSummary) {
        selection = [session.id]
        selectionPrimaryId = session.id
        if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
            startEmbedded(for: session)
        } else {
            openPreferredExternal(for: session)
        }
    }

    private func handleDeleteRequest(_ session: SessionSummary) {
        selection = [session.id]
        presentDeleteConfirmation()
    }

    private func presentDeleteConfirmation() {
        guard !selection.isEmpty else { return }
        deleteConfirmationPresented = true
    }

    private func deleteSelections(ids: [SessionSummary.ID]) {
        let summaries = ids.compactMap { summaryLookup[$0] }
        guard !summaries.isEmpty else { return }

        deleteConfirmationPresented = false
        isPerformingAction = true

        Task {
            await viewModel.delete(summaries: summaries)
            await MainActor.run {
                // Best-effort: stop any embedded terminals for deleted sessions
                #if canImport(SwiftTerm)
                    for s in summaries { TerminalSessionManager.shared.stop(key: s.id) }
                #endif
                isPerformingAction = false
                selection.subtract(ids)
                normalizeSelection()
            }
        }
    }

    private func startEmbedded(for session: SessionSummary) {
        // Build the default resume commands for this session so TerminalHostView can inject them
        embeddedInitialCommands[session.id] = viewModel.buildResumeCommands(session: session)
        runningSessionIDs.insert(session.id)
        // User已接手：清除待跟进高亮
        viewModel.clearAwaitingFollowup(session.id)
        // Nudge Codex to redraw cleanly once it starts, by sending "/" then backspace
        #if canImport(SwiftTerm)
            TerminalSessionManager.shared.scheduleSlashNudge(forKey: session.id, delay: 1.0)
        #endif
    }

    private func stopEmbedded(forID id: SessionSummary.ID) {
        // Tear down the embedded terminal view and terminate its child process
        #if canImport(SwiftTerm)
            TerminalSessionManager.shared.stop(key: id)
        #endif
        runningSessionIDs.remove(id)
        embeddedInitialCommands.removeValue(forKey: id)
        // 退出内置终端：清除待跟进高亮
        viewModel.clearAwaitingFollowup(id)
        if runningSessionIDs.isEmpty {
            isDetailMaximized = false
            columnVisibility = .all
        }
    }

    private func isTerminalLikelyRunning(forID id: SessionSummary.ID) -> Bool {
        // Multi-layer detection for more accurate running state:
        // 1. Check if terminal manager reports a running process
        #if canImport(SwiftTerm)
        if TerminalSessionManager.shared.hasRunningProcess(key: id) {
            return true
        }
        #endif

        // 2. Check if this is a pending new session (anchor awaiting rekey)
        if pendingEmbeddedRekeys.contains(where: { $0.anchorId == id }) {
            return true
        }

        // 3. Check recent file activity heartbeat (session actively writing)
        if viewModel.isActivelyUpdating(id) {
            return true
        }

        return false
    }

    private func requestStopEmbedded(forID id: SessionSummary.ID) {
        // Always check current running state before showing confirmation
        let isRunning = isTerminalLikelyRunning(forID: id)

        if isRunning {
            // Show confirmation dialog for running sessions
            confirmStopState = ConfirmStopState(sessionId: id)
        } else {
            // Directly stop if not running
            stopEmbedded(forID: id)
        }
    }

    private func shellEscapeForCD(_ path: String) -> String {
        // Minimal POSIX shell escaping suitable for `cd` arguments
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func workingDirectory(for session: SessionSummary) -> String {
        if FileManager.default.fileExists(atPath: session.cwd) {
            return session.cwd
        }
        return session.fileURL.deletingLastPathComponent().path
    }

    private func startEmbeddedNew(for session: SessionSummary, using source: SessionSource? = nil) {
        let target = source.map { session.overridingSource($0) } ?? session
        // Build the 'new session' commands (respecting project profile when present)
        let cwd =
            FileManager.default.fileExists(atPath: target.cwd)
            ? target.cwd : target.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapeForCD(cwd)
        let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
        var exportLines = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if target.source == .codex {
            exportLines.append("export CODEX_DISABLE_COLOR_QUERY=1")
        }
        let exports = exportLines.joined(separator: "; ")
        let invocation = viewModel.buildNewSessionCLIInvocationRespectingProject(session: target)
        let command = "PATH=\(injectedPATH) \(invocation)"
        // Enter alternate screen and clear for a truly clean view (cursor home);
        // avoids reflow artifacts and isolates scrollback while the new session runs.
        let preclear = "printf '\\033[?1049h\\033[H\\033[2J'"

        // Use virtual anchor id to avoid hijacking an existing session's running state
        let anchorId = "new-anchor:detail:\(target.id):\(Int(Date().timeIntervalSince1970)))"
        embeddedInitialCommands[anchorId] =
            preclear + "\n" + cd + "\n" + exports + "\n" + command + "\n"
        runningSessionIDs.insert(anchorId)
        // Record pending rekey so that when the new session appears, we can move this PTY to the real id
        pendingEmbeddedRekeys.append(
            PendingEmbeddedRekey(
                anchorId: anchorId, expectedCwd: canonicalizePath(cwd), t0: Date(), selectOnSuccess: true)
        )
        // Event-driven incremental refresh: set a hint so directory monitor triggers a targeted refresh
        if target.source == .codex {
            viewModel.setIncrementalHintForCodexToday()
        } else {
            viewModel.setIncrementalHintForClaudeProject(directory: cwd)
        }
        // Proactively trigger a targeted incremental refresh for immediate visibility
        Task {
            if target.source == .codex {
                await viewModel.refreshIncrementalForNewCodexToday()
                // Follow-up probes to catch late file creation (non-recursive FS monitor)
                try? await Task.sleep(nanoseconds: 600_000_000)
                await viewModel.refreshIncrementalForNewCodexToday()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await viewModel.refreshIncrementalForNewCodexToday()
            } else {
                // Claude Code: more aggressive refresh schedule because CLI may delay writing content
                await viewModel.refreshIncrementalForClaudeProject(directory: cwd)
                // Follow-up probes to catch file creation and content fill
                try? await Task.sleep(nanoseconds: 600_000_000)  // 0.6s
                await viewModel.refreshIncrementalForClaudeProject(directory: cwd)
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                await viewModel.refreshIncrementalForClaudeProject(directory: cwd)
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                await viewModel.refreshIncrementalForClaudeProject(directory: cwd)
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                await viewModel.refreshIncrementalForClaudeProject(directory: cwd)
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                await viewModel.refreshIncrementalForClaudeProject(directory: cwd)
            }
        }
        // Clear selection so fallbackRunningAnchorId() can display the virtual anchor terminal
        selection.removeAll()
        // Ensure terminal is visible
        isDetailMaximized = true
        columnVisibility = .detailOnly
    }

    private func startEmbeddedNewForProject(_ project: Project) {
        // Build 'new project' invocation and inject into embedded terminal
        let dir: String = {
            let d = (project.directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? NSHomeDirectory() : d
        }()
        let cd = "cd " + shellEscapeForCD(dir)
        let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
        let exportLines = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
            "export CODEX_DISABLE_COLOR_QUERY=1",
        ]
        let exports = exportLines.joined(separator: "; ")
        let invocation = viewModel.buildNewProjectCLIInvocation(project: project)
        let command = "PATH=\(injectedPATH) \(invocation)"
        let preclear = "printf '\\033[?1049h\\033[H\\033[2J'"

        // Always use a virtual anchor for project-level New
        let anchorId = "new-anchor:project:\(project.id):\(Int(Date().timeIntervalSince1970)))"
        embeddedInitialCommands[anchorId] = preclear + "\n" + cd + "\n" + exports + "\n" + command + "\n"
        runningSessionIDs.insert(anchorId)
        // Pending rekey: when the new session lands under this cwd, move PTY to the real id
        pendingEmbeddedRekeys.append(
            PendingEmbeddedRekey(
                anchorId: anchorId, expectedCwd: canonicalizePath(dir), t0: Date(), selectOnSuccess: true)
        )
        // Event-driven incremental refresh: scoped to today's Codex folder
        viewModel.setIncrementalHintForCodexToday()
        // Proactively refresh today's subset so the new item appears quickly
        Task {
            await viewModel.refreshIncrementalForNewCodexToday()
            // Follow-up probes to catch late file creation
            try? await Task.sleep(nanoseconds: 600_000_000)
            await viewModel.refreshIncrementalForNewCodexToday()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await viewModel.refreshIncrementalForNewCodexToday()
        }
        // Clear selection so fallbackRunningAnchorId() can display the virtual anchor terminal
        selection.removeAll()
        // Maximize detail to show embedded terminal
        isDetailMaximized = true
        columnVisibility = .detailOnly
    }

    private func openPreferredExternal(for session: SessionSummary) {
        viewModel.copyResumeCommandsRespectingProject(session: session)
        let app = viewModel.preferences.defaultResumeExternalApp
        let dir = workingDirectory(for: session)
        switch app {
        case .iterm2:
            let cmd = viewModel.buildResumeCLIInvocationRespectingProject(session: session)
            viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
        case .warp:
            viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
        case .terminal:
            _ = viewModel.openAppleTerminal(at: dir)
        case .none:
            break
        }
        Task {
            await SystemNotifier.shared.notify(
                title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }
    }

    private func openPreferredExternalForNew(session: SessionSummary) {
        // Record pending intent for auto-assign before launching
        viewModel.recordIntentForDetailNew(anchor: session)
        let app = viewModel.preferences.defaultResumeExternalApp
        let dir = workingDirectory(for: session)
        // Event hint for targeted incremental refresh on FS change
        if session.source == .codex {
            viewModel.setIncrementalHintForCodexToday()
        } else {
            viewModel.setIncrementalHintForClaudeProject(directory: dir)
        }
        // Also proactively refresh the targeted subset for faster UI update
        Task {
            if session.source == .codex {
                await viewModel.refreshIncrementalForNewCodexToday()
                // Follow-up probes to catch late file creation
                try? await Task.sleep(nanoseconds: 600_000_000)
                await viewModel.refreshIncrementalForNewCodexToday()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await viewModel.refreshIncrementalForNewCodexToday()
            } else {
                await viewModel.refreshIncrementalForClaudeProject(directory: dir)
                // Follow-up probes to catch late file creation
                try? await Task.sleep(nanoseconds: 600_000_000)
                await viewModel.refreshIncrementalForClaudeProject(directory: dir)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await viewModel.refreshIncrementalForClaudeProject(directory: dir)
            }
        }
        switch app {
        case .iterm2:
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: session)
            viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
        case .warp:
            // Warp scheme cannot run a command; open path only and rely on clipboard
            viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
        case .terminal:
            viewModel.openNewSessionRespectingProject(session: session)
        case .none:
            break
        }
        Task {
            await SystemNotifier.shared.notify(
                title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }
    }

    private func startNewSession(for session: SessionSummary, using source: SessionSource? = nil) {
        let target = source.map { session.overridingSource($0) } ?? session
        viewModel.copyNewSessionCommandsRespectingProject(session: target)
        openPreferredExternalForNew(session: target)
    }

    private enum NewLaunchStyle {
        case preferred
        case terminal
        case iterm
        case warp
        case embedded
    }

    private func launchNewSession(
        for session: SessionSummary, using source: SessionSource, style: NewLaunchStyle
    ) {
        let target = source == session.source ? session : session.overridingSource(source)
        switch style {
        case .preferred:
            if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                viewModel.recordIntentForDetailNew(anchor: target)
                startEmbeddedNew(for: target)
            } else {
                startNewSession(for: target)
            }
        case .terminal:
            viewModel.recordIntentForDetailNew(anchor: target)
            viewModel.copyNewSessionCommandsRespectingProject(session: target)
            _ = viewModel.openAppleTerminal(at: workingDirectory(for: target))
            Task {
                await SystemNotifier.shared.notify(
                    title: "CodMate",
                    body: "Command copied. Paste it in the opened terminal.")
            }
        case .iterm:
            viewModel.recordIntentForDetailNew(anchor: target)
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: target)
            viewModel.openPreferredTerminalViaScheme(
                app: .iterm2, directory: workingDirectory(for: target), command: cmd)
        case .warp:
            viewModel.recordIntentForDetailNew(anchor: target)
            viewModel.copyNewSessionCommandsRespectingProject(session: target)
            viewModel.openPreferredTerminalViaScheme(
                app: .warp, directory: workingDirectory(for: target))
            Task {
                await SystemNotifier.shared.notify(
                    title: "CodMate",
                    body: "Command copied. Paste it in the opened terminal.")
            }
        case .embedded:
            viewModel.recordIntentForDetailNew(anchor: target)
            startEmbeddedNew(for: target)
        }
    }

    @ViewBuilder
    private func sourceButtonLabel(title: String, source: SessionSource) -> some View {
        Text(title)
    }

    @ViewBuilder
    private func providerMenuLabel(prefix: String, source: SessionSource) -> some View {
        Text("\(prefix) \(source.branding.displayName)")
    }

    private func toggleDetailMaximized() {
        withAnimation(.easeInOut(duration: 0.18)) {
            let shouldHide = columnVisibility != .detailOnly
            columnVisibility = shouldHide ? .detailOnly : .all
            isDetailMaximized = shouldHide
        }
    }

    private func toggleSidebarVisibility() {
        withAnimation(.easeInOut(duration: 0.15)) {
            switch columnVisibility {
            case .all:
                columnVisibility = .doubleColumn // hide sidebar via system behavior
                storeSidebarHidden = true
            case .doubleColumn:
                columnVisibility = .all         // show sidebar
                storeSidebarHidden = false
            case .detailOnly:
                columnVisibility = .doubleColumn
                storeSidebarHidden = true
            default:
                columnVisibility = .doubleColumn
                storeSidebarHidden = true
            }
        }
    }

    private func toggleListVisibility() {
        // Revert to non-animated toggle to keep detail anchored and stable
        isListHidden.toggle()
        storeListHidden = isListHidden
    }

    private func applyVisibilityFromStorage(animated: Bool) {
        let action = {
            // Apply list visibility
            isListHidden = storeListHidden
            // Apply sidebar visibility when not maximized
            switch columnVisibility {
            case .detailOnly:
                break // keep maximized state
            case .all, .doubleColumn:
                if storeSidebarHidden {
                    if columnVisibility == .all { columnVisibility = .doubleColumn }
                } else {
                    if columnVisibility == .doubleColumn { columnVisibility = .all }
                }
            default:
                break
            }
        }
        if animated { withAnimation(.easeInOut(duration: 0.12)) { action() } } else { action() }
    }

    @ViewBuilder
    private func maximizeToggleButton() -> some View {
        Button {
            toggleDetailMaximized()
        } label: {
            Image(
                systemName: isDetailMaximized
                    ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            )
            .font(.system(size: 15, weight: .semibold))
            .padding(8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDetailMaximized ? "Restore view" : "Maximize terminal")
    }

    private func handleFolderSelection(
        result: Result<[URL], Error>,
        update: @escaping (URL) async -> Void
    ) {
        switch result {
        case .success(let urls):
            selectingSessionsRoot = false
            guard let url = urls.first else { return }
            Task { await update(url) }
        case .failure(let error):
            selectingSessionsRoot = false
            alertState = AlertState(
                title: "Failed to choose directory", message: error.localizedDescription)
        }
    }

    // Removed: executable chooser handler

    private var placeholder: some View {
        ContentUnavailableView(
            "Select a session", systemImage: "rectangle.and.text.magnifyingglass",
            description: Text("Pick a session from the middle list to view details.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Embedded PTY rekey helpers
extension ContentView {
    private func canonicalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }

    // Return a virtual-anchor id if any is running (no real focused session ties)
    private func fallbackRunningAnchorId() -> String? {
        let realIds = Set(summaryLookup.keys)
        // Prefer explicit new-anchor keys
        if let id = runningSessionIDs.first(where: { $0.hasPrefix("new-anchor:") }) { return id }
        // Otherwise any running id that is not a current summary (e.g., synthetic or stale)
        return runningSessionIDs.first(where: { !realIds.contains($0) })
    }

    private func reconcilePendingEmbeddedRekeys() {
        guard !pendingEmbeddedRekeys.isEmpty else { return }
        let all = viewModel.sections.flatMap(\.sessions)
        let now = Date()
        var remaining: [PendingEmbeddedRekey] = []
        for pending in pendingEmbeddedRekeys {
            // Window to match nearby creations
            let windowStart = pending.t0.addingTimeInterval(-2)
            let windowEnd = pending.t0.addingTimeInterval(120)
            let candidates = all.filter { s in
                guard s.id != pending.anchorId else { return false }
                let canon = canonicalizePath(s.cwd)
                guard canon == pending.expectedCwd else { return false }
                return s.startedAt >= windowStart && s.startedAt <= windowEnd
            }
            if let winner = candidates.min(by: {
                abs($0.startedAt.timeIntervalSince(pending.t0))
                    < abs($1.startedAt.timeIntervalSince(pending.t0))
            }) {
                #if canImport(SwiftTerm)
                    TerminalSessionManager.shared.rekey(from: pending.anchorId, to: winner.id)
                #endif
                if runningSessionIDs.contains(pending.anchorId) {
                    runningSessionIDs.remove(pending.anchorId)
                    runningSessionIDs.insert(winner.id)
                }
                if pending.selectOnSuccess || selection.contains(pending.anchorId) {
                    selection = [winner.id]
                }
            } else {
                if now.timeIntervalSince(pending.t0) < 180 {
                    remaining.append(pending)
                } else {
                    // Timeout: stop the anchor terminal to avoid lingering shells
                    #if canImport(SwiftTerm)
                        TerminalSessionManager.shared.stop(key: pending.anchorId)
                    #endif
                    runningSessionIDs.remove(pending.anchorId)
                    embeddedInitialCommands.removeValue(forKey: pending.anchorId)
                }
            }
        }
        pendingEmbeddedRekeys = remaining
    }
}

private struct AlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Export helper
extension ContentView {
    // No additional helpers: left session list acts as the switcher
    private func exportMarkdownForFocused() {
        guard let focused = focusedSummary else { return }
        exportMarkdownForSession(focused)
    }

    private func exportMarkdownForSession(_ session: SessionSummary) {
        let loader = SessionTimelineLoader()
        let allTurns = ((try? loader.load(url: session.fileURL)) ?? [])
        let kinds = viewModel.preferences.markdownVisibleKinds
        let turns: [ConversationTurn] = allTurns.compactMap { turn in
            let userAllowed = turn.userMessage.flatMap { kinds.contains(event: $0) } ?? false
            let keptOutputs = turn.outputs.filter { kinds.contains(event: $0) }
            if !userAllowed && keptOutputs.isEmpty { return nil }
            return ConversationTurn(
                id: turn.id,
                timestamp: turn.timestamp,
                userMessage: userAllowed ? turn.userMessage : nil,
                outputs: keptOutputs
            )
        }
        var lines: [String] = []
        lines.append("# \(session.displayName)")
        lines.append("")
        lines.append("- Started: \(session.startedAt)")
        if let end = session.lastUpdatedAt { lines.append("- Last Updated: \(end)") }
        if let model = session.model { lines.append("- Model: \(model)") }
        if let approval = session.approvalPolicy { lines.append("- Approval Policy: \(approval)") }
        lines.append("")
        for turn in turns {
            if let user = turn.userMessage {
                lines.append("**User** · \(user.timestamp)")
                if let text = user.text, !text.isEmpty { lines.append(text) }
            }
            let assistantLabel = session.source.branding.displayName
            for event in turn.outputs {
                let prefix: String
                switch event.actor {
                case .assistant: prefix = "**\(assistantLabel)**"
                case .tool: prefix = "**Tool**"
                case .info: prefix = "**Info**"
                case .user: prefix = "**User**"
                }
                lines.append("")
                lines.append("\(prefix) · \(event.timestamp)")
                if let title = event.title { lines.append("> \(title)") }
                if let text = event.text, !text.isEmpty { lines.append(text) }
                if let meta = event.metadata, !meta.isEmpty {
                    for key in meta.keys.sorted() {
                        lines.append("- \(key): \(meta[key] ?? "")")
                    }
                }
                if event.repeatCount > 1 {
                    lines.append("- repeated: ×\(event.repeatCount)")
                }
            }
            lines.append("")
        }
        let md = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.title = "Export Markdown"
        panel.allowedContentTypes = [.plainText]
        let base = sanitizedExportFileName(session.effectiveTitle, fallback: session.displayName)
        panel.nameFieldStringValue = base + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? md.data(using: .utf8)?.write(to: url)
        }
    }

    // Local helper to avoid Xcode target membership issues for utility files
    private func sanitizedExportFileName(_ s: String, fallback: String, maxLength: Int = 120)
        -> String
    {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return fallback }
        let disallowed = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        text = text.unicodeScalars.map { disallowed.contains($0) ? Character(" ") : Character($0) }
            .reduce(into: String(), { $0.append($1) })
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = fallback }
        if text.count > maxLength {
            let idx = text.index(text.startIndex, offsetBy: maxLength)
            text = String(text[..<idx])
        }
        return text
    }
}
