import Foundation

// MARK: - Claude Code user settings writer (~/.claude/settings.json)

actor ClaudeSettingsService {
    struct Paths {
        let dir: URL
        let file: URL
        static func `default`() -> Paths {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            let dir = home.appendingPathComponent(".claude", isDirectory: true)
            return Paths(dir: dir, file: dir.appendingPathComponent("settings.json", isDirectory: false))
        }
    }

    // MARK: - Runtime composite
    struct Runtime: Sendable {
        var permissionMode: String? // default/acceptEdits/bypassPermissions/plan
        var skipPermissions: Bool
        var allowSkipPermissions: Bool
        var debug: Bool
        var debugFilter: String?
        var verbose: Bool
        var ide: Bool
        var strictMCP: Bool
        var fallbackModel: String?
        var allowedTools: String?
        var disallowedTools: String?
        var addDirs: [String]?
    }

    struct NotificationHooksStatus: Sendable {
        var permissionHookInstalled: Bool
        var completionHookInstalled: Bool
    }

    private enum HookEvent: String {
        case permission
        case complete
    }

    private struct HookPayload {
        var title: String
        var body: String
    }

    private let codMateHookURLPrefix = "codmate://notify?source=claude&event="
    private let claudeNotificationKey = "Notification"
    private let claudeStopKey = "Stop"

    func applyRuntime(_ r: Runtime) throws {
        var obj = loadObject()
        func setOrRemove(_ key: String, _ value: Any?) {
            if let v = value {
                obj[key] = v
            } else {
                obj.removeValue(forKey: key)
            }
        }
        // permissionMode: omit when default
        let pm = (r.permissionMode == nil || r.permissionMode == "default") ? nil : r.permissionMode
        setOrRemove("permissionMode", pm)
        // booleans: only store when true to keep file light
        setOrRemove("skipPermissions", r.skipPermissions ? true : nil)
        setOrRemove("allowSkipPermissions", r.allowSkipPermissions ? true : nil)
        setOrRemove("debug", r.debug ? true : nil)
        let df = (r.debugFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? r.debugFilter : nil
        setOrRemove("debugFilter", df)
        setOrRemove("verbose", r.verbose ? true : nil)
        setOrRemove("ide", r.ide ? true : nil)
        setOrRemove("strictMCP", r.strictMCP ? true : nil)
        let fb = (r.fallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? r.fallbackModel : nil
        setOrRemove("fallbackModel", fb)
        let at = (r.allowedTools?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? r.allowedTools : nil
        let dt = (r.disallowedTools?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? r.disallowedTools : nil
        setOrRemove("allowedTools", at)
        setOrRemove("disallowedTools", dt)
        let dirs = (r.addDirs?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        setOrRemove("addDirs", (dirs?.isEmpty == false) ? dirs : nil)
        try writeObject(obj)
    }

    // MARK: - Notification hooks (CodMate-managed)
    func codMateNotificationHooksStatus() -> NotificationHooksStatus {
        let obj = loadObject()
        guard let hooks = obj["hooks"] as? [String: Any] else {
            return NotificationHooksStatus(permissionHookInstalled: false, completionHookInstalled: false)
        }
        return NotificationHooksStatus(
            permissionHookInstalled: containsCodMateHook(in: hooks, key: claudeNotificationKey, event: .permission),
            completionHookInstalled: containsCodMateHook(in: hooks, key: claudeStopKey, event: .complete)
        )
    }

    func setCodMateNotificationHooks(enabled: Bool) throws {
        var obj = loadObject()
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        hooks = updateHooksContainer(
            hooks,
            key: claudeNotificationKey,
            event: .permission,
            enabled: enabled
        )
        hooks = updateHooksContainer(
            hooks,
            key: claudeStopKey,
            event: .complete,
            enabled: enabled
        )
        if hooks.isEmpty {
            obj.removeValue(forKey: "hooks")
        } else {
            obj["hooks"] = hooks
        }
        try writeObject(obj)
    }

    private func containsCodMateHook(in hooks: [String: Any], key: String, event: HookEvent) -> Bool {
        guard let entries = hooks[key] as? [[String: Any]] else { return false }
        let marker = "\(codMateHookURLPrefix)\(event.rawValue)"
        for entry in entries {
            guard let nested = entry["hooks"] as? [[String: Any]] else { continue }
            if nested.contains(where: { ($0["command"] as? String)?.contains(marker) == true }) {
                return true
            }
        }
        return false
    }

    private func updateHooksContainer(
        _ hooks: [String: Any],
        key: String,
        event: HookEvent,
        enabled: Bool
    ) -> [String: Any] {
        var container = hooks
        var entries = (container[key] as? [[String: Any]]) ?? []
        let marker = "\(codMateHookURLPrefix)\(event.rawValue)"
        entries.removeAll { entry in
            guard let nested = entry["hooks"] as? [[String: Any]] else { return false }
            return nested.contains { ($0["command"] as? String)?.contains(marker) == true }
        }
        if enabled {
            if let urlString = hookURL(for: event) {
                // 使用 -j (隐藏启动) 而不是 -g (后台启动) 来防止 SwiftUI WindowGroup 自动创建新窗口
                let command = "/usr/bin/open -j \"\(urlString)\""
                entries.append(["hooks": [["type": "command", "command": command]]])
            }
        }
        if entries.isEmpty {
            container.removeValue(forKey: key)
        } else {
            container[key] = entries
        }
        return container
    }

    private func hookURL(for event: HookEvent) -> String? {
        let payload = hookPayload(for: event)
        var comps = URLComponents()
        comps.scheme = "codmate"
        comps.host = "notify"
        var query: [URLQueryItem] = [
            URLQueryItem(name: "source", value: "claude"),
            URLQueryItem(name: "event", value: event.rawValue)
        ]
        if let titleData = payload.title.data(using: .utf8) {
            query.append(URLQueryItem(name: "title64", value: titleData.base64EncodedString()))
        }
        if let bodyData = payload.body.data(using: .utf8) {
            query.append(URLQueryItem(name: "body64", value: bodyData.base64EncodedString()))
        }
        comps.queryItems = query
        return comps.url?.absoluteString
    }

    private func hookPayload(for event: HookEvent) -> HookPayload {
        switch event {
        case .permission:
            return HookPayload(
                title: "Claude Code",
                body: "Claude Code requires approval. Return to the Claude window to respond."
            )
        case .complete:
            return HookPayload(
                title: "Claude Code",
                body: "Claude Code finished its current task."
            )
        }
    }

    private let fm: FileManager
    private let paths: Paths

    init(fileManager: FileManager = .default, paths: Paths = .default()) {
        self.fm = fileManager
        self.paths = paths
    }

    // Load existing JSON dict or empty
    private func loadObject() -> [String: Any] {
        guard let data = try? Data(contentsOf: paths.file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // Atomic write with backup
    private func writeObject(_ obj: [String: Any]) throws {
        try fm.createDirectory(at: paths.dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: paths.file) {
            let backup = paths.file.appendingPathExtension("backup")
            try? data.write(to: backup, options: .atomic)
        }
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: paths.file, options: .atomic)
    }

    // MARK: - Public upserts
    func setModel(_ modelId: String?) throws {
        var obj = loadObject()
        if let m = modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            obj["model"] = m
        } else {
            obj.removeValue(forKey: "model")
        }
        try writeObject(obj)
    }

    func setForceLoginMethod(_ method: String?) throws {
        var obj = loadObject()
        if let m = method?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            obj["forceLoginMethod"] = m
        } else {
            obj.removeValue(forKey: "forceLoginMethod")
        }
        try writeObject(obj)
    }

    func setEnvBaseURL(_ baseURL: String?) throws {
        var obj = loadObject()
        var env = (obj["env"] as? [String: Any]) ?? [:]
        if let url = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            env["ANTHROPIC_BASE_URL"] = url
        } else {
            env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        }
        if env.isEmpty { obj.removeValue(forKey: "env") } else { obj["env"] = env }
        try writeObject(obj)
    }

    func setEnvToken(_ token: String?) throws {
        var obj = loadObject()
        var env = (obj["env"] as? [String: Any]) ?? [:]
        if let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            env["ANTHROPIC_AUTH_TOKEN"] = t
        } else {
            env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        }
        if env.isEmpty { obj.removeValue(forKey: "env") } else { obj["env"] = env }
        try writeObject(obj)
    }
}
