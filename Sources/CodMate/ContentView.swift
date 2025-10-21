import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: SessionListViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection = Set<SessionSummary.ID>()
    @State private var isPerformingAction = false
    @State private var deleteConfirmationPresented = false
    @State private var alertState: AlertState?
    @State private var selectingSessionsRoot = false
    @State private var selectingExecutable = false
    // Track which sessions are running in embedded terminal
    @State private var runningSessionIDs = Set<SessionSummary.ID>()
    @State private var isDetailMaximized = false
    @State private var showNewWithContext = false
    // When starting embedded sessions, record the initial command lines per-session
    @State private var embeddedInitialCommands: [SessionSummary.ID: String] = [:]
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
        
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent(sidebarMaxWidth: sidebarMaxWidth)
        } content: {
            listContent
            } detail: {
                detailColumn
            }
        .navigationSplitViewStyle(.balanced)
        .task {
            await viewModel.refreshSessions(force: true)
        }
        .onChange(of: viewModel.sections) { _, _ in
            normalizeSelection()
        }
        .onChange(of: selection) { _, _ in
            // Enforce: the middle list should always have one selected item
            normalizeSelection()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            alertState = AlertState(title: "Operation Failed", message: message)
            viewModel.errorMessage = nil
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                refreshToolbarContent
            }
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
        .fileImporter(
            isPresented: $selectingExecutable,
            allowedContentTypes: [.unixExecutable],
            allowsMultipleSelection: false
        ) { result in
            handleExecutableSelection(result: result)
        }
    }
    
    private func sidebarContent(sidebarMaxWidth: CGFloat) -> some View {
        SessionNavigationView(
            totalCount: viewModel.totalSessionCount,
            isLoading: viewModel.isLoading
        )
        .environmentObject(viewModel)
        .navigationSplitViewColumnWidth(
            min: 250, ideal: 270, max: max(250, sidebarMaxWidth))
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
            onOpenEmbedded: (viewModel.preferences.defaultResumeUseEmbeddedTerminal ? { startEmbedded(for: $0) } : nil)
        )
        .environmentObject(viewModel)
        .navigationSplitViewColumnWidth(min: 420, ideal: 480, max: 600)
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

            Group {
                if let focused = focusedSummary {
                    if runningSessionIDs.contains(focused.id) {
                        ZStack(alignment: .topTrailing) {
                            TerminalHostView(sessionID: focused.id,
                                             initialCommands: embeddedInitialCommands[focused.id] ?? viewModel.buildResumeCommands(session: focused),
                                             font: makeTerminalFont(size: 12),
                                             isDark: colorScheme == .dark)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.black.opacity(0.001)) // keep hit-testing simple, visually invisible
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )

                            // NOTE: Temporarily hide maximize/restore; re-enable after fold logic is refined
                            // maximizeToggleButton()
                            //     .padding(.top, 18)
                            //     .padding(.trailing, 18)
                            //     .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 2)
                        }
                    } else {
                        SessionDetailView(
                            summary: focused,
                            isProcessing: isPerformingAction,
                            onResume: {
                                if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                                    startEmbedded(for: focused)
                                } else {
                                    openPreferredExternal(for: focused)
                                }
                            },
                            onReveal: { viewModel.reveal(session: focused) },
                            onDelete: presentDeleteConfirmation
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    placeholder
                }
            }
        }
    }

    private var detailActionBar: some View {
        HStack(spacing: 12) {
            if let focused = focusedSummary {
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
                if let focused = focusedSummary {
                    Menu {
                        Button { showNewWithContext = true } label: {
                            Label("New With Context…", systemImage: "text.append")
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    } primaryAction: {
                        if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                            startEmbeddedNew(for: focused)
                        } else {
                            startNewSession(for: focused)
                        }
                    }
                    .disabled(isPerformingAction)
                    .help("Start a new Codex session (use project profile when available)")
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                }

                Menu {
                    // 1) Terminal (copy + open at path)
                    Button {
                        if let f = focusedSummary {
                            let dir = FileManager.default.fileExists(atPath: f.cwd) ? f.cwd : f.fileURL.deletingLastPathComponent().path
                            viewModel.copyResumeCommands(session: f)
                            _ = viewModel.openAppleTerminal(at: dir)
                            Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Paste it in the opened terminal.") }
                        }
                    } label: { Label("Open in Terminal", systemImage: "terminal") }

                    // 2) iTerm2 via scheme (direct)
                    Button {
                        if let f = focusedSummary {
                            let dir = FileManager.default.fileExists(atPath: f.cwd) ? f.cwd : f.fileURL.deletingLastPathComponent().path
                            let cmd = viewModel.buildResumeCLIInvocation(session: f)
                            viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
                        }
                    } label: { Label("Open in iTerm2 (Direct)", systemImage: "app.fill") }

                    // 3) Warp via path (copy + open tab)
                    Button {
                        if let f = focusedSummary {
                            let dir = FileManager.default.fileExists(atPath: f.cwd) ? f.cwd : f.fileURL.deletingLastPathComponent().path
                            viewModel.copyResumeCommands(session: f)
                            viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
                            Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Paste it in the opened terminal.") }
                        }
                    } label: { Label("Open in Warp (Path)", systemImage: "app.gift.fill") }

                    // Embedded terminal (respect preference)
                    if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                        Button {
                            if let f = focusedSummary { startEmbedded(for: f) }
                        } label: { Label("Open Embedded Terminal", systemImage: "rectangle.badge.plus") }
                    }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                } primaryAction: {
                    if let f = focusedSummary {
                        if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                            startEmbedded(for: f)
                        } else {
                            openPreferredExternal(for: f)
                        }
                    }
                }
                .disabled(isPerformingAction || focusedSummary == nil)
                .help("Resume and more options")
                .menuStyle(.borderedButton)
                .controlSize(.small)

                Button {
                    if let focused = focusedSummary { viewModel.reveal(session: focused) }
                } label: {
                    Image(systemName: "folder")
                }
                .disabled(focusedSummary == nil)
                .help("Reveal in Finder")

                if let focused = focusedSummary, runningSessionIDs.contains(focused.id) {
                    Button {
                        stopEmbedded(forID: focused.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Return to history")

                    Button {
                        viewModel.copyRealResumeCommand(session: focused)
                        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Real command copied") }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy real resume command")
                } else {
                    Button {
                        exportMarkdownForFocused()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(focusedSummary == nil)
                    .help("Export Markdown")
                }

                Button(role: .destructive) {
                    presentDeleteConfirmation()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selection.isEmpty || isPerformingAction)
                .help("Delete")
            }
            .buttonStyle(.bordered)
        }
    }

    private var focusedSummary: SessionSummary? {
        guard !selection.isEmpty else {
            return viewModel.sections.first?.sessions.first
        }

        let allSummaries = summaryLookup
        return
            selection
            .compactMap { allSummaries[$0] }
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
        openPreferredExternal(for: session)
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
    }

    private func stopEmbedded(forID id: SessionSummary.ID) {
        // Tear down the embedded terminal view and terminate its child process
        #if canImport(SwiftTerm)
        TerminalSessionManager.shared.stop(id: id)
        #endif
        runningSessionIDs.remove(id)
        embeddedInitialCommands.removeValue(forKey: id)
        if runningSessionIDs.isEmpty {
            isDetailMaximized = false
            columnVisibility = .all
        }
    }

    private func shellEscapeForCD(_ path: String) -> String {
        // Minimal POSIX shell escaping suitable for `cd` arguments
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func startEmbeddedNew(for session: SessionSummary) {
        // Build the 'new session' commands (respecting project profile when present)
        let cwd = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapeForCD(cwd)
        let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
        let exports = "export LANG=zh_CN.UTF-8; export LC_ALL=zh_CN.UTF-8; export LC_CTYPE=zh_CN.UTF-8; export TERM=xterm-256color; export CODEX_DISABLE_COLOR_QUERY=1"
        let invocation = viewModel.buildNewSessionCLIInvocationRespectingProject(session: session)
        let command = "PATH=\(injectedPATH) \(invocation)"
        embeddedInitialCommands[session.id] = cd + "\n" + exports + "\n" + command + "\n"
        runningSessionIDs.insert(session.id)
    }

    private func openPreferredExternal(for session: SessionSummary) {
        viewModel.copyResumeCommands(session: session)
        let app = viewModel.preferences.defaultResumeExternalApp
        let dir = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd
            : session.fileURL.deletingLastPathComponent().path
        switch app {
        case .iterm2:
            let cmd = viewModel.buildResumeCLIInvocation(session: session)
            viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
        case .warp:
            viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
        case .terminal:
            _ = viewModel.openAppleTerminal(at: dir)
        case .none:
            break
        }
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Paste it in the opened terminal.") }
    }

    private func openPreferredExternalForNew(session: SessionSummary) {
        // Record pending intent for auto-assign before launching
        viewModel.recordIntentForDetailNew(anchor: session)
        let app = viewModel.preferences.defaultResumeExternalApp
        let dir = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd
            : session.fileURL.deletingLastPathComponent().path
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
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Paste it in the opened terminal.") }
    }

    private func startNewSession(for session: SessionSummary) {
        viewModel.copyNewSessionCommandsRespectingProject(session: session)
        openPreferredExternalForNew(session: session)
    }

    private func toggleDetailMaximized() {
        withAnimation(.easeInOut(duration: 0.18)) {
            let shouldHide = columnVisibility != .detailOnly
            columnVisibility = shouldHide ? .detailOnly : .all
            isDetailMaximized = shouldHide
        }
    }

    @ViewBuilder
    private func maximizeToggleButton() -> some View {
        Button {
            toggleDetailMaximized()
        } label: {
            Image(systemName: isDetailMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
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

    private func handleExecutableSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            selectingExecutable = false
            guard let url = urls.first else { return }
            viewModel.updateExecutablePath(to: url)
        case .failure(let error):
            selectingExecutable = false
            alertState = AlertState(
                title: "Failed to choose CLI", message: error.localizedDescription)
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "Select a session", systemImage: "rectangle.and.text.magnifyingglass",
            description: Text("Pick a session from the middle list to view details.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Export helper
extension ContentView {
    private func exportMarkdownForFocused() {
        guard let focused = focusedSummary else { return }
        exportMarkdownForSession(focused)
    }

    private func exportMarkdownForSession(_ session: SessionSummary) {
        let loader = SessionTimelineLoader()
        let turns = ((try? loader.load(url: session.fileURL)) ?? []).removingEnvironmentContext()
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
            for event in turn.outputs {
                let prefix: String
                switch event.actor {
                case .assistant: prefix = "**Codex**"
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
        panel.nameFieldStringValue = session.displayName + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? md.data(using: .utf8)?.write(to: url)
        }
    }
}
