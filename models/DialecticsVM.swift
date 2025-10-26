import Foundation
import SwiftUI
import AppKit

@available(macOS 15.0, *)
@MainActor
final class DialecticsVM: ObservableObject {
    @Published var sessions: SessionsDiagnostics? = nil
    @Published var providers: CodexConfigService.ProviderDiagnostics? = nil
    @Published var resolvedCodexPath: String? = nil
    @Published var pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? ""

    private let sessionsSvc = SessionsDiagnosticsService()
    private let configSvc = CodexConfigService()
    private let actions = SessionActions()

    func runAll(preferences: SessionPreferencesStore) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defRoot = SessionPreferencesStore.defaultSessionsRoot(for: home)
        let s = await sessionsSvc.run(currentRoot: preferences.sessionsRoot, defaultRoot: defRoot)
        let p = await configSvc.diagnoseProviders()
        let resolved = actions.resolveExecutableURL(
            preferred: preferences.codexExecutableURL)?.path
        self.sessions = s
        self.providers = p
        self.resolvedCodexPath = resolved
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
    struct ProviderSummary: Codable {
        let id: String
        let name: String?
        let baseURL: String?
        let managedByCodMate: Bool
    }
    struct ProvidersReport: Codable {
        let configPath: String
        let providers: [ProviderSummary]
        let duplicateIDs: [String]
        let strayManagedBodies: Int
        let headerCounts: [String: Int]
        let canonicalRegion: String  // sanitized env_key values
    }
    struct CombinedReport: Codable {
        let timestamp: Date
        let appVersion: String
        let buildTime: String
        let osVersion: String
        let sessions: SessionsDiagnostics?
        let providers: ProvidersReport?
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
        let p = providers
        let pr: ProvidersReport? = p.map { d in
            let list = d.providers.map {
                ProviderSummary(
                    id: $0.id, name: $0.name, baseURL: $0.baseURL,
                    managedByCodMate: $0.managedByCodMate)
            }
            return ProvidersReport(
                configPath: d.configPath,
                providers: list,
                duplicateIDs: d.duplicateIDs,
                strayManagedBodies: d.strayManagedBodies,
                headerCounts: d.headerCounts,
                canonicalRegion: sanitizeCanonicalRegion(d.canonicalRegion)
            )
        }
        let cli: [String: String?] = [
            "preferredPath": preferences.codexExecutableURL.path,
            "resolvedPath": resolvedCodexPath,
            "PATH": pathEnv,
        ]
        return CombinedReport(
            timestamp: now,
            appVersion: appVersion,
            buildTime: buildTime,
            osVersion: osVersion,
            sessions: sessions,
            providers: pr,
            cli: cli
        )
    }

    private func sanitizeCanonicalRegion(_ text: String) -> String {
        // Redact env_key values to avoid leaking secrets
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("env_key") {
                out.append("env_key = \"***\"")
            } else {
                out.append(raw)
            }
        }
        return out.joined(separator: "\n")
    }
}
