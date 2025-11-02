import Foundation

// Actor responsible for interacting with Git in a given working tree.
// Uses `/usr/bin/env git` and a robust PATH as per CLI integration guidance.
actor GitService {
    struct Change: Identifiable, Sendable, Hashable {
        enum Kind: String, Sendable { case modified, added, deleted, untracked }
        let id = UUID()
        var path: String
        var staged: Kind?
        var worktree: Kind?
    }

    struct Repo: Sendable, Hashable {
        var root: URL
    }

    private let envPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    // Discover the git repository root for a directory, or nil if not a repo
    func repositoryRoot(for directory: URL) async -> Repo? {
        guard let out = try? await runGit(["rev-parse", "--show-toplevel"], cwd: directory),
              out.exitCode == 0
        else { return nil }
        let raw = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return Repo(root: URL(fileURLWithPath: raw, isDirectory: true))
    }

    // Aggregate staged/unstaged/untracked status. Prefer name-status to preserve kind when cheap.
    func status(in repo: Repo) async -> [Change] {
        // Parse name-status for both staged and unstaged; fall back to name-only semantics if parsing fails
        let stagedMap: [String: Change.Kind]
        if let out = try? await runGit(["diff", "--name-status", "--cached", "-z"], cwd: repo.root) {
            stagedMap = Self.parseNameStatusZ(out.stdout)
        } else {
            stagedMap = [:]
        }
        
        let unstagedMap: [String: Change.Kind]
        if let out = try? await runGit(["diff", "--name-status", "-z"], cwd: repo.root) {
            unstagedMap = Self.parseNameStatusZ(out.stdout)
        } else {
            unstagedMap = [:]
        }
        
        let untrackedNames = (try? await runGit(["ls-files", "--others", "--exclude-standard", "-z"], cwd: repo.root))?.stdout.split(separator: "\0").map { String($0) } ?? []

        var map: [String: Change] = [:]
        func ensure(_ path: String) -> Change {
            if let c = map[path] { return c }
            let c = Change(path: path, staged: nil, worktree: nil)
            map[path] = c
            return c
        }
        // staged
        for (name, kind) in stagedMap where !name.isEmpty {
            var c = ensure(name)
            c.staged = kind
            map[name] = c
        }
        // unstaged
        for (name, kind) in unstagedMap where !name.isEmpty {
            var c = ensure(name)
            c.worktree = kind
            map[name] = c
        }
        // untracked
        for name in untrackedNames where !name.isEmpty {
            var c = ensure(name)
            c.worktree = .untracked
            map[name] = c
        }

        return Array(map.values).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // Minimal parser for `git diff --name-status -z` output.
    // Handles: M/A/D/T/U and R/C (renames, copies) by attributing to the new path as modified.
    private static func parseNameStatusZ(_ stdout: String) -> [String: Change.Kind] {
        var result: [String: Change.Kind] = [:]
        let tokens = stdout.split(separator: "\0").map(String.init)
        var i = 0
        while i < tokens.count {
            let status = tokens[i]
            guard i + 1 < tokens.count else { break }
            let path1 = tokens[i + 1]
            var pathOut = path1
            var kind: Change.Kind = .modified
            // Normalize leading letter
            let code = status.first.map(String.init) ?? "M"
            switch code {
            case "A": kind = .added
            case "D": kind = .deleted
            case "M", "T", "U": kind = .modified
            case "R", "C":
                // Renames/Copies provide an extra path; choose the new path when present
                if i + 2 < tokens.count {
                    pathOut = tokens[i + 2]
                    i += 1 // consume the extra path as well below
                }
                kind = .modified
            default:
                kind = .modified
            }
            result[pathOut] = kind
            i += 2
        }
        return result
    }

    // Unified diff for the file; staged toggles --cached
    func diff(in repo: Repo, path: String, staged: Bool) async -> String {
        let args = ["diff", staged ? "--cached" : "", "--", path].filter { !$0.isEmpty }
        if let out = try? await runGit(args, cwd: repo.root) {
            return out.stdout
        }
        return ""
    }

    // Read file content from the worktree for preview
    func readFile(in repo: Repo, path: String, maxBytes: Int = 1_000_000) async -> String {
        let url = repo.root.appendingPathComponent(path)
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = try? h.read(upToCount: maxBytes)
        if let d = data, let s = String(data: d, encoding: .utf8) { return s }
        return ""
    }

    // Stage/unstage operations
    func stage(in repo: Repo, paths: [String]) async {
        guard !paths.isEmpty else { return }
        // Use -A to ensure deletions are staged as well
        _ = try? await runGit(["add", "-A", "--"] + paths, cwd: repo.root)
    }

    func unstage(in repo: Repo, paths: [String]) async {
        guard !paths.isEmpty else { return }
        _ = try? await runGit(["restore", "--staged", "--"] + paths, cwd: repo.root)
    }

    func commit(in repo: Repo, message: String) async -> Int32 {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return -1 }
        let out = try? await runGit(["commit", "-m", msg], cwd: repo.root)
        return out?.exitCode ?? -1
    }

    // Discard tracked changes (both index and worktree) for specific paths
    func discardTracked(in repo: Repo, paths: [String]) async -> Int32 {
        guard !paths.isEmpty else { return 0 }
        let out = try? await runGit(["restore", "--staged", "--worktree", "--"] + paths, cwd: repo.root)
        return out?.exitCode ?? -1
    }

    // Remove untracked files for specific paths
    func cleanUntracked(in repo: Repo, paths: [String]) async -> Int32 {
        guard !paths.isEmpty else { return 0 }
        let out = try? await runGit(["clean", "-f", "-d", "--"] + paths, cwd: repo.root)
        return out?.exitCode ?? -1
    }

    // MARK: - Helpers
    private struct ProcOut { let stdout: String; let stderr: String; let exitCode: Int32 }

    private func runGit(_ args: [String], cwd: URL) async throws -> ProcOut {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
        proc.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = envPATH + ":" + (env["PATH"] ?? "")
        proc.environment = env

        let outPipe = Pipe(); proc.standardOutput = outPipe
        let errPipe = Pipe(); proc.standardError = errPipe

        try proc.run()
        let outData = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        let errData = try errPipe.fileHandleForReading.readToEnd() ?? Data()
        proc.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return ProcOut(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus)
    }
}
