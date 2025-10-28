import Foundation

@MainActor
final class SessionPreferencesStore: ObservableObject {
    @Published var sessionsRoot: URL {
        didSet { persist() }
    }

    @Published var notesRoot: URL {
        didSet { persist() }
    }

    @Published var codexExecutableURL: URL {
        didSet { persist() }
    }

    @Published var claudeExecutableURL: URL {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private struct Keys {
        static let sessionsRootPath = "codex.sessions.rootPath"
        static let notesRootPath = "codex.notes.rootPath"
        static let executablePath = "codex.sessions.executablePath"
        static let claudeExecutablePath = "codex.sessions.claudeExecutablePath"
        static let resumeUseEmbedded = "codex.resume.useEmbedded"
        static let resumeCopyClipboard = "codex.resume.copyClipboard"
        static let resumeExternalApp = "codex.resume.externalApp"
        static let resumeSandboxMode = "codex.resume.sandboxMode"
        static let resumeApprovalPolicy = "codex.resume.approvalPolicy"
        static let resumeFullAuto = "codex.resume.fullAuto"
        static let resumeDangerBypass = "codex.resume.dangerBypass"
        static let autoAssignNewToSameProject = "codex.projects.autoAssignNewToSame"
        static let timelineVisibleKinds = "codex.timeline.visibleKinds"
        static let markdownVisibleKinds = "codex.markdown.visibleKinds"
        // Claude advanced
        static let claudeDebug = "claude.debug"
        static let claudeDebugFilter = "claude.debug.filter"
        static let claudeVerbose = "claude.verbose"
        static let claudePermissionMode = "claude.permission.mode"
        static let claudeAllowedTools = "claude.allowedTools"
        static let claudeDisallowedTools = "claude.disallowedTools"
        static let claudeAddDirs = "claude.addDirs"
        static let claudeIDE = "claude.ide"
        static let claudeStrictMCP = "claude.strictMCP"
        static let claudeFallbackModel = "claude.fallbackModel"
        static let claudeSkipPermissions = "claude.skipPermissions"
        static let claudeAllowSkipPermissions = "claude.allowSkipPermissions"
    }

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        let homeURL = fileManager.homeDirectoryForCurrentUser

        // Resolve sessions root without touching self
        let resolvedSessionsRoot: URL = {
            if let storedRoot = defaults.string(forKey: Keys.sessionsRootPath) {
                let url = URL(fileURLWithPath: storedRoot, isDirectory: true)
                if fileManager.fileExists(atPath: url.path) {
                    return url
                } else {
                    defaults.removeObject(forKey: Keys.sessionsRootPath)
                }
            }
            return SessionPreferencesStore.defaultSessionsRoot(for: homeURL)
        }()

        // Resolve notes root (prefer stored path; else sibling of sessions root)
        let resolvedNotesRoot: URL = {
            if let storedNotes = defaults.string(forKey: Keys.notesRootPath) {
                let url = URL(fileURLWithPath: storedNotes, isDirectory: true)
                if fileManager.fileExists(atPath: url.path) {
                    return url
                } else {
                    defaults.removeObject(forKey: Keys.notesRootPath)
                }
            }
            return SessionPreferencesStore.defaultNotesRoot(for: resolvedSessionsRoot)
        }()

        // Resolve executable path
        let resolvedExec: URL = {
            if let storedExec = defaults.string(forKey: Keys.executablePath) {
                let url = URL(fileURLWithPath: storedExec)
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url
                } else {
                    defaults.removeObject(forKey: Keys.executablePath)
                }
            }
            return SessionPreferencesStore.defaultExecutableURL()
        }()

