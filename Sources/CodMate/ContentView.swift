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
    @State private var resumeOutput: String?
    @State private var selectingSessionsRoot = false
    @State private var selectingExecutable = false
    // Track which sessions are running in embedded terminal
    @State private var runningSessionIDs = Set<SessionSummary.ID>()
    @State private var isDetailMaximized = false
    // Expose a common font helper to feed TerminalHostView
    private func makeTerminalFont(size: CGFloat) -> NSFont {
        #if canImport(SwiftTerm)
        // Reuse the same logic as EmbeddedTerminalView
        let candidates = [
            "Sarasa Mono SC", "Sarasa Term SC",
            "LXGW WenKai Mono",
            "Noto Sans Mono CJK SC", "NotoSansMonoCJKsc-Regular",
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
            await viewModel.refreshSessions()
        }
        .onChange(of: viewModel.sections) { _, _ in
            normalizeSelection()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            alertState = AlertState(title: "Operation Failed", message: message)
            viewModel.errorMessage = nil
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                toolbarContent
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
        .overlay(alignment: .bottom) {
            toastOverlay
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
            onOpenEmbedded: { startEmbedded(for: $0) }
        )
        .environmentObject(viewModel)
        .navigationSplitViewColumnWidth(min: 420, ideal: 480, max: 600)
        .sheet(item: $viewModel.editingSession, onDismiss: { viewModel.cancelEdits() }) { _ in
            EditSessionMetaView(viewModel: viewModel)
        }
    }
    
    private var toolbarContent: some View {
        HStack(spacing: 12) {
            TextField("Search Sessions", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)

            Button {
                Task { await viewModel.refreshSessions() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh session index")
        }
        .padding(.horizontal, 4)
    }
    
    @ViewBuilder
    private var toastOverlay: some View {
        if let output = resumeOutput {
            ToastView(text: output) {
                withAnimation {
                    resumeOutput = nil
                }
            }
            .padding(.bottom, 20)
        }
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
                                             initialCommands: viewModel.buildResumeCommands(session: focused),
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

                            // NOTE: 终端最大化/还原按钮暂时隐藏，待折叠逻辑完善后恢复显示
                            // maximizeToggleButton()
                            //     .padding(.top, 18)
                            //     .padding(.trailing, 18)
                            //     .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 2)
                        }
                    } else {
                        SessionDetailView(
                            summary: focused,
                            isProcessing: isPerformingAction,
                            onResume: { startEmbedded(for: focused) },
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
                Button(action: { Task { await viewModel.beginEditing(session: focused) } }) {
                    Text(focused.effectiveTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rename / Add Comment")
            }

            Spacer()

            HStack(spacing: 8) {
                Menu {
                    // 1) Terminal (copy + open at path)
                    Button {
                        if let f = focusedSummary {
                            let dir = FileManager.default.fileExists(atPath: f.cwd) ? f.cwd : f.fileURL.deletingLastPathComponent().path
                            viewModel.copyResumeCommands(session: f)
                            _ = viewModel.openAppleTerminal(at: dir)
                            Task { await SystemNotifier.shared.notify(title: "CodMate", body: "命令已拷贝，请粘贴到打开的终端") }
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
                            Task { await SystemNotifier.shared.notify(title: "CodMate", body: "命令已拷贝，请粘贴到打开的终端") }
                        }
                    } label: { Label("Open in Warp (Path)", systemImage: "app.gift.fill") }

                    // Alpha: embedded terminal
                    Button {
                        if let f = focusedSummary { startEmbedded(for: f) }
                    } label: { Label("Open Embedded Terminal (Alpha)", systemImage: "rectangle.badge.plus") }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                } primaryAction: {
                    if let f = focusedSummary {
                        viewModel.copyResumeCommands(session: f)
                        resumeOutput = "Commands copied to clipboard"
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
                        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "真实命令已拷贝") }
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
        let validIDs = Set(viewModel.sections.flatMap { $0.sessions.map(\.id) })
        selection.formIntersection(validIDs)
        if selection.isEmpty, let first = validIDs.first {
            selection.insert(first)
        }
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
        runningSessionIDs.insert(session.id)
    }

    private func stopEmbedded(forID id: SessionSummary.ID) {
        runningSessionIDs.remove(id)
        if runningSessionIDs.isEmpty {
            isDetailMaximized = false
            columnVisibility = .all
        }
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
        default:
            viewModel.openPreferredTerminal(app: app)
        }
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "命令已拷贝，请粘贴到打开的终端") }
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
        let events = (try? loader.load(url: session.fileURL)) ?? []
        var lines: [String] = []
        lines.append("# \(session.displayName)")
        lines.append("")
        lines.append("- Started: \(session.startedAt)")
        if let end = session.lastUpdatedAt { lines.append("- Last Updated: \(end)") }
        if let model = session.model { lines.append("- Model: \(model)") }
        if let approval = session.approvalPolicy { lines.append("- Approval Policy: \(approval)") }
        lines.append("")
        for e in events {
            let prefix: String
            switch e.actor {
            case .user: prefix = "**User**"
            case .assistant: prefix = "**Assistant**"
            case .tool: prefix = "**Tool**"
            case .info: prefix = "**Info**"
            }
            lines.append("\(prefix) · \(e.timestamp)\n")
            if let title = e.title { lines.append("> \(title)") }
            if let text = e.text, !text.isEmpty { lines.append(text) }
            if let meta = e.metadata, !meta.isEmpty {
                lines.append("")
                for k in meta.keys.sorted() { lines.append("- \(k): \(meta[k] ?? "")") }
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
