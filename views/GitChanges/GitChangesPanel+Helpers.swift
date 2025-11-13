import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension GitChangesPanel {
    // MARK: - Helper functions for tree manipulation
    func allDirectoryKeys(nodes: [FileNode]) -> [String] {
        var keys: [String] = []
        func walk(_ ns: [FileNode]) {
            for n in ns {
                if let d = n.dirPath { keys.append(d); if let cs = n.children { walk(cs) } }
            }
        }
        walk(nodes)
        return keys
    }

    func filteredNodes(_ nodes: [FileNode], query: String, contentMatches: Set<String>) -> [FileNode] {
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
                } else if let p = n.fullPath {
                    let matchesPath = contentMatches.contains(p)
                    if matchesPath
                        || n.name.localizedCaseInsensitiveContains(q)
                        || p.localizedCaseInsensitiveContains(q)
                    {
                        out.append(n)
                    }
                }
            }
            return out
        }
        return filter(nodes)
    }

    func isImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"].contains(ext)
    }

    // Expand a directory key to concrete file paths present in current change set
    func filePaths(under dirKey: String) -> [String] {
        let prefix = dirKey.hasSuffix("/") ? dirKey : (dirKey + "/")
        return vm.changes.map { $0.path }.filter { $0.hasPrefix(prefix) }
    }

    // All file paths belonging to a specific scope
    func allPaths(in scope: TreeScope) -> [String] {
        switch scope {
        case .staged:
            return vm.changes.compactMap { ($0.staged != nil) ? $0.path : nil }
        case .unstaged:
            return vm.changes.compactMap { ($0.worktree != nil) ? $0.path : nil }
        }
    }

    func rebuildNodes() {
        cachedNodesStaged = vm.treeSnapshot.staged
        cachedNodesUnstaged = vm.treeSnapshot.unstaged
        rebuildDisplayed()
    }

    func rebuildDisplayed() {
        let trimmed = treeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty ? Set<String>() : contentSearchMatches
        displayedStaged = filteredNodes(cachedNodesStaged, query: treeQuery, contentMatches: matches)
        displayedUnstaged = filteredNodes(cachedNodesUnstaged, query: treeQuery, contentMatches: matches)
    }

    // MARK: - Status helpers
    func statusColor(for path: String) -> Color {
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

    // Simple file type icon mapping
    func fileTypeIconName(for path: String) -> (name: String, color: Color) {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return ("swift", .orange)
        case "md": return ("doc.text", .green)
        case "json": return ("curlybraces", .teal)
        case "yml", "yaml": return ("list.bullet", .indigo)
        case "js", "ts", "tsx", "jsx": return ("chevron.left.slash.chevron.right", .yellow)
        case "png", "jpg", "jpeg", "gif", "svg": return ("photo", .purple)
        case "sh", "zsh", "bash": return ("terminal", .gray)
        default: return ("doc.plaintext", .secondary)
        }
    }

    // Helper: Status badge text
    @ViewBuilder
    func statusBadge(for change: GitService.Change) -> some View {
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

    func badgeView(text: String) -> some View {
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

    /// Expand all parent directories for a given file path in browser mode
    func ensureBrowserPathExpanded(_ filePath: String) {
        // Get all parent directory paths
        var pathComponents = filePath.split(separator: "/").map(String.init)
        pathComponents.removeLast() // Remove the file name itself

        var currentPath = ""
        for component in pathComponents {
            if !currentPath.isEmpty {
                currentPath += "/"
            }
            currentPath += component

            // Add to expanded set if not already expanded
            if !expandedDirsBrowser.contains(currentPath) {
                expandedDirsBrowser.insert(currentPath)
            }
        }

        // Rebuild the display to show expanded tree
        rebuildBrowserDisplayed()
    }

#if canImport(AppKit)
    func revealInFinder(path: String, isDirectory: Bool) {
        let base = vm.repoRoot ?? projectDirectory ?? workingDirectory
        let url = base.appendingPathComponent(path, isDirectory: isDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
#endif
}
