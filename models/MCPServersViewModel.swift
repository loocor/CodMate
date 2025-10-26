import Foundation
import SwiftUI

@available(macOS 15.0, *)
@MainActor
final class MCPServersViewModel: ObservableObject {
    enum Tab: Hashable { case importWizard, servers, advanced }

    // UI state
    @Published var activeTab: Tab = .importWizard
    @Published var importText: String = ""
    @Published var importError: String? = nil
    @Published var isParsing: Bool = false
    @Published var drafts: [MCPServerDraft] = []

    @Published var servers: [MCPServer] = []
    @Published var errorMessage: String? = nil

    private let store = MCPServersStore()

    func loadText(_ text: String) {
        importText = text
        parseImportText()
    }

    func clearImport() {
        importText = ""
        drafts = []
        importError = nil
        isParsing = false
    }

    func loadServers() async {
        let list = await store.list()
        self.servers = list
    }

    func parseImportText() {
        let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importError = nil
            drafts = []
            isParsing = false
            return
        }
        isParsing = true
        importError = nil
        Task.detached {
            do {
                let ds = try UniImportMCPNormalizer.parseText(trimmed)
                await MainActor.run {
                    self.drafts = ds
                    self.importError = ds.isEmpty ? "No servers detected" : nil
                }
            } catch {
                await MainActor.run {
                    self.drafts = []
                    self.importError = (error as? LocalizedError)?.errorDescription ?? "Failed to parse input"
                }
            }
            await MainActor.run { self.isParsing = false }
        }
    }

    func importDrafts() async {
        guard !drafts.isEmpty else { return }
        do {
            var incoming: [MCPServer] = []
            for d in drafts {
                let name = d.name ?? "imported-server"
                let srv = MCPServer(
                    name: name,
                    kind: d.kind,
                    command: d.command,
                    args: d.args,
                    env: d.env,
                    url: d.url,
                    headers: d.headers,
                    meta: d.meta,
                    enabled: true,
                    capabilities: []
                )
                incoming.append(srv)
            }
            try await store.upsertMany(incoming)
            await loadServers()
            // Reset import UI
            drafts = []
            importText = ""
            importError = nil
            activeTab = .servers
        } catch {
            errorMessage = "Failed to save servers: \(error.localizedDescription)"
        }
    }

    func setServerEnabled(_ server: MCPServer, _ enabled: Bool) async {
        do { try await store.setEnabled(name: server.name, enabled: enabled); await loadServers() } catch {
            errorMessage = "Failed to update: \(error.localizedDescription)"
        }
    }

    func setCapabilityEnabled(_ server: MCPServer, _ cap: MCPCapability, _ enabled: Bool) async {
        do { try await store.setCapabilityEnabled(name: server.name, capability: cap.name, enabled: enabled); await loadServers() } catch {
            errorMessage = "Failed to update: \(error.localizedDescription)"
        }
    }

    // Stub for capability discovery via MCP Swift SDK (to be integrated)
    func refreshCapabilities(for server: MCPServer) async {
        // TODO: Integrate MCP Swift SDK handshake and tools discovery
        // For MVP, keep existing capabilities untouched.
        await loadServers()
    }
}
