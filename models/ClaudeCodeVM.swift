import Foundation
import SwiftUI

@MainActor
final class ClaudeCodeVM: ObservableObject {
    let builtinModels: [String] = [
        "claude-3-5-sonnet-latest",
        "claude-3-haiku-latest",
        "claude-3-opus-latest",
    ]
    @Published var providers: [ProvidersRegistryService.Provider] = []
    @Published var activeProviderId: String?
    enum LoginMethod: String, CaseIterable, Identifiable { case api, subscription; var id: String { rawValue } }
    @Published var loginMethod: LoginMethod = .api
    @Published var aliasDefault: String = ""
    @Published var aliasHaiku: String = ""
    @Published var aliasSonnet: String = ""
    @Published var aliasOpus: String = ""
    @Published var lastError: String?

    private let registry = ProvidersRegistryService()
    private var saveDebounceTask: Task<Void, Never>? = nil
    private var applyProviderDebounceTask: Task<Void, Never>? = nil
    private var defaultAliasDebounceTask: Task<Void, Never>? = nil

    func loadAll() async {
        let providerList = await registry.listProviders()
        let bindings = await registry.getBindings()
        await MainActor.run {
            self.providers = providerList
            self.activeProviderId = bindings.activeProvider?[ProvidersRegistryService.Consumer.claudeCode.rawValue]
            self.syncAliases()
            self.syncLoginMethod()
        }
    }

    func availableModels() -> [String] {
        guard let id = activeProviderId,
              let provider = providers.first(where: { $0.id == id })
        else { return [] }
        return (provider.catalog?.models ?? []).map { $0.vendorModelId }
    }

    func applyDefaultAlias(_ modelId: String) async {
        guard let id = activeProviderId else {
            await MainActor.run { self.aliasDefault = modelId }
            return
        }
        let providerList = await registry.listProviders()
        guard var provider = providerList.first(where: { $0.id == id }) else { return }
        var connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] ?? .init(
            baseURL: nil,
            wireAPI: nil,
            envKey: "ANTHROPIC_AUTH_TOKEN",
            loginMethod: nil,
            queryParams: nil,
            httpHeaders: nil,
            envHttpHeaders: nil,
            requestMaxRetries: nil,
            streamMaxRetries: nil,
            streamIdleTimeoutMs: nil,
            modelAliases: nil)
        var aliases = connector.modelAliases ?? [:]
        aliases["default"] = modelId
        connector.modelAliases = aliases
        provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = connector
        do {
            try await registry.upsertProvider(provider)
            await MainActor.run { self.aliasDefault = modelId; self.lastError = nil }
        } catch { await MainActor.run { self.lastError = "Failed to set default model" } }
    }

    func tokenMissingForCurrentSelection() -> Bool {
        if loginMethod == .subscription { return false }
        let env = ProcessInfo.processInfo.environment
        if let id = activeProviderId,
           let provider = providers.first(where: { $0.id == id }) {
            let key = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
            let val = env[key]
            return (val == nil || val?.isEmpty == true)
        }
        let val = env["ANTHROPIC_AUTH_TOKEN"]
        return (val == nil || val?.isEmpty == true)
    }

    func applyActiveProvider() async {
        do {
            try await registry.setActiveProvider(.claudeCode, providerId: activeProviderId)
            await MainActor.run { self.lastError = nil }
        } catch {
            await MainActor.run { self.lastError = "Failed to set active provider" }
        }
        await MainActor.run {
            self.syncAliases()
            self.syncLoginMethod()
        }
    }

    func save() async {
        guard let id = activeProviderId else { return }
        let providerList = await registry.listProviders()
        guard var provider = providerList.first(where: { $0.id == id }) else { return }
        var connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] ?? .init(
            baseURL: nil,
            wireAPI: nil,
            envKey: "ANTHROPIC_AUTH_TOKEN",
            queryParams: nil,
            httpHeaders: nil,
            envHttpHeaders: nil,
            requestMaxRetries: nil,
            streamMaxRetries: nil,
            streamIdleTimeoutMs: nil,
            modelAliases: nil)

        var aliases: [String: String] = [:]
        func assign(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { aliases[key] = trimmed }
        }
        assign("default", aliasDefault)
        assign("haiku", aliasHaiku)
        assign("sonnet", aliasSonnet)
        assign("opus", aliasOpus)

        connector.modelAliases = aliases.isEmpty ? nil : aliases
        provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = connector

        do {
            try await registry.upsertProvider(provider)
            await MainActor.run { self.lastError = nil }
            await loadAll()
        } catch {
            await MainActor.run { self.lastError = "Failed to save aliases" }
        }
    }

    func scheduleSaveDebounced(delayMs: UInt64 = 300) {
        // Cancel any in-flight debounce task and schedule a new one
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            } catch { return }
            if Task.isCancelled { return }
            await self.save()
        }
    }

    private func syncAliases() {
        guard let id = activeProviderId,
              let provider = providers.first(where: { $0.id == id })
        else {
            aliasDefault = ""
            aliasHaiku = ""
            aliasSonnet = ""
            aliasOpus = ""
            return
        }
        let connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        let aliases = connector?.modelAliases ?? [:]
        let recommended = provider.recommended?.defaultModelFor?[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        aliasDefault = aliases["default"] ?? recommended ?? ""
        aliasHaiku = aliases["haiku"] ?? ""
        aliasSonnet = aliases["sonnet"] ?? ""
        aliasOpus = aliases["opus"] ?? ""
    }

    private func syncLoginMethod() {
        // Built-in (nil provider) defaults to subscription; third-party defaults to api
        guard let id = activeProviderId,
              let provider = providers.first(where: { $0.id == id }) else {
            loginMethod = .subscription
            return
        }
        let connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        if let lm = connector?.loginMethod, lm.lowercased() == "subscription" {
            loginMethod = .subscription
        } else {
            loginMethod = .api
        }
    }

    func setLoginMethod(_ method: LoginMethod) async {
        await MainActor.run { self.loginMethod = method }
        // Persist to registry for active provider (if any). Built-in (nil) has no connector; nothing to write.
        guard let id = activeProviderId else { return }
        let list = await registry.listProviders()
        guard var p = list.first(where: { $0.id == id }) else { return }
        var conn = p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] ?? .init(
            baseURL: nil, wireAPI: nil, envKey: nil, loginMethod: nil,
            queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
            requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
            modelAliases: nil)
        conn.loginMethod = method.rawValue
        // Restore default env key for API login if absent
        if method == .api && (conn.envKey == nil || conn.envKey?.isEmpty == true) {
            conn.envKey = "ANTHROPIC_AUTH_TOKEN"
        }
        if method == .subscription {
            // No need to store token env mapping; leave as-is but it will be ignored at launch.
        }
        p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = conn
        do { try await registry.upsertProvider(p) } catch { await MainActor.run { self.lastError = "Failed to save login method" } }
    }

    // MARK: - Debounced operations
    func scheduleApplyActiveProviderDebounced(delayMs: UInt64 = 300) {
        applyProviderDebounceTask?.cancel()
        applyProviderDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyActiveProvider()
        }
    }

    func scheduleApplyDefaultAliasDebounced(_ modelId: String, delayMs: UInt64 = 300) {
        defaultAliasDebounceTask?.cancel()
        defaultAliasDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyDefaultAlias(modelId)
        }
    }
}
