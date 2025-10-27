import Foundation
import SwiftUI

@MainActor
final class ClaudeCodeVM: ObservableObject {
    @Published var providers: [ProvidersRegistryService.Provider] = []
    @Published var activeProviderId: String?
    @Published var aliasDefault: String = ""
    @Published var aliasHaiku: String = ""
    @Published var aliasSonnet: String = ""
    @Published var aliasOpus: String = ""
    @Published var lastError: String?

    private let registry = ProvidersRegistryService()

    func loadAll() async {
        let providerList = await registry.listProviders()
        let bindings = await registry.getBindings()
        await MainActor.run {
            self.providers = providerList
            self.activeProviderId = bindings.activeProvider?[ProvidersRegistryService.Consumer.claudeCode.rawValue]
            self.syncAliases()
        }
    }

    func availableModels() -> [String] {
        guard let id = activeProviderId,
              let provider = providers.first(where: { $0.id == id })
        else { return [] }
        return (provider.catalog?.models ?? []).map { $0.vendorModelId }
    }

    func applyActiveProvider() async {
        do {
            try await registry.setActiveProvider(.claudeCode, providerId: activeProviderId)
            await MainActor.run { self.lastError = nil }
        } catch {
            await MainActor.run { self.lastError = "Failed to set active provider" }
        }
        await MainActor.run { self.syncAliases() }
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
}
