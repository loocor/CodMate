import AppKit
import Foundation

struct ProcessResult {
    let output: String
}

enum SessionActionError: LocalizedError {
    case executableNotFound(URL)
    case resumeFailed(output: String)
    case deletionFailed(URL)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(url):
            return "Executable codex CLI not found: \(url.path)"
        case let .resumeFailed(output):
            return "Failed to resume session: \(output)"
        case let .deletionFailed(url):
            return "Failed to move file to Trash: \(url.path)"
        }
    }
}

struct SessionActions {
    private let fileManager: FileManager = .default

    func resolveExecutableURL(preferred: URL?) -> URL? {
        if let preferred, fileManager.isExecutableFile(atPath: preferred.path) { return preferred }
        // Try /opt/homebrew/bin, /usr/local/bin, PATH via /usr/bin/which
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex", "/bin/codex"]
        for path in candidates { if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) } }
        // which codex
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "codex"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if which.terminationStatus == 0, let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            if fileManager.isExecutableFile(atPath: str) { return URL(fileURLWithPath: str) }
        }
        return nil
    }

    func resume(session: SessionSummary, executableURL: URL, options: ResumeOptions) async throws -> ProcessResult {
        guard let exec = resolveExecutableURL(preferred: executableURL) else { throw SessionActionError.executableNotFound(executableURL) }

        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let process = Process()
                    process.executableURL = exec
                    process.arguments = self.buildResumeArguments(session: session, options: options)
                    // Prefer original session cwd if exists
                    if FileManager.default.fileExists(atPath: session.cwd) {
                        process.currentDirectoryURL = URL(fileURLWithPath: session.cwd, isDirectory: true)
                    } else {
                        process.currentDirectoryURL = session.fileURL.deletingLastPathComponent()
                    }

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    var env = ProcessInfo.processInfo.environment
                    let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                    if let current = env["PATH"], !current.isEmpty {
                        env["PATH"] = injectedPATH + ":" + current
                    } else {
                        env["PATH"] = injectedPATH
                    }
                    process.environment = env

                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: ProcessResult(output: output))
                    } else {
                        continuation.resume(throwing: SessionActionError.resumeFailed(output: output))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Resume helpers (copy/open Terminal)
    private func shellEscapedPath(_ path: String) -> String {
        // Simple escape: wrap in single quotes and escape existing single quotes
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellQuoteIfNeeded(_ s: String) -> String {
        // Only quote when the string contains whitespace or shell‑sensitive characters.
        // Keep it readable (e.g., codex stays unquoted).
        let unsafe: Set<Character> = Set(" \t\n\r\"'`$&|;<>*?()[]{}\\")
        if s.contains(where: { unsafe.contains($0) }) {
            return shellEscapedPath(s)
        }
        return s
    }

    private func flags(from options: ResumeOptions) -> [String] {
        // Highest precedence: dangerously bypass
        if options.dangerouslyBypass { return ["--dangerously-bypass-approvals-and-sandbox"] }
        // Next: full-auto shortcut
        if options.fullAuto { return ["--full-auto"] }
        // Otherwise explicit -s and -a when provided
        var f: [String] = []
        if let s = options.sandbox { f += ["-s", s.rawValue] }
        if let a = options.approval { f += ["-a", a.rawValue] }
        return f
    }

    func buildResumeCLIInvocation(session: SessionSummary, executablePath: String, options: ResumeOptions) -> String {
        let exe = shellQuoteIfNeeded(executablePath)
        let base = "\(exe) resume \(session.id)"
        let f = flags(from: options).joined(separator: " ")
        return f.isEmpty ? base : base + " " + f
    }

    private func buildNewSessionArguments(session: SessionSummary, options: ResumeOptions) -> [String] {
        var args: [String] = []
        if let model = session.model, !model.isEmpty { args += ["--model", model] }
        args += flags(from: options)
        return args
    }

    func buildNewSessionCLIInvocation(session: SessionSummary, options: ResumeOptions) -> String {
        let exe = "codex"
        let args = buildNewSessionArguments(session: session, options: options).map { arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        return ([exe] + args).joined(separator: " ")
    }

    func buildResumeArguments(session: SessionSummary, options: ResumeOptions) -> [String] {
        ["resume", session.id] + flags(from: options)
    }

    func buildResumeCommandLines(session: SessionSummary, executableURL: URL, options: ResumeOptions) -> String {
        let cwd = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
        // Use bare 'codex' for embedded terminal to respect user's PATH resolution
        let execPath = "codex"
        // Embedded terminal: keep environment exports for robustness
        let exports = "export LANG=zh_CN.UTF-8; export LC_ALL=zh_CN.UTF-8; export LC_CTYPE=zh_CN.UTF-8; export TERM=xterm-256color"
        let invocation = buildResumeCLIInvocation(session: session, executablePath: execPath, options: options)
        let resume = "PATH=\(injectedPATH) \(invocation)"
        return cd + "\n" + exports + "\n" + resume + "\n"
    }

    func buildNewSessionCommandLines(session: SessionSummary, executableURL: URL, options: ResumeOptions) -> String {
        _ = executableURL // retained for API symmetry; PATH handles resolution
        let cwd = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
        let exports = "export LANG=zh_CN.UTF-8; export LC_ALL=zh_CN.UTF-8; export LC_CTYPE=zh_CN.UTF-8; export TERM=xterm-256color"
        let invocation = buildNewSessionCLIInvocation(session: session, options: options)
        let command = "PATH=\(injectedPATH) \(invocation)"
        return cd + "\n" + exports + "\n" + command + "\n"
    }

    func buildExternalNewSessionCommands(session: SessionSummary, executableURL: URL, options: ResumeOptions) -> String {
        _ = executableURL
        let cwd = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let newCommand = buildNewSessionCLIInvocation(session: session, options: options)
        return cd + "\n" + newCommand + "\n"
    }

    // Simplified two-line command for external terminals
    func buildExternalResumeCommands(session: SessionSummary, executableURL: URL, options: ResumeOptions) -> String {
        let cwd = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let execPath = resolveExecutableURL(preferred: executableURL)?.path ?? "codex"
        let resume = buildResumeCLIInvocation(session: session, executablePath: execPath, options: options)
        return cd + "\n" + resume + "\n"
    }

    func copyResumeCommands(session: SessionSummary, executableURL: URL, options: ResumeOptions, simplifiedForExternal: Bool = true) {
        let commands = simplifiedForExternal
            ? buildExternalResumeCommands(session: session, executableURL: executableURL, options: options)
            : buildResumeCommandLines(session: session, executableURL: executableURL, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    func copyNewSessionCommands(session: SessionSummary, executableURL: URL, options: ResumeOptions, simplifiedForExternal: Bool = true) {
        _ = executableURL
        let commands = simplifiedForExternal
            ? buildExternalNewSessionCommands(session: session, executableURL: executableURL, options: options)
            : buildNewSessionCommandLines(session: session, executableURL: executableURL, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    // MARK: - Project-level new session helpers
    private func buildNewProjectArguments(project: Project, options: ResumeOptions) -> [String] {
        var args: [String] = []
        // Prefer profile when provided
        if let profile = project.profileId, !profile.isEmpty { args += ["--profile", profile] }
        args += flags(from: options)
        return args
    }

    func buildNewProjectCLIInvocation(project: Project, options: ResumeOptions) -> String {
        let exe = "codex"
        let args = buildNewProjectArguments(project: project, options: options).map { arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) { return shellEscapedPath(arg) }
            return arg
        }
        return ([exe] + args).joined(separator: " ")
    }

    func buildNewProjectCommandLines(project: Project, executableURL: URL, options: ResumeOptions) -> String {
        _ = executableURL
        let cd = "cd " + shellEscapedPath(project.directory)
        let injectedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
        let exports = "export LANG=zh_CN.UTF-8; export LC_ALL=zh_CN.UTF-8; export LC_CTYPE=zh_CN.UTF-8; export TERM=xterm-256color"
        let invocation = buildNewProjectCLIInvocation(project: project, options: options)
        let command = "PATH=\(injectedPATH) \(invocation)"
        return cd + "\n" + exports + "\n" + command + "\n"
    }

    func buildExternalNewProjectCommands(project: Project, executableURL: URL, options: ResumeOptions) -> String {
        _ = executableURL
        let cd = "cd " + shellEscapedPath(project.directory)
        let cmd = buildNewProjectCLIInvocation(project: project, options: options)
        return cd + "\n" + cmd + "\n"
    }

    func copyNewProjectCommands(project: Project, executableURL: URL, options: ResumeOptions, simplifiedForExternal: Bool = true) {
        let commands = simplifiedForExternal
            ? buildExternalNewProjectCommands(project: project, executableURL: executableURL, options: options)
            : buildNewProjectCommandLines(project: project, executableURL: executableURL, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    @discardableResult
    func openNewProject(project: Project, executableURL: URL, options: ResumeOptions) -> Bool {
        let scriptText = {
            let lines = buildNewProjectCommandLines(project: project, executableURL: executableURL, options: options)
                .replacingOccurrences(of: "\n", with: "; ")
            return """
            tell application "Terminal"
              activate
              do script "\(lines)"
            end tell
            """
        }()

        if let script = NSAppleScript(source: scriptText) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            return errorDict == nil
        }
        return false
    }

    func copyRealResumeInvocation(session: SessionSummary, executableURL: URL, options: ResumeOptions) {
        let execPath = resolveExecutableURL(preferred: executableURL)?.path ?? executableURL.path
        let cmd = buildResumeCLIInvocation(session: session, executablePath: execPath, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd + "\n", forType: .string)
    }

    @discardableResult
    func openInTerminal(session: SessionSummary, executableURL: URL, options: ResumeOptions) -> Bool {
        let scriptText = {
            let lines = buildResumeCommandLines(session: session, executableURL: executableURL, options: options)
                .replacingOccurrences(of: "\n", with: "; ")
            return """
            tell application "Terminal"
              activate
              do script "\(lines)"
            end tell
            """
        }()

        if let script = NSAppleScript(source: scriptText) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            return errorDict == nil
        }
        return false
    }

    @discardableResult
    func openNewSession(session: SessionSummary, executableURL: URL, options: ResumeOptions) -> Bool {
        let scriptText = {
            let lines = buildNewSessionCommandLines(session: session, executableURL: executableURL, options: options)
                .replacingOccurrences(of: "\n", with: "; ")
            return """
            tell application "Terminal"
              activate
              do script "\(lines)"
            end tell
            """
        }()

        if let script = NSAppleScript(source: scriptText) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            return errorDict == nil
        }
        return false
    }

    // Open a terminal app without auto-executing; user can paste clipboard
    func openTerminalApp(_ app: TerminalApp) {
        guard let bundleID = app.bundleIdentifier else { return }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }

    // Optional: open using URL schemes (iTerm2 / Warp) when available
    func openTerminalViaScheme(_ app: TerminalApp, directory: String?, command: String? = nil) {
        let dir = directory ?? NSHomeDirectory()
        switch app {
        case .iterm2:
            var comps = URLComponents()
            comps.scheme = "iterm2"
            comps.path = "/command"
            comps.queryItems = [URLQueryItem(name: "d", value: dir)]
            if let command { comps.queryItems?.append(URLQueryItem(name: "c", value: command)) }
            if let url = comps.url {
                NSWorkspace.shared.open(url)
            } else {
                openTerminalApp(.iterm2)
            }
        case .warp:
            var comps = URLComponents()
            comps.scheme = "warp"
            comps.host = "action"
            comps.path = "/new_tab"
            comps.queryItems = [URLQueryItem(name: "path", value: dir)]
            if let url = comps.url {
                NSWorkspace.shared.open(url)
            } else {
                openTerminalApp(.warp)
            }
        default:
            openTerminalApp(app)
        }
    }

    // Open Terminal.app at a given directory (no auto-run). Returns success.
    @discardableResult
    func openAppleTerminal(at directory: String) -> Bool {
        // Use `open -a Terminal <dir>` to spawn a new window in that path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal", directory]
        do {
            try proc.run(); proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch { return false }
    }

    // MARK: - Warp Launch Configuration
    @discardableResult
    func openWarpLaunchConfig(session: SessionSummary, options: ResumeOptions) -> Bool {
        let cwd = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(".warp", isDirectory: true)
            .appendingPathComponent("launch_configurations", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { /* ignore */ }

        let baseName = "codmate-resume-\(session.id)"
        let fileName = baseName + ".yaml"
        let fileURL = folder.appendingPathComponent(fileName)
        let flagsString: String = {
            // Use configured options; prefer bare `codex` so Warp resolves via PATH.
            let cmd = buildResumeCLIInvocation(session: session, executablePath: "codex", options: options)
            // buildResumeCLIInvocation quotes the executable; strip single quotes for YAML simplicity.
            if cmd.hasPrefix("'codex'") { return String(cmd.dropFirst("'codex' ".count)) }
            if cmd.hasPrefix("\"codex\"") { return String(cmd.dropFirst("\"codex\" ".count)) }
            // Fallback: remove leading "codex " if present
            if cmd.hasPrefix("codex ") { return String(cmd.dropFirst("codex ".count)) }
            return cmd
        }()

        let yaml = """
        version: 1
        name: CodMate Resume \(session.id)
        windows:
          - tabs:
              - title: Codex
                panes:
                  - cwd: \(cwd)
                    commands:
                      - exec: codex \(flagsString)
        """
        do { try yaml.data(using: .utf8)?.write(to: fileURL) } catch {}

        // Prefer warp://launch/<config_name> (Warp resolves in its config dir), fallback to absolute path.
        if let urlByName = URL(string: "warp://launch/\(baseName)") {
            let ok = NSWorkspace.shared.open(urlByName)
            if ok { return true }
        }
        var comps = URLComponents()
        comps.scheme = "warp"
        comps.host = "launch"
        comps.path = "/" + fileURL.path
        if let url = comps.url { return NSWorkspace.shared.open(url) }
        return false
    }

    func revealInFinder(session: SessionSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
    }

    func delete(summaries: [SessionSummary]) throws {
        for summary in summaries {
            var resulting: NSURL?
            do {
                try fileManager.trashItem(at: summary.fileURL, resultingItemURL: &resulting)
            } catch {
                throw SessionActionError.deletionFailed(summary.fileURL)
            }
        }
    }
}
