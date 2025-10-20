import SwiftUI
import AppKit

struct NewWithContextSheet: View {
    @EnvironmentObject private var viewModel: SessionListViewModel
    @Binding var isPresented: Bool
    let anchor: SessionSummary

    @State private var searchText: String = ""
    @State private var selectedIDs = Set<String>()
    @State private var options = TreeshakeOptions()
    @State private var previewText: String = ""
    @State private var showPreview: Bool = false
    private let treeshaker = ContextTreeshaker()
    @State private var previewTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Button("Cancel") { cancelHeavyWork() }
                    .keyboardShortcut(.cancelAction)
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
        .frame(width: 860, height: 540)
        .padding(16)
        .task { await initialDefaults() }
        .onAppear { viewModel.cancelHeavyWork() }
        .onDisappear { cancelHeavyWork() }
        .onChange(of: selectedIDs) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: options.mergeConsecutiveAssistant) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: options.includeReasoning) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: options.includeToolSummary) { _, _ in if showPreview { schedulePreview() } }
        .onChange(of: options.maxMessageBytes) { _, _ in if showPreview { schedulePreview() } }
    }

    private var leftSessionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                searchField
            }

            List(selection: Binding(get: { selectedIDs }, set: { selectedIDs = $0 })) {
                ForEach(filteredSessions(), id: \.id) { s in
                    HStack(spacing: 8) {
                        Text(s.effectiveTitle).lineLimit(1)
                        Spacer()
                        Text(s.startedAt, style: .date)
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
                    .tag(s.id)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSelection(s.id) }
                }
            }
            .environment(\.defaultMinListRowHeight, 40)
            .environment(\.controlSize, .regular)
            .listStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        }
        .frame(width: 360)
    }

    private var rightOptionsAndPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
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
                        Slider(value: Binding(get: { Double(options.maxMessageBytes) / 1024.0 }, set: { options.maxMessageBytes = max(1024, Int($0 * 1024)) }), in: 1...32)
                        Text("\(options.maxMessageBytes / 1024)KB").monospacedDigit()
                            .frame(width: 64, alignment: .leading)
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
                .frame(width: 160)
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
    }

    private func filteredSessions() -> [SessionSummary] {
        let all = viewModel.sections.flatMap { $0.sessions }
        let pid = viewModel.projectIdForSession(anchor.id)
        let filtered = all.filter { s in
            if let pid, viewModel.projectIdForSession(s.id) != pid { return false }
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            return s.matches(search: searchText)
        }
        return filtered.sorted { ($0.startedAt) < ($1.startedAt) }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let ids = selectedIDs
        let opt = options
        let all = viewModel.sections.flatMap { $0.sessions }
        let lookup = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let sessions = ids.compactMap { lookup[$0] }.sorted { $0.startedAt < $1.startedAt }
        previewTask = Task.detached { [treeshaker] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            if Task.isCancelled { return }
            let text = await treeshaker.generateMarkdown(for: sessions, options: opt)
            if Task.isCancelled { return }
            await MainActor.run { self.previewText = text }
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
        let prompt = previewText
        let dir = FileManager.default.fileExists(atPath: anchor.cwd) ? anchor.cwd : anchor.fileURL.deletingLastPathComponent().path
        let app = viewModel.preferences.defaultResumeExternalApp
        switch app {
        case .iterm2:
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: anchor, initialPrompt: prompt)
            // Copy full command for visibility and shareability
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
            viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
        case .warp:
            // Warp cannot execute a command via URL; open tab at path and copy command for the user to paste.
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: anchor, initialPrompt: prompt)
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
            viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
        case .terminal:
            // Apple Terminal via AppleScript: run with PATH/env/profile + initial prompt
            viewModel.openNewSessionRespectingProject(session: anchor, initialPrompt: prompt)
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: anchor, initialPrompt: prompt)
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
        case .none:
            // Fallback: open Terminal at dir and copy command
            _ = viewModel.openAppleTerminal(at: dir)
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: anchor, initialPrompt: prompt)
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(cmd + "\n", forType: .string)
        }
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Session starts with provided context.") }
    }

    private func initialDefaults() async {
        // Default to same project filter; do not preselect to avoid heavy preview on open
        selectedIDs = []
    }
}
