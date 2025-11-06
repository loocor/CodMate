import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct GitChangesPanel: View {
    enum Presentation { case embedded, full }
    let workingDirectory: URL
    var presentation: Presentation = .embedded
    let preferences: SessionPreferencesStore
    var onRequestAuthorization: (() -> Void)? = nil
    @Binding var savedState: ReviewPanelState
    @StateObject var vm = GitChangesViewModel()
    // Layout state
    @State var leftColumnWidth: CGFloat = 0   // 0 = init to 1/4 of container
    @State var commitEditorHeight: CGFloat = 28
    // Tree state (keep staged/unstaged expansions independent)
    @State var expandedDirsStaged: Set<String> = []
    @State var expandedDirsUnstaged: Set<String> = []
    @State var treeQuery: String = ""
    // Cached trees for performance
    @State var cachedNodes: [FileNode] = [] // legacy (all)
    @State var displayedNodes: [FileNode] = [] // legacy (all)
    @State var cachedNodesStaged: [FileNode] = []
    @State var cachedNodesUnstaged: [FileNode] = []
    @State var displayedStaged: [FileNode] = []
    @State var displayedUnstaged: [FileNode] = []
    @State var stagedCollapsed: Bool = false
    @State var unstagedCollapsed: Bool = false
    @State var commitInlineHeight: CGFloat = 20
    @State var mode: ReviewPanelState.Mode = .diff
    @State var expandedDirsBrowser: Set<String> = []
    @State var browserNodes: [FileNode] = []
    @State var displayedBrowserRows: [BrowserRow] = []
    @State var isLoadingBrowserTree: Bool = false
    @State var browserTreeError: String? = nil
    @State var browserTreeTruncated: Bool = false
    @State var browserTotalEntries: Int = 0
    @State var browserTreeTask: Task<Void, Never>? = nil
    // Hover state for quick actions
    @State var hoverFilePath: String? = nil
    @State var hoverDirKey: String? = nil
    @State var hoverEditPath: String? = nil
    @State var hoverRevertPath: String? = nil
    @State var hoverStagePath: String? = nil
    @State var hoverDirButtonPath: String? = nil
    @State var hoverBrowserFilePath: String? = nil
    @State var hoverBrowserRevealPath: String? = nil
    @State var hoverBrowserEditPath: String? = nil
    @State var hoverBrowserStagePath: String? = nil
    @State var hoverBrowserDirKey: String? = nil
    @State var hoverStagedHeader: Bool = false
    @State var hoverUnstagedHeader: Bool = false
    @State var pendingDiscardPaths: [String] = []
    @State var showDiscardAlert: Bool = false
    @State var showCommitConfirm: Bool = false
    // Use an optional Int for segmented momentary actions: 0=collapse, 1=expand
    // @State private var treeToggleIndex: Int? = nil
    // Layout constraints
    let leftMin: CGFloat = 280
    let leftMax: CGFloat = 520
    let commitMinHeight: CGFloat = 140
    // Indent guide metrics (horizontal):
    // - indentStep: per-depth indent distance (matches VS Code's 16px)
    // - chevronWidth: width reserved for disclosure chevron
    let indentStep: CGFloat = 16
    let chevronWidth: CGFloat = 16
    let quickActionWidth: CGFloat = 18
    let quickActionHeight: CGFloat = 16
    let trailingPad: CGFloat = 8
    let hoverButtonSpacing: CGFloat = 8
    let statusBadgeWidth: CGFloat = 18
    let browserEntryLimit: Int = 6000
    // Viewer options (from Settings › Git Review). Defaults: line numbers ON, wrap OFF
    var wrapText: Bool { preferences.gitWrapText }
    var showLineNumbers: Bool { preferences.gitShowLineNumbers }
    // Wand button metrics
    let wandButtonSize: CGFloat = 24
    var wandReservedTrailing: CGFloat { wandButtonSize } // equal-width indent to avoid overlap
    @State var hoverWand: Bool = false
#if canImport(AppKit)
    @State var previewImage: NSImage? = nil
    @State var previewImageTask: Task<Void, Never>? = nil
#endif

    var body: some View {
        Group {
            if vm.repoRoot == nil {
                if vm.isResolvingRepo {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Resolving repository access…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.rectangle.on.rectangle")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Git Review Unavailable")
                            .font(.headline)
                        Text("This folder is either not a Git repository or requires permission. Authorize the repository root (the folder containing .git).")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 520)
                        Button("Authorize Repository Folder…") {
                            onRequestAuthorization?()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                contentWithPresentation
            }
        }
            .onReceive(NotificationCenter.default.publisher(for: .codMateRepoAuthorizationChanged)) { _ in
                vm.attach(to: workingDirectory)
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
            .confirmationDialog(
                "Commit changes?",
                isPresented: $showCommitConfirm,
                titleVisibility: .visible
            ) {
                Button("Commit", role: .destructive) { Task { await vm.commit() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                let msg = vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.isEmpty {
                    Text("This will create a commit for staged changes.")
                } else {
                    Text("Commit message:\n\n\(msg)")
                }
            }
            .task(id: workingDirectory) {
                vm.attach(to: workingDirectory)
            }
            .task(id: vm.repoRoot?.path) {
                browserNodes = []
                displayedBrowserRows = []
                browserTreeError = nil
                if mode == .browser {
                    reloadBrowserTreeIfNeeded(force: true)
                }
            }
            .modifier(LifecycleModifier(
                expandedDirsStaged: $expandedDirsStaged,
                expandedDirsUnstaged: $expandedDirsUnstaged,
                expandedDirsBrowser: $expandedDirsBrowser,
                savedState: $savedState,
                mode: $mode,
                vm: vm,
                treeQuery: treeQuery,
                onRebuildNodes: rebuildNodes,
                onRebuildDisplayed: rebuildDisplayed,
                onEnsureExpandAll: ensureExpandAllIfNeeded,
                onRebuildBrowserDisplayed: rebuildBrowserDisplayed,
                onRefreshBrowserTree: { reloadBrowserTreeIfNeeded(force: false) }
            ))
    }

    private var contentWithPresentation: some View {
        Group {
            switch presentation {
            case .embedded:
                baseContent
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .full:
                baseContent
            }
        }
    }

    // Extracted heavy content to reduce body type-checking complexity
    private var baseContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VSplitView {
                GeometryReader { geo in
                    splitContent(totalWidth: geo.size.width)
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
    }

    private func splitContent(totalWidth: CGFloat) -> some View {
        // Top split: left file tree and right diff/preview, with draggable divider
        let leftW = effectiveLeftWidth(total: totalWidth)
        let gutterW: CGFloat = 33 // divider 1pt + 8pt padding each side
        let rightW = max(totalWidth - gutterW - leftW, 240)
        return HStack(spacing: 0) {
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
                let newW = clampLeftWidth(leftColumnWidth + value.translation.width, total: totalWidth)
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
    }

    private func ensureExpandAllIfNeeded() {
        if expandedDirsStaged.isEmpty {
            expandedDirsStaged = Set(allDirectoryKeys(nodes: cachedNodesStaged))
        }
        if expandedDirsUnstaged.isEmpty {
            expandedDirsUnstaged = Set(allDirectoryKeys(nodes: cachedNodesUnstaged))
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
    func measureCommitHeight(_ text: String, width: CGFloat) -> CGFloat {
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
    struct FileNode: Identifiable {
        let id = UUID()
        var name: String
        var fullPath: String? // non-nil for files
        var dirPath: String? = nil // non-nil for directories
        var children: [FileNode]? = nil
        var isDirectory: Bool { dirPath != nil }
    }

    // MARK: - TreeScope enum
    enum TreeScope { case unstaged, staged }

    func makeTree(from changes: [GitService.Change]) -> [FileNode] {
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
            for (k, v) in b.children {
                if let p = v.filePath, v.children.isEmpty {
                    nodes.append(FileNode(name: k, fullPath: p, dirPath: nil, children: nil))
                } else {
                    let key = (name == nil) ? k : (name! + "/" + k)
                    let children = explorerSort(convert(v, name: key))
                    nodes.append(FileNode(name: k, fullPath: nil, dirPath: key, children: children))
                }
            }
            return explorerSort(nodes)
        }
        return convert(root)
    }
}
