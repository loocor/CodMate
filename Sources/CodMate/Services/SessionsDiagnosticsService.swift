import Foundation

struct SessionsDiagnostics: Codable, Sendable {
    struct Probe: Codable, Sendable {
        var path: String
        var exists: Bool
        var isDirectory: Bool
        var enumeratedJsonlCount: Int
        var sampleFiles: [String]
        var enumeratorError: String?
    }

    var timestamp: Date
    var current: Probe
    var defaultRoot: Probe
    var suggestions: [String]
}

actor SessionsDiagnosticsService {
    private let fm: FileManager

    init(fileManager: FileManager = .default) {
        self.fm = fileManager
    }

    func run(currentRoot: URL, defaultRoot: URL) async -> SessionsDiagnostics {
        let currentProbe = probe(root: currentRoot)
        let defaultProbe = probe(root: defaultRoot)

        var suggestions: [String] = []
        if currentProbe.enumeratedJsonlCount == 0, defaultProbe.enumeratedJsonlCount > 0,
            currentProbe.exists
        {
            suggestions.append("Switch sessions root to default path; it contains sessions.")
        }
        if !currentProbe.exists {
            suggestions.append("Current sessions root does not exist; create or select another directory.")
        }
        if currentProbe.exists, !currentProbe.isDirectory {
            suggestions.append("Current sessions root is not a directory; select a folder.")
        }
        if currentProbe.enumeratedJsonlCount == 0,
            currentProbe.enumeratorError == nil,
            defaultProbe.enumeratedJsonlCount == 0
        {
            suggestions.append("No .jsonl files found under both roots; ensure Codex CLI is writing sessions.")
        }

        return SessionsDiagnostics(
            timestamp: Date(),
            current: currentProbe,
            defaultRoot: defaultProbe,
            suggestions: suggestions
        )
    }

    // MARK: - Helpers
    private func probe(root: URL) -> SessionsDiagnostics.Probe {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: root.path, isDirectory: &isDir)
        var count = 0
        var samples: [String] = []
        var enumError: String? = nil

        if exists, isDir.boolValue {
            if let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    if url.pathExtension.lowercased() == "jsonl" {
                        count += 1
                        if samples.count < 10 { samples.append(url.path) }
                    }
                }
            } else {
                enumError = "Failed to open enumerator for \(root.path)"
            }
        }

        return .init(
            path: root.path,
            exists: exists,
            isDirectory: isDir.boolValue,
            enumeratedJsonlCount: count,
            sampleFiles: samples,
            enumeratorError: enumError
        )
    }
}

