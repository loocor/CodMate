import Foundation
import SwiftUI

@MainActor
final class CodexVM: ObservableObject {
    enum ReasoningEffort: String, CaseIterable, Identifiable {
        case minimal, low, medium, high
        var id: String { rawValue }
    }
    enum ReasoningSummary: String, CaseIterable, Identifiable {
        case auto, concise, detailed, none
        var id: String { rawValue }
    }
    enum ModelVerbosity: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
    }
    enum OtelKind: String, Identifiable {
        case http, grpc
        var id: String { rawValue }
    }

    // Providers
    @Published var providers: [CodexProvider] = []
    @Published var activeProviderId: String?
    @Published var showProviderEditor = false
    @Published var providerDraft: CodexProvider = .init(
        id: "", name: nil, baseURL: nil, envKey: nil, wireAPI: nil, queryParamsRaw: nil,
        httpHeadersRaw: nil, envHttpHeadersRaw: nil, requestMaxRetries: nil, streamMaxRetries: nil,
        streamIdleTimeoutMs: nil, managedByCodMate: true)
    private var editingExistingId: String? = nil
    var editingKindIsNew: Bool { editingExistingId == nil }
    @Published var showDeleteAlert: Bool = false
    @Published var deleteTargetId: String? = nil

    // Runtime
    @Published var model: String = ""
    @Published var reasoningEffort: ReasoningEffort = .medium
    @Published var reasoningSummary: ReasoningSummary = .auto
    @Published var modelVerbosity: ModelVerbosity = .medium
    @Published var sandboxMode: SandboxMode = .workspaceWrite
    @Published var approvalPolicy: ApprovalPolicy = .onRequest
    @Published var runtimeDirty = false

    // Notifications
    @Published var tuiNotifications: Bool = false
    @Published var systemNotifications: Bool = false
    @Published var notifyBridgePath: String?
    @Published var rawConfigText: String = ""

    // Privacy
    @Published var envInherit: String = "all"
    @Published var envIgnoreDefaults: Bool = false
    @Published var envIncludeOnly: String = ""
    @Published var envExclude: String = ""
    @Published var envSetPairs: String = ""
    @Published var hideAgentReasoning: Bool = false
    @Published var showRawAgentReasoning: Bool = false
    @Published var fileOpener: String = "vscode"
    // OTEL
    @Published var otelEnabled: Bool = false
    @Published var otelKind: OtelKind = .http
    @Published var otelEndpoint: String = ""

    @Published var lastError: String?

    private let service = CodexConfigService()
    // Preset helper
    enum ProviderPreset { case k2, glm, deepseek }
    @Published var providerKeyApplyURL: String? = nil

    func loadAll() async {
        await loadProviders()
        await loadRuntime()
        await loadNotifications()
        await loadPrivacy()
        await reloadRawConfig()
    }

    func loadProviders() async {
        providers = await service.listProviders()
        activeProviderId = await service.activeProvider()
    }

    func presentAddProvider() {
        editingExistingId = nil
        providerDraft = .init(
            id: "", name: nil, baseURL: nil, envKey: nil, wireAPI: nil, queryParamsRaw: nil,
            httpHeadersRaw: nil, envHttpHeadersRaw: nil, requestMaxRetries: nil,
            streamMaxRetries: nil, streamIdleTimeoutMs: nil, managedByCodMate: true)
        providerKeyApplyURL = nil
        showProviderEditor = true
    }

    func presentAddProviderPreset(_ preset: ProviderPreset) {
        editingExistingId = nil
        switch preset {
        case .k2:
            providerDraft = .init(
                id: "", name: "K2", baseURL: "https://api.moonshot.cn/v1", envKey: nil,
                wireAPI: "responses", queryParamsRaw: nil, httpHeadersRaw: nil,
                envHttpHeadersRaw: nil,
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
                managedByCodMate: true)
            providerKeyApplyURL = "https://platform.moonshot.cn/console/api-keys"
        case .glm:
            providerDraft = .init(
                id: "", name: "GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4/", envKey: nil,
                wireAPI: "responses", queryParamsRaw: nil, httpHeadersRaw: nil,
                envHttpHeadersRaw: nil,
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
                managedByCodMate: true)
            providerKeyApplyURL = "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"
        case .deepseek:
            providerDraft = .init(
                id: "", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", envKey: nil,
                wireAPI: "responses", queryParamsRaw: nil, httpHeadersRaw: nil,
                envHttpHeadersRaw: nil,
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
                managedByCodMate: true)
            providerKeyApplyURL = "https://platform.deepseek.com/api_keys"
        }
        showProviderEditor = true
    }

    func presentEditProvider(_ p: CodexProvider) {
        editingExistingId = p.id
        providerDraft = p
        switch p.id.lowercased() {
        case "k2": providerKeyApplyURL = "https://platform.moonshot.cn/console/api-keys"
        case "glm": providerKeyApplyURL = "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"
        case "deepseek": providerKeyApplyURL = "https://platform.deepseek.com/api_keys"
        default: providerKeyApplyURL = nil
        }
        showProviderEditor = true
    }

    func dismissEditor() { showProviderEditor = false }

    func saveProviderDraft() async {
        lastError = nil
        do {
            var provider = providerDraft
            // Trim and normalize
            func norm(_ s: String?) -> String? {
                let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return t.isEmpty ? nil : t
            }
            provider.name = norm(provider.name)
            provider.baseURL = norm(provider.baseURL)
            provider.envKey = norm(provider.envKey)
            // wire_api must be one of: responses, chat. If empty → nil; if invalid → keep as-is (user intent), but presets default to responses.
            if let w = norm(provider.wireAPI) {
                let lw = w.lowercased()
                provider.wireAPI = (lw == "responses" || lw == "chat") ? lw : w
            } else {
                provider.wireAPI = nil
            }
            provider.queryParamsRaw = norm(provider.queryParamsRaw)
            provider.httpHeadersRaw = norm(provider.httpHeadersRaw)
            provider.envHttpHeadersRaw = norm(provider.envHttpHeadersRaw)

            // Basic validation: require at least a base URL or name
            if provider.baseURL == nil && provider.name == nil {
                lastError = "Please enter at least a Name or Base URL."
                return
            }

            if editingKindIsNew {
                // Determine id: prefer existing non-empty id, otherwise slugify name/base
                let proposed = norm(provider.id) ?? provider.name ?? provider.baseURL ?? "provider"
                let baseSlug = Self.slugify(proposed)
                var candidate = baseSlug.isEmpty ? "provider" : baseSlug
                var n = 2
                while providers.contains(where: { $0.id == candidate }) {
                    candidate = "\(baseSlug)-\(n)"
                    n += 1
                }
                provider.id = candidate
            } else {
                provider.id = editingExistingId ?? provider.id
            }
            try await service.upsertProvider(provider)
            showProviderEditor = false
            await loadProviders()
        } catch {
            lastError = "Failed to save provider: \(error.localizedDescription)"
        }
    }

    func deleteProvider(id: String) {
        Task { [weak self] in
            do {
                try await self?.service.deleteProvider(id: id)
                await self?.loadProviders()
            } catch {
                await MainActor.run {
                    self?.lastError = "Delete failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func requestDeleteProvider(id: String) {
        deleteTargetId = id
        showDeleteAlert = true
    }
    func cancelDelete() {
        showDeleteAlert = false
        deleteTargetId = nil
    }
    func confirmDelete() async {
        guard let id = deleteTargetId else { return }
        deleteProvider(id: id)
        await MainActor.run {
            self.showDeleteAlert = false
            self.deleteTargetId = nil
        }
    }

    func applyActiveProvider() async {
        do { try await service.setActiveProvider(activeProviderId) } catch {
            lastError = "Failed to set active provider"
        }
    }

    func deleteEditingProviderViaEditor() async {
        guard let id = editingExistingId else { return }
        do {
            try await service.deleteProvider(id: id)
            await loadProviders()
            await MainActor.run { self.showProviderEditor = false }
        } catch {
            await MainActor.run { self.lastError = "Delete failed: \(error.localizedDescription)" }
        }
    }

    // Runtime
    func loadRuntime() async {
        model = await service.getTopLevelString("model") ?? model
        if let e = await service.getTopLevelString("model_reasoning_effort"),
            let v = ReasoningEffort(rawValue: e)
        {
            reasoningEffort = v
        }
        if let s = await service.getTopLevelString("model_reasoning_summary"),
            let v = ReasoningSummary(rawValue: s)
        {
            reasoningSummary = v
        }
        if let v = await service.getTopLevelString("model_verbosity"),
            let mv = ModelVerbosity(rawValue: v)
        {
            modelVerbosity = mv
        }
        if let s = await service.getTopLevelString("sandbox_mode"),
            let sm = SandboxMode(rawValue: s)
        {
            sandboxMode = sm
        }
        if let a = await service.getTopLevelString("approval_policy"),
            let ap = ApprovalPolicy(rawValue: a)
        {
            approvalPolicy = ap
        }
    }

    func applyModel() async {
        do { try await service.setTopLevelString("model", value: model) } catch {
            lastError = "Save failed"
        }
    }
    func applyReasoning() async {
        do {
            try await service.setTopLevelString(
                "model_reasoning_effort", value: reasoningEffort.rawValue)
            try await service.setTopLevelString(
                "model_reasoning_summary", value: reasoningSummary.rawValue)
            try await service.setTopLevelString("model_verbosity", value: modelVerbosity.rawValue)
        } catch { lastError = "Save failed" }
    }
    func applySandbox() async {
        do { try await service.setSandboxMode(sandboxMode.rawValue) } catch {
            lastError = "Save failed"
        }
    }
    func applyApproval() async {
        do { try await service.setApprovalPolicy(approvalPolicy.rawValue) } catch {
            lastError = "Save failed"
        }
    }

    // Notifications
    func loadNotifications() async {
        tuiNotifications = await service.getTuiNotifications()
        let arr = await service.getNotifyArray()
        if let bridge = arr.first {
            systemNotifications = true
            notifyBridgePath = bridge
        } else {
            systemNotifications = false
            notifyBridgePath = nil
        }
    }
    func applyTuiNotifications() async {
        do { try await service.setTuiNotifications(tuiNotifications) } catch {
            lastError = "Failed to save TUI notifications"
        }
    }
    func applySystemNotifications() async {
        do {
            if systemNotifications {
                let url = try await service.ensureNotifyBridgeInstalled()
                notifyBridgePath = url.path
                try await service.setNotifyArray([url.path])
            } else {
                notifyBridgePath = nil
                try await service.setNotifyArray(nil)
            }
        } catch { lastError = "Failed to configure system notifications" }
    }

    // Privacy
    func loadPrivacy() async {
        _ = await service.sanitizeQuotedBooleans()
        let p = await service.getShellEnvironmentPolicy()
        envInherit = p.inherit ?? envInherit
        envIgnoreDefaults = p.ignoreDefaultExcludes ?? envIgnoreDefaults
        envIncludeOnly = (p.includeOnly ?? []).joined(separator: ", ")
        envExclude = (p.exclude ?? []).joined(separator: ", ")
        envSetPairs = (p.set ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(
            separator: "\n")
        hideAgentReasoning = await service.getBool("hide_agent_reasoning")
        showRawAgentReasoning = await service.getBool("show_raw_agent_reasoning")
        fileOpener = await service.getTopLevelString("file_opener") ?? fileOpener

        let oc = await service.getOtelConfig()
        otelEnabled = oc.exporterKind != .none
        otelKind = (oc.exporterKind == .otlpGrpc) ? .grpc : .http
        otelEndpoint = oc.endpoint ?? ""
    }

    func applyEnvPolicy() async {
        var dict: [String: String] = [:]
        for line in envSetPairs.split(separator: "\n") {
            let s = String(line)
            guard let eq = s.firstIndex(of: "=") else { continue }
            let k = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { dict[k] = v }
        }
        let policy = CodexConfigService.ShellEnvironmentPolicy(
            inherit: envInherit,
            ignoreDefaultExcludes: envIgnoreDefaults,
            includeOnly: tokens(envIncludeOnly),
            exclude: tokens(envExclude),
            set: dict.isEmpty ? nil : dict
        )
        do { try await service.setShellEnvironmentPolicy(policy) } catch {
            lastError = "Failed to save env policy"
        }
    }
    func applyHideReasoning() async {
        do { try await service.setBool("hide_agent_reasoning", hideAgentReasoning) } catch {
            lastError = "Failed"
        }
    }
    func applyShowRawReasoning() async {
        do { try await service.setBool("show_raw_agent_reasoning", showRawAgentReasoning) } catch {
            lastError = "Failed"
        }
    }
    func applyFileOpener() async {
        do { try await service.setFileOpener(fileOpener) } catch { lastError = "Failed" }
    }
    func applyOtel() async {
        let kind: CodexConfigService.OtelExporterKind =
            otelEnabled ? (otelKind == .grpc ? .otlpGrpc : .otlpHttp) : .none
        let cfg = CodexConfigService.OtelConfig(
            environment: nil, exporterKind: kind, endpoint: otelEndpoint)
        do { try await service.setOtelConfig(cfg) } catch { lastError = "Failed to save OTEL" }
    }

    private func tokens(_ s: String) -> [String]? {
        let arr = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty
        }
        return arr.isEmpty ? nil : arr
    }
    // Raw config helpers
    func reloadRawConfig() async { rawConfigText = await service.readRawConfigText() }
    func openConfigInEditor() {
        Task { @MainActor in
            let url = await service.configFileURL()
            NSWorkspace.shared.open(url)
        }
    }
    private static func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        let mapped = lower.map { c -> Character in
            if c.isLetter || c.isNumber { return c }
            return "-"
        }
        var collapsed: [Character] = []
        var lastDash = false
        for ch in mapped {
            if ch == "-" {
                if !lastDash {
                    collapsed.append(ch)
                    lastDash = true
                }
            } else {
                collapsed.append(ch)
                lastDash = false
            }
        }
        while collapsed.first == "-" { collapsed.removeFirst() }
        while collapsed.last == "-" { collapsed.removeLast() }
        let s2 = String(collapsed)
        return s2.isEmpty ? "provider" : s2
    }
}
