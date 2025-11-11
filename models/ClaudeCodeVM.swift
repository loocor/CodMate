import Foundation
import SwiftUI
import AppKit

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
    @Published var rawSettingsText: String = ""
    @Published var notificationsEnabled: Bool = false
    @Published var notificationBridgeHealthy: Bool = false
    @Published var notificationSelfTestResult: String? = nil

    private let registry = ProvidersRegistryService()
    private var saveDebounceTask: Task<Void, Never>? = nil
    private var applyProviderDebounceTask: Task<Void, Never>? = nil
    private var defaultAliasDebounceTask: Task<Void, Never>? = nil
    private var runtimeDebounceTask: Task<Void, Never>? = nil
    private var notificationDebounceTask: Task<Void, Never>? = nil

    func loadAll() async {
        let providerList = await registry.listProviders()
        let bindings = await registry.getBindings()
        await MainActor.run {
            self.providers = providerList
            self.activeProviderId = bindings.activeProvider?[ProvidersRegistryService.Consumer.claudeCode.rawValue]
            self.syncAliases()
            self.syncLoginMethod()
        }
        await loadNotificationSettings()
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
            // Persist to ~/.claude/settings.json → model only for third‑party providers
            if self.activeProviderId != nil {
                if SecurityScopedBookmarks.shared.isSandboxed {
                    let home = SessionPreferencesStore.getRealUserHomeURL()
                    _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess, message: "Authorize your Home folder to update Claude settings")
                }
                let settings = ClaudeSettingsService()
                try? await settings.setModel(modelId)
            }
        } catch { await MainActor.run { self.lastError = "Failed to set default model" } }
    }

    func tokenMissingForCurrentSelection() -> Bool {
        if loginMethod == .subscription { return false }
        let env = ProcessInfo.processInfo.environment
        if let id = activeProviderId,
           let provider = providers.first(where: { $0.id == id }) {
            let key = provider.envKey ?? provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
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
        // Decide persistence policy
        let isBuiltin = (activeProviderId == nil)
        // Built‑in provider → clear provider-specific keys (model/env base URL/forceLogin/token)
        if isBuiltin {
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
            }
            let settings = ClaudeSettingsService()
            try? await settings.setModel(nil)
            try? await settings.setEnvBaseURL(nil)
            try? await settings.setForceLoginMethod(nil)
            try? await settings.setEnvToken(nil)
            return
        }

        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
        }
        let settings = ClaudeSettingsService()
        // Base URL only for third‑party providers
        let base = isBuiltin ? nil : selectedClaudeBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await settings.setEnvBaseURL((base?.isEmpty == false) ? base : nil)
        // Force login only for API; remove for subscription
        if loginMethod == .api {
            try? await settings.setForceLoginMethod("console")
        } else {
            try? await settings.setForceLoginMethod(nil)
        }
        // Token only for API
        if loginMethod == .api {
            var token: String? = nil
            if let id = activeProviderId,
               let provider = providers.first(where: { $0.id == id }) {
                let conn = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
                let keyName = provider.envKey ?? conn?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
                let env = ProcessInfo.processInfo.environment
                if let val = env[keyName], !val.isEmpty {
                    token = val
                } else {
                    let looksLikeToken = keyName.lowercased().contains("sk-") || keyName.hasPrefix("eyJ") || keyName.contains(".")
                    if looksLikeToken { token = keyName }
                }
            }
            try? await settings.setEnvToken(token)
        } else {
            try? await settings.setEnvToken(nil)
        }
    }

    func save() async {
        guard let id = activeProviderId else { return }
        let providerList = await registry.listAllProviders()
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
            // Persist model only for third‑party providers
            if self.activeProviderId != nil {
                if SecurityScopedBookmarks.shared.isSandboxed {
                    let home = SessionPreferencesStore.getRealUserHomeURL()
                    _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
                }
                let settings = ClaudeSettingsService()
                let m = aliasDefault.trimmingCharacters(in: .whitespacesAndNewlines)
                try? await settings.setModel(m.isEmpty ? nil : m)
            }
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

    // MARK: - Runtime settings writer
    func scheduleApplyRuntimeSettings(_ preferences: SessionPreferencesStore, delayMs: UInt64 = 250) {
        runtimeDebounceTask?.cancel()
        runtimeDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyRuntimeSettings(preferences)
        }
    }

    func applyRuntimeSettings(_ preferences: SessionPreferencesStore) async {
        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
        }
        let settings = ClaudeSettingsService()
        let addDirs: [String]? = {
            let raw = preferences.claudeAddDirs.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return nil }
            return raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { String($0) }
        }()
        let runtime = ClaudeSettingsService.Runtime(
            permissionMode: preferences.claudePermissionMode.rawValue,
            skipPermissions: preferences.claudeSkipPermissions,
            allowSkipPermissions: preferences.claudeAllowSkipPermissions,
            debug: preferences.claudeDebug,
            debugFilter: preferences.claudeDebugFilter,
            verbose: preferences.claudeVerbose,
            ide: preferences.claudeIDE,
            strictMCP: preferences.claudeStrictMCP,
            fallbackModel: preferences.claudeFallbackModel,
            allowedTools: preferences.claudeAllowedTools,
            disallowedTools: preferences.claudeDisallowedTools,
            addDirs: addDirs
        )
        try? await settings.applyRuntime(runtime)
    }

    func loadNotificationSettings() async {
        let settings = ClaudeSettingsService()
        let status = await settings.codMateNotificationHooksStatus()
        await MainActor.run {
            let healthy = status.permissionHookInstalled && status.completionHookInstalled
            self.notificationsEnabled = healthy
            self.notificationBridgeHealthy = healthy
            if !healthy {
                self.notificationSelfTestResult = nil
            }
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
        // Restore default env key for API login if absent (prefer provider-level key)
        if method == .api && (p.envKey == nil || p.envKey?.isEmpty == true) {
            p.envKey = "ANTHROPIC_AUTH_TOKEN"
        }
        if method == .subscription {
            // No need to store token env mapping; leave as-is but it will be ignored at launch.
        }
        p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = conn
        do {
            try await registry.upsertProvider(p)
            // Persist to settings: only when API; subscription removes forced key and token
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
            }
            let settings = ClaudeSettingsService()
            if method == .api {
                try? await settings.setForceLoginMethod("console")
                var token: String? = nil
                let env = ProcessInfo.processInfo.environment
                let keyName = p.envKey ?? p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
                if let val = env[keyName], !val.isEmpty {
                    token = val
                } else {
                    let looksLikeToken = keyName.lowercased().contains("sk-") || keyName.hasPrefix("eyJ") || keyName.contains(".")
                    if looksLikeToken { token = keyName }
                }
                try? await settings.setEnvToken(token)
            } else {
                try? await settings.setForceLoginMethod(nil)
                try? await settings.setEnvToken(nil)
            }
        } catch {
            await MainActor.run { self.lastError = "Failed to save login method" }
        }
    }

    private func applyNotificationSettings() async {
        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
                directory: home,
                purpose: .generalAccess,
                message: "Authorize ~/.claude to update Claude notifications"
            )
        }
        let settings = ClaudeSettingsService()
        do {
            try await settings.setCodMateNotificationHooks(enabled: notificationsEnabled)
            await loadNotificationSettings()
        } catch {
            await MainActor.run { self.lastError = "Failed to update Claude notifications" }
        }
    }

    func runNotificationSelfTest() async {
        notificationSelfTestResult = nil
        var comps = URLComponents()
        comps.scheme = "codmate"
        comps.host = "notify"
        let title = "CodMate"
        let body = "Claude notifications self-test"
        var items = [
            URLQueryItem(name: "source", value: "claude"),
            URLQueryItem(name: "event", value: "test")
        ]
        if let titleData = title.data(using: .utf8) {
            items.append(URLQueryItem(name: "title64", value: titleData.base64EncodedString()))
        }
        if let bodyData = body.data(using: .utf8) {
            items.append(URLQueryItem(name: "body64", value: bodyData.base64EncodedString()))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            notificationSelfTestResult = "Invalid test URL"
            return
        }
        let success = NSWorkspace.shared.open(url)
        notificationSelfTestResult = success ? "Sent (check Notification Center)" : "Failed to open codmate:// URL"
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

    func scheduleApplyNotificationSettingsDebounced(delayMs: UInt64 = 250) {
        notificationDebounceTask?.cancel()
        notificationDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyNotificationSettings()
        }
    }

    // MARK: - Raw settings helpers
    func settingsFileURL() -> URL {
        SessionPreferencesStore.getRealUserHomeURL()
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func reloadRawSettings() async {
        let url = settingsFileURL()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        await MainActor.run { self.rawSettingsText = text }
    }

    func openSettingsInEditor() {
        Task { @MainActor in
            NSWorkspace.shared.open(self.settingsFileURL())
        }
    }
}
