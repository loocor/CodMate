import Foundation

struct SSHHost: Hashable, Sendable {
    let alias: String
}

struct SSHConfigResolver {
    private let fileManager: FileManager
    private let configURL: URL

    init(
        fileManager: FileManager = .default,
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    ) {
        self.fileManager = fileManager
        self.configURL = configURL
    }

    func resolvedHosts() -> [SSHHost] {
        guard let data = try? Data(contentsOf: configURL),
              let raw = String(data: data, encoding: .utf8) else {
            return []
        }
        var hosts: [String] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.hasPrefix("#") else { continue }
            if trimmed.lowercased().hasPrefix("host ") {
                let parts = trimmed.dropFirst("host".count).trimmingCharacters(in: .whitespaces)
                for token in parts.split(whereSeparator: \.isWhitespace) {
                    let candidate = String(token)
                    guard !candidate.contains("*"), !candidate.contains("?") else { continue }
                    hosts.append(candidate)
                }
            }
        }
        // Preserve order but ensure uniqueness
        var seen: Set<String> = []
        var ordered: [SSHHost] = []
        for host in hosts {
            if seen.insert(host).inserted {
                ordered.append(SSHHost(alias: host))
            }
        }
        return ordered
    }
}
