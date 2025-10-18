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
        static let llmBaseURL = "codex.llm.baseURL"
        static let llmAPIKey = "codex.llm.apiKey"
        static let llmModel = "codex.llm.model"
        static let llmAuto = "codex.llm.autoGenerate"
        static let resumeUseEmbedded = "codex.resume.useEmbedded"
        static let resumeCopyClipboard = "codex.resume.copyClipboard"
        static let resumeExternalApp = "codex.resume.externalApp"
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
        // Initialize LLM prefs from defaults directly to avoid calling methods before initialization completes
        self.llmBaseURL = defaults.string(forKey: Keys.llmBaseURL) ?? "https://api.openai.com"
        self.llmAPIKey = defaults.string(forKey: Keys.llmAPIKey) ?? ""
        self.llmModel = defaults.string(forKey: Keys.llmModel) ?? "gpt-4o-mini"
        self.llmAutoGenerate = defaults.object(forKey: Keys.llmAuto) as? Bool ?? false

        // Resume defaults
        self.defaultResumeUseEmbeddedTerminal =
            defaults.object(forKey: Keys.resumeUseEmbedded) as? Bool ?? true
        self.defaultResumeCopyToClipboard =
            defaults.object(forKey: Keys.resumeCopyClipboard) as? Bool ?? true
        let appRaw = defaults.string(forKey: Keys.resumeExternalApp) ?? TerminalApp.terminal.rawValue
        self.defaultResumeExternalApp = TerminalApp(rawValue: appRaw) ?? .terminal
    }

    private func persist() {
        defaults.set(sessionsRoot.path, forKey: Keys.sessionsRootPath)
        defaults.set(codexExecutableURL.path, forKey: Keys.executablePath)
    }

    // MARK: - LLM Preferences
    @Published var llmBaseURL: String {
        didSet { defaults.set(llmBaseURL, forKey: Keys.llmBaseURL) }
    }
    @Published var llmAPIKey: String {
        didSet { defaults.set(llmAPIKey, forKey: Keys.llmAPIKey) }
    }
    @Published var llmModel: String {
        didSet { defaults.set(llmModel, forKey: Keys.llmModel) }
    }
    @Published var llmAutoGenerate: Bool {
        didSet { defaults.set(llmAutoGenerate, forKey: Keys.llmAuto) }
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, fileManager: .default)
    }

    private func loadLLMDefaults() {}

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
}
