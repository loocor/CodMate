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
    @State private var selectingExecutable = false
    // Track which sessions are running in embedded terminal
    @State private var runningSessionIDs = Set<SessionSummary.ID>()
    @State private var isDetailMaximized = false
    @State private var showNewWithContext = false
    // When starting embedded sessions, record the initial command lines per-session
    @State private var embeddedInitialCommands: [SessionSummary.ID: String] = [:]
    // Track pending rekey for embedded New so we can move the PTY to the real new session id
    struct PendingEmbeddedRekey {
        let anchorId: String
        let expectedCwd: String
        let t0: Date
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
            onOpenEmbedded: (viewModel.preferences.defaultResumeUseEmbeddedTerminal
                ? { startEmbedded(for: $0) } : nil),
            onPrimarySelect: { s in selectionPrimaryId = s.id }
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
                        // Left list acts as the terminal switcher across sessions
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
                        .environmentObject(viewModel)
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
                let focused = focusedSummary

                Menu {
                    if let focused {
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
                                        launchNewSession(for: focused, using: sessionSource, style: .preferred)
                                    } label: {
                                        Label("Use Preferred Launch", systemImage: "gearshape")
                                    }
                                    Button {
                                        launchNewSession(for: focused, using: sessionSource, style: .terminal)
                                    } label: {
                                        Label("Open in Terminal", systemImage: "terminal")
                                    }
                                    Button {
                                        launchNewSession(for: focused, using: sessionSource, style: .iterm)
                                    } label: {
                                        Label("Open in iTerm2", systemImage: "app.fill")
                                    }
                                    Button {
                                        launchNewSession(for: focused, using: sessionSource, style: .warp)
                                    } label: {
                                        Label("Open in Warp", systemImage: "app.gift.fill")
                                    }
                                    if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                                        Button {
                                            launchNewSession(for: focused, using: sessionSource, style: .embedded)
                                        } label: {
                                            Label("Open Embedded Terminal", systemImage: "rectangle.badge.plus")
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
                    if let focused {
                        launchNewSession(for: focused, using: focused.source, style: .preferred)
                    }
                }
                .disabled(isPerformingAction || focused == nil)
                .help(
                    focused.map { "Start a new \($0.source.branding.displayName) session" }
                        ?? "Select a session to start new conversations"
                )
                .menuStyle(.borderedButton)
                .controlSize(.small)

                Menu {
                    if let focused {
                        Button {
                            viewModel.copyResumeCommandsRespectingProject(session: focused)
                            _ = viewModel.openAppleTerminal(at: workingDirectory(for: focused))
                            Task {
                                await SystemNotifier.shared.notify(
                                    title: "CodMate",
                                    body: "Command copied. Paste it in the opened terminal.")
                            }
                        } label: {
                            Label("Open in Terminal", systemImage: "terminal")
                        }

                        Button {
                            let dir = workingDirectory(for: focused)
                            let cmd = viewModel.buildResumeCLIInvocationRespectingProject(session: focused)
                            viewModel.openPreferredTerminalViaScheme(
                                app: .iterm2, directory: dir, command: cmd)
                        } label: {
                        Label("Open in iTerm2", systemImage: "app.fill")
                        }

                        Button {
                            viewModel.copyResumeCommandsRespectingProject(session: focused)
                            viewModel.openPreferredTerminalViaScheme(
                                app: .warp, directory: workingDirectory(for: focused))
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
                                startEmbedded(for: focused)
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
                    if let focused {
                        if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                            startEmbedded(for: focused)
                        } else {
                            openPreferredExternal(for: focused)
                        }
                    }
                }
                .disabled(isPerformingAction || focused == nil)
                .help(
                    focused.map { "Resume \($0.source.branding.displayName) session" }
                        ?? "Select a session to resume"
                )
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
                        Task {
                            await SystemNotifier.shared.notify(
                                title: "CodMate", body: "Real command copied")
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy real resume command")
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
        if runningSessionIDs.isEmpty {
            isDetailMaximized = false
            columnVisibility = .all
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

        embeddedInitialCommands[target.id] =
            preclear + "\n" + cd + "\n" + exports + "\n" + command + "\n"
        runningSessionIDs.insert(target.id)
        // Record pending rekey so that when the new session appears, we can move this PTY to the real id
        pendingEmbeddedRekeys.append(
            PendingEmbeddedRekey(
                anchorId: target.id, expectedCwd: canonicalizePath(cwd), t0: Date())
        )
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

// MARK: - Embedded PTY rekey helpers
extension ContentView {
    private func canonicalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
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
                if selection.contains(pending.anchorId) {
                    selection = [winner.id]
                }
            } else {
                if now.timeIntervalSince(pending.t0) < 180 { remaining.append(pending) }
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
    private func sanitizedExportFileName(_ s: String, fallback: String, maxLength: Int = 120) -> String {
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
        if text.count > maxLength { let idx = text.index(text.startIndex, offsetBy: maxLength); text = String(text[..<idx]) }
        return text
    }
}
