import Foundation

// MARK: - Persistent MCP Servers Store

actor MCPServersStore {
    struct Paths { let home: URL; let fileURL: URL }

    static func defaultPaths(fileManager: FileManager = .default) -> Paths {
        let home = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codmate", isDirectory: true)
        return Paths(home: home, fileURL: home.appendingPathComponent("mcp-servers.json"))
    }

    private let fm: FileManager
    private let paths: Paths
    private var cache: [MCPServer]? = nil

    init(paths: Paths = MCPServersStore.defaultPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
    }

    // MARK: Load/Save
    func load() -> [MCPServer] {
        if let cache { return cache }
        let url = paths.fileURL
        guard let data = try? Data(contentsOf: url) else { cache = []; return [] }
        if let list = try? JSONDecoder().decode([MCPServer].self, from: data) {
            cache = list
            return list
        }
        cache = []
        return []
    }

    private func save(_ list: [MCPServer]) throws {
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let tmp = paths.fileURL.appendingPathExtension("tmp")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(list)
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: paths.fileURL.path) { try fm.removeItem(at: paths.fileURL) }
        try fm.moveItem(at: tmp, to: paths.fileURL)
        cache = list
    }

    // MARK: Public API
    func list() -> [MCPServer] { load() }

    func upsert(_ server: MCPServer) throws {
        var list = load()
        if let idx = list.firstIndex(where: { $0.name == server.name }) {
            list[idx] = server
        } else {
            list.append(server)
        }
        try save(list)
    }

    func upsertMany(_ servers: [MCPServer]) throws {
        var map: [String: MCPServer] = [:]
        for s in load() { map[s.name] = s }
        for s in servers { map[s.name] = s }
        let sorted = map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try save(sorted)
    }

    // Export enabled servers to Claude Code config file (~/.claude.json)
    // Claude Code accepts MCP configuration from:
    // 1. ~/.claude.json (user-level config for all projects)
    // 2. <project>/.mcp.json (project-shared config via git)
    // 3. ~/.claude.json with project-specific overrides
    //
    // Safety strategy:
    // - Only modifies the "mcpServers" field
    // - Preserves all other existing configuration
    // - Creates backup before writing
    // - Uses atomic write to prevent partial corruption
    func exportEnabledForClaudeConfig() throws {
        let list = load().filter { $0.enabled }
        let claudeConfigPath = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")

        // Step 1: Load existing config or create empty object
        var existingConfig: [String: Any] = [:]
        var existingData: Data? = nil

        if fm.fileExists(atPath: claudeConfigPath.path) {
            existingData = try? Data(contentsOf: claudeConfigPath)
            if let data = existingData,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existingConfig = json
            }
        }

        // Step 2: Build mcpServers object
        var serversObj: [String: Any] = [:]
        for s in list {
            var entry: [String: Any] = [:]
            if let url = s.url { entry["url"] = url }
            if let cmd = s.command { entry["command"] = cmd }
            if let args = s.args { entry["args"] = args }
            if let env = s.env { entry["env"] = env }
            if let headers = s.headers { entry["headers"] = headers }
            serversObj[s.name] = entry
        }

        // Step 3: Update or remove mcpServers key
        if serversObj.isEmpty {
            existingConfig.removeValue(forKey: "mcpServers")
        } else {
            existingConfig["mcpServers"] = serversObj
        }

        // Step 4: Create backup if file exists
        if let backupData = existingData {
            let backupPath = claudeConfigPath.appendingPathExtension("backup")
            try? backupData.write(to: backupPath, options: .atomic)
        }

        // Step 5: Write atomically to ~/.claude.json
        let data = try JSONSerialization.data(withJSONObject: existingConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: claudeConfigPath, options: .atomic)
    }

    func delete(name: String) throws {
        var list = load()
        list.removeAll { $0.name == name }
        try save(list)
    }

    func setEnabled(name: String, enabled: Bool) throws {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.name == name }) else { return }
        list[idx].enabled = enabled
        try save(list)
    }

    func setCapabilityEnabled(name: String, capability: String, enabled: Bool) throws {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.name == name }) else { return }
        var caps = list[idx].capabilities
        if let cidx = caps.firstIndex(where: { $0.name == capability }) {
            caps[cidx].enabled = enabled
        } else {
            caps.append(MCPCapability(name: capability, enabled: enabled))
        }
        list[idx].capabilities = caps
        try save(list)
    }
}
