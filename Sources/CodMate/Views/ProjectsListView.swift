import SwiftUI
import AppKit

struct ProjectsListView: View {
    @EnvironmentObject private var viewModel: SessionListViewModel
    @State private var editingProject: Project? = nil
    @State private var showEdit = false

    var body: some View {
        let counts = viewModel.projectCountsFromNotes()
        let items = viewModel.projects.sorted(by: { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending })

        return List(selection: Binding(get: { viewModel.selectedProjectId }, set: { viewModel.setSelectedProject($0) })) {
            if items.isEmpty {
                ContentUnavailableView("No Projects", systemImage: "square.grid.2x2")
            } else {
                ForEach(items) { p in
                    ProjectRow(
                        project: p,
                        displayName: displayName(p),
                        count: counts[p.id] ?? 0,
                        onNewSession: { viewModel.openNewSession(project: p) }
                    )
                    .tag(Optional.some(p.id))
                    .listRowInsets(EdgeInsets())
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.setSelectedProject(p.id) }
                    .contextMenu {
                        Button { viewModel.openNewSession(project: p) } label: {
                            Label("New Session in Project", systemImage: "plus")
                        }
                        Button { editingProject = p; showEdit = true } label: {
                            Label("Edit Project / Property", systemImage: "pencil")
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        let ids = items.flatMap { $0.split(separator: "\n").map(String.init) }
                        Task { await viewModel.assignSessions(to: p.id, ids: ids) }
                        return true
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 16)
        .environment(\.controlSize, .small)
        .sheet(isPresented: $showEdit) {
            if let project = editingProject {
                ProjectEditorSheet(isPresented: $showEdit, mode: .edit(existing: project))
                    .environmentObject(viewModel)
            }
        }
    }

    private func displayName(_ p: Project) -> String {
        if !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return p.name }
        let base = URL(fileURLWithPath: p.directory, isDirectory: true).lastPathComponent
        return base.isEmpty ? p.id : base
    }
}

private struct ProjectRow: View {
    let project: Project
    let displayName: String
    let count: Int
    var onNewSession: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(displayName)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Button(action: onNewSession) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("New Session in Project")
        }
        .frame(height: 16)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
    }
}

struct ProjectEditorSheet: View {
    enum Mode { case new, edit(existing: Project) }
    @EnvironmentObject private var viewModel: SessionListViewModel
    @Binding var isPresented: Bool
    let mode: Mode

    @State private var name: String = ""
    @State private var directory: String = ""
    @State private var trustLevel: String = ""
    @State private var overview: String = ""
    @State private var instructions: String = ""
    @State private var profileId: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(modeTitle).font(.title3).fontWeight(.semibold)

            TabView {
                Tab("General", systemImage: "gearshape") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Name").font(.subheadline)
                            TextField("Display name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 320)
                        }
                        GridRow {
                            Text("Directory").font(.subheadline)
                            HStack(spacing: 8) {
                                TextField("/absolute/path", text: $directory)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose…") { chooseDirectory() }
                            }
                        }
                    }
                }
                Tab("Details", systemImage: "info.circle") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Trust Level").font(.subheadline)
                            TextField("trusted | untrusted", text: $trustLevel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                        GridRow {
                            Text("Overview").font(.subheadline)
                            TextField("Short description", text: $overview, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 360)
                        }
                    }
                }
                Tab("Instructions", systemImage: "text.alignleft") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default instructions for new sessions").font(.subheadline)
                        TextEditor(text: $instructions)
                            .font(.body)
                            .frame(minHeight: 220)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    }
                }
                Tab("Profile", systemImage: "person.crop.square") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Profile ID").font(.subheadline)
                            TextField("optional-profile-id", text: $profileId)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }
                        Text("Profiles 是对 Codex configuration 的命名封装，可在 Codex Settings 中配置。这里填入 profile 的标识即可复用相应运行模式。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 4)

            HStack {
                if case .edit(let p) = mode {
                    Text("ID: \(p.id)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                Button(primaryActionTitle) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear(perform: load)
    }

    private var modeTitle: String { if case .edit = mode { return "Edit Project" } else { return "New Project" } }
    private var primaryActionTitle: String { if case .edit = mode { return "Save" } else { return "Create" } }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    private func load() {
        if case .edit(let p) = mode {
            name = p.name
            directory = p.directory
            trustLevel = p.trustLevel ?? ""
            overview = p.overview ?? ""
            instructions = p.instructions ?? ""
            profileId = p.profileId ?? ""
        }
    }

    private func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789-"
        var out = lower.map { ch -> Character in
            if allowed.contains(ch) { return ch }
            if ch.isLetter || ch.isNumber { return "-" }
            return "-"
        }
        var str = String(out)
        while str.contains("--") { str = str.replacingOccurrences(of: "--", with: "-") }
        str = str.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return str.isEmpty ? "project" : str
    }

    private func generateId() -> String {
        let baseName: String = {
            let n = name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { return n }
            let base = URL(fileURLWithPath: directory, isDirectory: true).lastPathComponent
            return base.isEmpty ? "project" : base
        }()
        var candidate = slugify(baseName)
        let existing = Set(viewModel.projects.map(\.id))
        var i = 1
        while existing.contains(candidate) {
            i += 1
            candidate = slugify(baseName) + "-\(i)"
        }
        return candidate
    }

    private func save() {
        let trust = trustLevel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : trustLevel
        let ov = overview.trimmingCharacters(in: .whitespaces).isEmpty ? nil : overview
        let instr = instructions.trimmingCharacters(in: .whitespaces).isEmpty ? nil : instructions
        let profile = profileId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : profileId

        switch mode {
        case .new:
            let id = generateId()
            let p = Project(id: id, name: (name.isEmpty ? id : name), directory: directory, trustLevel: trust, overview: ov, instructions: instr, profileId: profile)
            Task { await viewModel.configServiceUpsert(project: p); await viewModel.loadProjects(); isPresented = false }
        case .edit(let old):
            let p = Project(id: old.id, name: name, directory: directory, trustLevel: trust, overview: ov, instructions: instr, profileId: profile)
            Task { await viewModel.configServiceUpsert(project: p); await viewModel.loadProjects(); isPresented = false }
        }
    }
}
