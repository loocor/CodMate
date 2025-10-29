import Foundation
import SwiftUI
import AppKit

@available(macOS 15.0, *)
@MainActor
final class DialecticsVM: ObservableObject {
    @Published var sessions: SessionsDiagnostics? = nil
    @Published var resolvedCodexPath: String? = nil
    @Published var resolvedClaudePath: String? = nil
    @Published var pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? ""

    private let sessionsSvc = SessionsDiagnosticsService()
    private let actions = SessionActions()

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
        let resolved = actions.resolveExecutableURL(
            preferred: preferences.codexExecutableURL)?.path
        let resolvedClaude = actions.resolveExecutableURL(
            preferred: preferences.claudeExecutableURL, executableName: "claude")?.path
        self.sessions = s
        self.resolvedCodexPath = resolved
        self.resolvedClaudePath = resolvedClaude
        self.pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
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
            "preferredPath": preferences.codexExecutableURL.path,
            "resolvedPath": resolvedCodexPath,
            "preferredClaudePath": preferences.claudeExecutableURL.path,
            "resolvedClaudePath": resolvedClaudePath,
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
