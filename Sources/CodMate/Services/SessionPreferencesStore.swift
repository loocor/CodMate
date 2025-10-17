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
    }

    private func persist() {
        defaults.set(sessionsRoot.path, forKey: Keys.sessionsRootPath)
        defaults.set(codexExecutableURL.path, forKey: Keys.executablePath)
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
