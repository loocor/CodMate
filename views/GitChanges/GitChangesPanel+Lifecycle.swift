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
                    if mode == .browser { onRefreshBrowserTree() }
                }
            )

            view = AnyView(
                view.onChange(of: vm.changes) { _, _ in
                    onRebuildNodes()
                    onEnsureExpandAll()
                    if mode == .browser { onRefreshBrowserTree() }
                }
            )

            view = AnyView(
                view.onChange(of: treeQuery) { _, _ in
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

            return view
        }

        private func restoreState() {
            if !savedState.expandedDirsStaged.isEmpty || !savedState.expandedDirsUnstaged.isEmpty {
                expandedDirsStaged = savedState.expandedDirsStaged
                expandedDirsUnstaged = savedState.expandedDirsUnstaged
            } else if !savedState.expandedDirs.isEmpty {
                expandedDirsStaged = savedState.expandedDirs
                expandedDirsUnstaged = savedState.expandedDirs
            }
            if !savedState.expandedDirsBrowser.isEmpty {
                expandedDirsBrowser = savedState.expandedDirsBrowser
            }
            mode = savedState.mode
            vm.selectedPath = savedState.selectedPath
            if let stagedSide = savedState.selectedSideStaged {
                vm.selectedSide = stagedSide ? .staged : .unstaged
            }
            vm.showPreviewInsteadOfDiff = savedState.showPreview
            vm.commitMessage = savedState.commitMessage
        }
    }
}
