import SwiftUI
import AppKit

struct ProjectsListView: View {
    @EnvironmentObject private var viewModel: SessionListViewModel
    @State private var editingProject: Project? = nil
    @State private var showEdit = false
    @State private var showNewProject = false
    @State private var newParentProject: Project? = nil
    @State private var pendingDelete: Project? = nil
    @State private var showDeleteConfirm = false

    var body: some View {
        let countsDisplay = viewModel.projectCountsDisplay()
        let tree = buildProjectTree(viewModel.projects)
        let selectionBinding: Binding<String?> = Binding<String?>(
            get: { viewModel.selectedProjectId },
            set: { viewModel.setSelectedProject($0) }
        )

        return List(selection: selectionBinding) {
            if tree.isEmpty {
                ContentUnavailableView("No Projects", systemImage: "square.grid.2x2")
            } else {
                OutlineGroup(tree, children: \.children) { node in
                    let p = node.project
                    let pair = countsDisplay[p.id] ?? (visible: 0, total: 0)
                    ProjectRow(
                        project: p,
                        displayName: displayName(p),
                        visible: pair.visible,
                        total: pair.total,
                        onNewSession: { viewModel.newSession(project: p) },
                        onEdit: { editingProject = p; showEdit = true },
                        onDelete: { pendingDelete = p; showDeleteConfirm = true }
                    )
                    .tag(Optional.some(p.id))
                    .listRowInsets(EdgeInsets())
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editingProject = p; showEdit = true }
                    .onTapGesture { viewModel.setSelectedProject(p.id) }
                    .contextMenu {
                        Button { viewModel.newSession(project: p) } label: {
                            Label("New Session", systemImage: "plus")
                        }
                        Button {
                            newParentProject = p
                            showNewProject = true
                        } label: {
                            Label("New Subproject", systemImage: "plus.square.on.square")
                        }
                        Divider()

                        // Open in Editor submenu
                        Menu {
                            ForEach(EditorApp.allCases) { editor in
                                Button {
                                    viewModel.openProjectInEditor(p, using: editor)
                                } label: {
                                    HStack {
                                        Label(editor.title, systemImage: "chevron.left.forwardslash.chevron.right")
                                        if !editor.isInstalled {
                                            Text("(Not Installed)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(!editor.isInstalled)
                            }
                        } label: {
                            Label("Open in", systemImage: "arrow.up.forward.app")
                        }
                        .disabled(p.directory == nil || p.directory?.isEmpty == true)

                        Button {
                            viewModel.revealProjectDirectory(p)
                        } label: {
                            Label("Reveal in Finder", systemImage: "finder")
                        }
                        .disabled(p.directory == nil || p.directory?.isEmpty == true)

                        Button { editingProject = p; showEdit = true } label: {
                            Label("Edit Project / Property", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            // Route through the same confirmation flow used by the row action menu
                            pendingDelete = p
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Project", systemImage: "trash")
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        let all = items.flatMap { $0.split(separator: "\n").map(String.init) }
                        let ids = Array(Set(all))
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
        .sheet(isPresented: $showNewProject) {
            ProjectEditorSheet(
                isPresented: $showNewProject,
                mode: .new,
                prefill: ProjectEditorSheet.Prefill(
                    name: nil,
                    directory: newParentProject?.directory,
                    trustLevel: nil,
                    overview: nil,
                    instructions: nil,
                    profileId: nil,
                    parentId: newParentProject?.id
                )
            )
            .environmentObject(viewModel)
        }
        .confirmationDialog(
            "Delete project?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { prj in
            let hasChildren = viewModel.projects.contains { $0.parentId == prj.id }
            if hasChildren {
                Button("Delete Project and Subprojects", role: .destructive) {
                    Task { await viewModel.deleteProjectCascade(id: prj.id) }
                    pendingDelete = nil
                }
                Button("Move Subprojects to Top Level") {
                    Task { await viewModel.deleteProjectMoveChildrenUp(id: prj.id) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } else {
                Button("Delete", role: .destructive) {
                    Task { await viewModel.deleteProject(id: prj.id) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        } message: { prj in
            Text("Sessions remain intact. This only removes the project record. This action cannot be undone.")
        }
    }

    private func displayName(_ p: Project) -> String {
        if !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return p.name }
        if let dir = p.directory, !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = URL(fileURLWithPath: dir, isDirectory: true).lastPathComponent
            return base.isEmpty ? p.id : base
        }
        return p.id
    }
}

private struct ProjectRow: View {
    let project: Project
    let displayName: String
    let visible: Int
    let total: Int
    var onNewSession: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(displayName)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            let showCount = (visible > 0) || (total > 0)
            if showCount {
                Text("\(visible)/\(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 16)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .padding(.leading, 8)
    }
}

struct ProjectEditorSheet: View {
    enum Mode { case new, edit(existing: Project) }
    @EnvironmentObject private var viewModel: SessionListViewModel
    @Binding var isPresented: Bool
    let mode: Mode
    struct Prefill: Sendable {
        var name: String?
        var directory: String?
        var trustLevel: String?
        var overview: String?
        var instructions: String?
        var profileId: String?
        var parentId: String?
    }
    var prefill: Prefill? = nil
    var autoAssignSessionIDs: [String]? = nil
    @State private var showCloseConfirm = false
    @State private var original: Snapshot? = nil

    @State private var name: String = ""
    @State private var directory: String = ""
    @State private var trustLevel: String = ""
    @State private var overview: String = ""
    @State private var instructions: String = ""
    @State private var profileId: String = ""
    @State private var profileModel: String? = nil
    @State private var profileSandbox: SandboxMode? = nil
    @State private var profileApproval: ApprovalPolicy? = nil
    @State private var profileFullAuto: Bool? = nil
    @State private var profileDangerBypass: Bool? = nil
    @State private var profilePathPrependText: String = ""
    @State private var profileEnvText: String = ""
    @State private var parentProjectId: String? = nil
    @State private var sources: Set<ProjectSessionSource> = ProjectSessionSource.allSet

    private struct Snapshot: Equatable {
        var name: String
        var directory: String
        var trustLevel: String
        var overview: String
        var instructions: String
        var profileModel: String?
        var profileSandbox: SandboxMode?
        var profileApproval: ApprovalPolicy?
        var profileFullAuto: Bool?
        var profileDangerBypass: Bool?
        var profilePathPrependText: String
        var profileEnvText: String
        var parentProjectId: String?
        var sources: Set<ProjectSessionSource>
    }

    // Unified layout constants for aligned labels/fields across tabs
    private let labelColWidth: CGFloat = 120
    private let fieldColWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(modeTitle).font(.title3).fontWeight(.semibold)

            TabView {
                Tab("General", systemImage: "gearshape") {
                    VStack(alignment: .leading, spacing: 12) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("Name")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                TextField("Display name", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: fieldColWidth, alignment: .leading)
                            }
                            GridRow {
                                Text("Directory")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                HStack(spacing: 8) {
                                    TextField("/absolute/path", text: $directory)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: .infinity)
                                    Button("Choose…") { chooseDirectory() }
                                }
                                .frame(width: fieldColWidth, alignment: .leading)
                            }
                            GridRow {
                                Text("Parent Project")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                Picker("", selection: Binding(get: { parentProjectId ?? "(none)" }, set: { parentProjectId = $0 == "(none)" ? nil : $0 })) {
                                    Text("(none)").tag("(none)")
                                    ForEach(viewModel.projects.filter { $0.id != (modeSelfId()) }, id: \.id) { p in
                                        Text(p.name.isEmpty ? p.id : p.name).tag(p.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: fieldColWidth, alignment: .leading)
                            }
                            GridRow {
                                Text("Trust Level")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                Picker("", selection: trustLevelBinding) {
                                    Text("trusted").tag("trusted")
                                    Text("untrusted").tag("untrusted")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            GridRow {
                                Text("Sources")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                HStack(spacing: 16) {
                                    ForEach(ProjectSessionSource.allCases) { source in
                                        Toggle(source.displayName, isOn: binding(for: source))
                                            .toggleStyle(.checkbox)
                                    }
                                }
                                .frame(width: fieldColWidth, alignment: .leading)
                            }
                            GridRow(alignment: .top) {
                                Text("Overview")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 6) {
                                    TextEditor(text: $overview)
                                        .font(.body)
                                        .frame(minHeight: 88, maxHeight: 120)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.2))
                                        )
                                }
                                .frame(width: fieldColWidth, alignment: .leading)
                            }
                        }
                    }
                    .padding(16)
                }
                Tab("Instructions", systemImage: "text.alignleft") {
                    HStack {
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $instructions)
                                .font(.body)
                                .frame(minHeight: 120, maxHeight: 220)
                                .frame(width: fieldColWidth)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.2))
                                )
                            Text("Default instructions for new sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
                Tab("Profile", systemImage: "person.crop.square") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Project Profile (applies to new sessions)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("Model")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                TextField("e.g. gpt-4o-mini", text: Binding(get: { profileModel ?? "" }, set: { profileModel = $0.isEmpty ? nil : $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: fieldColWidth, alignment: .leading)
                            }
                        }

                        // Sandbox + Approval (left-aligned)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("Sandbox")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                Picker("", selection: Binding(get: { profileSandbox ?? .workspaceWrite }, set: { profileSandbox = $0 })) {
                                    ForEach(SandboxMode.allCases) { s in Text(s.title).tag(s) }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            GridRow {
                                Text("Approval")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                Picker("", selection: Binding(get: { profileApproval ?? .onRequest }, set: { profileApproval = $0 })) {
                                    ForEach(ApprovalPolicy.allCases) { a in Text(a.title).tag(a) }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            GridRow {
                                Text("Presets")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                HStack(spacing: 12) {
                                    Toggle("Full Auto", isOn: Binding(get: { profileFullAuto ?? false }, set: { profileFullAuto = $0 }))
                                    Toggle("Danger Bypass", isOn: Binding(get: { profileDangerBypass ?? false }, set: { profileDangerBypass = $0 }))
                                }
                                .frame(width: fieldColWidth, alignment: .leading)
                            }
                        }

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("PATH Prepend")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                TextField("/opt/custom/bin:/project/bin", text: $profilePathPrependText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: fieldColWidth, alignment: .leading)
                            }
                            GridRow(alignment: .top) {
                                Text("Environment")
                                    .font(.subheadline)
                                    .frame(width: labelColWidth, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 6) {
                                    TextEditor(text: $profileEnvText)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(minHeight: 100, maxHeight: 180)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                                    Text("One per line: KEY=VALUE. Will export as export KEY='VALUE'.").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: fieldColWidth, alignment: .leading)
                            }
                        }
                        Text("These settings apply to new sessions of this project and map to --model / -s / -a / --full-auto / --dangerously-bypass-approvals-and-sandbox. The CLI may also load the named profile (auto-mapped to project ID).").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
            .padding(.bottom, 4)

            HStack {
                if case .edit(let p) = mode {
                    Text("ID: \(p.id)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { attemptClose() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryActionTitle) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear(perform: load)
        .alert("Discard changes?", isPresented: $showCloseConfirm) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard", role: .destructive) { isPresented = false }
        } message: {
            Text("Your edits will be lost.")
        }
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
        switch mode {
        case .edit(let p):
            name = p.name
            directory = p.directory ?? ""
            trustLevel = p.trustLevel ?? "trusted"
            parentProjectId = p.parentId
            overview = p.overview ?? ""
            instructions = p.instructions ?? ""
            profileId = p.profileId ?? ""
            let initialSources = p.sources.isEmpty ? ProjectSessionSource.allSet : p.sources
            sources = initialSources
            if let pr = p.profile {
                profileModel = pr.model
                profileSandbox = pr.sandbox
                profileApproval = pr.approval
                profileFullAuto = pr.fullAuto
                profileDangerBypass = pr.dangerouslyBypass
                if let pp = pr.pathPrepend { profilePathPrependText = pp.joined(separator: ":") }
                if let env = pr.env {
                    let lines = env.keys.sorted().map { k in
                        let v = env[k] ?? ""
                        return "\(k)=\(v)"
                    }
                    profileEnvText = lines.joined(separator: "\n")
                }
            }
        case .new:
            sources = ProjectSessionSource.allSet
            if let pf = prefill {
                if let v = pf.name { name = v }
                if let v = pf.directory { directory = v }
                if let v = pf.trustLevel { trustLevel = v } else { trustLevel = "trusted" }
                if let v = pf.overview { overview = v }
                if let v = pf.instructions { instructions = v }
                if let v = pf.profileId { profileId = v }
                if let v = pf.parentId { parentProjectId = v }
            }
        }
        original = currentSnapshot()
    }

    private func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789-"
        let chars = lower.map { ch -> Character in
            if allowed.contains(ch) { return ch }
            if ch.isLetter || ch.isNumber { return "-" }
            return "-"
        }
        var str = String(chars)
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
        // Profile ID: auto map to project ID by default
        let cleanedProfileId = profileId.trimmingCharacters(in: .whitespaces)
        let profile: String? = cleanedProfileId.isEmpty ? nil : cleanedProfileId
        let dirOpt: String? = {
            let d = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? nil : directory
        }()
        let finalSources = sources.isEmpty ? ProjectSessionSource.allSet : sources

        switch mode {
        case .new:
            let id = generateId()
            let projProfile = buildProjectProfile()
            let finalProfileId = profile ?? id
            let p = Project(
                id: id,
                name: (name.isEmpty ? id : name),
                directory: dirOpt,
                trustLevel: trust,
                overview: ov,
                instructions: instr,
                profileId: finalProfileId,
                profile: projProfile,
                parentId: parentProjectId,
                sources: finalSources
            )
            Task {
                await viewModel.createOrUpdateProject(p)
                if let ids = autoAssignSessionIDs, !ids.isEmpty {
                    await viewModel.assignSessions(to: id, ids: ids)
                }
                isPresented = false
            }
        case .edit(let old):
            let projProfile = buildProjectProfile()
            let finalProfileId = profile ?? old.id
            let p = Project(
                id: old.id,
                name: name,
                directory: dirOpt,
                trustLevel: trust,
                overview: ov,
                instructions: instr,
                profileId: finalProfileId,
                profile: projProfile,
                parentId: parentProjectId,
                sources: finalSources
            )
            Task { await viewModel.createOrUpdateProject(p); isPresented = false }
        }
    }

    private var trustLevelSegment: String { trustLevel == "untrusted" ? "untrusted" : "trusted" }
    private var trustLevelBinding: Binding<String> {
        Binding<String>(
            get: { trustLevelSegment },
            set: { newValue in trustLevel = (newValue == "untrusted") ? "untrusted" : "trusted" }
        )
    }

    private func binding(for source: ProjectSessionSource) -> Binding<Bool> {
        Binding<Bool>(
            get: { sources.contains(source) },
            set: { newValue in
                if newValue {
                    sources.insert(source)
                } else {
                    if sources.count == 1 && sources.contains(source) { return }
                    sources.remove(source)
                }
            }
        )
    }

    private func modeSelfId() -> String? {
        if case .edit(let p) = mode { return p.id }
        return nil
    }

    private func buildProjectProfile() -> ProjectProfile? {
        if (profileId.trimmingCharacters(in: .whitespaces).isEmpty)
            && (profileModel?.isEmpty ?? true)
            && profileSandbox == nil
            && profileApproval == nil
            && profileFullAuto == nil
            && profileDangerBypass == nil
        {
            return nil
        }
        return ProjectProfile(
            model: profileModel?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : profileModel,
            sandbox: profileSandbox,
            approval: profileApproval,
            fullAuto: profileFullAuto,
            dangerouslyBypass: profileDangerBypass,
            pathPrepend: parsePathPrepend(profilePathPrependText),
            env: parseEnv(profileEnvText)
        )
    }

    private func parsePathPrepend(_ text: String) -> [String]? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return s.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func parseEnv(_ text: String) -> [String:String]? {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        var dict: [String:String] = [:]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let eq = t.firstIndex(of: "=") else { continue }
            let key = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(t[t.index(after: eq)...])
            if !key.isEmpty { dict[key] = val }
        }
        return dict.isEmpty ? nil : dict
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(
            name: name,
            directory: directory,
            trustLevel: trustLevel,
            overview: overview,
            instructions: instructions,
            profileModel: profileModel,
            profileSandbox: profileSandbox,
            profileApproval: profileApproval,
            profileFullAuto: profileFullAuto,
            profileDangerBypass: profileDangerBypass,
            profilePathPrependText: profilePathPrependText,
            profileEnvText: profileEnvText,
            parentProjectId: parentProjectId,
            sources: sources
        )
    }

    private func attemptClose() {
        if let original, original != currentSnapshot() {
            showCloseConfirm = true
        } else {
            isPresented = false
        }
    }


}
private struct ProjectTreeNode: Identifiable, Hashable {
    let id: String
    let project: Project
    var children: [ProjectTreeNode]?
}

private func buildProjectTree(_ projects: [Project]) -> [ProjectTreeNode] {
    var map: [String: ProjectTreeNode] = [:]
    var roots: [ProjectTreeNode] = []
    for p in projects {
        map[p.id] = ProjectTreeNode(id: p.id, project: p, children: [])
    }
    for p in projects {
        if let pid = p.parentId, let parent = map[pid] {
            let copy = map[p.id]!
            // attach under parent
            var parentCopy = parent
            parentCopy.children?.append(copy)
            map[pid] = parentCopy
        }
    }
    // rebuild roots (those without a valid parent)
    for p in projects.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
        if let pid = p.parentId, projects.contains(where: { $0.id == pid }) {
            continue
        }
        // gather children from map updated above
        let node = map[p.id] ?? ProjectTreeNode(id: p.id, project: p, children: nil)
        roots.append(fixChildren(node, map: map))
    }
    return roots
}

private func fixChildren(_ node: ProjectTreeNode, map: [String: ProjectTreeNode]) -> ProjectTreeNode {
    var out = node
    let project = node.project
    let children = map.values.filter { $0.project.parentId == project.id }
        .sorted { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending }
        .map { fixChildren($0, map: map) }
    out.children = children.isEmpty ? nil : children
    return out
}
