import Foundation
import SwiftUI
import AppKit

@available(macOS 15.0, *)
@MainActor
final class DialecticsVM: ObservableObject {
    @Published var sessions: SessionsDiagnostics? = nil
    @Published var codexPresent: Bool = false
    @Published var codexVersion: String? = nil
    @Published var claudePresent: Bool = false
    @Published var claudeVersion: String? = nil
    @Published var pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? ""

    private let sessionsSvc = SessionsDiagnosticsService()

    func runAll(preferences: SessionPreferencesStore) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defRoot = SessionPreferencesStore.defaultSessionsRoot(for: home)
        let notesDefault = SessionPreferencesStore.defaultNotesRoot(for: defRoot)
        let projectsDefault = SessionPreferencesStore.defaultProjectsRoot(for: home)
        let claudeDefault = home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        let claudeCurrent: URL? = FileManager.default.fileExists(atPath: claudeDefault.path) ? claudeDefault : nil
        let s = await sessionsSvc.run(
            currentRoot: preferences.sessionsRoot,
            defaultRoot: defRoot,
            notesCurrentRoot: preferences.notesRoot,
            notesDefaultRoot: notesDefault,
            projectsCurrentRoot: preferences.projectsRoot,
            projectsDefaultRoot: projectsDefault,
            claudeCurrentRoot: claudeCurrent,
            claudeDefaultRoot: claudeDefault
        )
        let mergedPATH = Self.detectLoginShellPATH() ?? Self.defaultMergedPATH()
        let resolved = Self.which("codex", path: mergedPATH)
        let resolvedClaude = Self.which("claude", path: mergedPATH)
        self.sessions = s
        self.codexPresent = (resolved != nil)
        self.claudePresent = (resolvedClaude != nil)
        self.codexVersion = resolved != nil ? Self.version(of: "codex", path: mergedPATH) : nil
        self.claudeVersion = resolvedClaude != nil ? Self.version(of: "claude", path: mergedPATH) : nil
        self.pathEnv = mergedPATH
    }

    private static func defaultMergedPATH() -> String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if current.isEmpty { return defaultPATH }
        // Prepend default to prefer Homebrew paths while preserving user's PATH
        return defaultPATH + ":" + current
    }

    private static func detectLoginShellPATH() -> String? {
        // Ask user's login+interactive shell to print PATH (covers .zprofile/.bash_profile + .zshrc/.bashrc)
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lic", "printf %s \"$PATH\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    }

    private static func shellWhich(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lic", "command -v \(name) || which \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    }

    private static func which(_ name: String, path: String) -> String? {
        // Attempt 1: which
        do {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["which", name]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            proc.environment = env
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    return str
                }
            }
        } catch { /* continue to fallback */ }

        // Attempt 2: shell-based lookup (respects user's rc files)
        if let viaShell = shellWhich(name) { return viaShell }

        // Attempt 3: manual PATH scan
        let fm = FileManager.default
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func version(of name: String, path: String) -> String? {
        // Try common version flags: --version, version, -V, -v
        let candidates: [[String]] = [["--version"], ["version"], ["-V"], ["-v"]]
        for args in candidates {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [name] + args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env["NO_COLOR"] = "1"
            proc.environment = env
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch { continue }

            // Read both stdout and stderr (some CLIs print version to stderr)
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            var out = (String(data: outData, encoding: .utf8) ?? "")
            let err = (String(data: errData, encoding: .utf8) ?? "")
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out = err
            }
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { continue }
            if let firstLine = out.split(separator: "\n").first { out = String(firstLine) }
            if let ver = firstVersionToken(in: out) { return ver }
            // Accept non-empty banner as fallback
            return String(out.prefix(48))
        }
        return nil
    }

    private static func firstVersionToken(in line: String) -> String? {
        // Match first token that looks like digits[.digits][.digits][-.suffix]
        // Lightweight scan to avoid Regex dependency differences
        let separators = CharacterSet.whitespacesAndNewlines
        let tokens = line.components(separatedBy: separators).filter { !$0.isEmpty }
        for t in tokens {
            var s = t
            // Trim common punctuation
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;()[]{}"))
            // Basic pattern check
            let parts = s.split(separator: ".")
            if parts.count >= 2 && parts.count <= 4 && parts.allSatisfy({ $0.allSatisfy({ $0.isNumber }) || $0.contains("-") }) {
                // Allow hyphenated suffix like 1.2.3-beta
                let core = parts.prefix(3)
                if core.allSatisfy({ $0.allSatisfy({ $0.isNumber }) }) { return s }
            }
        }
        return nil
    }

    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
    var buildTime: String {
        guard let exe = Bundle.main.executableURL,
            let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
            let date = attrs[.modificationDate] as? Date
        else { return "Unavailable" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df.string(from: date)
    }
    var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - Report
    struct CombinedReport: Codable {
        let timestamp: Date
        let appVersion: String
        let buildTime: String
        let osVersion: String
        let sessions: SessionsDiagnostics?
        let cli: [String: String?]
    }

    func saveReport(preferences: SessionPreferencesStore) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        panel.nameFieldStringValue = "CodMate-Diagnostics-\(df.string(from: now)).json"
        panel.beginSheetModal(
            for: NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first!
        ) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let report = self.buildReport(preferences: preferences, now: now)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(report) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    @MainActor private func buildReport(preferences: SessionPreferencesStore, now: Date)
        -> CombinedReport
    {
        let cli: [String: String?] = [
            "codexPresent": String(codexPresent),
            "codexVersion": codexVersion,
            "claudePresent": String(claudePresent),
            "claudeVersion": claudeVersion,
            "PATH": pathEnv,
        ]
        return CombinedReport(
            timestamp: now,
            appVersion: appVersion,
            buildTime: buildTime,
            osVersion: osVersion,
            sessions: sessions,
            cli: cli
        )
    }
}
