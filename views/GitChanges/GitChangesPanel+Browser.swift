import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension GitChangesPanel {
    struct BrowserRow: Identifiable {
        let node: FileNode
        let depth: Int

        var id: String {
            if let dir = node.dirPath { return "dir:\(dir)" }
            if let file = node.fullPath { return "file:\(file)" }
            return "node:\(node.name)-\(depth)"
        }

        var directoryKey: String? { node.dirPath }
        var filePath: String? { node.fullPath }
    }

    var browserTreeView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLoadingBrowserTree {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading repository…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if let error = browserTreeError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    HStack {
                        Button("Retry") { requestBrowserTreeReload(force: true) }
                        if let action = onRequestAuthorization {
                            Button("Authorize Repository Folder…") { action() }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 6)
            } else if displayedBrowserRows.isEmpty {
                let message = treeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No files in repository."
                    : "No matches."
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(displayedBrowserRows) { row in
                        browserRow(row)
                    }
                }
            }
            if browserTreeTruncated {
                Text("Showing first \(browserEntryLimit) entries. Use search to narrow results.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            if !isLoadingBrowserTree, browserTreeError == nil, browserTotalEntries > 0 {
                Text("\(browserTotalEntries)\(browserTreeTruncated ? "+" : "") items")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func browserRow(_ row: BrowserRow) -> some View {
        if row.node.isDirectory {
            browserDirectoryRow(row)
        } else {
            browserFileRow(row)
        }
    }

    private func browserDirectoryRow(_ row: BrowserRow) -> some View {
        let key = row.directoryKey ?? row.node.name
        let indent = CGFloat(max(row.depth, 0)) * indentStep
        let isExpanded = !treeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expandedDirsBrowser.contains(key)
        return HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Color.clear.frame(width: indent + chevronWidth)
                let guideColor = Color.secondary.opacity(0.15)
                if row.depth > 0 {
                    ForEach(0..<row.depth, id: \.self) { idx in
                        Rectangle()
                            .fill(guideColor)
                            .frame(width: 1)
                            .offset(x: CGFloat(idx) * indentStep + chevronWidth / 2)
                    }
                }
                HStack(spacing: 0) {
                    Spacer().frame(width: indent)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: chevronWidth, height: 20)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(row.node.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.trailing, trailingPad)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill((hoverBrowserDirKey == key) ? Color.secondary.opacity(0.06) : Color.clear)
        )
        .onTapGesture {
            toggleBrowserDirectory(key)
        }
        .onHover { inside in
            if inside {
                hoverBrowserDirKey = key
            } else if hoverBrowserDirKey == key {
                hoverBrowserDirKey = nil
            }
        }
        .contextMenu {
            Button(isExpanded ? "Collapse" : "Expand") {
                toggleBrowserDirectory(key)
            }
            let paths = filePaths(under: key)
            if !paths.isEmpty {
                Button("Stage Folder") {
                    Task { await vm.stage(paths: paths) }
                }
                Button("Unstage Folder") {
                    Task { await vm.unstage(paths: paths) }
                }
            }
#if canImport(AppKit)
            Button("Reveal in Finder") {
                revealBrowserItem(path: key, isDirectory: true)
            }
#endif
        }
    }

    private func browserFileRow(_ row: BrowserRow) -> some View {
        Group {
            if let path = row.filePath {
                browserFileRowContent(path: path, row: row)
            } else {
                EmptyView()
            }
        }
    }
    
    @ViewBuilder
    private func browserFileRowContent(path: String, row: BrowserRow) -> some View {
        let indent = CGFloat(max(row.depth, 0)) * indentStep
        let change = vm.changes.first { $0.path == path }
        let isSelected = vm.selectedPath == path
        let bulletColor = change.map { statusColor(for: $0.path) } ?? Color.clear
        let showStageAction = change != nil
        let activeHover = hoverBrowserFilePath == path
        let buttonCount: Int = {
            var count = 1 // Open
#if canImport(AppKit)
            count += 1 // Reveal
#endif
            if showStageAction { count += 1 }
            return count
        }()
        let actionWidth = CGFloat(buttonCount) * quickActionWidth + CGFloat(max(buttonCount - 1, 0)) * hoverButtonSpacing
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Color.clear.frame(width: indent)
                if row.depth > 0 {
                    let guideColor = Color.secondary.opacity(0.15)
                    ForEach(0..<row.depth, id: \.self) { idx in
                        Rectangle()
                            .fill(guideColor)
                            .frame(width: 1)
                            .offset(x: CGFloat(idx) * indentStep - indentStep / 2)
                    }
                }
            }
            .frame(width: indent)
            HStack(spacing: 6) {
                if change != nil {
                    Circle()
                        .fill(bulletColor.opacity(0.8))
                        .frame(width: 6, height: 6)
                } else {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 6, height: 6)
                }
                let icon = fileTypeIconName(for: path)
                Image(systemName: icon.name)
                    .font(.system(size: 12))
                    .foregroundStyle(icon.color)
                Text(row.node.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.trailing, activeHover ? (actionWidth + trailingPad + (change != nil ? statusBadgeWidth : 0)) : (trailingPad + (change != nil ? statusBadgeWidth : 0)))
            .overlay(alignment: .trailing) {
                HStack(spacing: hoverButtonSpacing) {
                    if activeHover {
                        Button {
                            vm.openFile(path, using: preferences.defaultFileEditor)
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle((hoverBrowserEditPath == path) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: quickActionWidth, height: quickActionHeight)
                        .onHover { inside in
                            if inside {
                                hoverBrowserEditPath = path
                            } else if hoverBrowserEditPath == path {
                                hoverBrowserEditPath = nil
                            }
                        }
#if canImport(AppKit)
                        Button {
                            revealBrowserItem(path: path, isDirectory: false)
                        } label: {
                            Image(systemName: "folder")
                                .foregroundStyle((hoverBrowserRevealPath == path) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: quickActionWidth, height: quickActionHeight)
                        .onHover { inside in
                            if inside {
                                hoverBrowserRevealPath = path
                            } else if hoverBrowserRevealPath == path {
                                hoverBrowserRevealPath = nil
                            }
                        }
#endif
                        if let change {
                            Button {
                                Task {
                                    if change.staged != nil {
                                        await vm.unstage(paths: [path])
                                    } else {
                                        await vm.stage(paths: [path])
                                    }
                                }
                            } label: {
                                Image(systemName: change.staged != nil ? "minus.circle" : "plus.circle")
                                    .foregroundStyle((hoverBrowserStagePath == path) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: quickActionWidth, height: quickActionHeight)
                            .onHover { inside in
                                if inside {
                                    hoverBrowserStagePath = path
                                } else if hoverBrowserStagePath == path {
                                    hoverBrowserStagePath = nil
                                }
                            }
                        }
                    }
                    if let change {
                        statusBadge(for: change)
                            .frame(height: quickActionHeight)
                    }
                }
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (activeHover ? Color.secondary.opacity(0.06) : Color.clear))
        )
        .onTapGesture {
            handleBrowserSelection(path: path)
        }
        .onHover { inside in
            if inside {
                hoverBrowserFilePath = path
            } else if hoverBrowserFilePath == path {
                hoverBrowserFilePath = nil
            }
        }
        .contextMenu {
            Button("Open in Editor") {
                vm.openFile(path, using: preferences.defaultFileEditor)
            }
#if canImport(AppKit)
            Button("Reveal in Finder") {
                revealBrowserItem(path: path, isDirectory: false)
            }
#endif
            if let change {
                if change.staged != nil {
                    Button("Unstage File") {
                        Task { await vm.unstage(paths: [path]) }
                    }
                } else {
                    Button("Stage File") {
                        Task { await vm.stage(paths: [path]) }
                    }
                }
            } else {
                Button("Stage File") {
                    Task { await vm.stage(paths: [path]) }
                }
            }
        }
        .onTapGesture(count: 2) {
            vm.openFile(path, using: preferences.defaultFileEditor)
        }
    }

    func reloadBrowserTreeIfNeeded(force: Bool = false) {
        requestBrowserTreeReload(force: force)
    }

    func requestBrowserTreeReload(force: Bool = false) {
        guard mode == .browser else {
            browserTreeTask?.cancel()
            browserTreeTask = nil
            return
        }
        if !force {
            if isLoadingBrowserTree { return }
            if !browserNodes.isEmpty && browserTreeError == nil { return }
        }
        guard let root = vm.repoRoot else { return }

        browserTreeTask?.cancel()
        isLoadingBrowserTree = true
        browserTreeError = nil

        let limit = browserEntryLimit
        let viewModel = vm
        browserTreeTask = Task {
            let gitResult = await viewModel.listVisiblePaths(limit: limit)
            if Task.isCancelled {
                await MainActor.run {
                    browserTreeTask = nil
                    isLoadingBrowserTree = false
                }
                return
            }
            let loadResult: (nodes: [FileNode], truncated: Bool, total: Int, error: String?)
            if let gitResult {
                let nodes = buildBrowserTreeFromPaths(gitResult.paths)
                loadResult = (nodes, gitResult.truncated, gitResult.paths.count, nil)
            } else {
                let fallback = buildBrowserTreeFromFileSystem(root: root, limit: limit)
                loadResult = (fallback.nodes, fallback.truncated, fallback.total, fallback.error)
            }
            if Task.isCancelled {
                await MainActor.run {
                    browserTreeTask = nil
                    isLoadingBrowserTree = false
                }
                return
            }
            await MainActor.run {
                browserTreeTask = nil
                isLoadingBrowserTree = false
                if let error = loadResult.error, loadResult.nodes.isEmpty {
                    browserTreeError = error
                    browserNodes = []
                    displayedBrowserRows = []
                    browserTreeTruncated = false
                    browserTotalEntries = 0
                } else {
                    browserTreeError = nil
                    browserNodes = GitReviewTreeBuilder.explorerSort(loadResult.nodes)
                    browserTreeTruncated = loadResult.truncated
                    browserTotalEntries = loadResult.total
                    rebuildBrowserDisplayed()
                }
            }
        }
    }

    func rebuildBrowserDisplayed() {
        let filtered: [FileNode]
        let query = treeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filtered = browserNodes
        } else {
            filtered = filteredNodes(browserNodes, query: query)
        }
        displayedBrowserRows = flattenBrowserNodes(filtered, depth: 0, forceExpand: !query.isEmpty)
    }

    private func flattenBrowserNodes(_ nodes: [FileNode], depth: Int, forceExpand: Bool) -> [BrowserRow] {
        var rows: [BrowserRow] = []
        for node in nodes {
            let row = BrowserRow(node: node, depth: depth)
            rows.append(row)
            if node.isDirectory, let key = node.dirPath ?? (depth == 0 ? node.name : nil) {
                if forceExpand || expandedDirsBrowser.contains(key) {
                    let children = GitReviewTreeBuilder.explorerSort(node.children ?? [])
                    rows.append(contentsOf: flattenBrowserNodes(children, depth: depth + 1, forceExpand: forceExpand))
                }
            }
        }
        return rows
    }

    private func toggleBrowserDirectory(_ key: String) {
        if expandedDirsBrowser.contains(key) {
            expandedDirsBrowser.remove(key)
        } else {
            expandedDirsBrowser.insert(key)
        }
        rebuildBrowserDisplayed()
    }

    private func buildBrowserTreeFromPaths(_ paths: [String]) -> [FileNode] {
        struct Builder {
            var children: [String: Builder] = [:]
            var filePath: String? = nil
        }
        var root = Builder()
        for path in paths {
            guard !path.isEmpty else { continue }
            let components = path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            func insert(_ index: Int, current: inout Builder) {
                let key = components[index]
                if index == components.count - 1 {
                    var child = current.children[key, default: Builder()]
                    child.filePath = path
                    current.children[key] = child
                } else {
                    var child = current.children[key, default: Builder()]
                    insert(index + 1, current: &child)
                    current.children[key] = child
                }
            }
            insert(0, current: &root)
        }
        func convert(_ builder: Builder, prefix: String?) -> [FileNode] {
            var nodes: [FileNode] = []
            for (name, child) in builder.children {
                let fullPath = prefix.map { "\($0)/\(name)" } ?? name
                if let filePath = child.filePath, child.children.isEmpty {
                    nodes.append(FileNode(name: name, fullPath: filePath, dirPath: nil, children: nil))
                } else {
                    let childrenNodes = convert(child, prefix: fullPath)
                    nodes.append(FileNode(name: name, fullPath: nil, dirPath: fullPath, children: GitReviewTreeBuilder.explorerSort(childrenNodes)))
                }
            }
            return GitReviewTreeBuilder.explorerSort(nodes)
        }
        return convert(root, prefix: nil)
    }

    private func buildBrowserTreeFromFileSystem(root: URL, limit: Int) -> (nodes: [FileNode], truncated: Bool, total: Int, error: String?) {
        let (paths, truncated, error) = collectFileSystemPaths(root: root, limit: limit)
        if paths.isEmpty {
            return ([], truncated, 0, error ?? "Unable to enumerate repository contents.")
        }
        let nodes = buildBrowserTreeFromPaths(paths)
        return (nodes, truncated, paths.count, error)
    }

    private func collectFileSystemPaths(root: URL, limit: Int) -> ([String], Bool, String?) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        var encounteredError: String?
        let options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { url, error in
            encounteredError = error.localizedDescription
            return true
        }) else {
            return ([], false, "Unable to enumerate repository contents.")
        }

        let base = root.path + "/"
        var collected: [String] = []
        var truncated = false

        while let item = enumerator.nextObject() as? URL {
            let path = item.path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count))
            if relative.isEmpty { continue }
            if relative == ".git" || relative.hasPrefix(".git/") {
                enumerator.skipDescendants()
                continue
            }
            if let values = try? item.resourceValues(forKeys: Set(keys)), values.isDirectory == true {
                continue
            }
            collected.append(relative)
            if collected.count >= limit {
                truncated = true
                break
            }
        }
        return (collected, truncated, encounteredError)
    }

    private func handleBrowserSelection(path: String) {
#if canImport(AppKit)
        previewImageTask?.cancel()
        previewImage = nil
#endif
        vm.selectedPath = path
        if let change = vm.changes.first(where: { $0.path == path }) {
            if change.worktree != nil {
                vm.selectedSide = .unstaged
            } else {
                vm.selectedSide = .staged
            }
            vm.showPreviewInsteadOfDiff = isImagePath(path)
        } else {
            vm.selectedSide = .unstaged
            vm.showPreviewInsteadOfDiff = true
        }
        Task {
            await vm.refreshDetail()
#if canImport(AppKit)
            loadPreviewImageIfNeeded()
#endif
        }
    }

#if canImport(AppKit)
    private func revealBrowserItem(path: String, isDirectory: Bool) {
        revealInFinder(path: path, isDirectory: isDirectory)
    }
#endif
}
