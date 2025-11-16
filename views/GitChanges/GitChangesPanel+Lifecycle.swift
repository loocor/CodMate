import SwiftUI

extension GitChangesPanel {
    // MARK: - Lifecycle Modifier
    struct LifecycleModifier: ViewModifier {
        @Binding var expandedDirsStaged: Set<String>
        @Binding var expandedDirsUnstaged: Set<String>
        @Binding var expandedDirsBrowser: Set<String>
        @Binding var savedState: ReviewPanelState
        @Binding var mode: ReviewPanelState.Mode
        let vm: GitChangesViewModel
        let treeQuery: String
        let onSearchQueryChanged: (String) -> Void
        let onRebuildNodes: () -> Void
        let onRebuildDisplayed: () -> Void
        let onEnsureExpandAll: () -> Void
        let onRebuildBrowserDisplayed: () -> Void
        let onRefreshBrowserTree: () -> Void

        func body(content: Content) -> some View {
            var view = AnyView(
                content.onAppear {
                    restoreState()
                    onRebuildNodes()
                    onRebuildDisplayed()
                    onRebuildBrowserDisplayed()
                    onEnsureExpandAll()
                    onSearchQueryChanged(treeQuery)
                    if mode == .browser { onRefreshBrowserTree() }
                }
            )

            view = AnyView(
                view.onChange(of: vm.treeSnapshot) { _, _ in
                    onRebuildNodes()
                    onEnsureExpandAll()
                    if mode == .browser { onRefreshBrowserTree() }
                }
            )

            view = AnyView(
                view.onChange(of: treeQuery) { _, newValue in
                    onSearchQueryChanged(newValue)
                    onRebuildDisplayed()
                    onRebuildBrowserDisplayed()
                }
            )

            view = AnyView(
                view.onChange(of: expandedDirsStaged) { _, newVal in
                    savedState.expandedDirsStaged = newVal
                }
            )

            view = AnyView(
                view.onChange(of: expandedDirsUnstaged) { _, newVal in
                    savedState.expandedDirsUnstaged = newVal
                }
            )

            view = AnyView(
                view.onChange(of: expandedDirsBrowser) { _, newVal in
                    savedState.expandedDirsBrowser = newVal
                    onRebuildBrowserDisplayed()
                }
            )

            view = AnyView(
                view.onChange(of: vm.selectedPath) { _, newVal in
                    savedState.selectedPath = newVal
                }
            )

            view = AnyView(
                view.onChange(of: vm.selectedSide) { _, newVal in
                    savedState.selectedSideStaged = (newVal == .staged)
                }
            )

            view = AnyView(
                view.onChange(of: vm.showPreviewInsteadOfDiff) { _, newVal in
                    savedState.showPreview = newVal
                }
            )

            view = AnyView(
                view.onChange(of: vm.commitMessage) { _, newVal in
                    savedState.commitMessage = newVal
                }
            )

            view = AnyView(
                view.onChange(of: mode) { _, newVal in
                    savedState.mode = newVal
                    if newVal == .browser {
                        onRebuildBrowserDisplayed()
                        onRefreshBrowserTree()
                    }
                }
            )

            // Persist Graph visibility flag when it changes
            view = AnyView(
                view.onChange(of: savedState.showGraph) { _, _ in
                    // No-op: wiring point retained for completeness
                }
            )

            return view
        }

        private func restoreState() {
            var initial = savedState
            // Migrate legacy browser mode to diff mode:
            // Since the default mode has changed from .browser to .diff,
            // automatically migrate any saved .browser state to .diff.
            // User can still manually switch to browser or graph if needed.
            if initial.mode == .browser {
                initial.mode = .diff
                savedState = initial
            }

            if !initial.expandedDirsStaged.isEmpty || !initial.expandedDirsUnstaged.isEmpty {
                expandedDirsStaged = initial.expandedDirsStaged
                expandedDirsUnstaged = initial.expandedDirsUnstaged
            } else if !initial.expandedDirs.isEmpty {
                expandedDirsStaged = initial.expandedDirs
                expandedDirsUnstaged = initial.expandedDirs
            }
            if !initial.expandedDirsBrowser.isEmpty {
                expandedDirsBrowser = initial.expandedDirsBrowser
            }
            mode = initial.mode
            vm.selectedPath = initial.selectedPath
            if let stagedSide = initial.selectedSideStaged {
                vm.selectedSide = stagedSide ? .staged : .unstaged
            }
            vm.showPreviewInsteadOfDiff = initial.showPreview
            vm.commitMessage = initial.commitMessage
        }
    }
}
