import Foundation

// Lightweight, per-session UI state for the Review (Git Changes) panel.
// Keeps tree expansion/selection, view mode, and in-progress commit message.
struct ReviewPanelState: Equatable {
    enum Mode: Equatable {
        case diff
        case browser
        case graph
    }

    // Legacy combined set (pre-branching); still read for backward restore.
    var expandedDirs: Set<String> = []
    // New: independent expansion for staged/unstaged trees
    var expandedDirsStaged: Set<String> = []
    var expandedDirsUnstaged: Set<String> = []
    var selectedPath: String? = nil
    // true = staged side; false = unstaged; nil = default (unstaged)
    var selectedSideStaged: Bool? = nil
    var showPreview: Bool = false
    var commitMessage: String = ""
    var mode: Mode = .diff
    var expandedDirsBrowser: Set<String> = []
    // Whether the Git Graph view is visible in the right detail area.
    // This is a lightweight UI flag; it is safe if not restored.
    // Kept here to allow persistence across app runs if desired.
    var showGraph: Bool = false
}

extension ReviewPanelState.Mode {
    mutating func toggle() {
        self = (self == .diff) ? .browser : .diff
    }
}
