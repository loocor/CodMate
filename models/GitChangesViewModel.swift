import AppKit
import Foundation

@MainActor
final class GitChangesViewModel: ObservableObject {
    @Published private(set) var repoRoot: URL? = nil
    @Published private(set) var changes: [GitService.Change] = []
    @Published var selectedPath: String? = nil
    enum CompareSide: Equatable { case unstaged, staged }
    @Published var selectedSide: CompareSide = .unstaged
    @Published var showPreviewInsteadOfDiff: Bool = false
    @Published var diffText: String = ""  // or file preview text when in preview mode
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var commitMessage: String = ""

    private let service = GitService()
    private var monitorWorktree: DirectoryMonitor?
    private var monitorIndex: DirectoryMonitor?
    private var refreshTask: Task<Void, Never>? = nil
    private var repo: GitService.Repo? = nil

    func attach(to directory: URL) {
        Task { [weak self] in
            guard let self else { return }
            await self.resolveRepoRoot(from: directory)
            await self.refreshStatus()
            self.configureMonitors()
        }
    }

    func detach() {
        monitorWorktree?.cancel(); monitorWorktree = nil
        monitorIndex?.cancel(); monitorIndex = nil
        repo = nil
        repoRoot = nil
        changes = []
        selectedPath = nil
        diffText = ""
    }

    private func resolveRepoRoot(from directory: URL) async {
        let canonical = directory
        if let repo = await service.repositoryRoot(for: canonical) {
            self.repo = repo
            self.repoRoot = repo.root
        } else {
            self.repo = nil
            self.repoRoot = nil
        }
    }

    private func configureMonitors() {
        guard let root = repoRoot else { return }
        // Monitor the worktree directory (non-recursive; still good enough to get write pulses)
        monitorWorktree?.cancel()
        monitorWorktree = DirectoryMonitor(url: root) { [weak self] in self?.scheduleRefresh() }
        // Monitor .git/index changes (staging updates)
        let indexURL = root.appendingPathComponent(".git/index")
        monitorIndex?.cancel()
        monitorIndex = DirectoryMonitor(url: indexURL) { [weak self] in self?.scheduleRefresh() }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.refreshStatus()
        }
    }

    func refreshStatus() async {
        guard let repo = self.repo else {
            changes = []; selectedPath = nil; diffText = ""; return
        }
        isLoading = true
        let list = await service.status(in: repo)
        isLoading = false
        changes = list
        // Maintain selection when possible
        if let sel = selectedPath, !list.contains(where: { $0.path == sel }) {
            selectedPath = nil
            diffText = ""
        }
        await refreshDetail()
    }

    func refreshDetail() async {
        guard let repo = self.repo, let path = selectedPath else { diffText = ""; return }
        if showPreviewInsteadOfDiff {
            let text = await service.readFile(in: repo, path: path)
            diffText = text
        } else {
            // VS Code-like rule: staged selection shows index vs HEAD; unstaged shows worktree vs index.
            // Fallbacks: if staged diff is empty but unstaged exists, show unstaged; if untracked and unstaged, synthesize.
            let isStagedSide = (selectedSide == .staged)
            var text = await service.diff(in: repo, path: path, staged: isStagedSide)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // If we're on staged view but diff is empty, try unstaged view as a fallback
                if isStagedSide {
                    text = await service.diff(in: repo, path: path, staged: false)
                }
                // If still empty and the file is untracked in worktree, synthesize full-add diff
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let kind = changes.first(where: { $0.path == path })?.worktree, kind == .untracked {
                    let content = await service.readFile(in: repo, path: path)
                    text = Self.syntheticDiff(forPath: path, content: content)
                }
            }
            diffText = text
        }
    }

    private static func syntheticDiff(forPath path: String, content: String) -> String {
        // Produce a minimal unified diff for a new (untracked) file vs /dev/null
        let lines = content.split(separator: "\\n", omittingEmptySubsequences: false)
        let count = lines.count
        var out: [String] = []
        out.append("--- /dev/null")
        out.append("+++ b/\(path)")
        out.append("@@ -0,0 +\(count) @@")
        for l in lines { out.append("+" + String(l)) }
        return out.joined(separator: "\\n")
    }


    func toggleStage(for paths: [String]) async {
        guard let repo = self.repo else { return }
        // Determine which ones are staged
        let staged: Set<String> = Set(changes.compactMap { ($0.staged != nil) ? $0.path : nil })
        let toUnstage = paths.filter { staged.contains($0) }
        let toStage = paths.filter { !staged.contains($0) }
        if !toStage.isEmpty { await service.stage(in: repo, paths: toStage) }
        if !toUnstage.isEmpty { await service.unstage(in: repo, paths: toUnstage) }
        await refreshStatus()
    }

    func commit() async {
        guard let repo = self.repo else { return }
        let code = await service.commit(in: repo, message: commitMessage)
        if code == 0 {
            commitMessage = ""
            await refreshStatus()
        } else {
            errorMessage = "Commit failed (exit code \(code))"
        }
    }

    // MARK: - Discard
    func discard(paths: [String]) async {
        guard let repo = self.repo else { return }
        let pathSet = Set(paths)
        let map: [String: GitService.Change] = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        let untracked = pathSet.filter { (map[$0]?.worktree == .untracked) }
        let tracked = pathSet.subtracting(untracked)
        if !tracked.isEmpty {
            _ = await service.discardTracked(in: repo, paths: Array(tracked))
        }
        if !untracked.isEmpty {
            _ = await service.cleanUntracked(in: repo, paths: Array(untracked))
        }
        await refreshStatus()
    }

    // MARK: - Open in external editor (file)
    func openFile(_ path: String, using editor: EditorApp) {
        guard let root = repoRoot else { return }
        let filePath = root.appendingPathComponent(path).path
        // Try CLI command first
        if let exe = Self.findExecutableInPath(editor.cliCommand) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = [filePath]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do {
                try p.run(); return
            } catch {
                // fall through
            }
        }
        // Fallback: open via bundle id
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: filePath)], withApplicationAt: appURL, configuration: config) { _, err in
                if let err {
                    Task { @MainActor in self.errorMessage = "Failed to open \(editor.title): \(err.localizedDescription)" }
                }
            }
            return
        }
        errorMessage = "\(editor.title) is not installed. Please install it or try a different editor."
    }

    private static func findExecutableInPath(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        do {
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch { return nil }
    }
}
