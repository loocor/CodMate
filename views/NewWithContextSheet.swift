import SwiftUI
import AppKit

struct NewWithContextSheet: View {
    @EnvironmentObject private var viewModel: SessionListViewModel
    @Binding var isPresented: Bool
    let anchor: SessionSummary

    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    @State private var selectedIDs = Set<String>()
    @State private var options = TreeshakeOptions()
    @State private var previewText: String = ""
    @State private var showPreview: Bool = false
    private let treeshaker = ContextTreeshaker()
    @State private var previewTask: Task<Void, Never>? = nil
    @State private var escMonitor: Any? = nil
    @State private var selectedSource: SessionSource? = nil
    @State private var includeSessionExcerpts: Bool = true
    @State private var includeProjectInstructions: Bool = false
    @State private var selectedProjectId: String? = nil
    @State private var additionalInstructions: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowConfigurator { window in
                window.isMovableByWindowBackground = true
                window.styleMask.insert(.resizable)
                var min = window.contentMinSize; min.width = max(min.width, 760); min.height = max(min.height, 420); window.contentMinSize = min
                var maxS = window.contentMaxSize; if maxS.width <= 0 { maxS.width = 2000 } ; if maxS.height <= 0 { maxS.height = 1400 } ; window.contentMaxSize = maxS
            }
            .frame(width: 0, height: 0)
            HStack {
                Text("New Session With Context")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Button { /* TODO: help */ } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .help("Help")
            }

            HStack(alignment: .top, spacing: 12) {
                leftSessionPicker
                rightOptionsAndPreview
            }

