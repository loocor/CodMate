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
        self.llmBaseURL = ""
        self.llmAPIKey = ""
        self.llmModel = ""
        self.llmAutoGenerate = false
        loadLLMDefaults()
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

    private func loadLLMDefaults() {
        llmBaseURL = defaults.string(forKey: Keys.llmBaseURL) ?? "https://api.openai.com"
        llmAPIKey = defaults.string(forKey: Keys.llmAPIKey) ?? ""
        llmModel = defaults.string(forKey: Keys.llmModel) ?? "gpt-4o-mini"
        llmAutoGenerate = defaults.object(forKey: Keys.llmAuto) as? Bool ?? false
    }

    static func defaultSessionsRoot(for homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func defaultExecutableURL() -> URL {
        URL(fileURLWithPath: "/usr/local/bin/codex")
    }
}
