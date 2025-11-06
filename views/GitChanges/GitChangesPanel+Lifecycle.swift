import SwiftUI

extension GitChangesPanel {
    // MARK: - Lifecycle Modifier
    struct LifecycleModifier: ViewModifier {
        @Binding var expandedDirsStaged: Set<String>
        @Binding var expandedDirsUnstaged: Set<String>
        @Binding var savedState: ReviewPanelState
        let vm: GitChangesViewModel
        let treeQuery: String
        let onRebuildNodes: () -> Void
        let onRebuildDisplayed: () -> Void
        let onEnsureExpandAll: () -> Void

        func body(content: Content) -> some View {
            content
                .onAppear {
                    // Restore previously saved review panel state for this session
                    if !savedState.expandedDirsStaged.isEmpty || !savedState.expandedDirsUnstaged.isEmpty {
                        expandedDirsStaged = savedState.expandedDirsStaged
                        expandedDirsUnstaged = savedState.expandedDirsUnstaged
                    } else if !savedState.expandedDirs.isEmpty { // legacy fallback
                        expandedDirsStaged = savedState.expandedDirs
                        expandedDirsUnstaged = savedState.expandedDirs
                    }
                    vm.selectedPath = savedState.selectedPath
                    if let stagedSide = savedState.selectedSideStaged {
                        vm.selectedSide = stagedSide ? .staged : .unstaged
                    }
                    vm.showPreviewInsteadOfDiff = savedState.showPreview
                    vm.commitMessage = savedState.commitMessage

                    onRebuildNodes()
                    onRebuildDisplayed()
                    onEnsureExpandAll()
                }
                .onAppear {
                    onEnsureExpandAll()
                }
                .onChange(of: vm.changes) { _, _ in
                    onRebuildNodes()
                    onEnsureExpandAll()
                }
                .onChange(of: treeQuery) { _, _ in
                    onRebuildDisplayed()
                }
                .onChange(of: expandedDirsStaged) { _, newVal in savedState.expandedDirsStaged = newVal }
                .onChange(of: expandedDirsUnstaged) { _, newVal in savedState.expandedDirsUnstaged = newVal }
                .onChange(of: vm.selectedPath) { _, newVal in
                    savedState.selectedPath = newVal
                }
                .onChange(of: vm.selectedSide) { _, newVal in
                    savedState.selectedSideStaged = (newVal == .staged)
                }
                .onChange(of: vm.showPreviewInsteadOfDiff) { _, newVal in
                    savedState.showPreview = newVal
                }
                .onChange(of: vm.commitMessage) { _, newVal in
                    savedState.commitMessage = newVal
                }
        }
    }
}
