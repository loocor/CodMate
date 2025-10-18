import Foundation

import Foundation

@MainActor
final class SessionPreferencesStore: ObservableObject {
    @Published var sessionsRoot: URL {
        didSet { persist() }
    }

    @Published var codexExecutableURL: URL {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private struct Keys {
        static let sessionsRootPath = "codex.sessions.rootPath"
        static let executablePath = "codex.sessions.executablePath"
        static let resumeUseEmbedded = "codex.resume.useEmbedded"
        static let resumeCopyClipboard = "codex.resume.copyClipboard"
        static let resumeExternalApp = "codex.resume.externalApp"
        static let resumeSandboxMode = "codex.resume.sandboxMode"
        static let resumeApprovalPolicy = "codex.resume.approvalPolicy"
        static let resumeFullAuto = "codex.resume.fullAuto"
        static let resumeDangerBypass = "codex.resume.dangerBypass"
    }

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        let homeURL = fileManager.homeDirectoryForCurrentUser

        if let storedRoot = defaults.string(forKey: Keys.sessionsRootPath) {
            self.sessionsRoot = URL(fileURLWithPath: storedRoot, isDirectory: true)
        } else {
            self.sessionsRoot = SessionPreferencesStore.defaultSessionsRoot(for: homeURL)
        }

        if let storedExec = defaults.string(forKey: Keys.executablePath) {
            self.codexExecutableURL = URL(fileURLWithPath: storedExec)
        } else {
            self.codexExecutableURL = SessionPreferencesStore.defaultExecutableURL()
        }
        // Resume defaults
        self.defaultResumeUseEmbeddedTerminal =
            defaults.object(forKey: Keys.resumeUseEmbedded) as? Bool ?? true
        self.defaultResumeCopyToClipboard =
            defaults.object(forKey: Keys.resumeCopyClipboard) as? Bool ?? true
        let appRaw = defaults.string(forKey: Keys.resumeExternalApp) ?? TerminalApp.terminal.rawValue
        self.defaultResumeExternalApp = TerminalApp(rawValue: appRaw) ?? .terminal

        // CLI policy defaults
        if let s = defaults.string(forKey: Keys.resumeSandboxMode), let val = SandboxMode(rawValue: s) {
            self.defaultResumeSandboxMode = val
        } else {
            self.defaultResumeSandboxMode = .workspaceWrite
        }
        if let a = defaults.string(forKey: Keys.resumeApprovalPolicy), let val = ApprovalPolicy(rawValue: a) {
            self.defaultResumeApprovalPolicy = val
        } else {
            self.defaultResumeApprovalPolicy = .onRequest
        }
        self.defaultResumeFullAuto = defaults.object(forKey: Keys.resumeFullAuto) as? Bool ?? false
        self.defaultResumeDangerBypass = defaults.object(forKey: Keys.resumeDangerBypass) as? Bool ?? false
    }

    private func persist() {
        defaults.set(sessionsRoot.path, forKey: Keys.sessionsRootPath)
        defaults.set(codexExecutableURL.path, forKey: Keys.executablePath)
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, fileManager: .default)
    }

    static func defaultSessionsRoot(for homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func defaultExecutableURL() -> URL {
        URL(fileURLWithPath: "/usr/local/bin/codex")
    }

    // MARK: - Resume Preferences
    @Published var defaultResumeUseEmbeddedTerminal: Bool {
        didSet { defaults.set(defaultResumeUseEmbeddedTerminal, forKey: Keys.resumeUseEmbedded) }
    }
    @Published var defaultResumeCopyToClipboard: Bool {
        didSet { defaults.set(defaultResumeCopyToClipboard, forKey: Keys.resumeCopyClipboard) }
    }
    @Published var defaultResumeExternalApp: TerminalApp {
        didSet { defaults.set(defaultResumeExternalApp.rawValue, forKey: Keys.resumeExternalApp) }
    }

    @Published var defaultResumeSandboxMode: SandboxMode {
        didSet { defaults.set(defaultResumeSandboxMode.rawValue, forKey: Keys.resumeSandboxMode) }
    }
    @Published var defaultResumeApprovalPolicy: ApprovalPolicy {
        didSet { defaults.set(defaultResumeApprovalPolicy.rawValue, forKey: Keys.resumeApprovalPolicy) }
    }
    @Published var defaultResumeFullAuto: Bool {
        didSet { defaults.set(defaultResumeFullAuto, forKey: Keys.resumeFullAuto) }
    }
    @Published var defaultResumeDangerBypass: Bool {
        didSet { defaults.set(defaultResumeDangerBypass, forKey: Keys.resumeDangerBypass) }
    }

    var resumeOptions: ResumeOptions {
        ResumeOptions(
            sandbox: defaultResumeSandboxMode,
            approval: defaultResumeApprovalPolicy,
            fullAuto: defaultResumeFullAuto,
            dangerouslyBypass: defaultResumeDangerBypass
        )
    }
}