        // Assign after all are computed to avoid using self before init completes
        self.sessionsRoot = resolvedSessionsRoot
        self.notesRoot = resolvedNotesRoot
        // Resolve claude executable path
        let resolvedClaudeExec: URL = {
            if let storedExec = defaults.string(forKey: Keys.claudeExecutablePath) {
                let url = URL(fileURLWithPath: storedExec)
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url
                } else {
                    defaults.removeObject(forKey: Keys.claudeExecutablePath)
                }
            }
            return SessionPreferencesStore.defaultClaudeExecutableURL()
        }()

        self.codexExecutableURL = resolvedExec
        self.claudeExecutableURL = resolvedClaudeExec
        // Resume defaults
        self.defaultResumeUseEmbeddedTerminal =
            defaults.object(forKey: Keys.resumeUseEmbedded) as? Bool ?? true
        self.defaultResumeCopyToClipboard =
            defaults.object(forKey: Keys.resumeCopyClipboard) as? Bool ?? true
        let appRaw = defaults.string(forKey: Keys.resumeExternalApp) ?? TerminalApp.terminal.rawValue
        self.defaultResumeExternalApp = TerminalApp(rawValue: appRaw) ?? .terminal

        // CLI policy defaults (with legacy value coercion)
        if let s = defaults.string(forKey: Keys.resumeSandboxMode), let val = SessionPreferencesStore.coerceSandboxMode(s) {
            self.defaultResumeSandboxMode = val
            if val.rawValue != s { defaults.set(val.rawValue, forKey: Keys.resumeSandboxMode) }
        } else {
            self.defaultResumeSandboxMode = .workspaceWrite
        }
        if let a = defaults.string(forKey: Keys.resumeApprovalPolicy), let val = SessionPreferencesStore.coerceApprovalPolicy(a) {
            self.defaultResumeApprovalPolicy = val
            if val.rawValue != a { defaults.set(val.rawValue, forKey: Keys.resumeApprovalPolicy) }
        } else {
            self.defaultResumeApprovalPolicy = .onRequest
        }
        self.defaultResumeFullAuto = defaults.object(forKey: Keys.resumeFullAuto) as? Bool ?? false
        self.defaultResumeDangerBypass = defaults.object(forKey: Keys.resumeDangerBypass) as? Bool ?? false
        // Projects behaviors
        self.autoAssignNewToSameProject = defaults.object(forKey: Keys.autoAssignNewToSameProject) as? Bool ?? true

        // Message visibility defaults
        if let storedTimeline = defaults.array(forKey: Keys.timelineVisibleKinds) as? [String] {
            self.timelineVisibleKinds = Set(storedTimeline.compactMap { MessageVisibilityKind(rawValue: $0) })
        } else {
            self.timelineVisibleKinds = MessageVisibilityKind.timelineDefault
        }
        if let storedMarkdown = defaults.array(forKey: Keys.markdownVisibleKinds) as? [String] {
            self.markdownVisibleKinds = Set(storedMarkdown.compactMap { MessageVisibilityKind(rawValue: $0) })
        } else {
            self.markdownVisibleKinds = MessageVisibilityKind.markdownDefault
        }
        // Claude advanced defaults
        self.claudeDebug = defaults.object(forKey: Keys.claudeDebug) as? Bool ?? false
        self.claudeDebugFilter = defaults.string(forKey: Keys.claudeDebugFilter) ?? ""
        self.claudeVerbose = defaults.object(forKey: Keys.claudeVerbose) as? Bool ?? false
        if let pm = defaults.string(forKey: Keys.claudePermissionMode) {
            self.claudePermissionMode = ClaudePermissionMode(rawValue: pm) ?? .default
        } else { self.claudePermissionMode = .default }
        self.claudeAllowedTools = defaults.string(forKey: Keys.claudeAllowedTools) ?? ""
        self.claudeDisallowedTools = defaults.string(forKey: Keys.claudeDisallowedTools) ?? ""
        self.claudeAddDirs = defaults.string(forKey: Keys.claudeAddDirs) ?? ""
        self.claudeIDE = defaults.object(forKey: Keys.claudeIDE) as? Bool ?? false
        self.claudeStrictMCP = defaults.object(forKey: Keys.claudeStrictMCP) as? Bool ?? false
        self.claudeFallbackModel = defaults.string(forKey: Keys.claudeFallbackModel) ?? ""
        self.claudeSkipPermissions = defaults.object(forKey: Keys.claudeSkipPermissions) as? Bool ?? false
        self.claudeAllowSkipPermissions = defaults.object(forKey: Keys.claudeAllowSkipPermissions) as? Bool ?? false
    }

    private func persist() {
        defaults.set(sessionsRoot.path, forKey: Keys.sessionsRootPath)
        defaults.set(notesRoot.path, forKey: Keys.notesRootPath)
        defaults.set(codexExecutableURL.path, forKey: Keys.executablePath)
        defaults.set(claudeExecutableURL.path, forKey: Keys.claudeExecutablePath)
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, fileManager: .default)
    }

    static func defaultSessionsRoot(for homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func defaultNotesRoot(for sessionsRoot: URL) -> URL {
        sessionsRoot.deletingLastPathComponent().appendingPathComponent("notes", isDirectory: true)
    }

    static func defaultExecutableURL() -> URL {
        URL(fileURLWithPath: "/usr/local/bin/codex")
    }

    static func defaultClaudeExecutableURL() -> URL {
        URL(fileURLWithPath: "/usr/local/bin/claude")
    }

    // MARK: - Legacy coercion helpers
    private static func coerceSandboxMode(_ raw: String) -> SandboxMode? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = SandboxMode(rawValue: v) { return exact }
        switch v {
        case "full": return SandboxMode.dangerFullAccess
        case "rw", "write": return SandboxMode.workspaceWrite
        case "ro", "read": return SandboxMode.readOnly
        default: return nil
        }
    }

    private static func coerceApprovalPolicy(_ raw: String) -> ApprovalPolicy? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = ApprovalPolicy(rawValue: v) { return exact }
        switch v {
        case "auto": return ApprovalPolicy.onRequest
        case "fail", "onfail": return ApprovalPolicy.onFailure
        default: return nil
        }
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

    // Projects: auto-assign new sessions from detail to same project (default ON)
    @Published var autoAssignNewToSameProject: Bool {
        didSet { defaults.set(autoAssignNewToSameProject, forKey: Keys.autoAssignNewToSameProject) }
    }

    // Visibility for timeline and export markdown
    @Published var timelineVisibleKinds: Set<MessageVisibilityKind> = MessageVisibilityKind.timelineDefault {
        didSet { defaults.set(Array(timelineVisibleKinds.map { $0.rawValue }), forKey: Keys.timelineVisibleKinds) }
    }
    @Published var markdownVisibleKinds: Set<MessageVisibilityKind> = MessageVisibilityKind.markdownDefault {
        didSet { defaults.set(Array(markdownVisibleKinds.map { $0.rawValue }), forKey: Keys.markdownVisibleKinds) }
    }

    var resumeOptions: ResumeOptions {
        var opt = ResumeOptions(
            sandbox: defaultResumeSandboxMode,
            approval: defaultResumeApprovalPolicy,
            fullAuto: defaultResumeFullAuto,
            dangerouslyBypass: defaultResumeDangerBypass
        )
        // Carry Claude advanced flags for launch
        opt.claudeDebug = claudeDebug
        opt.claudeDebugFilter = claudeDebugFilter.isEmpty ? nil : claudeDebugFilter
        opt.claudeVerbose = claudeVerbose
        opt.claudePermissionMode = claudePermissionMode
        opt.claudeAllowedTools = claudeAllowedTools.isEmpty ? nil : claudeAllowedTools
        opt.claudeDisallowedTools = claudeDisallowedTools.isEmpty ? nil : claudeDisallowedTools
        opt.claudeAddDirs = claudeAddDirs.isEmpty ? nil : claudeAddDirs
        opt.claudeIDE = claudeIDE
        opt.claudeStrictMCP = claudeStrictMCP
        opt.claudeFallbackModel = claudeFallbackModel.isEmpty ? nil : claudeFallbackModel
        opt.claudeSkipPermissions = claudeSkipPermissions
        opt.claudeAllowSkipPermissions = claudeAllowSkipPermissions
        return opt
    }

    // MARK: - Claude Advanced (Published)
    @Published var claudeDebug: Bool { didSet { defaults.set(claudeDebug, forKey: Keys.claudeDebug) } }
    @Published var claudeDebugFilter: String { didSet { defaults.set(claudeDebugFilter, forKey: Keys.claudeDebugFilter) } }
    @Published var claudeVerbose: Bool { didSet { defaults.set(claudeVerbose, forKey: Keys.claudeVerbose) } }
    @Published var claudePermissionMode: ClaudePermissionMode { didSet { defaults.set(claudePermissionMode.rawValue, forKey: Keys.claudePermissionMode) } }
    @Published var claudeAllowedTools: String { didSet { defaults.set(claudeAllowedTools, forKey: Keys.claudeAllowedTools) } }
    @Published var claudeDisallowedTools: String { didSet { defaults.set(claudeDisallowedTools, forKey: Keys.claudeDisallowedTools) } }
    @Published var claudeAddDirs: String { didSet { defaults.set(claudeAddDirs, forKey: Keys.claudeAddDirs) } }
    @Published var claudeIDE: Bool { didSet { defaults.set(claudeIDE, forKey: Keys.claudeIDE) } }
    @Published var claudeStrictMCP: Bool { didSet { defaults.set(claudeStrictMCP, forKey: Keys.claudeStrictMCP) } }
    @Published var claudeFallbackModel: String { didSet { defaults.set(claudeFallbackModel, forKey: Keys.claudeFallbackModel) } }
    @Published var claudeSkipPermissions: Bool { didSet { defaults.set(claudeSkipPermissions, forKey: Keys.claudeSkipPermissions) } }
    @Published var claudeAllowSkipPermissions: Bool { didSet { defaults.set(claudeAllowSkipPermissions, forKey: Keys.claudeAllowSkipPermissions) } }
}
