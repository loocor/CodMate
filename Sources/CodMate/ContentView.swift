import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: SessionListViewModel

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var navigationSelection: SessionNavigationItem
    @State private var selection = Set<SessionSummary.ID>()
    @State private var isPerformingAction = false
    @State private var deleteConfirmationPresented = false
    @State private var alertState: AlertState?
    @State private var resumeOutput: String?
    @State private var selectingSessionsRoot = false
    @State private var selectingExecutable = false

    init(viewModel: SessionListViewModel) {
        self.viewModel = viewModel
        _navigationSelection = State(initialValue: viewModel.navigationSelection)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionNavigationView(
                selection: navSelectionBinding,
                totalCount: viewModel.totalSessionCount,
                isLoading: viewModel.isLoading
            )
            .environmentObject(viewModel)
            .frame(minWidth: 220)
        } content: {
            SessionListColumnView(
                sections: viewModel.sections,
                selection: $selection,
                sortOrder: $viewModel.sortOrder,
                isLoading: viewModel.isLoading,
                onResume: resumeFromList,
                onReveal: { viewModel.reveal(session: $0) },
                onDeleteRequest: handleDeleteRequest
            )
            .frame(minWidth: 320)
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
            alertState = AlertState(title: "操作失败", message: message)
            viewModel.errorMessage = nil
        }
        .onChange(of: navigationSelection) { _, newValue in
            if viewModel.navigationSelection != newValue {
                viewModel.navigationSelection = newValue
            }
        }
        .onChange(of: viewModel.navigationSelection) { _, newValue in
            if navigationSelection != newValue {
                navigationSelection = newValue
            }
        }
        .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: Text("搜索会话"))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await viewModel.refreshSessions() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise.circle.fill")
                }
                .controlSize(.large)
                .help("刷新会话索引")
            }
        }
        .alert(item: $alertState) { state in
            Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("好的"))
            )
        }
        .alert("确认删除所选会话？", isPresented: $deleteConfirmationPresented, presenting: Array(selection)) { ids in
            Button("取消", role: .cancel) {}
            Button("移至废纸篓", role: .destructive) {
                deleteSelections(ids: ids)
            }
        } message: { _ in
            Text("会话文件将被移至废纸篓，可在 Finder 中恢复。")
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
            if let output = resumeOutput {
                ToastView(text: output) {
                    withAnimation {
                        resumeOutput = nil
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private var navSelectionBinding: Binding<SessionNavigationItem> {
        Binding(
            get: { navigationSelection },
            set: { newValue in
                navigationSelection = newValue
                viewModel.navigationSelection = newValue
            }
        )
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
                    SessionDetailView(
                        summary: focused,
                        isProcessing: isPerformingAction,
                        onResume: { resume(session: focused) },
                        onReveal: { viewModel.reveal(session: focused) },
                        onDelete: presentDeleteConfirmation
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    placeholder
                }
            }
        }
    }

    private var detailActionBar: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                if let focused = focusedSummary { resume(session: focused) }
            } label: {
                Label("恢复", systemImage: "play.fill")
            }
            .disabled(isPerformingAction || focusedSummary == nil)
            
            Button {
                if let focused = focusedSummary { viewModel.reveal(session: focused) }
            } label: {
                Label("访达中查看", systemImage: "folder")
            }
            .disabled(focusedSummary == nil)

            Button(role: .destructive) {
                presentDeleteConfirmation()
            } label: {
                Label("删除会话", systemImage: "trash")
            }
            .disabled(selection.isEmpty || isPerformingAction)

            Button {
                exportMarkdownForFocused()
            } label: {
                Label("导出 Markdown", systemImage: "square.and.arrow.down")
            }
            .disabled(focusedSummary == nil)
        }
        .buttonStyle(.bordered)
    }

    private var focusedSummary: SessionSummary? {
        guard !selection.isEmpty else {
            return viewModel.sections.first?.sessions.first
        }

        let allSummaries = summaryLookup
        return selection
            .compactMap { allSummaries[$0] }
            .sorted { lhs, rhs in
                (lhs.lastUpdatedAt ?? lhs.startedAt) > (rhs.lastUpdatedAt ?? rhs.startedAt)
            }
            .first
    }

    private var summaryLookup: [SessionSummary.ID: SessionSummary] {
        Dictionary(uniqueKeysWithValues: viewModel.sections
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
        resume(session: session)
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

    private func resume(session: SessionSummary) {
        guard !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            let result = await viewModel.resume(session: session)
            await MainActor.run {
                isPerformingAction = false
                switch result {
                case let .success(processResult):
                    resumeOutput = processResult.output.isEmpty ? "会话已恢复。" : processResult.output
                    Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        await MainActor.run {
                            withAnimation {
                                resumeOutput = nil
                            }
                        }
                    }
                case let .failure(error):
                    alertState = AlertState(title: "恢复失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func handleFolderSelection(
        result: Result<[URL], Error>,
        update: @escaping (URL) async -> Void
    ) {
        switch result {
        case let .success(urls):
            selectingSessionsRoot = false
            guard let url = urls.first else { return }
            Task { await update(url) }
        case let .failure(error):
            selectingSessionsRoot = false
            alertState = AlertState(title: "选择目录失败", message: error.localizedDescription)
        }
    }

    private func handleExecutableSelection(result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            selectingExecutable = false
            guard let url = urls.first else { return }
            viewModel.updateExecutablePath(to: url)
        case let .failure(error):
            selectingExecutable = false
            alertState = AlertState(title: "选择 CLI 失败", message: error.localizedDescription)
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("选择一个会话", systemImage: "rectangle.and.text.magnifyingglass", description: Text("从中间列表中选择一个会话查看详细信息。"))
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
        let loader = SessionTimelineLoader()
        let events = (try? loader.load(url: focused.fileURL)) ?? []
        var lines: [String] = []
        lines.append("# \(focused.displayName)")
        lines.append("")
        lines.append("- 开始时间：\(focused.startedAt)")
        if let end = focused.lastUpdatedAt { lines.append("- 最后更新：\(end)") }
        if let model = focused.model { lines.append("- 模型：\(model)") }
        if let approval = focused.approvalPolicy { lines.append("- 审批策略：\(approval)") }
        lines.append("")
        for e in events {
            let prefix: String
            switch e.actor { case .user: prefix = "**用户**"; case .assistant: prefix = "**助手**"; case .tool: prefix = "**工具**"; case .info: prefix = "**信息**" }
            lines.append("\(prefix) · \(e.timestamp)\n")
            if let title = e.title { lines.append("> \(title)") }
            if let text = e.text, !text.isEmpty { lines.append(text) }
            if let meta = e.metadata, !meta.isEmpty { lines.append(""); for k in meta.keys.sorted() { lines.append("- \(k): \(meta[k] ?? "")") } }
            lines.append("")
        }
        let md = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.title = "导出 Markdown"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = focused.displayName + ".md"
        if panel.runModal() == .OK, let url = panel.url { try? md.data(using: .utf8)?.write(to: url) }
    }
}
