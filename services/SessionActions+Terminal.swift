import AppKit
import Foundation

extension SessionActions {
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


}
