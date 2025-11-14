import Foundation
import SwiftUI

@MainActor
final class GitGraphViewModel: ObservableObject {
    @Published private(set) var commits: [GitService.GraphCommit] = []
    @Published var filteredCommits: [GitService.GraphCommit] = []
    @Published var selectedCommit: GitService.GraphCommit? = nil
    @Published var searchQuery: String = ""
    @Published private(set) var commitPatch: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String? = nil
    // Graph lane layout
    struct LaneInfo: Sendable, Hashable {
        var laneIndex: Int                // index of the commit's own lane
        var parentLaneIndices: [Int]      // lane indices of parents in next row
        var activeLaneCount: Int          // lanes count to consider for verticals this row
        var continuingLanes: Set<Int>     // lanes that should show a vertical line in this row
    }
    @Published private(set) var laneInfoById: [String: LaneInfo] = [:]
    @Published private(set) var maxLaneCount: Int = 1

    private let service = GitService()
    private var repo: GitService.Repo? = nil
    private var refreshTask: Task<Void, Never>? = nil

    // Branch scope controls
    @Published var showAllBranches: Bool = true
    @Published var showRemoteBranches: Bool = true
    @Published var limit: Int = 300
    @Published var branches: [String] = []
    @Published var selectedBranch: String? = nil   // nil = current HEAD when showAllBranches == false
    @Published private(set) var workingChangesCount: Int = 0

    func attach(to root: URL?) {
        guard let root else { commits = []; filteredCommits = []; return }
        if SecurityScopedBookmarks.shared.isSandboxed {
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: root)
        }
        self.repo = GitService.Repo(root: root)
        loadBranches()
        loadCommits()
    }

    func loadCommits(limit: Int = 200) {
        guard let repo = self.repo else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            isLoading = true
            let list = await service.logGraphCommits(
                in: repo,
                limit: self.limit,
                includeAllBranches: self.showAllBranches,
                includeRemoteBranches: self.showRemoteBranches,
                singleRef: (self.showAllBranches ? nil : (self.selectedBranch?.isEmpty == false ? self.selectedBranch : nil))
            )
            // Working tree virtual entry
            let status = await service.status(in: repo)
            self.workingChangesCount = status.count
            var finalList = list
            if self.workingChangesCount > 0 {
                let headId = list.first?.id
                let virtual = GitService.GraphCommit(
                    id: "::working-tree::",
                    shortId: "*",
                    author: "*",
                    date: "0 seconds ago",
                    subject: "Uncommitted Changes (\(status.count))",
                    parents: headId != nil ? [headId!] : [],
                    decorations: []
                )
                finalList = [virtual] + list
            }
            isLoading = false
            self.commits = finalList
            applyFilter()
            if selectedCommit == nil { selectedCommit = list.first }
            computeLaneLayout()
            await loadPatchForSelection()
        }
    }

    func applyFilter() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { filteredCommits = commits; return }
        filteredCommits = commits.filter { c in
            if c.subject.lowercased().contains(q) { return true }
            if c.author.lowercased().contains(q) { return true }
            if c.shortId.lowercased().contains(q) { return true }
            if c.decorations.joined(separator: ",").lowercased().contains(q) { return true }
            return false
        }
    }

    func selectCommit(_ c: GitService.GraphCommit) {
        selectedCommit = c
        Task { await loadPatchForSelection() }
    }

    func loadPatchForSelection() async {
        guard let repo = self.repo, let id = selectedCommit?.id else { commitPatch = ""; return }
        if id == "::working-tree::" { commitPatch = ""; return }
        let text = await service.commitPatch(in: repo, commitId: id)
        commitPatch = text
    }

    // MARK: - Lanes
    private func computeLaneLayout() {
        guard !commits.isEmpty else {
            laneInfoById = [:]
            maxLaneCount = 1
            return
        }
        // lanes array holds the commit SHA expected to appear in that lane in the NEXT row
        var lanes: [String?] = []
        var byId: [String: LaneInfo] = [:]
        var maxLanes = 1

        for commit in commits {
            let before = lanes // snapshot for continuing determination

            // Determine current lane for this commit
            let laneIndex: Int
            if let idx = lanes.firstIndex(where: { $0 == commit.id }) {
                laneIndex = idx
            } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                laneIndex = empty
                if empty >= lanes.count { lanes.append(nil) }
            } else {
                laneIndex = lanes.count
                lanes.append(nil)
            }

            // Assign parents to lanes for the next row
            var parentLaneIndices: [Int] = []
            if let firstParent = commit.parents.first {
                // First parent continues the current lane
                if laneIndex < lanes.count { lanes[laneIndex] = firstParent } else {
                    // shouldn't happen, but be safe
                    lanes.append(firstParent)
                }
                parentLaneIndices.append(laneIndex)
                // Additional parents take other lanes (existing if present, else empty slot, else append)
                if commit.parents.count > 1 {
                    for p in commit.parents.dropFirst() {
                        if let existing = lanes.firstIndex(where: { $0 == p }) {
                            parentLaneIndices.append(existing)
                        } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                            lanes[empty] = p
                            parentLaneIndices.append(empty)
                        } else {
                            lanes.append(p)
                            parentLaneIndices.append(lanes.count - 1)
                        }
                    }
                }
            } else {
                // No parents; lane ends here
                if laneIndex < lanes.count { lanes[laneIndex] = nil }
            }

            // Trim trailing nils to keep lane array compact
            while let last = lanes.last, last == nil { _ = lanes.popLast() }

            let after = lanes
            let activeCount = max(before.count, after.count)
            var continuing: Set<Int> = []
            if activeCount > 0 {
                for i in 0..<activeCount {
                    let hasBefore = i < before.count ? (before[i] != nil || i == laneIndex) : false
                    let hasAfter = i < after.count ? (after[i] != nil) : false
                    if hasBefore || hasAfter { continuing.insert(i) }
                }
            }

            byId[commit.id] = LaneInfo(
                laneIndex: laneIndex,
                parentLaneIndices: parentLaneIndices,
                activeLaneCount: activeCount,
                continuingLanes: continuing
            )
            if let localMax = (parentLaneIndices + [laneIndex]).max() {
                maxLanes = max(maxLanes, localMax + 1)
            } else {
                maxLanes = max(maxLanes, laneIndex + 1)
            }
        }
        laneInfoById = byId
        maxLaneCount = max(1, maxLanes)
    }

    func loadBranches() {
        guard let repo else { branches = []; return }
        Task { [weak self] in
            guard let self else { return }
            let names = await service.listBranches(in: repo, includeRemoteBranches: showRemoteBranches)
            await MainActor.run { self.branches = names }
        }
    }
}
