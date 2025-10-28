import Foundation

// MARK: - Providers Registry (Codex-first, Claude Code placeholder)

actor ProvidersRegistryService {
    // Consumers we support in registry (keys for connectors/bindings)
    enum Consumer: String, Codable, CaseIterable { case codex, claudeCode }

    struct Connector: Codable, Equatable {
        var baseURL: String?
        var wireAPI: String? // responses | chat
        var envKey: String?
        // Login method for this consumer's connector: "api" (default) or "subscription" (Claude login)
        var loginMethod: String?
        var queryParams: [String: String]?
        var httpHeaders: [String: String]?
        var envHttpHeaders: [String: String]?
        var requestMaxRetries: Int?
        var streamMaxRetries: Int?
        var streamIdleTimeoutMs: Int?
        // Optional per-consumer model aliases (used by Claude Code):
        // keys: "default", "haiku", "sonnet", "opus"
        var modelAliases: [String: String]?
    }

    struct ModelCaps: Codable, Equatable {
        var reasoning: Bool?; var tool_use: Bool?; var vision: Bool?; var long_context: Bool?
        var code_tuned: Bool?; var tps_hint: String?; var max_output_tokens: Int?
    }

    struct ModelEntry: Codable, Equatable {
        var vendorModelId: String
        var caps: ModelCaps?
        var aliases: [String]?
    }

    struct Catalog: Codable, Equatable {
        var models: [ModelEntry]?
    }

    struct Recommended: Codable, Equatable {
        var defaultModelFor: [String: String]? // consumer -> vendorModelId
    }

    struct Provider: Codable, Identifiable, Equatable {
        var id: String
        var name: String?
        var `class`: String? // openai-compatible | anthropic | other
        var managedByCodMate: Bool
        var connectors: [String: Connector] // consumer -> connector
        var catalog: Catalog?
        var recommended: Recommended?
    }

    struct Bindings: Codable, Equatable {
        var activeProvider: [String: String]? // consumer -> providerId
        var defaultModel: [String: String]?   // consumer -> vendorModelId
    }

    struct Migration: Codable, Equatable { var importedFromCodexConfigAt: Date? }

    struct Registry: Codable, Equatable {
        var version: Int
        var providers: [Provider]
        var bindings: Bindings
        var migration: Migration?
    }

    // MARK: - Paths
    struct Paths { let home: URL; let fileURL: URL }
    static func defaultPaths(fileManager: FileManager = .default) -> Paths {
        let home = fileManager.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".codmate", isDirectory: true)
        return Paths(home: dir, fileURL: dir.appendingPathComponent("providers.json"))
    }

    private let fm: FileManager
    private let paths: Paths

    init(paths: Paths = ProvidersRegistryService.defaultPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
    }

    // MARK: - Public API
    func load() -> Registry {
        let url = paths.fileURL
        if let data = try? Data(contentsOf: url),
           let reg = try? JSONDecoder().decode(Registry.self, from: data) {
            return reg
        }
        return Registry(
            version: 1,
            providers: [],
            bindings: .init(activeProvider: nil, defaultModel: nil),
            migration: nil
        )
    }

    func save(_ reg: Registry) throws {
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let tmp = paths.fileURL.appendingPathExtension("tmp")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(reg)
        try data.write(to: tmp, options: .atomic)
        // Replace atomically
        if fm.fileExists(atPath: paths.fileURL.path) {
            try fm.removeItem(at: paths.fileURL)
        }
        try fm.moveItem(at: tmp, to: paths.fileURL)
    }

    func listProviders() -> [Provider] { load().providers }

    func upsertProvider(_ provider: Provider) throws {
        var reg = load()
        if let idx = reg.providers.firstIndex(where: { $0.id == provider.id }) {
            reg.providers[idx] = provider
        } else {
            reg.providers.append(provider)
        }
        try save(reg)
    }

    func deleteProvider(id: String) throws {
        var reg = load()
        reg.providers.removeAll { $0.id == id }
        try save(reg)
    }

    func getBindings() -> Bindings { load().bindings }

    func setActiveProvider(_ consumer: Consumer, providerId: String?) throws {
        var reg = load()
        var ap = reg.bindings.activeProvider ?? [:]
        ap[consumer.rawValue] = providerId
        reg.bindings.activeProvider = ap
        try save(reg)
    }

    func setDefaultModel(_ consumer: Consumer, modelId: String?) throws {
        var reg = load()
        var dm = reg.bindings.defaultModel ?? [:]
        dm[consumer.rawValue] = modelId
        reg.bindings.defaultModel = dm
        try save(reg)
    }

    // MARK: - Migration from Codex config (providers + active/model)
    func migrateFromCodexIfNeeded(codex: CodexConfigService = CodexConfigService()) async {
        var reg = load()
        if reg.migration?.importedFromCodexConfigAt != nil { return }
        // If registry already has providers, skip migration
        if !reg.providers.isEmpty { return }

        // Pull from Codex config.toml
        let list = await codex.listProviders()
        let active = await codex.activeProvider()
        let model = await codex.getTopLevelString("model")
        var providers: [Provider] = []
        for p in list {
            var connectors: [String: Connector] = [:]
            let c = Connector(
                baseURL: p.baseURL,
                wireAPI: p.wireAPI,
                envKey: p.envKey,
                queryParams: nil,
                httpHeaders: nil,
                envHttpHeaders: nil,
                requestMaxRetries: p.requestMaxRetries,
                streamMaxRetries: p.streamMaxRetries,
                streamIdleTimeoutMs: p.streamIdleTimeoutMs,
                modelAliases: nil
            )
            connectors[Consumer.codex.rawValue] = c
            // leave claudeCode empty placeholder
            let np = Provider(
                id: p.id,
                name: p.name,
                class: "openai-compatible",
                managedByCodMate: p.managedByCodMate,
                connectors: connectors,
                catalog: nil,
                recommended: nil
            )
            providers.append(np)
        }
        reg.providers = providers
        var ap = reg.bindings.activeProvider ?? [:]
        ap[Consumer.codex.rawValue] = active
        reg.bindings.activeProvider = ap
        var dm = reg.bindings.defaultModel ?? [:]
        if let model { dm[Consumer.codex.rawValue] = model }
        reg.bindings.defaultModel = dm
        reg.migration = .init(importedFromCodexConfigAt: Date())
        try? save(reg)
    }
}
