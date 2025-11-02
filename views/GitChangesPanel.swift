import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct GitChangesPanel: View {
    enum Presentation { case embedded, full }
    let workingDirectory: URL
    var presentation: Presentation = .embedded
    let preferences: SessionPreferencesStore
    @StateObject private var vm = GitChangesViewModel()
    // Layout state
    @State private var leftColumnWidth: CGFloat = 0   // 0 = init to 1/4 of container
    @State private var commitEditorHeight: CGFloat = 28
    // Tree state
    @State private var expandedDirs: Set<String> = []
    @State private var treeQuery: String = ""
    // Cached trees for performance
    @State private var cachedNodes: [FileNode] = [] // legacy (all)
    @State private var displayedNodes: [FileNode] = [] // legacy (all)
    @State private var cachedNodesStaged: [FileNode] = []
    @State private var cachedNodesUnstaged: [FileNode] = []
    @State private var displayedStaged: [FileNode] = []
    @State private var displayedUnstaged: [FileNode] = []
    @State private var stagedCollapsed: Bool = false
    @State private var unstagedCollapsed: Bool = false
    @State private var commitInlineHeight: CGFloat = 20
    // Hover state for quick actions
    @State private var hoverFilePath: String? = nil
    @State private var hoverDirKey: String? = nil
    @State private var hoverStagedHeader: Bool = false
    @State private var hoverUnstagedHeader: Bool = false
    @State private var pendingDiscardPaths: [String] = []
    @State private var showDiscardAlert: Bool = false
    @State private var showGlobalMenu: Bool = false
    // Use an optional Int for segmented momentary actions: 0=collapse, 1=expand
    // @State private var treeToggleIndex: Int? = nil // 已移除，改用直接按钮
    // Layout constraints
    private let leftMin: CGFloat = 240
    private let leftMax: CGFloat = 520
    private let commitMinHeight: CGFloat = 140
    // Indent guide metrics (horizontal):
    // - indentStep: per-depth indent distance (matches VS Code's 16px)
    // - chevronWidth: width reserved for disclosure chevron
    private let indentStep: CGFloat = 16
    private let chevronWidth: CGFloat = 16
    private let quickActionWidth: CGFloat = 18
    // Viewer options (defaults: line numbers ON, wrap OFF)
    private let wrapText: Bool = false
    private let showLineNumbers: Bool = true

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            header
            VSplitView {
                GeometryReader { geo in
                    // Top split: left file tree and right diff/preview, with draggable divider
                    HStack(spacing: 0) {
                        let leftW = effectiveLeftWidth(total: geo.size.width)
                        let gutterW: CGFloat = 17 // divider 1pt + 8pt padding each side
                        let rightW = max(geo.size.width - gutterW - leftW, 240)
                        leftPane
                            .frame(width: leftW)
                            .frame(minWidth: leftMin, maxWidth: leftMax)
                        // Visible divider with padding; whole gutter is draggable
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 8)
                            Divider().frame(width: 1)
                            Color.clear.frame(width: 8)
                        }
                            .frame(width: gutterW)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                let newW = clampLeftWidth(leftColumnWidth + value.translation.width, total: geo.size.width)
                                leftColumnWidth = newW
                            })
                            .onHover { inside in
                                #if canImport(AppKit)
                                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                                #endif
                            }
                        detailView
                            .frame(width: rightW)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        if leftColumnWidth == 0 {
                            leftColumnWidth = clampLeftWidth(geo.size.width * 0.25, total: geo.size.width)
                        }
                    }
                }

                // (Commit box moved to left pane top)
            }
        }
        Group {
            switch presentation {
            case .embedded:
                content
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .full:
                content
            }
        }
        .alert("Discard changes?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                let paths = pendingDiscardPaths
                pendingDiscardPaths = []
                Task { await vm.discard(paths: paths) }
            }
            Button("Cancel", role: .cancel) {
                pendingDiscardPaths = []
            }
        } message: {
            let count = pendingDiscardPaths.count
            Text("This will permanently discard changes for \(count) file\(count == 1 ? "" : "s").")
        }
        .task(id: workingDirectory) {
            vm.attach(to: workingDirectory)
        }
        .onAppear { rebuildNodes(); rebuildDisplayed() }
        .onChange(of: vm.changes) { _, _ in rebuildNodes() }
        .onChange(of: treeQuery) { _, _ in rebuildDisplayed() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Changes", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                if let root = vm.repoRoot?.path {
                    Text(root)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
                Spacer()
                Picker("", selection: $vm.showPreviewInsteadOfDiff) {
                    Text("Diff").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
                .controlSize(.small)
                .labelsHidden()

                Button {
                    Task { await vm.refreshStatus() }
                } label: {
                    Image(systemName: vm.isLoading ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let err = vm.errorMessage, !err.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.08))
                )
            }
        }
    }

    // MARK: - Layout helpers
    private func clampLeftWidth(_ proposed: CGFloat, total: CGFloat) -> CGFloat {
        let minW = leftMin
        let maxW = min(leftMax, total - 240) // keep space for right pane + gutter
        return max(minW, min(maxW, proposed))
    }
    private func effectiveLeftWidth(total: CGFloat) -> CGFloat {
        let w = (leftColumnWidth == 0) ? total * 0.25 : leftColumnWidth
        return clampLeftWidth(w, total: total)
    }

    // Measure dynamic height for inline commit editor based on width
    private func measureCommitHeight(_ text: String, width: CGFloat) -> CGFloat {
        #if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let s = text.isEmpty ? " " : text
        let rect = (s as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(20, ceil(rect.height))
        #else
        return 20
        #endif
    }

    // MARK: - File tree (grouped by directories)
    private struct FileNode: Identifiable {
        let id = UUID()
        var name: String
        var fullPath: String? // non-nil for files
        var dirPath: String? = nil // non-nil for directories
        var children: [FileNode]? = nil
        var isDirectory: Bool { dirPath != nil }
    }

    private func makeTree(from changes: [GitService.Change]) -> [FileNode] {
        // Build a recursive tree of directories → files
        struct BuilderNode {
            var children: [String: BuilderNode] = [:]
            var filePath: String? = nil
        }
        var root = BuilderNode()
        for c in changes {
            let comps = c.path.split(separator: "/").map(String.init)
            func insert(_ idx: Int, _ current: inout BuilderNode) {
                if idx == comps.count - 1 {
                    var leaf = current.children[comps[idx], default: BuilderNode()]
                    leaf.filePath = c.path
                    current.children[comps[idx]] = leaf
                    return
                }
                var next = current.children[comps[idx], default: BuilderNode()]
                insert(idx + 1, &next)
                current.children[comps[idx]] = next
            }
            insert(0, &root)
        }
        func convert(_ b: BuilderNode, name: String? = nil) -> [FileNode] {
            var nodes: [FileNode] = []
            for (k, v) in b.children.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
                if let p = v.filePath {
                    nodes.append(FileNode(name: k, fullPath: p, dirPath: nil, children: nil))
                } else {
                    let key = (name == nil) ? k : (name! + "/" + k)
                    nodes.append(FileNode(name: k, fullPath: nil, dirPath: key, children: convert(v, name: key)))
                }
            }
            return nodes
        }
        return convert(root)
    }

    // old filesTree removed in favor of custom leftPane/treeRows

    // MARK: - Left pane (toolbar + tree)
    private var leftPane: some View {
        VStack(spacing: 6) {
            // Toolbar - Redesigned with explicit layout control
            GeometryReader { toolbarGeo in
                let availableWidth = toolbarGeo.size.width
                let pickerWidth: CGFloat = 56 // 两个28pt的正方形按钮
                let menuWidth: CGFloat = 30 // 增加到 30pt 给 menu 更多空间
                let spacing: CGFloat = 8
                let totalFixedWidth = pickerWidth + menuWidth + (spacing * 2)
                let searchWidth = max(80, availableWidth - totalFixedWidth)

                HStack(spacing: 0) {
                    // Search box - calculated width
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $treeQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2))
                    )
                    .frame(width: searchWidth)

                    // Fixed spacing
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: spacing, height: 1)

                    // Collapse/Expand button group - transparent buttons
                    HStack(spacing: 0) {
                        // Collapse All button
                        Button {
                            expandedDirs.removeAll()
                        } label: {
                            Image(systemName: "arrow.up.right.and.arrow.down.left")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28) // 正方形，与搜索框高度一致
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                // 悬停时的视觉反馈可以通过系统默认处理
                            }
                        }

                        // Expand All button
                        Button {
                            var keys: [String] = []
                            keys += allDirectoryKeys(nodes: cachedNodesStaged)
                            keys += allDirectoryKeys(nodes: cachedNodesUnstaged)
                            expandedDirs = Set(keys)
                        } label: {
                            Image(systemName: "arrow.down.left.and.arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28) // 正方形，与搜索框高度一致
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                // 悬停时的视觉反馈可以通过系统默认处理
                            }
                        }
                    }
                    .frame(width: pickerWidth, alignment: .center)

                    // Fixed spacing
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: spacing, height: 1)

                    // Three-dot menu - custom popover (hide arrow)
                    HStack {
                        Button {
                            showGlobalMenu.toggle()
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showGlobalMenu) {
                            PopMenuList(
                                items: [
                                    .init(title: "Stage All") {
                                        showGlobalMenu = false
                                        Task {
                                            let paths = vm.changes.filter { $0.staged == nil }.map { $0.path }
                                            await vm.toggleStage(for: paths)
                                        }
                                    },
                                    .init(title: "Unstage All") {
                                        showGlobalMenu = false
                                        Task {
                                            let paths = vm.changes.filter { $0.staged != nil }.map { $0.path }
                                            await vm.toggleStage(for: paths)
                                        }
                                    }
                                ],
                                tail: [
                                    .init(title: "Discard All Changes…", role: .destructive) {
                                        pendingDiscardPaths = vm.changes.map { $0.path }
                                        showGlobalMenu = false
                                        showDiscardAlert = true
                                    }
                                ]
                            )
                            .frame(width: 220)
                        }
                    }
                    .frame(width: menuWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 32)

            // Inline commit message (one line, auto-grow; no button)
            GeometryReader { gr in
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $vm.commitMessage)
                        .font(.system(.body))
                        .textEditorStyle(.plain)
                        .frame(minHeight: 20)
                        .frame(height: min(200, max(20, commitInlineHeight)))
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                    .onChange(of: vm.commitMessage) { _, _ in
                        let w = max(10, gr.size.width - 12)
                        commitInlineHeight = measureCommitHeight(vm.commitMessage, width: w)
                    }
                    if vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Commit message…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .padding(.leading, 10)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: min(200, max(20, commitInlineHeight)) + 12)

            // Trees in VS Code-style sections
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Staged section
                    HStack(spacing: 6) {
                        Button {
                            stagedCollapsed.toggle()
                        } label: {
                            Image(systemName: stagedCollapsed ? "chevron.right" : "chevron.down")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .frame(width: chevronWidth)
                        Text("Staged Changes (\(vm.changes.filter { $0.staged != nil }.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { stagedCollapsed.toggle() }
                    .onHover { hoverStagedHeader = $0 }
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hoverStagedHeader ? Color.secondary.opacity(0.06) : Color.clear)
                    )
                    .frame(height: 22)
                    if !stagedCollapsed {
                        treeRows(nodes: displayedStaged, depth: 1, scope: .staged)
                    }

                    // Unstaged section
                    HStack(spacing: 6) {
                        Button { unstagedCollapsed.toggle() } label: {
                            Image(systemName: unstagedCollapsed ? "chevron.right" : "chevron.down")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .frame(width: chevronWidth)
                        Text("Changes (\(vm.changes.filter { $0.staged == nil && $0.worktree != nil }.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { unstagedCollapsed.toggle() }
                    .onHover { hoverUnstagedHeader = $0 }
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hoverUnstagedHeader ? Color.secondary.opacity(0.06) : Color.clear)
                    )
                    .frame(height: 22)
                    if !unstagedCollapsed {
                        treeRows(nodes: displayedUnstaged, depth: 1, scope: .unstaged)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func allDirectoryKeys(nodes: [FileNode]) -> [String] {
        var keys: [String] = []
        func walk(_ ns: [FileNode]) {
            for n in ns {
                if let d = n.dirPath { keys.append(d); if let cs = n.children { walk(cs) } }
            }
        }
        walk(nodes)
        return keys
    }

    private func filteredNodes(_ nodes: [FileNode], query: String) -> [FileNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nodes }
        func filter(_ ns: [FileNode]) -> [FileNode] {
            var out: [FileNode] = []
            for n in ns {
                if n.isDirectory {
                    let kids = n.children.map(filter) ?? []
                    if n.name.localizedCaseInsensitiveContains(q) || !kids.isEmpty {
                        var dir = n
                        dir.children = kids
                        out.append(dir)
                    }
                } else if let p = n.fullPath,
                          n.name.localizedCaseInsensitiveContains(q) || p.localizedCaseInsensitiveContains(q) {
                    out.append(n)
                }
            }
            return out
        }
        return filter(nodes)
    }

    // Expand a directory key to concrete file paths present in current change set
    private func filePaths(under dirKey: String) -> [String] {
        let prefix = dirKey.hasSuffix("/") ? dirKey : (dirKey + "/")
        return vm.changes.map { $0.path }.filter { $0.hasPrefix(prefix) }
    }

    private func rebuildNodes() {
        let staged = vm.changes.filter { $0.staged != nil }
        let unstaged = vm.changes.filter { $0.staged == nil && $0.worktree != nil }
        cachedNodesStaged = makeTree(from: staged)
        cachedNodesUnstaged = makeTree(from: unstaged)
        rebuildDisplayed()
    }
    private func rebuildDisplayed() {
        displayedStaged = filteredNodes(cachedNodesStaged, query: treeQuery)
        displayedUnstaged = filteredNodes(cachedNodesUnstaged, query: treeQuery)
    }

    private enum TreeScope { case unstaged, staged }
    @ViewBuilder
    private func treeRows(nodes: [FileNode], depth: Int, scope: TreeScope) -> some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                // Directory row with VS Code-style layout
                let isExpanded = expandedDirs.contains(node.dirPath ?? "")
                HStack(spacing: 0) {
                    // Indentation guides (vertical lines)
                    ZStack(alignment: .leading) {
                        Color.clear.frame(width: CGFloat(depth) * indentStep + chevronWidth)
                        let guideColor = Color.secondary.opacity(0.15)
                        ForEach(0..<depth, id: \.self) { i in
                            Rectangle().fill(guideColor).frame(width: 1)
                                .offset(x: CGFloat(i) * indentStep + chevronWidth / 2)
                        }
                        // Chevron (disclosure triangle)
                        HStack(spacing: 0) {
                            Spacer().frame(width: CGFloat(depth) * indentStep)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: chevronWidth, height: 20)
                        }
                    }
                    // Folder icon and name
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(node.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // Hover quick action: Stage/Unstage entire folder
                        if let dir = node.dirPath {
                            let hasStaged = vm.changes.contains { $0.path.hasPrefix(dir + "/") && $0.staged != nil }
                            Button(action: {
                                Task {
                                    let paths = filePaths(under: dir)
                                    guard !paths.isEmpty else { return }
                                    await vm.toggleStage(for: paths)
                                }
                            }) {
                                Image(systemName: hasStaged ? "minus.circle" : "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .opacity((hoverDirKey == dir) ? 1 : 0)
                            .frame(width: quickActionWidth)
                        }
                    }
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((hoverDirKey == (node.dirPath ?? "")) ? Color.secondary.opacity(0.06) : Color.clear)
                )
                .onTapGesture {
                    if let key = node.dirPath {
                        if expandedDirs.contains(key) { expandedDirs.remove(key) } else { expandedDirs.insert(key) }
                    }
                }
                .onHover { inside in
                    if let key = node.dirPath {
                        if inside { hoverDirKey = key } else if hoverDirKey == key { hoverDirKey = nil }
                    }
                }
                .contextMenu {
                    if let dir = node.dirPath {
                        Button("Stage Folder") {
                            Task { await vm.toggleStage(for: filePaths(under: dir)) }
                        }
                        Button("Unstage Folder") {
                            Task { await vm.toggleStage(for: filePaths(under: dir)) }
                        }
                        Divider()
                        Button("Discard Folder Changes…", role: .destructive) {
                            pendingDiscardPaths = filePaths(under: dir)
                            showDiscardAlert = true
                        }
                    }
                }

                // Expanded children
                if isExpanded {
                    AnyView(treeRows(nodes: node.children ?? [], depth: depth + 1, scope: scope))
                }
            } else {
                // File row
                let path = node.fullPath ?? node.name
                let staged = vm.changes.first(where: { $0.path == path })?.staged != nil
                let isSelected = (vm.selectedPath == path) && ((scope == .staged && vm.selectedSide == .staged) || (scope == .unstaged && vm.selectedSide == .unstaged))
                HStack(spacing: 0) {
                    // Indentation guides (vertical lines)
                    ZStack(alignment: .leading) {
                        Color.clear.frame(width: CGFloat(depth) * indentStep + chevronWidth)
                        let guideColor = Color.secondary.opacity(0.15)
                        ForEach(0..<depth, id: \.self) { i in
                            Rectangle().fill(guideColor).frame(width: 1)
                                .offset(x: CGFloat(i) * indentStep + chevronWidth / 2)
                        }
                    }
                    // File icon and name
                    HStack(spacing: 6) {
                        // File type indicator or icon
                        Circle()
                            .fill(statusColor(for: path))
                            .frame(width: 6, height: 6)
                        Text(node.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // Hover quick action: Open with default editor (single click)
                        Button { vm.openFile(path, using: preferences.defaultFileEditor) } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity((hoverFilePath == path) ? 1 : 0)
                        .frame(width: quickActionWidth)
                        // Hover quick action: Discard file (VSCode-style revert icon)
                        Button(action: {
                            pendingDiscardPaths = [path]
                            showDiscardAlert = true
                        }) {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity((hoverFilePath == path) ? 1 : 0)
                        .frame(width: quickActionWidth)
                        // Hover quick action: Stage/Unstage
                        Button(action: { Task { await vm.toggleStage(for: [path]) } }) {
                            Image(systemName: staged ? "minus.circle" : "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity((hoverFilePath == path) ? 1 : 0)
                        .frame(width: quickActionWidth)
                        // Status badge (最右侧)
                        if let change = vm.changes.first(where: { $0.path == path }) {
                            statusBadge(for: change)
                                .padding(.trailing, 6)
                        }
                    }
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : ((hoverFilePath == path) ? Color.secondary.opacity(0.06) : Color.clear))
                )
                .onTapGesture {
                    vm.selectedPath = path
                    vm.selectedSide = (scope == .staged ? .staged : .unstaged)
                    Task { await vm.refreshDetail() }
                }
                .onHover { inside in
                    if inside { hoverFilePath = path } else if hoverFilePath == path { hoverFilePath = nil }
                }
                .contextMenu {
                    Button(staged ? "Unstage" : "Stage") {
                        Task { await vm.toggleStage(for: [path]) }
                    }
                    Divider()
                    Button("Open in VS Code") { vm.openFile(path, using: .vscode) }
                    Button("Open in Cursor") { vm.openFile(path, using: .cursor) }
                    Button("Open in Zed") { vm.openFile(path, using: .zed) }
                    Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: vm.repoRoot?.appendingPathComponent(path).path ?? path)) }
                    Divider()
                    Button("Discard Changes…", role: .destructive) {
                        pendingDiscardPaths = [path]
                        showDiscardAlert = true
                    }
                }
            }
        }
    }

    // Helper: Status color indicator for files
    private func statusColor(for path: String) -> Color {
        guard let change = vm.changes.first(where: { $0.path == path }) else {
            return Color.secondary.opacity(0.3)
        }
        // Check if staged or worktree
        if let _ = change.staged {
            return Color.green.opacity(0.7)
        } else if let kind = change.worktree {
            switch kind {
            case .modified: return Color.orange.opacity(0.7)
            case .deleted: return Color.red.opacity(0.7)
            case .untracked: return Color.green.opacity(0.7)
            default: return Color.blue.opacity(0.7)
            }
        }
        return Color.secondary.opacity(0.3)
    }

    // Helper: Status badge text
    @ViewBuilder
    private func statusBadge(for change: GitService.Change) -> some View {
        if let _ = change.staged {
            badgeView(text: "S")
        } else if let kind = change.worktree {
            switch kind {
            case .modified: badgeView(text: "M")
            case .deleted: badgeView(text: "D")
            case .untracked: badgeView(text: "U")
            case .added: badgeView(text: "A")
            }
        }
    }

    private func badgeView(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.1))
            )
    }

    private var detailView: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttributedTextView(
                text: vm.diffText.isEmpty
                    ? (vm.selectedPath == nil ? "Select a file to view diff/preview." : (vm.showPreviewInsteadOfDiff ? "(Empty preview)" : "(No diff)"))
                    : vm.diffText,
                isDiff: !vm.showPreviewInsteadOfDiff,
                wrap: wrapText,
                showLineNumbers: showLineNumbers,
                fontSize: 12
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
            )
        }
        .id("detail:\(vm.selectedPath ?? "-")|\(vm.selectedSide == .staged ? "s" : "u")|\(vm.showPreviewInsteadOfDiff ? "p" : "d")|wrap:\(wrapText ? 1 : 0)|ln:\(showLineNumbers ? 1 : 0)")
        .task(id: vm.selectedPath) { await vm.refreshDetail() }
        .task(id: vm.selectedSide) { await vm.refreshDetail() }
        .task(id: vm.showPreviewInsteadOfDiff) { await vm.refreshDetail() }
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commit")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if presentation == .full {
                // Clamp editor height between 1 and 10 lines (≈20pt/line)
                let line: CGFloat = 20
                let minH: CGFloat = line
                let maxH: CGFloat = line * 10
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $vm.commitMessage)
                        .font(.system(.body))
                        .textEditorStyle(.plain)
                        .frame(minHeight: minH)
                        .frame(height: min(maxH, max(minH, commitEditorHeight)))
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                    // Drag handle adjusts preferred editor height within bounds
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 6)
                        .gesture(DragGesture().onChanged { value in
                            let nh = max(minH, min(maxH, commitEditorHeight + value.translation.height))
                            commitEditorHeight = nh
                        })
                    HStack {
                        Spacer()
                        Button("Commit") { Task { await vm.commit() } }
                            .disabled(vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    TextField("Message", text: $vm.commitMessage)
                    Button("Commit") { Task { await vm.commit() } }
                        .disabled(vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(8)
        .background(
            Group {
                if presentation == .embedded {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                }
            }
        )
        .overlay(
            Group {
                if presentation == .embedded {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15))
                }
            }
        )
    }
}

// Lightweight menu list for popovers, mimicking macOS menu rows (no arrow)
private struct PopMenuItem: Identifiable {
    enum Role { case normal, destructive }
    let id = UUID()
    var title: String
    var role: Role = .normal
    var action: () -> Void
}

private struct PopMenuList: View {
    var items: [PopMenuItem]
    var tail: [PopMenuItem] = [] // optional trailing group separated by a divider
    @State private var hovered: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            groupView(items)
            if !tail.isEmpty {
                Divider().padding(.vertical, 4)
                groupView(tail)
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private func groupView(_ group: [PopMenuItem]) -> some View {
        ForEach(group) { item in
            Button(action: item.action) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .foregroundStyle(item.role == .destructive ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        }
    }
}
