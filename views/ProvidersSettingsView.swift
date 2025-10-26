import SwiftUI

@available(macOS 15.0, *)
struct ProvidersSettingsView: View {
    @StateObject private var vm = ProvidersVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                providersList
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360, maxHeight: .infinity)
                Divider()
                rightPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .sheet(isPresented: $vm.showEditor) { ProviderEditorSheet(vm: vm) }
        .task { await vm.loadAll() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Providers")
                    .font(.title2).fontWeight(.bold)
                Text("Manage global providers and Codex/Claude bindings")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { Task { await vm.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .buttonStyle(.borderless)
        }
    }

    private var providersList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All Providers").font(.headline)
                Spacer()
                Menu {
                    Button("K2") { vm.addPreset(.k2) }
                    Button("GLM") { vm.addPreset(.glm) }
                    Button("DeepSeek") { vm.addPreset(.deepseek) }
                    Divider()
                    Button("Other…") { vm.addOther() }
                } label: { Label("Add", systemImage: "plus") }
            }
            List(selection: $vm.selectedId) {
                ForEach(vm.providers, id: \.id) { p in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: vm.activeCodexProviderId == p.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name?.isEmpty == false ? p.name! : p.id)
                                .font(.body.weight(.medium))
                            endpointRow(label: "Codex", value: p.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL)
                            endpointRow(label: "Claude", value: p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL)
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(p.id as String?)
                    .contextMenu {
                        Button("Edit…") { vm.showEditor = true; vm.selectedId = p.id }
                        Button("Test") { Task { await vm.testConnectivity() } }
                        Divider()
                        Button(role: .destructive) { Task { await vm.delete(id: p.id) } } label: { Text("Delete") }
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, 18)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func endpointRow(label: String, value: String?) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text((value?.isEmpty == false) ? value! : "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Edit…") { vm.showEditor = true }
                    .disabled(vm.selectedId == nil)
                Button("Test") { Task { await vm.testConnectivity() } }
                    .disabled(vm.selectedId == nil)
                Spacer()
            }
            GroupBox("Details") {
                if let p = vm.editingProviderBinding() {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Codex base").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(p.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL ?? "")
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        HStack {
                            Text("Claude base").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL ?? "")
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        if let last = vm.testResultText {
                            Divider()
                            Text(last).font(.caption)
                        }
                    }
                    .padding(6)
                } else {
                    Text("Select a provider to view details").foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    // old tab panes removed to keep Providers view pure. Editing happens in a sheet.

    private var bindingsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Codex") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("Active Provider").font(.subheadline).fontWeight(.medium)
                            Picker("", selection: $vm.activeCodexProviderId) {
                                Text("(Built‑in)").tag(String?.none)
                                ForEach(vm.providers, id: \.id) { p in
                                    Text(p.name?.isEmpty == false ? p.name! : p.id).tag(String?(p.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .onChange(of: vm.activeCodexProviderId) { _, newVal in
                                Task { await vm.applyActiveCodexProvider(newVal) }
                            }
                        }
                        GridRow {
                            Text("Default Model").font(.subheadline).fontWeight(.medium)
                            HStack(spacing: 8) {
                                TextField("gpt-5-codex", text: $vm.defaultCodexModel)
                                    .onSubmit { Task { await vm.applyDefaultCodexModel() } }
                                let ids = vm.catalogModelIdsForActiveCodex()
                                if !ids.isEmpty {
                                    Menu {
                                        ForEach(ids, id: \.self) { mid in
                                            Button(mid) { vm.defaultCodexModel = mid; Task { await vm.applyDefaultCodexModel() } }
                                        }
                                    } label: {
                                        Label("From Catalog", systemImage: "chevron.down")
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                GroupBox("Claude Code") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("Active Provider").font(.subheadline).fontWeight(.medium)
                            Picker("", selection: $vm.activeClaudeProviderId) {
                                Text("(None)").tag(String?.none)
                                ForEach(vm.providers, id: \.id) { p in
                                    Text(p.name?.isEmpty == false ? p.name! : p.id).tag(String?(p.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .onChange(of: vm.activeClaudeProviderId) { _, newVal in
                                Task { await vm.applyActiveClaudeProvider(newVal) }
                            }
                        }
                    }
                }
                Text(vm.lastError ?? "").foregroundStyle(.red)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

}

// MARK: - Editor Sheet (Standard vs Advanced)
@available(macOS 15.0, *)
private struct ProviderEditorSheet: View {
    @ObservedObject var vm: ProvidersVM
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: EditorTab = .basic

    private enum EditorTab { case basic, advanced }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Edit Provider").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            TabView(selection: $selectedTab) {
                basicTab
                    .tabItem { Label("Basic", systemImage: "slider.horizontal.3") }
                    .tag(EditorTab.basic)
                advancedTab
                    .tabItem { Label("Advanced", systemImage: "gearshape") }
                    .tag(EditorTab.advanced)
            }
            .frame(minHeight: 260)
            if let result = vm.testResultText, !result.isEmpty {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = vm.lastError, !error.isEmpty {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Test & Save") {
                    Task {
                        if await vm.testAndSave() {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canSave)
            }
        }
        .padding(16)
        .frame(minWidth: 640)
        .onAppear { vm.loadModelRowsFromSelected() }
    }

    private var basicTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Connection") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Name").font(.subheadline).fontWeight(.medium)
                            Text("Display label shown in lists.").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("Provider name", text: vm.binding(for: \.providerName))
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex Base URL").font(.subheadline).fontWeight(.medium)
                            Text("OpenAI-compatible endpoint").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("https://api.example.com/v1", text: vm.binding(for: \.codexBaseURL))
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Claude Base URL").font(.subheadline).fontWeight(.medium)
                            Text("Anthropic-compatible endpoint").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("https://gateway.example.com/anthropic", text: vm.binding(for: \.claudeBaseURL))
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API Key Env").font(.subheadline).fontWeight(.medium)
                            Text("Environment variable used for both connectors").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("OPENAI_API_KEY", text: vm.binding(for: \.codexEnvKey))
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Wire API").font(.subheadline).fontWeight(.medium)
                            Text("responses | chat").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("chat", text: vm.binding(for: \.codexWireAPI))
                    }
                }
                .padding(8)
            }
        }
        .padding(.horizontal, 4)
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Model Aliases") {
                VStack(alignment: .leading, spacing: 8) {
                    aliasField(label: "default", text: vm.binding(for: \.aliasDefault), placeholder: "vendor model id")
                    aliasField(label: "haiku", text: vm.binding(for: \.aliasHaiku), placeholder: "vendor model id")
                    aliasField(label: "sonnet", text: vm.binding(for: \.aliasSonnet), placeholder: "vendor model id")
                    aliasField(label: "opus", text: vm.binding(for: \.aliasOpus), placeholder: "vendor model id")
                }
                .padding(8)
            }
            GroupBox("Models Directory") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Models").font(.subheadline).fontWeight(.medium)
                        Spacer()
                        Button { vm.addModelRow() } label: { Label("Add", systemImage: "plus") }
                            .buttonStyle(.borderless)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Model ID").font(.caption.weight(.medium))
                            Text("Reasoning").font(.caption.weight(.medium))
                            Text("Tool Use").font(.caption.weight(.medium))
                            Text("Vision").font(.caption.weight(.medium))
                            Text("Long Ctx").font(.caption.weight(.medium))
                            Spacer(minLength: 0)
                        }
                        ForEach($vm.modelRows, id: \.id) { $row in
                            GridRow {
                                TextField("vendor model id", text: $row.modelId)
                                Toggle("", isOn: $row.reasoning).labelsHidden()
                                Toggle("", isOn: $row.toolUse).labelsHidden()
                                Toggle("", isOn: $row.vision).labelsHidden()
                                Toggle("", isOn: $row.longContext).labelsHidden()
                                HStack {
                                    Spacer(minLength: 0)
                                    Button(role: .destructive) { vm.deleteModelRow(rowKey: row.id) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .padding(.horizontal, 4)
    }
    
    @ViewBuilder
    private func aliasField(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(width: 60, alignment: .leading)
            TextField(placeholder, text: text)
        }
    }
}
// MARK: - ViewModel (Codex-first)
@available(macOS 15.0, *)
@MainActor
final class ProvidersVM: ObservableObject {
    enum Preset { case k2, glm, deepseek }

    @Published var providers: [ProvidersRegistryService.Provider] = []
    @Published var selectedId: String? = nil {
        didSet {
            guard selectedId != oldValue else { return }
            syncEditingFieldsFromSelected()
            loadModelRowsFromSelected()
            testResultText = nil
        }
    }

    // Connection fields
    @Published var providerName: String = ""
    @Published var codexBaseURL: String = ""
    @Published var codexEnvKey: String = "OPENAI_API_KEY"
    @Published var codexWireAPI: String = "responses"
    @Published var claudeBaseURL: String = ""
    @Published var canSave: Bool = false

    @Published var aliasDefault: String = ""
    @Published var aliasHaiku: String = ""
    @Published var aliasSonnet: String = ""
    @Published var aliasOpus: String = ""

    @Published var activeCodexProviderId: String? = nil
    @Published var defaultCodexModel: String = ""
    @Published var activeClaudeProviderId: String? = nil

    @Published var lastError: String? = nil
    @Published var testResultText: String? = nil
    @Published var showEditor: Bool = false

    private let registry = ProvidersRegistryService()
    private let codex = CodexConfigService()

    func loadAll() async {
        await registry.migrateFromCodexIfNeeded(codex: codex)
        await reload()
    }

    func reload() async {
        let list = await registry.listProviders()
        providers = list
        let bindings = await registry.getBindings()
        activeCodexProviderId = bindings.activeProvider?[ProvidersRegistryService.Consumer.codex.rawValue]
        defaultCodexModel = bindings.defaultModel?[ProvidersRegistryService.Consumer.codex.rawValue] ?? ""
        activeClaudeProviderId = bindings.activeProvider?[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        if selectedId == nil { selectedId = providers.first?.id }
        syncEditingFieldsFromSelected()
        loadModelRowsFromSelected()
    }

    private func syncEditingFieldsFromSelected() {
        guard let sel = selectedId, let provider = providers.first(where: { $0.id == sel }) else {
            providerName = ""
            codexBaseURL = ""
            codexEnvKey = "OPENAI_API_KEY"
            codexWireAPI = "responses"
            claudeBaseURL = ""
            aliasDefault = ""
            aliasHaiku = ""
            aliasSonnet = ""
            aliasOpus = ""
            recomputeCanSave()
            return
        }
        providerName = provider.name ?? ""
        let codexConnector = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]
        let claudeConnector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        codexBaseURL = codexConnector?.baseURL ?? ""
        codexEnvKey = codexConnector?.envKey ?? claudeConnector?.envKey ?? "OPENAI_API_KEY"
        codexWireAPI = codexConnector?.wireAPI ?? "responses"
        claudeBaseURL = claudeConnector?.baseURL ?? ""
        let aliases = claudeConnector?.modelAliases ?? [:]
        aliasDefault = aliases["default"] ?? ""
        aliasHaiku = aliases["haiku"] ?? ""
        aliasSonnet = aliases["sonnet"] ?? ""
        aliasOpus = aliases["opus"] ?? ""
        recomputeCanSave()
    }

    func editingProviderBinding() -> ProvidersRegistryService.Provider? {
        guard let sel = selectedId else { return nil }
        return providers.first(where: { $0.id == sel })
    }

    // MARK: - Models directory editing
    struct ModelRow: Identifiable, Hashable {
        var key: UUID = UUID()
        var id: UUID { key }
        var modelId: String
        var reasoning: Bool
        var toolUse: Bool
        var vision: Bool
        var longContext: Bool
    }
    @Published var modelRows: [ModelRow] = []

    func loadModelRowsFromSelected() {
        guard let sel = selectedId, let p = providers.first(where: { $0.id == sel }) else {
            modelRows = []
            return
        }
        let rows: [ModelRow] = (p.catalog?.models ?? []).map { me in
            let c = me.caps
            return ModelRow(
                modelId: me.vendorModelId,
                reasoning: c?.reasoning ?? false,
                toolUse: c?.tool_use ?? false,
                vision: c?.vision ?? false,
                longContext: c?.long_context ?? false
            )
        }
        modelRows = rows
    }

    func addModelRow() { modelRows.append(.init(modelId: "", reasoning: false, toolUse: false, vision: false, longContext: false)) }
    func deleteModelRow(rowKey: UUID) { modelRows.removeAll { $0.id == rowKey } }

    func binding(for keyPath: ReferenceWritableKeyPath<ProvidersVM, String>) -> Binding<String> {
        Binding<String>(get: { self[keyPath: keyPath] }, set: { newVal in
            self[keyPath: keyPath] = newVal
            self.recomputeCanSave()
            self.testResultText = nil
        })
    }

    private func recomputeCanSave() {
        let codex = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let claude = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let env = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        canSave = !env.isEmpty && (!codex.isEmpty || !claude.isEmpty)
    }

    @discardableResult
    func saveEditing() async -> Bool {
        lastError = nil
        guard let sel = selectedId else { lastError = "No provider selected"; return false }
        guard var p = providers.first(where: { $0.id == sel }) else { lastError = "Missing provider"; return false }
        let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        p.name = trimmedName.isEmpty ? nil : trimmedName
        var conn = p.connectors[ProvidersRegistryService.Consumer.codex.rawValue] ?? .init(baseURL: nil, wireAPI: nil, envKey: nil, queryParams: nil, httpHeaders: nil, envHttpHeaders: nil, requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil)
        let trimmedCodexBase = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnv = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWire = codexWireAPI.trimmingCharacters(in: .whitespacesAndNewlines)
        conn.baseURL = trimmedCodexBase.isEmpty ? nil : trimmedCodexBase
        conn.envKey = trimmedEnv.isEmpty ? nil : trimmedEnv
        conn.wireAPI = trimmedWire.isEmpty ? nil : trimmedWire
        p.connectors[ProvidersRegistryService.Consumer.codex.rawValue] = conn
        var cconn = p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] ?? .init(baseURL: nil, wireAPI: nil, envKey: nil, queryParams: nil, httpHeaders: nil, envHttpHeaders: nil, requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil)
        let trimmedClaudeBase = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        cconn.baseURL = trimmedClaudeBase.isEmpty ? nil : trimmedClaudeBase
        cconn.envKey = trimmedEnv.isEmpty ? nil : trimmedEnv
        var a: [String:String] = [:]
        let d = aliasDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = aliasHaiku.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = aliasSonnet.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = aliasOpus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { a["default"] = d }
        if !h.isEmpty { a["haiku"] = h }
        if !s.isEmpty { a["sonnet"] = s }
        if !o.isEmpty { a["opus"] = o }
        cconn.modelAliases = a.isEmpty ? nil : a
        p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = cconn
        let cleanedModels: [ProvidersRegistryService.ModelEntry] = modelRows.compactMap { r in
            let trimmed = r.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let caps = ProvidersRegistryService.ModelCaps(
                reasoning: r.reasoning, tool_use: r.toolUse, vision: r.vision, long_context: r.longContext,
                code_tuned: nil, tps_hint: nil, max_output_tokens: nil
            )
            return ProvidersRegistryService.ModelEntry(vendorModelId: trimmed, caps: caps, aliases: nil)
        }
        p.catalog = cleanedModels.isEmpty ? nil : ProvidersRegistryService.Catalog(models: cleanedModels)
        do {
            try await registry.upsertProvider(p)
            await upsertCodexProviderBlock(from: p)
            await reload()
            return true
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func testAndSave() async -> Bool {
        lastError = nil
        testResultText = nil
        let codexURL = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeURL = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !codexURL.isEmpty || !claudeURL.isEmpty else {
            lastError = "Provide at least one endpoint URL"
            return false
        }
        var lines: [String] = []
        var passed = true
        if !codexURL.isEmpty {
            let (line, ok) = await evaluateEndpoint(label: "Codex", urlString: codexURL)
            lines.append(line)
            passed = passed && ok
        }
        if !claudeURL.isEmpty {
            let (line, ok) = await evaluateEndpoint(label: "Claude", urlString: claudeURL)
            lines.append(line)
            passed = passed && ok
        }
        testResultText = lines.isEmpty ? "No URLs to test" : lines.joined(separator: "\n")
        guard passed else {
            lastError = "Connectivity check failed"
            return false
        }
        return await saveEditing()
    }

    // Catalog helpers
    func catalogModelIdsForActiveCodex() -> [String] {
        let ap = activeCodexProviderId
        guard let id = ap, let p = providers.first(where: { $0.id == id }) else { return [] }
        return (p.catalog?.models ?? []).map { $0.vendorModelId }
    }

    func setActiveCodexProvider(_ id: String?) async {
        do { try await registry.setActiveProvider(.codex, providerId: id) } catch {
            lastError = "Failed to set active: \(error.localizedDescription)"
        }
        await reload()
    }

    func applyActiveCodexProvider(_ id: String?) async {
        do {
            try await registry.setActiveProvider(.codex, providerId: id)
            try await codex.setActiveProvider(id)
        } catch {
            lastError = "Failed to apply active provider to Codex"
        }
        await reload()
    }

    func applyActiveClaudeProvider(_ id: String?) async {
        do {
            try await registry.setActiveProvider(.claudeCode, providerId: id)
        } catch {
            lastError = "Failed to apply active provider to Claude Code"
        }
        await reload()
    }

    func applyDefaultCodexModel() async {
        do {
            try await registry.setDefaultModel(.codex, modelId: defaultCodexModel.isEmpty ? nil : defaultCodexModel)
            try await codex.setTopLevelString("model", value: defaultCodexModel.isEmpty ? nil : defaultCodexModel)
        } catch { lastError = "Failed to apply default model to Codex" }
        await reload()
    }

    func delete(id: String) async {
        do { try await registry.deleteProvider(id: id) } catch {
            lastError = "Delete failed: \(error.localizedDescription)"
        }
        await reload()
    }

    func addOther() { addPresetInternal(name: nil, base: nil, envKey: "OPENAI_API_KEY") }

    func addPreset(_ preset: Preset) {
        switch preset {
        case .k2: addPresetInternal(name: "K2", base: "https://api.moonshot.cn/v1", envKey: "K2_API_KEY")
        case .glm: addPresetInternal(name: "GLM", base: "https://open.bigmodel.cn/api/paas/v4/", envKey: "ZHIPUAI_API_KEY")
        case .deepseek: addPresetInternal(name: "DeepSeek", base: "https://api.deepseek.com/v1", envKey: "DEEPSEEK_API_KEY")
        }
    }

    private func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        let mapped = lower.map { (c: Character) -> Character in (c.isLetter || c.isNumber) ? c : "-" }
        var out: [Character] = []
        var lastDash = false
        for ch in mapped {
            if ch == "-" { if !lastDash { out.append(ch); lastDash = true } }
            else { out.append(ch); lastDash = false }
        }
        while out.first == "-" { out.removeFirst() }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "provider" : String(out)
    }

    private func addPresetInternal(name: String?, base: String?, envKey: String) {
        Task {
            let list = await registry.listProviders()
            var idBase = name ?? base ?? "provider"
            let baseSlug = slugify(idBase)
            var candidate = baseSlug
            var n = 2
            while list.contains(where: { $0.id == candidate }) { candidate = "\(baseSlug)-\(n)"; n += 1 }
            var connectors: [String: ProvidersRegistryService.Connector] = [:]
            connectors[ProvidersRegistryService.Consumer.codex.rawValue] = .init(
                baseURL: base, wireAPI: "responses", envKey: envKey,
                queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil
            )
            // Pre-create a Claude Code connector placeholder to simplify configuration later
            connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = .init(
                baseURL: nil, wireAPI: nil, envKey: envKey,
                queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil
            )
            let provider = ProvidersRegistryService.Provider(
                id: candidate, name: name, class: "openai-compatible", managedByCodMate: true,
                connectors: connectors, catalog: nil, recommended: nil
            )
            do {
                try await registry.upsertProvider(provider)
                await upsertCodexProviderBlock(from: provider)
                await reload()
                await MainActor.run { self.selectedId = candidate }
            } catch { await MainActor.run { self.lastError = "Add failed: \(error.localizedDescription)" } }
        }
    }

    private func upsertCodexProviderBlock(from provider: ProvidersRegistryService.Provider) async {
        guard let conn = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue] else { return }
        let cp = CodexProvider(
            id: provider.id,
            name: provider.name,
            baseURL: conn.baseURL,
            envKey: conn.envKey,
            wireAPI: conn.wireAPI,
            queryParamsRaw: nil,
            httpHeadersRaw: nil,
            envHttpHeadersRaw: nil,
            requestMaxRetries: conn.requestMaxRetries,
            streamMaxRetries: conn.streamMaxRetries,
            streamIdleTimeoutMs: conn.streamIdleTimeoutMs,
            managedByCodMate: true
        )
        do { try await codex.upsertProvider(cp) } catch { await MainActor.run { self.lastError = "Failed to sync provider to Codex config" } }
    }

    // MARK: - Connectivity test (basic reachability; 200/401/403 treated as reachable)
    func testConnectivity() async {
        testResultText = nil
        guard let sel = selectedId, let p = providers.first(where: { $0.id == sel }) else { return }
        let codexURL = (p.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeURL = (p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if !codexURL.isEmpty {
            let (line, _) = await evaluateEndpoint(label: "Codex", urlString: codexURL)
            lines.append(line)
        }
        if !claudeURL.isEmpty {
            let (line, _) = await evaluateEndpoint(label: "Claude", urlString: claudeURL)
            lines.append(line)
        }
        testResultText = lines.isEmpty ? "No URLs to test" : lines.joined(separator: "\n")
    }

    private func evaluateEndpoint(label: String, urlString: String) async -> (String, Bool) {
        guard let url = URL(string: urlString) else { return ("\(label): invalid URL", false) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let ok = (200...299).contains(code) || code == 401 || code == 403
            return ("\(label): HTTP \(code) \(ok ? "(reachable)" : "(unexpected)")", ok)
        } catch {
            return ("\(label): \(error.localizedDescription)", false)
        }
    }
}
