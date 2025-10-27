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
        case .executableNotFound(let url):
            return "Executable codex CLI not found: \(url.path)"
        case .resumeFailed(let output):
            return "Failed to resume session: \(output)"
        case .deletionFailed(let url):
            return "Failed to move file to Trash: \(url.path)"
        }
    }
}

struct SessionActions {
    private let fileManager: FileManager = .default
    private let codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    private let sshExecutablePath = "/usr/bin/ssh"
    private let defaultPathInjection =
        "/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$HOME/.local/bin:$HOME/bin:${PATH}"

    // MARK: - Local helpers: profiles in ~/.codex/config.toml
    private func listPersistedProfiles() -> Set<String> {
        let configURL = codexHome.appendingPathComponent("config.toml", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
            let raw = String(data: data, encoding: .utf8)
        else {
            return []
        }
        var out: Set<String> = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            // Match exact header: [profiles.<id>]
            if t.hasPrefix("[profiles.") && t.hasSuffix("]") {
                let start = "[profiles.".count
                let endIndex = t.index(before: t.endIndex)
                let id = String(t[t.index(t.startIndex, offsetBy: start)..<endIndex])
                let trimmed = id.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.insert(trimmed) }
            }
        }
        return out
    }

    private func persistedProfileExists(_ id: String?) -> Bool {
        guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return listPersistedProfiles().contains(id)
    }

    // MARK: - Codex model resolution (global settings)
    // Read a top-level string key from ~/.codex/config.toml (naïve line-based parser)
    private func readTopLevelConfigString(_ key: String) -> String? {
        let url = codexHome.appendingPathComponent("config.toml", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key + " ") || t.hasPrefix(key + "=") else { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            var value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }

    // Effective model for new Codex sessions:
    // - Prefer global Codex config model
    // - Else, only fall back to session.model when the origin is Codex
    private func effectiveCodexModel(for session: SessionSummary) -> String? {
        if let configured = readTopLevelConfigString("model")?.trimmingCharacters(
            in: .whitespacesAndNewlines), !configured.isEmpty
        {
            return configured
        }
        if session.source.baseKind == .codex {
            if let m = session.model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                return m
            }
        }
        return nil
    }

    private func renderInlineProfileConfig(
        key id: String,
        model: String?,
        approvalPolicy: String?,
        sandboxMode: String?
    ) -> String? {
        // Build a TOML inline table for --config: profiles.<id>={ model="...", approval_policy="...", sandbox_mode="..." }
        var pairs: [String] = []
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let val = model.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("model=\"\(val)\"")
        }
        if let approval = approvalPolicy,
            !approval.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let val = approval.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("approval_policy=\"\(val)\"")
        }
        if let sandbox = sandboxMode,
            !sandbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let val = sandbox.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("sandbox_mode=\"\(val)\"")
        }
        guard !pairs.isEmpty else { return nil }
        return "profiles.\(id)={ \(pairs.joined(separator: ", ")) }"
    }

    func resolveExecutableURL(preferred: URL?, executableName: String = "codex") -> URL? {
        if let preferred, fileManager.isExecutableFile(atPath: preferred.path) { return preferred }
        // Try /opt/homebrew/bin, /usr/local/bin, PATH via /usr/bin/which
        let candidates = [
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "/usr/bin/\(executableName)",
            "/bin/\(executableName)",
        ]
        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // which codex
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", executableName]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if which.terminationStatus == 0,
            let str = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines), !str.isEmpty
        {
            if fileManager.isExecutableFile(atPath: str) { return URL(fileURLWithPath: str) }
        }
        return nil
    }

    @MainActor
    func resume(session: SessionSummary, executableURL: URL, options: ResumeOptions) async throws
        -> ProcessResult
    {
        if session.isRemote, let host = session.remoteHost {
            return try await resumeRemote(session: session, host: host, options: options)
        }
        let exeName = session.source.baseKind == .codex ? "codex" : "claude"
        guard let exec = resolveExecutableURL(preferred: executableURL, executableName: exeName)
        else {
            throw SessionActionError.executableNotFound(executableURL)
        }
        return try await withCheckedThrowingContinuation { continuation in
            // Run process work off the main actor without capturing self across concurrency boundaries
            let args: [String]
            switch session.source.baseKind {
            case .codex:
                args = buildResumeArguments(session: session, options: options)
            case .claude:
                args = ["--resume", session.id]
            }
            let cwd: URL = {
                if FileManager.default.fileExists(atPath: session.cwd) {
                    return URL(fileURLWithPath: session.cwd, isDirectory: true)
                } else {
                    return session.fileURL.deletingLastPathComponent()
                }
            }()
            Task.detached {
                do {
                    let process = Process()
                    process.executableURL = exec
                    process.arguments = args
                    // Prefer original session cwd if exists
                    process.currentDirectoryURL = cwd

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    var env = ProcessInfo.processInfo.environment
                    let injectedPATH =
                        "/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
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
                        continuation.resume(
                            throwing: SessionActionError.resumeFailed(output: output))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resumeRemote(
        session: SessionSummary,
        host: String,
        options: ResumeOptions
    ) async throws -> ProcessResult {
        let command = buildRemoteResumeShellCommand(session: session, options: options)
        let sshPath = sshExecutablePath
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: sshPath)
                    process.arguments = ["-t", host, command]

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe

                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: ProcessResult(output: output))
                    } else {
                        continuation.resume(
                            throwing: SessionActionError.resumeFailed(output: output))
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

    // Reliable conversation id for resume commands: always use the session_meta id
    // parsed from the log (SessionSummary.id). This matches Codex CLI's
    // expectation (UUID) and Claude's native id semantics.
    private func conversationId(for session: SessionSummary) -> String { session.id }

    private func embeddedExportLines(for source: SessionSource) -> [String] {
        var lines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if source.baseKind == .codex {
            lines.append("export CODEX_DISABLE_COLOR_QUERY=1")
        }
        return lines
    }

    private func workingDirectory(for session: SessionSummary) -> String {
        if session.isRemote {
            let trimmed = session.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            if let remotePath = session.remotePath {
                let parent = (remotePath as NSString).deletingLastPathComponent
                if !parent.isEmpty { return parent }
            }
            return session.cwd
        }
        if fileManager.fileExists(atPath: session.cwd) {
            return session.cwd
        }
        return session.fileURL.deletingLastPathComponent().path
    }

    private func remoteExecutableName(for session: SessionSummary) -> String {
        session.source.baseKind == .codex ? "codex" : "claude"
    }

    private func buildRemoteShellCommand(
        session: SessionSummary,
        exports: [String],
        pathInjection: String,
        invocation: String
    ) -> String {
        let cwd = workingDirectory(for: session)
        var chain: [String] = []
        if !exports.isEmpty {
            chain.append(exports.joined(separator: " && "))
        }
        chain.append("PATH=\(pathInjection) \(invocation)")
        let body = chain.joined(separator: " && ")
        return "cd \(shellEscapedPath(cwd)) && \(body)"
    }

    private func buildRemoteResumeShellCommand(
        session: SessionSummary,
        options: ResumeOptions
    ) -> String {
        let exports = embeddedExportLines(for: session.source)
        let invocation = buildResumeCLIInvocation(
            session: session,
            executablePath: remoteExecutableName(for: session),
            options: options
        )
        return buildRemoteShellCommand(
            session: session,
            exports: exports,
            pathInjection: defaultPathInjection,
            invocation: invocation
        )
    }

    private func buildRemoteNewShellCommand(
        session: SessionSummary,
        options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> String {
        let exports = embeddedExportLines(for: session.source)
        let invocation = buildNewSessionCLIInvocation(
            session: session,
            options: options,
            initialPrompt: initialPrompt
        )
        return buildRemoteShellCommand(
            session: session,
            exports: exports,
            pathInjection: defaultPathInjection,
            invocation: invocation
        )
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

    func buildResumeCLIInvocation(
        session: SessionSummary, executablePath: String, options: ResumeOptions
    ) -> String {
        let exe = shellQuoteIfNeeded(executablePath)
        switch session.source.baseKind {
        case .codex:
            // Resume should preserve original session semantics; do not override flags.
            return "\(exe) resume \(conversationId(for: session))"
        case .claude:
            let args = ["--resume", session.id].map(shellQuoteIfNeeded)
            return ([exe] + args).joined(separator: " ")
        }
    }

    private func buildNewSessionArguments(session: SessionSummary, options: ResumeOptions)
        -> [String]
    {
        var args: [String] = []
        // Do not append --model for Codex new sessions; rely on project profile or global config
        args += flags(from: options)
        return args
    }

    func buildNewSessionCLIInvocation(
        session: SessionSummary, options: ResumeOptions, initialPrompt: String? = nil
    ) -> String {
        switch session.source.baseKind {
        case .codex:
            // Launch a fresh Codex session by invoking `codex` directly (no "new" subcommand).
            let exe = "codex"
            var parts: [String] = [exe]
            let args = buildNewSessionArguments(session: session, options: options).map {
                arg -> String in
                if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                    return shellEscapedPath(arg)
                }
                return arg
            }
            parts.append(contentsOf: args)
            if let prompt = initialPrompt, !prompt.isEmpty {
                parts.append(shellSingleQuoted(prompt))
            }
            return parts.joined(separator: " ")
        case .claude:
            var parts: [String] = ["claude"]
            if let model = session.model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("--model")
                parts.append(shellQuoteIfNeeded(model))
            }
            if let prompt = initialPrompt, !prompt.isEmpty {
                parts.append(shellSingleQuoted(prompt))
            }
            return parts.joined(separator: " ")
        }
    }

    func buildResumeArguments(session: SessionSummary, options: ResumeOptions) -> [String] {
        // Do not append flags; resume should restore original semantics.
        ["resume", conversationId(for: session)]
    }

    func buildResumeCommandLines(
        session: SessionSummary, executableURL: URL, options: ResumeOptions
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteResumeShellCommand(session: session, options: options)
            let command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
            return command + "\n"
        }
        let cwd = workingDirectory(for: session)
        let cd = "cd " + shellEscapedPath(cwd)
        // Use bare executable name for embedded terminal to respect user's PATH resolution
        let execPath = session.source.baseKind == .codex ? "codex" : "claude"
        // Embedded terminal: keep environment exports for robustness (source-specific)
        let exports = embeddedExportLines(for: session.source).joined(separator: "; ")
        let invocation = buildResumeCLIInvocation(
            session: session, executablePath: execPath, options: options)
        let resume = "PATH=\(defaultPathInjection) \(invocation)"
        return cd + "\n" + exports + "\n" + resume + "\n"
    }

    func buildNewSessionCommandLines(
        session: SessionSummary, executableURL: URL, options: ResumeOptions
    ) -> String {
        _ = executableURL  // retained for API symmetry; PATH handles resolution
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteNewShellCommand(
                session: session,
                options: options,
                initialPrompt: nil
            )
            let command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
            return command + "\n"
        }
        let cwd = workingDirectory(for: session)
        let cd = "cd " + shellEscapedPath(cwd)
        let exports = embeddedExportLines(for: session.source).joined(separator: "; ")
        let invocation = buildNewSessionCLIInvocation(session: session, options: options)
        let command = "PATH=\(defaultPathInjection) \(invocation)"
        return cd + "\n" + exports + "\n" + command + "\n"
    }

    func buildExternalNewSessionCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions
    ) -> String {
        _ = executableURL
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteNewShellCommand(
                session: session,
                options: options,
                initialPrompt: nil
            )
            let command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
            return command + "\n"
        }
        let cwd = workingDirectory(for: session)
        let cd = "cd " + shellEscapedPath(cwd)
        let newCommand = buildNewSessionCLIInvocation(session: session, options: options)
        return cd + "\n" + newCommand + "\n"
    }

    // Simplified two-line command for external terminals
    func buildExternalResumeCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteResumeShellCommand(session: session, options: options)
            let command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
            return command + "\n"
        }
        let cwd = workingDirectory(for: session)
        let cd = "cd " + shellEscapedPath(cwd)
        let execName = session.source.baseKind == .codex ? "codex" : "claude"
        let execPath =
            resolveExecutableURL(preferred: executableURL, executableName: execName)?.path
            ?? execName
        let resume = buildResumeCLIInvocation(
            session: session, executablePath: execPath, options: options)
        return cd + "\n" + resume + "\n"
    }

    func copyResumeCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true
    ) {
        let commands =
            simplifiedForExternal
            ? buildExternalResumeCommands(
                session: session, executableURL: executableURL, options: options)
            : buildResumeCommandLines(
                session: session, executableURL: executableURL, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    func copyNewSessionCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true
    ) {
        _ = executableURL
        let commands =
            simplifiedForExternal
            ? buildExternalNewSessionCommands(
                session: session, executableURL: executableURL, options: options)
            : buildNewSessionCommandLines(
                session: session, executableURL: executableURL, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    // MARK: - Project-level new session helpers
    private func buildNewProjectArguments(project: Project, options: ResumeOptions) -> [String] {
        var args: [String] = []
        // Embedded per-project profile config (preferred)
        let pp = project.profile
        let profileId = project.profileId?.trimmingCharacters(in: .whitespaces)

        // Flags only; avoid explicit --model for Codex new to keep behavior consistent
        if let pp {
            if pp.dangerouslyBypass == true {
                args += ["--dangerously-bypass-approvals-and-sandbox"]
            } else if pp.fullAuto == true {
                args += ["--full-auto"]
            } else {
                if let s = pp.sandbox { args += ["-s", s.rawValue] }
                if let a = pp.approval { args += ["-a", a.rawValue] }
            }
        } else {
            // Fallback to explicit flags
            args += flags(from: options)
        }

        // Always use -c to inject inline profile (zero-write approach)
        if let profileId, !profileId.isEmpty {
            // Resolve effective approval/sandbox for project-level new inline profile
            var approvalRaw: String? = pp?.approval?.rawValue
            var sandboxRaw: String? = pp?.sandbox?.rawValue
            if sandboxRaw == nil {
                if pp?.dangerouslyBypass == true {
                    sandboxRaw = SandboxMode.dangerFullAccess.rawValue
                } else if let opt = options.sandbox?.rawValue {
                    sandboxRaw = opt
                }
            }
            if approvalRaw == nil {
                if let opt = options.approval?.rawValue {
                    approvalRaw = opt
                } else {
                    approvalRaw = ApprovalPolicy.onRequest.rawValue
                }
            }
            if sandboxRaw == nil { sandboxRaw = SandboxMode.workspaceWrite.rawValue }

            if let inline = renderInlineProfileConfig(
                key: profileId,
                model: pp?.model,  // include model only inside profile injection
                approvalPolicy: approvalRaw,
                sandboxMode: sandboxRaw
            ) {
                args += ["--profile", profileId, "-c", inline]
            } else {
                // profile id provided but nothing to inject; omit --profile to avoid referring to a non-existent profile
            }
        }
        return args
    }

    func buildNewProjectCLIInvocation(project: Project, options: ResumeOptions) -> String {
        let exe = "codex"
        let args = buildNewProjectArguments(project: project, options: options).map {
            arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        // Invoke `codex` directly without a "new" subcommand
        return ([exe] + args).joined(separator: " ")
    }

    func buildNewProjectCommandLines(project: Project, executableURL: URL, options: ResumeOptions)
        -> String
    {
        _ = executableURL
        let cdLine: String? = {
            if let dir = project.directory,
                !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "cd " + shellEscapedPath(dir)
            }
            return nil
        }()
        // PATH injection: prepend project-specific paths if any
        let prepend = project.profile?.pathPrepend ?? []
        let prependString = prepend.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: ":")
        let defaultPATH =
            "/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$HOME/.local/bin:$HOME/bin"
        let injectedPATH =
            (prependString.isEmpty ? defaultPATH : prependString + ":" + defaultPATH) + ":${PATH}"
        // Exports: locale defaults + project env
        var exportLines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
            "export CODEX_DISABLE_COLOR_QUERY=1",
        ]
        if let env = project.profile?.env {
            for (k, v) in env {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                exportLines.append("export \(key)=\(shellSingleQuoted(v))")
            }
        }
        let exports = exportLines.joined(separator: "; ")
        let invocation = buildNewProjectCLIInvocation(project: project, options: options)
        let command = "PATH=\(injectedPATH) \(invocation)"
        if let cd = cdLine {
            return cd + "\n" + exports + "\n" + command + "\n"
        } else {
            return exports + "\n" + command + "\n"
        }
    }

    func buildExternalNewProjectCommands(
        project: Project, executableURL: URL, options: ResumeOptions
    ) -> String {
        _ = executableURL
        let cdLine: String? = {
            if let dir = project.directory,
                !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "cd " + shellEscapedPath(dir)
            }
            return nil
        }()
        // Build exports similarly to embedded version so users can paste easily
        let prepend = project.profile?.pathPrepend ?? []
        let prependString = prepend.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: ":")
        let defaultPATH =
            "/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$HOME/.local/bin:$HOME/bin"
        let injectedPATH =
            (prependString.isEmpty ? defaultPATH : prependString + ":" + defaultPATH) + ":${PATH}"
        var exportLines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if let env = project.profile?.env {
            for (k, v) in env {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                exportLines.append("export \(key)=\(shellSingleQuoted(v))")
            }
        }
        let exports = exportLines.joined(separator: "; ")
        let cmd = buildNewProjectCLIInvocation(project: project, options: options)
        if let cd = cdLine {
            return cd + "\n" + exports + "\n" + "PATH=\(injectedPATH) \(cmd)\n"
        } else {
            return exports + "\n" + "PATH=\(injectedPATH) \(cmd)\n"
        }
    }

    func copyNewProjectCommands(
        project: Project, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true
    ) {
        let commands =
            simplifiedForExternal
            ? buildExternalNewProjectCommands(
                project: project, executableURL: executableURL, options: options)
            : buildNewProjectCommandLines(
                project: project, executableURL: executableURL, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    @discardableResult
    func openNewProject(project: Project, executableURL: URL, options: ResumeOptions) -> Bool {
        let scriptText = {
            let lines = buildNewProjectCommandLines(
                project: project, executableURL: executableURL, options: options
            )
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

    // MARK: - Detail New using Project Profile (cd = session.cwd)
    private func buildNewSessionArguments(
        using project: Project, fallbackModel: String?, options: ResumeOptions
    ) -> [String] {
        var args: [String] = []
        let pid = project.profileId?.trimmingCharacters(in: .whitespaces)

        // Flags precedence: danger -> full-auto -> explicit -s/-a when present in project profile
        if project.profile?.dangerouslyBypass == true {
            args += ["--dangerously-bypass-approvals-and-sandbox"]
        } else if project.profile?.fullAuto == true {
            args += ["--full-auto"]
        } else {
            if let s = project.profile?.sandbox { args += ["-s", s.rawValue] }
            if let a = project.profile?.approval { args += ["-a", a.rawValue] }
        }

        // Always use -c to inject inline profile (zero-write approach)
        if let pid, !pid.isEmpty {
            // Do not append explicit --model for Codex new; rely on project profile (persisted or inline) or global config
            let modelFromProject = project.profile?.model

            // Effective policies for inline profile injection (New using project):
            // - approval: prefer explicit; otherwise prefer options; else default to on-request
            // - sandbox: prefer explicit; otherwise Danger Bypass => danger-full-access; otherwise options; else default to workspace-write
            var approvalRaw: String? = project.profile?.approval?.rawValue
            var sandboxRaw: String? = project.profile?.sandbox?.rawValue
            if sandboxRaw == nil {
                if project.profile?.dangerouslyBypass == true {
                    sandboxRaw = SandboxMode.dangerFullAccess.rawValue
                } else if let opt = options.sandbox?.rawValue {
                    sandboxRaw = opt
                }
            }
            if approvalRaw == nil {
                if let opt = options.approval?.rawValue {
                    approvalRaw = opt
                } else {
                    approvalRaw = ApprovalPolicy.onRequest.rawValue
                }
            }
            if sandboxRaw == nil { sandboxRaw = SandboxMode.workspaceWrite.rawValue }

            if let inline = renderInlineProfileConfig(
                key: pid,
                model: modelFromProject ?? fallbackModel,
                approvalPolicy: approvalRaw,
                sandboxMode: sandboxRaw
            ) {
                // Zero-write: inject the inline profile and select it
                args += ["--profile", pid, "-c", inline]
            }
        }
        return args
    }

    func buildNewSessionUsingProjectProfileCLIInvocation(
        session: SessionSummary, project: Project, options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> String {
        // Launch using project profile; choose executable based on session source.
        let exe = session.source.baseKind == .codex ? "codex" : "claude"
        var parts: [String] = [exe]

        // For Claude, only include model if specified; profile settings don't apply.
        if session.source.baseKind == .claude {
            if let model = session.model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("--model")
                parts.append(shellQuoteIfNeeded(model))
            }
            if let prompt = initialPrompt, !prompt.isEmpty {
                parts.append(shellSingleQuoted(prompt))
            }
            return parts.joined(separator: " ")
        }

        // For Codex, use full project profile arguments
        let args = buildNewSessionArguments(
            using: project, fallbackModel: effectiveCodexModel(for: session), options: options
        ).map { arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        parts.append(contentsOf: args)
        if let prompt = initialPrompt, !prompt.isEmpty {
            parts.append(shellSingleQuoted(prompt))
        }
        return parts.joined(separator: " ")
    }

    func buildNewSessionUsingProjectProfileCommandLines(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> String {
        _ = executableURL
        let prepend = project.profile?.pathPrepend ?? []
        let prependString = prepend.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: ":")
        let defaultPATH =
            "/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$HOME/.local/bin:$HOME/bin"
        let injectedPATH =
            (prependString.isEmpty ? defaultPATH : prependString + ":" + defaultPATH) + ":${PATH}"
        var exportLines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if let env = project.profile?.env {
            for (k, v) in env {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                exportLines.append("export \(key)=\(shellSingleQuoted(v))")
            }
        }
        let invocation = buildNewSessionUsingProjectProfileCLIInvocation(
            session: session, project: project, options: options, initialPrompt: initialPrompt)
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteShellCommand(
                session: session,
                exports: exportLines,
                pathInjection: injectedPATH,
                invocation: invocation
            )
            let command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
            return command + "\n"
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let exports = exportLines.joined(separator: "; ")
        let command = "PATH=\(injectedPATH) \(invocation)"
        return cd + "\n" + exports + "\n" + command + "\n"
    }

    func buildExternalNewSessionUsingProjectProfileCommands(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> String {
        _ = executableURL
        let prepend = project.profile?.pathPrepend ?? []
        let prependString = prepend.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: ":")
        let defaultPATH =
            "/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$HOME/.local/bin:$HOME/bin"
        let injectedPATH =
            (prependString.isEmpty ? defaultPATH : prependString + ":" + defaultPATH) + ":${PATH}"
        var exportLines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if let env = project.profile?.env {
            for (k, v) in env {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                exportLines.append("export \(key)=\(shellSingleQuoted(v))")
            }
        }
        let invocation = buildNewSessionUsingProjectProfileCLIInvocation(
            session: session, project: project, options: options, initialPrompt: initialPrompt)
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteShellCommand(
                session: session,
                exports: exportLines,
                pathInjection: injectedPATH,
                invocation: invocation
            )
            let command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
            return command + "\n"
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let cmd = "PATH=\(injectedPATH) \(invocation)"
        let exports = exportLines.joined(separator: "; ")
        return cd + "\n" + exports + "\n" + cmd + "\n"
    }

    func copyNewSessionUsingProjectProfileCommands(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true, initialPrompt: String? = nil
    ) {
        let commands =
            simplifiedForExternal
            ? buildExternalNewSessionUsingProjectProfileCommands(
                session: session, project: project, executableURL: executableURL, options: options,
                initialPrompt: initialPrompt)
            : buildNewSessionUsingProjectProfileCommandLines(
                session: session, project: project, executableURL: executableURL, options: options,
                initialPrompt: initialPrompt)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    // MARK: - Resume (detail) respecting Project Profile
    private func buildResumeArguments(
        using project: Project, fallbackModel: String?, options: ResumeOptions
    ) -> [String] {
        var args: [String] = []
        let pid = project.profileId?.trimmingCharacters(in: .whitespaces)

        // Always use -c to inject inline profile (zero-write approach)
        // Only select profile; do not pass flags to preserve original resume semantics
        if let pid, !pid.isEmpty {
            // Compute effective approval/sandbox for resume inline profile
            // approval: prefer explicit; else options; else default on-request
            // sandbox: prefer explicit; else Danger Bypass => danger-full-access; else options; else default workspace-write
            var approvalRaw: String? = project.profile?.approval?.rawValue
            var sandboxRaw: String? = project.profile?.sandbox?.rawValue
            if sandboxRaw == nil {
                if project.profile?.dangerouslyBypass == true {
                    sandboxRaw = SandboxMode.dangerFullAccess.rawValue
                } else if let opt = options.sandbox?.rawValue {
                    sandboxRaw = opt
                }
            }
            if approvalRaw == nil {
                if let opt = options.approval?.rawValue {
                    approvalRaw = opt
                } else {
                    approvalRaw = ApprovalPolicy.onRequest.rawValue
                }
            }
            if sandboxRaw == nil { sandboxRaw = SandboxMode.workspaceWrite.rawValue }

            if let inline = renderInlineProfileConfig(
                key: pid,
                model: project.profile?.model ?? fallbackModel,
                approvalPolicy: approvalRaw,
                sandboxMode: sandboxRaw
            ) {
                // Zero-write: inject the inline profile and select it
                args += ["--profile", pid, "-c", inline]
            }
        }
        return args
    }

    func buildResumeUsingProjectProfileCLIInvocation(
        session: SessionSummary, project: Project, options: ResumeOptions
    ) -> String {
        // Choose executable based on session source; select profile (no flags for Claude).
        let exe = session.source.baseKind == .codex ? "codex" : "claude"
        var parts: [String] = [exe]

        // For Claude, profiles don't apply; use simple resume command.
        if session.source.baseKind == .claude {
            parts.append("--resume")
            parts.append(session.id)
            return parts.joined(separator: " ")
        }

        // For Codex, place global flags before subcommand: codex --profile <pid> resume <id>
        let args = buildResumeArguments(
            using: project, fallbackModel: effectiveCodexModel(for: session), options: options
        ).map { arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        parts.append(contentsOf: args)
        parts.append("resume")
        parts.append(conversationId(for: session))
        return parts.joined(separator: " ")
    }

    func buildResumeUsingProjectProfileCLIInvocation(
        session: SessionSummary, project: Project, executablePath: String, options: ResumeOptions
    ) -> String {
        let exe = shellQuoteIfNeeded(executablePath)
        var parts: [String] = [exe]

        // For Claude, profiles don't apply; use simple resume command.
        if session.source.baseKind == .claude {
            parts.append("--resume")
            parts.append(session.id)
            return parts.joined(separator: " ")
        }

        // For Codex, place global flags before subcommand: codex --profile <pid> resume <id>
        let args = buildResumeArguments(
            using: project, fallbackModel: effectiveCodexModel(for: session), options: options
        ).map { arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        parts.append(contentsOf: args)
        parts.append("resume")
        parts.append(conversationId(for: session))
        return parts.joined(separator: " ")
    }

    func buildResumeUsingProjectProfileCommandLines(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions
    ) -> String {
        _ = executableURL
        let prepend = project.profile?.pathPrepend ?? []
        let prependString = prepend.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: ":")
        let defaultPATH =
            "/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$HOME/.local/bin:$HOME/bin"
        let injectedPATH =
            (prependString.isEmpty ? defaultPATH : prependString + ":" + defaultPATH) + ":${PATH}"
        var exportLines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if session.source.baseKind == .codex {
            exportLines.append("export CODEX_DISABLE_COLOR_QUERY=1")
        }
        if let env = project.profile?.env {
            for (k, v) in env {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                exportLines.append("export \(key)=\(shellSingleQuoted(v))")
            }
        }
        let invocation = buildResumeUsingProjectProfileCLIInvocation(
            session: session, project: project, options: options)
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteShellCommand(
                session: session,
                exports: exportLines,
                pathInjection: injectedPATH,
                invocation: invocation
            )
            let command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
            return command + "\n"
        }
        let cwd = workingDirectory(for: session)
        let cd = "cd " + shellEscapedPath(cwd)
        let exports = exportLines.joined(separator: "; ")
        let command = "PATH=\(injectedPATH) \(invocation)"
        return cd + "\n" + exports + "\n" + command + "\n"
    }

    func buildExternalResumeUsingProjectProfileCommands(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions
    ) -> String {
        _ = executableURL
        let prepend = project.profile?.pathPrepend ?? []
        let prependString = prepend.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: ":")
        let defaultPATH =
            "/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$HOME/.local/bin:$HOME/bin"
        let injectedPATH =
            (prependString.isEmpty ? defaultPATH : prependString + ":" + defaultPATH) + ":${PATH}"
        var exportLines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if session.source.baseKind == .codex {
            exportLines.append("export CODEX_DISABLE_COLOR_QUERY=1")
        }
        if let env = project.profile?.env {
            for (k, v) in env {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                exportLines.append("export \(key)=\(shellSingleQuoted(v))")
            }
        }
        let invocation = buildResumeUsingProjectProfileCLIInvocation(
            session: session, project: project, options: options)
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteShellCommand(
                session: session,
                exports: exportLines,
                pathInjection: injectedPATH,
                invocation: invocation
            )
            let command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
            return command + "\n"
        }
        let cwd = workingDirectory(for: session)
        let cd = "cd " + shellEscapedPath(cwd)
        let exports = exportLines.joined(separator: "; ")
        let cmd = "PATH=\(injectedPATH) \(invocation)"
        return cd + "\n" + exports + "\n" + cmd + "\n"
    }

    func copyResumeUsingProjectProfileCommands(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true
    ) {
        let commands =
            simplifiedForExternal
            ? buildExternalResumeUsingProjectProfileCommands(
                session: session, project: project, executableURL: executableURL, options: options)
            : buildResumeUsingProjectProfileCommandLines(
                session: session, project: project, executableURL: executableURL, options: options)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    @discardableResult
    func openNewSessionUsingProjectProfile(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> Bool {
        let scriptText = {
            let lines = buildNewSessionUsingProjectProfileCommandLines(
                session: session, project: project, executableURL: executableURL, options: options,
                initialPrompt: initialPrompt
            )
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

    // MARK: - Helpers
    private func shellSingleQuoted(_ v: String) -> String {
        "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func copyRealResumeInvocation(
        session: SessionSummary, executableURL: URL, options: ResumeOptions
    ) {
        let command: String
        if session.isRemote, let host = session.remoteHost {
            let remote = buildRemoteResumeShellCommand(session: session, options: options)
            command = "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remote))"
        } else {
            let execName = session.source.baseKind == .codex ? "codex" : "claude"
            let execPath =
                resolveExecutableURL(preferred: executableURL, executableName: execName)?.path
                ?? executableURL.path
            command = buildResumeCLIInvocation(
                session: session, executablePath: execPath, options: options)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command + "\n", forType: .string)
    }

    @discardableResult
    func openInTerminal(session: SessionSummary, executableURL: URL, options: ResumeOptions) -> Bool
    {
        let scriptText = {
            let lines = buildResumeCommandLines(
                session: session, executableURL: executableURL, options: options
            )
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
    func openNewSession(session: SessionSummary, executableURL: URL, options: ResumeOptions) -> Bool
    {
        let scriptText = {
            let lines = buildNewSessionCommandLines(
                session: session, executableURL: executableURL, options: options
            )
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
            NSWorkspace.shared.openApplication(
                at: appURL, configuration: config, completionHandler: nil)
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
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch { return false }
    }

    // MARK: - Warp Launch Configuration
    @discardableResult
    func openWarpLaunchConfig(session: SessionSummary, options: ResumeOptions) -> Bool {
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(".warp", isDirectory: true)
            .appendingPathComponent("launch_configurations", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { /* ignore */  }

        let baseName = "codmate-resume-\(session.id)"
        let fileName = baseName + ".yaml"
        let fileURL = folder.appendingPathComponent(fileName)
        let flagsString: String = {
            // Use configured options; prefer bare `codex` so Warp resolves via PATH.
            let cmd = buildResumeCLIInvocation(
                session: session, executablePath: "codex", options: options)
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
