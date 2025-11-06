import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension GitChangesPanel {
    @ViewBuilder
    func treeRows(nodes: [FileNode], depth: Int, scope: TreeScope) -> some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                // Directory row with VS Code-style layout
                let key = node.dirPath ?? ""
                let isExpanded: Bool = {
                    switch scope {
                    case .staged: return expandedDirsStaged.contains(key)
                    case .unstaged: return expandedDirsUnstaged.contains(key)
                    }
                }()
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
                    }
                    .padding(.trailing, (hoverDirKey == (node.dirPath ?? "")) ? (quickActionWidth + trailingPad) : trailingPad)
                    .overlay(alignment: .trailing) {
                        if let dir = node.dirPath {
                            HStack(spacing: hoverButtonSpacing) {
                                Button(action: {
                                    Task {
                                        let paths = filePaths(under: dir)
                                        guard !paths.isEmpty else { return }
                                        if scope == .staged { await vm.unstage(paths: paths) }
                                        else { await vm.stage(paths: paths) }
                                    }
                                }) {
                                    Image(systemName: scope == .staged ? "minus.circle" : "plus.circle")
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { hoverDirButtonPath = dir } else if hoverDirButtonPath == dir { hoverDirButtonPath = nil }
                                }
                                .frame(width: quickActionWidth, height: quickActionHeight)
                            }
                            .foregroundStyle((hoverDirButtonPath == dir) ? Color.accentColor : Color.secondary)
                            .opacity((hoverDirKey == dir) ? 1 : 0)
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
                    if let k = node.dirPath {
                        switch scope {
                        case .staged:
                            if expandedDirsStaged.contains(k) { expandedDirsStaged.remove(k) } else { expandedDirsStaged.insert(k) }
                        case .unstaged:
                            if expandedDirsUnstaged.contains(k) { expandedDirsUnstaged.remove(k) } else { expandedDirsUnstaged.insert(k) }
                        }
                    }
                }
                .onHover { inside in
                    if let key = node.dirPath {
                        if inside { hoverDirKey = key } else if hoverDirKey == key { hoverDirKey = nil }
                    }
                }
                .contextMenu {
                    if let dir = node.dirPath {
                        let allPaths = filePaths(under: dir)
                        if scope == .staged {
                            Button("Unstage Folder") { Task { await vm.unstage(paths: allPaths) } }
                        } else {
                            Button("Stage Folder") { Task { await vm.stage(paths: allPaths) } }
                        }
#if canImport(AppKit)
                        Button("Reveal in Finder") {
                            revealInFinder(path: dir, isDirectory: true)
                        }
#endif
                        Divider()
                        Button("Discard Folder Changes…", role: .destructive) {
                            pendingDiscardPaths = allPaths
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
                        let icon = fileTypeIconName(for: path)
                        Image(systemName: icon.name)
                            .font(.system(size: 12))
                            .foregroundStyle(icon.color)
                        Text(node.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.trailing, (hoverFilePath == path)
                        ? (statusBadgeWidth + trailingPad + quickActionWidth*3 + hoverButtonSpacing*2)
                        : (statusBadgeWidth + trailingPad))
                    .overlay(alignment: .trailing) {
                            HStack(spacing: hoverButtonSpacing) {
                            if hoverFilePath == path {
                                Button { vm.openFile(path, using: preferences.defaultFileEditor) } label: {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundStyle((hoverEditPath == path) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { hoverEditPath = path } else if hoverEditPath == path { hoverEditPath = nil }
                                }
                                .frame(width: quickActionWidth, height: quickActionHeight)

                                Button(action: {
                                    pendingDiscardPaths = [path]
                                    showDiscardAlert = true
                                }) {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                        .foregroundStyle((hoverRevertPath == path) ? Color.red : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { hoverRevertPath = path } else if hoverRevertPath == path { hoverRevertPath = nil }
                                }
                                .frame(width: quickActionWidth, height: quickActionHeight)

                                Button(action: {
                                    Task {
                                        if scope == .staged { await vm.unstage(paths: [path]) }
                                        else { await vm.stage(paths: [path]) }
                                    }
                                }) {
                                    Image(systemName: scope == .staged ? "minus.circle" : "plus.circle")
                                        .foregroundStyle((hoverStagePath == path) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { hoverStagePath = path } else if hoverStagePath == path { hoverStagePath = nil }
                                }
                                .frame(width: quickActionWidth, height: quickActionHeight)
                            }

                            if let change = vm.changes.first(where: { $0.path == path }) {
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
                    if scope == .staged {
                        Button("Unstage") { Task { await vm.unstage(paths: [path]) } }
                    } else {
                        Button("Stage") { Task { await vm.stage(paths: [path]) } }
                    }
                    Divider()
                    Button("Open in VS Code") { vm.openFile(path, using: .vscode) }
                    Button("Open in Cursor") { vm.openFile(path, using: .cursor) }
                    Button("Open in Zed") { vm.openFile(path, using: .zed) }
                    Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: vm.repoRoot?.appendingPathComponent(path).path ?? path)) }
#if canImport(AppKit)
                    Button("Reveal in Finder") { revealInFinder(path: path, isDirectory: false) }
#endif
                    Divider()
                    Button("Discard Changes…", role: .destructive) {
                        pendingDiscardPaths = [path]
                        showDiscardAlert = true
                    }
                }
            }
        }
    }
}
