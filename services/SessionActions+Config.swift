import Foundation

extension SessionActions {
    func listPersistedProfiles() -> Set<String> {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
            let raw = String(data: data, encoding: .utf8)
        else {
            return []
        }
        var out: Set<String> = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if t.hasPrefix("[profiles.") && t.hasSuffix("]") {
                let start = "[profiles.".count
                let endIndex = t.index(before: t.endIndex)
                let id = String(t[t.index(t.startIndex, offsetBy: start)..<endIndex])
                let trimmed = id.trimmingCharacters(in: CharacterSet.whitespaces)
                if !trimmed.isEmpty { out.insert(trimmed) }
            }
        }
        return out
    }

    func persistedProfileExists(_ id: String?) -> Bool {
        guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return listPersistedProfiles().contains(id)
    }

    func readTopLevelConfigString(_ key: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = raw.trimmingCharacters(in: CharacterSet.whitespaces)
            guard t.hasPrefix(key + " ") || t.hasPrefix(key + "=") else { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            var value = String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet.whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }

    func effectiveCodexModel(for session: SessionSummary) -> String? {
        if let configured = readTopLevelConfigString("model")?.trimmingCharacters(
            in: .whitespacesAndNewlines), !configured.isEmpty
        {
            return configured
        }
        if session.source.baseKind == .codex {
            if let m = session.model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                return m
            }
        }
        return nil
    }

    func renderInlineProfileConfig(
        key id: String,
        model: String?,
        approvalPolicy: String?,
        sandboxMode: String?
    ) -> String? {
        var pairs: [String] = []
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let val = model.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("model=\"\(val)\"")
        }
        if let approval = approvalPolicy,
            !approval.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let val = approval.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("approval_policy=\"\(val)\"")
        }
        if let sandbox = sandboxMode,
            !sandbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let val = sandbox.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("sandbox_mode=\"\(val)\"")
        }
        guard !pairs.isEmpty else { return nil }
        return "profiles.\(id)={ \(pairs.joined(separator: ", ")) }"
    }
}
