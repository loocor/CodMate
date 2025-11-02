import Foundation

// Lightweight, per-session UI state for the Review (Git Changes) panel.
// Keeps tree expansion/selection, view mode, and in-progress commit message.
struct ReviewPanelState: Equatable {
    var expandedDirs: Set<String> = []
    var selectedPath: String? = nil
    // true = staged side; false = unstaged; nil = default (unstaged)
    var selectedSideStaged: Bool? = nil
    var showPreview: Bool = false
    var commitMessage: String = ""
}
