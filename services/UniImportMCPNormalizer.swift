import Foundation

// MARK: - Uni-Import Normalizer (JSON-first MVP)

enum UniImportError: Error, LocalizedError { case invalid, empty
    var errorDescription: String? {
        switch self {
        case .invalid: return "Failed to parse input"
        case .empty: return "No servers detected in the input"
        }
    }
}

struct UniImportMCPNormalizer {
    // Accept plain text (JSON snippets, fenced blocks, or raw object)
    static func parseText(_ text: String) throws -> [MCPServerDraft] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UniImportError.empty }

        // Try direct JSON (then a broad { ... } slice fallback)
        if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
            let drafts = draftFromJSON(json)
            if !drafts.isEmpty { return drafts }
        }

        // Fenced ```json blocks or widest {...}
        if let inner = extractJSONSlice(from: trimmed) {
            if let json = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) {
                let drafts = draftFromJSON(json)
                if !drafts.isEmpty { return drafts }
            }
        }

        // Try TOML (heuristic): extract a TOML-looking slice and parse minimal keys
        if let tomlSlice = extractTOMLSlice(from: trimmed) {
            let drafts = draftFromTOML(tomlSlice)
            if !drafts.isEmpty { return drafts }
        }

        throw UniImportError.invalid
    }

    // Very small heuristic to grab a JSON-looking slice
    private static func extractJSONSlice(from text: String) -> String? {
        if let m = text.range(of: "```json", options: .caseInsensitive),
           let end = text.range(of: "```", range: m.upperBound..<text.endIndex) {
            return String(text[m.upperBound..<end.lowerBound])
        }
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}") , e > s {
            return String(text[s...e])
        }
        return nil
    }

    private static func normString(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func normStringArray(_ v: Any?) -> [String]? {
        if let a = v as? [Any] {
            let mapped = a.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return mapped.isEmpty ? nil : mapped
        }
        if let s = normString(v) {
            let parts = s.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
            return parts.isEmpty ? nil : parts
        }
        return nil
    }

    private static func normDict(_ v: Any?) -> [String: String]? {
        guard let o = v as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, raw) in o { out[k] = (raw as? String) ?? String(describing: raw) }
        return out.isEmpty ? nil : out
    }

    private static func parseKind(_ value: Any?) -> MCPServerKind {
        let token = (value as? String)?.lowercased() ?? ""
        switch token {
        case "sse", "server-sent-events": return .sse
        case "streamable_http", "streamable-http", "http", "http_stream": return .streamable_http
        default: return .stdio
        }
    }

    private static func buildDraft(name: Any?, config: Any?) -> MCPServerDraft? {
        guard let raw = config as? [String: Any] else { return nil }
        let n = normString(name) ?? normString(raw["name"]) ?? "imported-server"
        let kind = parseKind(raw["kind"] ?? raw["type"] ?? raw["server_type"])
        let command = normString(raw["command"] ?? raw["command_path"] ?? raw["launch"]) ?? nil
        let args = normStringArray(raw["args"]) ?? nil
        let env = normDict(raw["env"]) ?? nil
        let url = normString(raw["url"] ?? raw["endpoint"] ?? raw["baseUrl"]) ?? nil
        let headers = normDict(raw["headers"]) ?? nil

        var meta = MCPServerMeta()
        meta.description = normString(raw["description"]) ?? normString((raw["meta"] as? [String: Any])?["description"]) ?? nil
        meta.version = normString((raw["meta"] as? [String: Any])?["version"]) ?? nil
        meta.websiteUrl = normString((raw["meta"] as? [String: Any])?["websiteUrl"]) ?? nil
        meta.repositoryURL = normString((raw["meta"] as? [String: Any])?["repository"]) ?? nil

        return MCPServerDraft(name: n, kind: kind, command: command, args: args, env: env, url: url, headers: headers, meta: meta)
    }

    private static func draftFromJSON(_ json: Any) -> [MCPServerDraft] {
        guard let obj = json as? [String: Any] else {
            return []
        }
        if let servers = obj["mcpServers"] as? [String: Any] {
            return servers.compactMap { key, value in buildDraft(name: key, config: value) }
        }
        if let servers = obj["servers"] as? [String: Any] {
            let drafts = servers.compactMap { key, value in buildDraft(name: key, config: value) }
            if !drafts.isEmpty { return drafts }
        }
        if let array = obj["servers"] as? [Any] {
            return array.compactMap { entry in
                let n = (entry as? [String: Any])?["name"]
                return buildDraft(name: n, config: entry)
            }
        }
        if let single = buildDraft(name: obj["name"], config: obj) { return [single] }
        return []
    }

    // MARK: - Minimal TOML support (heuristic)

    private static func extractTOMLSlice(from text: String) -> String? {
        // 1) fenced ```toml
        if let m = text.range(of: "```toml", options: .regularExpression),
           let end = text.range(of: "```", range: m.upperBound..<text.endIndex) {
            return String(text[m.upperBound..<end.lowerBound])
        }
        // 2) section-based window around [mcp_servers.*] or [[servers]] or [servers]
        let lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        let sectionRegex = try? NSRegularExpression(pattern: "^\\s*\\[(?:mcp_servers(?:\\.[^\\]]+)?)\\]\\s*$|^\\s*\\[\\[servers\\]\\]\\s*$|^\\s*\\[servers\\]\\s*$", options: [.caseInsensitive])
        let isTomlish: (String) -> Bool = { l in
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            if trimmed.hasPrefix("#") { return true }
            if trimmed.contains("=") { return true }
            return false
        }
        var start = -1
        for (i, l) in lines.enumerated() {
            if let rx = sectionRegex, rx.firstMatch(in: l, options: [], range: NSRange(location: 0, length: l.utf16.count)) != nil {
                start = i; break
            }
        }
        if start >= 0 {
            var end = lines.count
            var nonToml = 0
            for j in start..<lines.count {
                if isTomlish(lines[j]) { nonToml = 0; continue }
                nonToml += 1
                if nonToml >= 2 { end = j - 1; break }
            }
            return lines[start..<end].joined(separator: "\n")
        }
        return nil
    }

    private static func parseTomlArray(_ s: String) -> [String]? {
        // very small parser for ["a", "b"] or [a, b]
        let inner = s.trimmingCharacters(in: .whitespaces)
        guard inner.first == "[", inner.last == "]" else { return nil }
        let body = inner.dropFirst().dropLast()
        let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for p in parts {
            var t = p
            if t.hasPrefix("\"") && t.hasSuffix("\"") { t = String(t.dropFirst().dropLast()) }
            if t.hasPrefix("'") && t.hasSuffix("'") { t = String(t.dropFirst().dropLast()) }
            if !t.isEmpty { out.append(String(t)) }
        }
        return out.isEmpty ? nil : out
    }

    private static func parseTomlInlineTable(_ s: String) -> [String: String]? {
        // { key = "v", k2 = "v2" }
        let inner = s.trimmingCharacters(in: .whitespaces)
        guard inner.first == "{", inner.last == "}" else { return nil }
        let body = inner.dropFirst().dropLast()
        var out: [String: String] = [:]
        for pair in body.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                var val = kv[1].trimmingCharacters(in: .whitespaces)
                if val.hasPrefix("\"") && val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }
                if val.hasPrefix("'") && val.hasSuffix("'") { val = String(val.dropFirst().dropLast()) }
                out[key] = val
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func parseTomlScalar(_ v: String) -> String? {
        var t = v.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") { t = String(t.dropFirst().dropLast()) }
        if t.hasPrefix("'") && t.hasSuffix("'") { t = String(t.dropFirst().dropLast()) }
        return t
    }

    private static func draftFromTOML(_ text: String) -> [MCPServerDraft] {
        var drafts: [MCPServerDraft] = []
        var currentName: String? = nil
        var current: [String: String] = [:]

        func flushCurrent() {
            guard let name = currentName else { return }
            // build draft from current kv
            let kindToken = (current["kind"] ?? current["type"] ?? current["server_type"])?.lowercased()
            let kind: MCPServerKind = {
                switch kindToken {
                case "sse", "server-sent-events": return .sse
                case "streamable_http", "streamable-http", "http", "http_stream": return .streamable_http
                default: return .stdio
                }
            }()
            let args = current["args"].flatMap(parseTomlArray)
            let env = current["env"].flatMap(parseTomlInlineTable)
            let headers = current["headers"].flatMap(parseTomlInlineTable)
            let meta = MCPServerMeta(description: current["meta.description"],
                                     version: current["meta.version"],
                                     websiteUrl: current["meta.websiteUrl"] ?? current["meta.website_url"],
                                     repositoryURL: current["meta.repository"])
            let draft = MCPServerDraft(
                name: name,
                kind: kind,
                command: current["command"],
                args: args,
                env: env,
                url: current["url"] ?? current["endpoint"] ?? current["baseUrl"],
                headers: headers,
                meta: meta
            )
            drafts.append(draft)
            current.removeAll(keepingCapacity: true)
        }

        // Normalize lines and iterate
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sectionRx = try? NSRegularExpression(pattern: "^\\s*\\[(.+)\\]\\s*$")
        let doubleSectionRx = try? NSRegularExpression(pattern: "^\\s*\\[\\[(.+)\\]\\]\\s*$")

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Section headers
            if let rx = doubleSectionRx, let _ = rx.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
                // e.g., [[servers]]
                flushCurrent()
                currentName = nil
                continue
            }
            if let rx = sectionRx, let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
                let r = m.range(at: 1)
                if let rr = Range(r, in: line) {
                    let section = String(line[rr])
                    if section.lowercased().hasPrefix("mcp_servers.") {
                        flushCurrent()
                        let name = String(section.dropFirst("mcp_servers.".count))
                        currentName = name
                    } else if section.lowercased().hasPrefix("servers.") {
                        flushCurrent()
                        let name = String(section.dropFirst("servers.".count))
                        currentName = name
                    } else {
                        flushCurrent()
                        currentName = nil
                    }
                }
                continue
            }

            // key = value
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // accumulate
            if key == "name" { currentName = parseTomlScalar(value) }
            current[key] = value
        }
        flushCurrent()

        return drafts
    }
}