            HStack {
                Button("Close") { isPresented = false }
                Spacer()
                Button {
                    copyOnly()
                } label: {
                    Label("Copy Markdown", systemImage: "doc.on.doc")
                }
                Button {
                    copyOpenNew()
                } label: {
                    Label("Start With Context", systemImage: "plus")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 960, idealWidth: 1024, maxWidth: .infinity,
               minHeight: 540, idealHeight: 680, maxHeight: .infinity)
        .padding(16)
        .task { await initialDefaults() }
        .onAppear {
            viewModel.cancelHeavyWork()
            // Default focus to the left search field
            DispatchQueue.main.async { self.searchFocused = true }
            // Intercept ESC to cancel heavy work without closing the sheet
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // ESC
                    cancelHeavyWork()
                    return nil // swallow event
                }
                return event
            }
        }
        .onDisappear {
            cancelHeavyWork()
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
        .onChange(of: selectedIDs) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: options.mergeConsecutiveAssistant) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: options.includeReasoning) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: options.includeToolSummary) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: options.maxMessageBytes) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: viewModel.preferences.markdownVisibleKinds) { _, _ in if showPreview { schedulePreview() } }
    }

    private var leftSessionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                searchField
            }

            List {
                ForEach(filteredSessions(), id: \.id) { s in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { selectedIDs.contains(s.id) },
                            set: { checked in
                                if checked { selectedIDs.insert(s.id) } else { selectedIDs.remove(s.id) }
                            }
                        ))
                        .labelsHidden()

                        Text(s.effectiveTitle)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(s.startedAt.formatted(date: .numeric, time: .shortened))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(s.id)
                }
            }
            .environment(\.defaultMinListRowHeight, 40)
            .environment(\.controlSize, .regular)
            .listStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        }
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
    }

    private var rightOptionsAndPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Provider picker (no title, right aligned)
                    HStack {
                        Spacer(minLength: 0)
                        Picker("Provider", selection: Binding(get: {
                            selectedSource ?? .codex
                        }, set: { newVal in
                            selectedSource = newVal
                        })) {
                            Text("Codex").tag(SessionSource.codex)
                            Text("Claude Code").tag(SessionSource.claude)
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 240, alignment: .trailing)
                    }
                    Divider()
                    Toggle("Include selected session excerpts", isOn: $includeSessionExcerpts)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Toggle("Include project instructions", isOn: $includeProjectInstructions)
                        Spacer(minLength: 12)
                        if includeProjectInstructions {
                            Picker("Project", selection: Binding(get: {
                                selectedProjectId ?? viewModel.projectIdForSession(anchor.id)
                            }, set: { newVal in
                                selectedProjectId = newVal
                                schedulePreview()
                            })) {
                                ForEach(viewModel.projects, id: \.id) { p in
                                    Text(p.name).tag(Optional(p.id))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240, alignment: .trailing)
                        }
                    }
                    // Removed inline project instructions preview per design — keep UI compact.
                    Divider()
                    // Preview configuration (merged into same card)
                    Toggle("Merge consecutive assistant replies", isOn: $options.mergeConsecutiveAssistant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Toggle("Include reasoning (off by default)", isOn: $options.includeReasoning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Toggle("Include tool result summary", isOn: $options.includeToolSummary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text("Max message size (KB)")
                            .frame(width: 170, alignment: .trailing)
                        Slider(
                            value: Binding(
                                get: { Double(options.maxMessageBytes) / 1024.0 },
                                set: { options.maxMessageBytes = max(1024, Int($0 * 1024)) }
                            ), in: 1...16
                        )
                        .frame(maxWidth: .infinity)
                        Text("\(options.maxMessageBytes / 1024)KB")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Toggle("Show preview", isOn: $showPreview)
                            .controlSize(.small)
                            .onChange(of: showPreview) { _, on in if on { schedulePreview() } }
                        Spacer()
                        if !showPreview {
                            Text("Preview is off. Copy works; toggle to enable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if showPreview {
                        ScrollView {
                            Text(previewText.isEmpty ? "Preview will appear here" : previewText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(previewText.isEmpty ? .tertiary : .primary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // keep space to fill remaining height when preview is off
                        Spacer(minLength: 0)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        )
        .frame(maxWidth: .infinity)
    }

    private func filteredSessions() -> [SessionSummary] {
        // Source from the full project set, not the middle-list sections (which are date-scoped)
        let all = viewModel.allSessionsInSameProject(as: anchor)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = all.filter { s in
            if q.isEmpty { return true }
            return s.matches(search: q)
        }
        return filtered.sorted { a, b in
            let da = a.lastUpdatedAt ?? a.startedAt
            let db = b.lastUpdatedAt ?? b.startedAt
            return da > db  // recent first
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        // Capture inputs on MainActor
        let ids = selectedIDs
        let opt = options
        let kinds = viewModel.preferences.markdownVisibleKinds
        let all = viewModel.allSessionsInSameProject(as: anchor)
        let lookup = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let takeSessions = includeSessionExcerpts
        let sessions = takeSessions ? ids.compactMap { lookup[$0] }.sorted { $0.startedAt < $1.startedAt } : []
        let takeProject = includeProjectInstructions
        let pid = selectedProjectId ?? viewModel.projectIdForSession(anchor.id)
        let projectInstructions: String? = {
            guard takeProject, let pid = pid,
                  let p = viewModel.projects.first(where: { $0.id == pid }),
                  let instr = p.instructions, !instr.isEmpty else { return nil }
            return instr
        }()

        previewTask = Task.detached { [treeshaker] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            var parts: [String] = []
            if takeSessions, !sessions.isEmpty {
                var use = opt
                use.visibleKinds = kinds
                if !(kinds.contains(.reasoning)) { use.includeReasoning = false }
                if !(kinds.contains(.infoOther)) { use.includeToolSummary = false }
                let text = await treeshaker.generateMarkdown(for: sessions, options: use)
                if !text.isEmpty { parts.append(text) }
            }
            if let instr = projectInstructions { parts.append("Project Instructions:\n\n" + instr) }
            if Task.isCancelled { return }
            let output = parts.joined(separator: "\n\n---\n\n")
            await MainActor.run { self.previewText = output }
        }
    }

    private func cancelHeavyWork() {
        previewTask?.cancel()
        previewTask = nil
    }

    private func copyOnly() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(previewText, forType: .string)
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Slim markdown copied.") }
    }

    private func copyOpenNew() {
        // Record pending intent for auto-assign
        let chosenSource = selectedSource ?? anchor.source
        let chosen = (chosenSource == anchor.source) ? anchor : anchor.overridingSource(chosenSource)
        viewModel.recordIntentForDetailNew(anchor: chosen)
        let prompt = previewText
        let dir = FileManager.default.fileExists(atPath: chosen.cwd) ? chosen.cwd : chosen.fileURL.deletingLastPathComponent().path
        let app = viewModel.preferences.defaultResumeExternalApp
        switch app {
        case .iterm2:
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: chosen, initialPrompt: prompt)
            // Copy full command for visibility and shareability
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
            viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
        case .warp:
            // Warp cannot execute a command via URL; open tab at path and copy command for the user to paste.
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: chosen, initialPrompt: prompt)
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
            viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
        case .terminal:
            // Apple Terminal via AppleScript: run with PATH/env/profile + initial prompt
            viewModel.openNewSessionRespectingProject(session: chosen, initialPrompt: prompt)
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: chosen, initialPrompt: prompt)
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
        case .none:
            // Fallback: open Terminal at dir and copy command
            _ = viewModel.openAppleTerminal(at: dir)
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: chosen, initialPrompt: prompt)
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
        }
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Session starts with provided context.") }
    }

    private func initialDefaults() async {
        // Default to same project filter; do not preselect to avoid heavy preview on open
        selectedIDs = []
        selectedSource = .codex
        selectedProjectId = viewModel.projectIdForSession(anchor.id)
    }
}
