import AppKit
import OSLog
import Foundation

@MainActor
final class GitChangesViewModel: ObservableObject {
    private static let log = Logger(subsystem: "ai.codmate.app", category: "AICommit")
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
    @Published var isGenerating: Bool = false
    @Published private(set) var generatingRepoPath: String? = nil

    private let service = GitService()
    private var monitorWorktree: DirectoryMonitor?
    private var monitorIndex: DirectoryMonitor?
    private var refreshTask: Task<Void, Never>? = nil
    private var repo: GitService.Repo? = nil
    private var generatingTask: Task<Void, Never>? = nil

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

    // Explicit stage only
    func stage(paths: [String]) async {
        guard let repo = self.repo, !paths.isEmpty else { return }
        await service.stage(in: repo, paths: paths)
        await refreshStatus()
    }

    // Explicit unstage only
    func unstage(paths: [String]) async {
        guard let repo = self.repo, !paths.isEmpty else { return }
        await service.unstage(in: repo, paths: paths)
        await refreshStatus()
    }

    // Folder action: stage remaining if not all staged, otherwise unstage all
    func applyFolderStaging(for dirKey: String, paths: [String]) async {
        guard !paths.isEmpty else { return }
        let stagedSet: Set<String> = Set(changes.compactMap { ($0.staged != nil) ? $0.path : nil })
        let allStaged = paths.allSatisfy { stagedSet.contains($0) }
        if allStaged {
            await unstage(paths: paths)
        } else {
            let toStage = paths.filter { !stagedSet.contains($0) }
            await stage(paths: toStage)
        }
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

    // MARK: - Commit message generation (minimal pass)
    func generateCommitMessage(providerId: String? = nil, modelId: String? = nil, maxBytes: Int = 128 * 1024) {
        // Debounce: if already generating for the same repo, ignore
        if isGenerating, let current = repoRoot?.path, generatingRepoPath == current {
            print("[AICommit] Debounced: generation already in progress for repo=\(current)")
            Self.log.info("Debounced: generation already in progress for repo=\(current, privacy: .public)")
            return
        }
        generatingTask = Task { [weak self] in
            guard let self else { return }
            guard let repo = self.repo else {
                await MainActor.run { self.errorMessage = "Not a Git repository" }
                return
            }
            let repoPath = repo.root.path
            await MainActor.run {
                self.isGenerating = true
                self.generatingRepoPath = repoPath
            }
            defer { Task { @MainActor in
                self.isGenerating = false
                self.generatingRepoPath = nil
            } }
            // Fetch staged diff (index vs HEAD)
            let full = await self.service.stagedUnifiedDiff(in: repo)
            if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run { self.errorMessage = "No staged changes to summarize" }
                print("[AICommit] No staged changes; generation skipped")
                Self.log.info("No staged changes; generation skipped")
                return
            }
            // Truncate by bytes for safety
            let truncated = Self.prefixBytes(of: full, maxBytes: maxBytes)
            let prompt = Self.commitPrompt(diff: truncated)
            let llm = LLMHTTPService()
            print("[AICommit] Start generation providerId=\(providerId ?? "(auto)") bytes=\(truncated.utf8.count)")
            Self.log.info("Start generation providerId=\(providerId ?? "(auto)", privacy: .public) bytes=\(truncated.utf8.count)")
            do {
                let res = try await llm.generateText(prompt: prompt, options: .init(preferred: .auto, model: modelId, timeout: 25, providerId: providerId))
                let cleaned = Self.cleanCommitMessage(from: res.text)
                await MainActor.run {
                    if self.repoRoot?.path == repoPath {
                        self.commitMessage = cleaned
                    } else {
                        // Repo changed during generation; drop the result
                        print("[AICommit] Repo switched during generation; result discarded for repo=\(repoPath)")
                    }
                }
                let preview = cleaned.prefix(120)
                print("[AICommit] Success provider=\(res.providerId) elapsedMs=\(res.elapsedMs) msg=\(preview)")
                Self.log.info("Success provider=\(res.providerId, privacy: .public) elapsedMs=\(res.elapsedMs) msg=\(String(preview), privacy: .public)")
            } catch {
                print("[AICommit] Error: \(error.localizedDescription)")
                Self.log.error("Generation error: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.errorMessage = "AI generation failed" }
            }
        }
    }

    private static func prefixBytes(of s: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = s.data(using: .utf8) ?? Data()
        if data.count <= maxBytes { return s }
        let slice = data.prefix(maxBytes)
        return String(data: slice, encoding: .utf8) ?? String(s.prefix(maxBytes / 2))
    }

    private static func commitPrompt(diff: String) -> String {
        // Allow user override via Settings › Git Review template stored in preferences.
        // The template acts as a preamble; we always append the diff after it.
        let key = "git.review.commitPromptTemplate"
        if let tpl = UserDefaults.standard.string(forKey: key), !tpl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tpl + "\n\nDiff:\n" + diff
        }
        var body: [String] = []
        body.append("You are a helpful assistant that writes Conventional Commits in imperative mood.")
        body.append("Task: produce a high‑quality commit message with:")
        body.append("1) A concise subject line (type: scope? subject)")
        body.append("2) A brief body (2–4 lines or bullets) explaining motivation and key changes")
        body.append("Constraints: subject <= 80 chars; wrap body lines <= 72 chars; no trailing period in subject.")
        body.append("")
        body.append("Consider the staged diff below (may be truncated):")
        body.append("Diff:")
        body.append(diff)
        return body.joined(separator: "\n")
    }

    private static func cleanCommitMessage(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove surrounding code fences if any
        if s.hasPrefix("```") {
            if let range = s.range(of: "```", options: [], range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex) {
                s = String(s[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let end = s.range(of: "```") { s = String(s[..<end.lowerBound]) }
            }
        }
        // Strip surrounding quotes if the whole text is quoted
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        // Collapse spaces
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }
}
