import SwiftUI

@available(macOS 15.0, *)
struct ProvidersSettingsView: View {
    @StateObject private var vm = ProvidersVM()
    @State private var pendingDeleteId: String?
    @State private var pendingDeleteName: String?

    var body: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 20) {
                header
                providersList
            }
            .padding(.bottom, 16)
        }
        .sheet(isPresented: Binding(
            get: { vm.showEditor },
            set: { newValue in
                vm.showEditor = newValue
                if !newValue {
                    // Reset new provider state when sheet closes
                    vm.isNewProvider = false
                    vm.newProviderPreset = nil
                }
            }
        )) { ProviderEditorSheet(vm: vm) }
        .presentationSizing(.automatic)
        .task { await vm.loadAll() }
        .confirmationDialog(
            "Delete Provider",
            isPresented: Binding(
                get: { pendingDeleteId != nil },
                set: { if !$0 { pendingDeleteId = nil; pendingDeleteName = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId {
                    Task { await vm.delete(id: id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let name = pendingDeleteName {
                Text("Are you sure you want to delete \"\(name)\"? This action cannot be undone.")
            } else {
                Text("Are you sure you want to delete this provider? This action cannot be undone.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Providers")
                .font(.title2)
                .fontWeight(.bold)
            Text("Manage global providers and Codex/Claude bindings")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var providersList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !vm.providers.isEmpty {
                HStack {
                    Spacer()
                    Menu {
                        Button("K2") { vm.addPreset(.k2) }
                        Button("GLM") { vm.addPreset(.glm) }
                        Button("DeepSeek") { vm.addPreset(.deepseek) }
                        Divider()
                        Button("Other…") { vm.startNewProvider() }
                    } label: { Label("Add", systemImage: "plus") }
                }
            }

            if vm.providers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Providers")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Add a provider to get started")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Menu {
                        Button(action: { vm.addPreset(.k2) }) {
                            Label("K2", systemImage: "server.rack")
                        }
                        Button(action: { vm.addPreset(.glm) }) {
                            Label("GLM", systemImage: "server.rack")
                        }
                        Button(action: { vm.addPreset(.deepseek) }) {
                            Label("DeepSeek", systemImage: "server.rack")
                        }
                        Divider()
                        Button(action: { vm.startNewProvider() }) {
                            Label("Custom Provider…", systemImage: "plus.circle")
                        }
                    } label: {
                        Label("Add Provider", systemImage: "plus")
                            .font(.body)
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 200)
                .padding(.horizontal, -8)
            } else {
                List(selection: $vm.selectedId) {
                    ForEach(vm.providers, id: \.id) { p in
                        HStack(alignment: .center, spacing: 0) {

                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: vm.activeCodexProviderId == p.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                                Text(p.name?.isEmpty == false ? p.name! : p.id)
                                    .font(.body.weight(.medium))
                            }
                            .frame(minWidth: 120, alignment: .leading)

                            Spacer(minLength: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                endpointBlock(
                                    label: "Codex",
                                    value: p.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL
                                )
                                endpointBlock(
                                    label: "Claude",
                                    value: p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                vm.selectedId = p.id
                                vm.showEditor = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.body)
                            }
                            .buttonStyle(.borderless)
                            .help("Edit provider")
                        }
                        .padding(.vertical, 4)
                        .tag(p.id as String?)
                        .contextMenu {
                            Button("Edit…") { vm.showEditor = true; vm.selectedId = p.id }
                            Divider()
                            Button(role: .destructive) {
                                pendingDeleteId = p.id
                                pendingDeleteName = p.name?.isEmpty == false ? p.name : p.id
                            } label: { Text("Delete") }
                        }
                    }
                }
                .frame(minHeight: 200)
                .padding(.horizontal, -8)
            }
        }
    }

    @ViewBuilder
    private func endpointBlock(label: String, value: String?) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text((value?.isEmpty == false) ? value! : "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }


    // MARK: - Helper Views

    private func settingsScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 24)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(10)
        .background(Color(nsColor: .separatorColor).opacity(0.35))
        .cornerRadius(10)
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

    private enum EditorTab { case basic, models }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(vm.isNewProvider ? "New Provider" : "Edit Provider").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            TabView(selection: $selectedTab) {
                basicTab
                    .tabItem { Label("Basic", systemImage: "slider.horizontal.3") }
                    .tag(EditorTab.basic)
                modelsTab
                    .tabItem { Label("Models", systemImage: "list.bullet.rectangle") }
                    .tag(EditorTab.models)
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
                Button("Test") {
                    Task { await vm.testEditingFields() }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        if await vm.saveEditing() {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canSave)
            }
        }
        .padding(16)
        .frame(
            minWidth: 640,
            idealWidth: 760,
            maxWidth: .infinity,
            minHeight: 360,
            idealHeight: 420,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .onAppear { vm.loadModelRowsFromSelected() }
    }

    private var basicTab: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        Text("Environment variable name")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("OPENAI_API_KEY", text: vm.binding(for: \.codexEnvKey))
                        if let keyURL = vm.providerKeyURL {
                            Link("Get Key", destination: keyURL)
                                .font(.caption)
                                .help("Open provider API key management page")
                        }
                    }
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wire API").font(.subheadline).fontWeight(.medium)
                        Text("Protocol for Codex CLI")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("", selection: vm.binding(for: \.codexWireAPI)) {
                        Text("Chat").tag("chat")
                        Text("Responses").tag("responses")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(8)
            if let docs = vm.providerDocsURL {
                Link("View API documentation", destination: docs)
                    .font(.caption)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Models").font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button { vm.addModelRow() } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Default").font(.caption.weight(.medium))
                        Text("Model ID").font(.caption.weight(.medium))
                        Text("Reasoning").font(.caption.weight(.medium))
                        Text("Tool Use").font(.caption.weight(.medium))
                        Text("Vision").font(.caption.weight(.medium))
                        Text("Long Ctx").font(.caption.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    ForEach($vm.modelRows, id: \.id) { $row in
                        GridRow {
                            Toggle("", isOn: Binding(get: { vm.defaultModelRowID == row.id }, set: { isOn in vm.setDefaultModelRow(rowID: isOn ? row.id : nil, modelId: isOn ? row.modelId : nil) }))
                                .labelsHidden()
                                .disabled(row.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            TextField("vendor model id", text: $row.modelId)
                                .onChange(of: row.modelId) { _, newValue in
                                    vm.handleModelIDChange(for: row.id, newValue: newValue)
                                }
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
        .padding(.horizontal, 4)
    }

    }
// MARK: - ViewModel (Codex-first)
@available(macOS 15.0, *)
@MainActor
final class ProvidersVM: ObservableObject {
    enum Preset: String, Identifiable {
        case k2 = "K2"
        case glm = "GLM"
        case deepseek = "DeepSeek"

        var id: String { rawValue }

        var baseURL: String {
            switch self {
            case .k2: return "https://api.moonshot.cn/v1"
            case .glm: return "https://open.bigmodel.cn/api/paas/v4/"
            case .deepseek: return "https://api.deepseek.com/v1"
            }
        }

        var claudeBaseURL: String? {
            switch self {
            case .k2: return "https://api.moonshot.cn/anthropic"
            case .glm: return nil
            case .deepseek: return nil
            }
        }

        var envKey: String {
            switch self {
            case .k2: return "K2_API_KEY"
            case .glm: return "ZHIPUAI_API_KEY"
            case .deepseek: return "DEEPSEEK_API_KEY"
            }
        }

        var getKeyURL: String {
            switch self {
            case .k2: return "https://platform.moonshot.cn/console/api-keys"
            case .glm: return "https://open.bigmodel.cn/usercenter/apikeys"
            case .deepseek: return "https://platform.deepseek.com/api_keys"
            }
        }

        var serviceName: String {
            switch self {
            case .k2: return "Moonshot AI"
            case .glm: return "GLM-4"
            case .deepseek: return "DeepSeek"
            }
        }

        var docsURL: String? {
            switch self {
            case .k2: return "https://platform.moonshot.cn/docs"
            case .glm: return "https://open.bigmodel.cn/dev/api"
            case .deepseek: return "https://platform.deepseek.com/docs"
            }
        }
    }

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
    @Published var codexWireAPI: String = "chat"
    @Published var claudeBaseURL: String = ""
    @Published var canSave: Bool = false

    @Published var activeCodexProviderId: String? = nil
    @Published var defaultCodexModel: String = ""
    @Published var activeClaudeProviderId: String? = nil

    @Published var lastError: String? = nil
    @Published var testResultText: String? = nil
    @Published var showEditor: Bool = false
    @Published var isNewProvider: Bool = false
    @Published var newProviderPreset: Preset? = nil
    @Published var providerKeyURL: URL? = nil
    @Published var providerDocsURL: URL? = nil

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

        // If current selectedId is not in the list anymore, select the first one or clear
        if let currentId = selectedId, !list.contains(where: { $0.id == currentId }) {
            selectedId = list.first?.id
        } else if selectedId == nil {
            selectedId = list.first?.id
        }

        syncEditingFieldsFromSelected()
        loadModelRowsFromSelected()
    }

    private func syncEditingFieldsFromSelected() {
        guard let sel = selectedId, let provider = providers.first(where: { $0.id == sel }) else {
            providerName = ""
            codexBaseURL = ""
            codexEnvKey = "OPENAI_API_KEY"
            codexWireAPI = "chat"
            claudeBaseURL = ""
            defaultModelId = nil
            applyPresetMetadata(nil)
            recomputeCanSave()
            return
        }
        providerName = provider.name ?? ""
        let codexConnector = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]
        let claudeConnector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        codexBaseURL = codexConnector?.baseURL ?? ""
        codexEnvKey = codexConnector?.envKey ?? claudeConnector?.envKey ?? "OPENAI_API_KEY"
        codexWireAPI = normalizedWireAPI(codexConnector?.wireAPI)
        claudeBaseURL = claudeConnector?.baseURL ?? ""
        applyPresetMetadata(presetFor(provider: provider))
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
    @Published var defaultModelId: String?
    @Published var defaultModelRowID: UUID? = nil

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
        if let defined = providerDefaultModel(from: p), let match = rows.first(where: { $0.modelId == defined }) {
            defaultModelRowID = match.id
            defaultModelId = match.modelId
        } else if let first = rows.first(where: { !$0.modelId.isEmpty }) {
            defaultModelRowID = first.id
            defaultModelId = first.modelId
        } else {
            defaultModelRowID = nil
            defaultModelId = nil
        }
        normalizeDefaultSelection()
    }

    private func providerDefaultModel(from provider: ProvidersRegistryService.Provider) -> String? {
        if let recommended = provider.recommended?.defaultModelFor?[ProvidersRegistryService.Consumer.codex.rawValue], !recommended.isEmpty {
            return recommended
        }
        if let alias = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.modelAliases?["default"], !alias.isEmpty {
            return alias
        }
        if let first = provider.catalog?.models?.first?.vendorModelId {
            return first
        }
        return nil
    }

    func setDefaultModelRow(rowID: UUID?, modelId: String?) {
        defaultModelRowID = rowID
        let trimmed = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        defaultModelId = trimmed.isEmpty ? nil : trimmed
        normalizeDefaultSelection()
    }

    func handleModelIDChange(for rowID: UUID, newValue: String) {
        guard defaultModelRowID == rowID else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultModelId = trimmed.isEmpty ? nil : trimmed
        normalizeDefaultSelection()
    }

    private func normalizeDefaultSelection() {
        if modelRows.isEmpty {
            defaultModelRowID = nil
            defaultModelId = nil
            return
        }
        if let rowID = defaultModelRowID,
           let current = modelRows.first(where: { $0.id == rowID }),
           !current.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaultModelId = current.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        if let defined = defaultModelId,
           let match = modelRows.first(where: { $0.modelId == defined }) {
            defaultModelRowID = match.id
            defaultModelId = match.modelId
            return
        }
        if let fallback = modelRows.first(where: { !$0.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            defaultModelRowID = fallback.id
            defaultModelId = fallback.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            defaultModelRowID = nil
            defaultModelId = nil
        }
    }

    private func resolvedDefaultModel(from models: [ProvidersRegistryService.ModelEntry]) -> String? {
        let ids = models.map { $0.vendorModelId }
        if let current = defaultModelId?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty, ids.contains(current) {
            return current
        }
        return ids.first
    }


    func addModelRow() {
        let row = ModelRow(modelId: "", reasoning: false, toolUse: false, vision: false, longContext: false)
        modelRows.append(row)
        normalizeDefaultSelection()
    }
    func deleteModelRow(rowKey: UUID) {
        modelRows.removeAll { $0.id == rowKey }
        normalizeDefaultSelection()
    }

    func binding(for keyPath: ReferenceWritableKeyPath<ProvidersVM, String>) -> Binding<String> {
        Binding<String>(get: { self[keyPath: keyPath] }, set: { newVal in
            self[keyPath: keyPath] = newVal
            self.recomputeCanSave()
            self.testResultText = nil
        })
    }

    private func normalizedWireAPI(_ value: String?) -> String {
        let lowered = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch lowered {
        case "responses": return "responses"
        default: return "chat"
        }
    }

    private func presetFor(provider: ProvidersRegistryService.Provider) -> Preset? {
        let id = provider.id.lowercased()
        if id == "k2" || provider.connectors.values.contains(where: { ($0.baseURL ?? "").contains("moonshot") }) {
            return .k2
        }
        if id == "glm" || provider.connectors.values.contains(where: { ($0.baseURL ?? "").contains("bigmodel") }) {
            return .glm
        }
        if id == "deepseek" || provider.connectors.values.contains(where: { ($0.baseURL ?? "").contains("deepseek") }) {
            return .deepseek
        }
        return nil
    }

    private func applyPresetMetadata(_ preset: Preset?) {
        if let preset, let keyURL = URL(string: preset.getKeyURL) {
            providerKeyURL = keyURL
        } else {
            providerKeyURL = nil
        }
        if let preset, let docs = preset.docsURL, let url = URL(string: docs) {
            providerDocsURL = url
        } else {
            providerDocsURL = nil
        }
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

        // Handle new provider creation
        if isNewProvider {
            return await saveNewProvider()
        }

        guard var p = providers.first(where: { $0.id == sel }) else { lastError = "Missing provider"; return false }
        let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        p.name = trimmedName.isEmpty ? nil : trimmedName
        var conn = p.connectors[ProvidersRegistryService.Consumer.codex.rawValue] ?? .init(baseURL: nil, wireAPI: nil, envKey: nil, queryParams: nil, httpHeaders: nil, envHttpHeaders: nil, requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil)
        let trimmedCodexBase = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnv = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWire = normalizedWireAPI(codexWireAPI)
        conn.baseURL = trimmedCodexBase.isEmpty ? nil : trimmedCodexBase
        conn.envKey = trimmedEnv.isEmpty ? nil : trimmedEnv
        conn.wireAPI = normalizedWire
        p.connectors[ProvidersRegistryService.Consumer.codex.rawValue] = conn
        var cconn = p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] ?? .init(baseURL: nil, wireAPI: nil, envKey: nil, queryParams: nil, httpHeaders: nil, envHttpHeaders: nil, requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil)
        let trimmedClaudeBase = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        cconn.baseURL = trimmedClaudeBase.isEmpty ? nil : trimmedClaudeBase
        cconn.envKey = trimmedEnv.isEmpty ? nil : trimmedEnv
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
        normalizeDefaultSelection()
        let defaultModel = resolvedDefaultModel(from: cleanedModels)
        defaultModelId = defaultModel
        var updatedRecommended: ProvidersRegistryService.Recommended?
        if var recommended = p.recommended {
            var defaults = recommended.defaultModelFor ?? [:]
            let codexKey = ProvidersRegistryService.Consumer.codex.rawValue
            let claudeKey = ProvidersRegistryService.Consumer.claudeCode.rawValue
            if let defaultModel {
                defaults[codexKey] = defaultModel
                defaults[claudeKey] = defaultModel
            } else {
                defaults.removeValue(forKey: codexKey)
                defaults.removeValue(forKey: claudeKey)
            }
            recommended.defaultModelFor = defaults.isEmpty ? nil : defaults
            updatedRecommended = recommended.defaultModelFor == nil ? nil : recommended
        } else if let defaultModel {
            updatedRecommended = ProvidersRegistryService.Recommended(defaultModelFor: [
                ProvidersRegistryService.Consumer.codex.rawValue: defaultModel,
                ProvidersRegistryService.Consumer.claudeCode.rawValue: defaultModel
            ])
        }
        p.recommended = updatedRecommended
        do {
            try await registry.upsertProvider(p)
            if activeCodexProviderId == p.id {
                try await registry.setDefaultModel(.codex, modelId: defaultModel)
                do {
                    try await codex.setTopLevelString("model", value: defaultModel)
                } catch {
                    lastError = "Failed to write model to Codex config"
                }
            }
            if activeClaudeProviderId == p.id {
                try await registry.setDefaultModel(.claudeCode, modelId: defaultModel)
            }
            await syncActiveCodexProviderIfNeeded(with: p)
            await reload()
            return true
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    private func saveNewProvider() async -> Bool {
        let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = await registry.listProviders()
        let baseSlug = slugify(trimmedName.isEmpty ? "provider" : trimmedName)
        var candidate = baseSlug
        var n = 2
        while list.contains(where: { $0.id == candidate }) { candidate = "\(baseSlug)-\(n)"; n += 1 }

        var connectors: [String: ProvidersRegistryService.Connector] = [:]
        let trimmedCodexBase = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnv = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWire = normalizedWireAPI(codexWireAPI)

        if !trimmedCodexBase.isEmpty || !trimmedEnv.isEmpty {
            connectors[ProvidersRegistryService.Consumer.codex.rawValue] = .init(
                baseURL: trimmedCodexBase.isEmpty ? nil : trimmedCodexBase,
                wireAPI: normalizedWire,
                envKey: trimmedEnv.isEmpty ? nil : trimmedEnv,
                queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil
            )
        }

        let trimmedClaudeBase = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedClaudeBase.isEmpty || !trimmedEnv.isEmpty {
            let cconn = ProvidersRegistryService.Connector(
                baseURL: trimmedClaudeBase.isEmpty ? nil : trimmedClaudeBase,
                wireAPI: nil,
                envKey: trimmedEnv.isEmpty ? nil : trimmedEnv,
                queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil
            )
            connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = cconn
        }

        let cleanedModels: [ProvidersRegistryService.ModelEntry] = modelRows.compactMap { r in
            let trimmed = r.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let caps = ProvidersRegistryService.ModelCaps(
                reasoning: r.reasoning, tool_use: r.toolUse, vision: r.vision, long_context: r.longContext,
                code_tuned: nil, tps_hint: nil, max_output_tokens: nil
            )
            return ProvidersRegistryService.ModelEntry(vendorModelId: trimmed, caps: caps, aliases: nil)
        }

        let catalog = cleanedModels.isEmpty ? nil : ProvidersRegistryService.Catalog(models: cleanedModels)
        normalizeDefaultSelection()
        let defaultModel = resolvedDefaultModel(from: cleanedModels)
        defaultModelId = defaultModel
        var recommended: ProvidersRegistryService.Recommended?
        if let defaultModel {
            recommended = ProvidersRegistryService.Recommended(defaultModelFor: [
                ProvidersRegistryService.Consumer.codex.rawValue: defaultModel,
                ProvidersRegistryService.Consumer.claudeCode.rawValue: defaultModel
            ])
        }

        let provider = ProvidersRegistryService.Provider(
            id: candidate,
            name: trimmedName.isEmpty ? nil : trimmedName,
            class: "openai-compatible",
            managedByCodMate: true,
            connectors: connectors,
            catalog: catalog,
            recommended: recommended
        )

        do {
            try await registry.upsertProvider(provider)
            await syncActiveCodexProviderIfNeeded(with: provider)
            isNewProvider = false
            await reload()
            selectedId = candidate
            return true
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Test editing fields (before save)
    func testEditingFields() async {
        lastError = nil
        testResultText = nil
        let codexURL = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeURL = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !codexURL.isEmpty || !claudeURL.isEmpty else {
            testResultText = "No URLs to test"
            return
        }
        var lines: [String] = []
        if !codexURL.isEmpty {
            let result = await evaluateEndpoint(label: "Codex", urlString: codexURL)
            lines.append(formattedLine(for: result))
        }
        if !claudeURL.isEmpty {
            let result = await evaluateEndpoint(label: "Claude", urlString: claudeURL)
            lines.append(formattedLine(for: result))
        }
        testResultText = lines.isEmpty ? "No URLs to test" : lines.joined(separator: "\n")
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
            if let id, let provider = providers.first(where: { $0.id == id }) {
                try await codex.applyProviderFromRegistry(provider)
            } else {
                try await codex.applyProviderFromRegistry(nil)
            }
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
        do {
            try await registry.deleteProvider(id: id)
            if activeCodexProviderId == id {
                try await registry.setActiveProvider(.codex, providerId: nil)
                try await registry.setDefaultModel(.codex, modelId: nil)
                await syncActiveCodexProviderIfNeeded(with: nil)
            }
        } catch {
            lastError = "Delete failed: \(error.localizedDescription)"
        }
        await reload()
    }

    func addOther() { startNewProvider(preset: nil) }

    func startNewProvider(preset: Preset? = nil) {
        isNewProvider = true
        newProviderPreset = preset
        selectedId = "new-provider-temp"

        if let preset = preset {
            // Pre-fill with preset values
            providerName = preset.rawValue
            codexBaseURL = preset.baseURL
            codexEnvKey = preset.envKey
            codexWireAPI = "chat"
            claudeBaseURL = preset.claudeBaseURL ?? ""
            applyPresetMetadata(preset)
        } else {
            // Empty for custom provider
            providerName = ""
            codexBaseURL = ""
            codexEnvKey = "OPENAI_API_KEY"
            codexWireAPI = "chat"
            claudeBaseURL = ""
            applyPresetMetadata(nil)
        }

        modelRows = []
        defaultModelId = nil
        defaultModelRowID = nil
        testResultText = nil
        lastError = nil
        recomputeCanSave()
        showEditor = true
    }

    func addPreset(_ preset: Preset) {
        startNewProvider(preset: preset)
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

    private func syncActiveCodexProviderIfNeeded(with provider: ProvidersRegistryService.Provider?) async {
        let targetId = provider?.id
        if targetId == activeCodexProviderId || (provider == nil && activeCodexProviderId != nil) {
            do {
                try await codex.applyProviderFromRegistry(provider)
            } catch {
                await MainActor.run { self.lastError = "Failed to sync provider to Codex config" }
            }
        }
    }

    private struct EndpointCheck {
        let message: String
        let ok: Bool
        let statusCode: Int
    }

    private func directAPIKeyValue() -> String? {
        let trimmed = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-") ? trimmed : nil
    }

    private func evaluateEndpoint(label: String, urlString: String) async -> EndpointCheck {
        guard let baseURL = URL(string: urlString) else {
            return EndpointCheck(message: "\(label): invalid URL", ok: false, statusCode: -1)
        }
        var attempts: [URL] = [baseURL]
        attempts.append(baseURL.appendingPathComponent("models"))
        attempts.append(baseURL.appendingPathComponent("status"))
        let lower = baseURL.absoluteString.lowercased()
        if lower.contains("anthropic") {
            attempts.append(baseURL.appendingPathComponent("messages"))
        } else {
            let wire = normalizedWireAPI(codexWireAPI)
            if wire == "chat" {
                attempts.append(baseURL.appendingPathComponent("chat/completions"))
            } else {
                attempts.append(baseURL.appendingPathComponent("responses"))
            }
        }
        var last = EndpointCheck(message: "\(label): request failed", ok: false, statusCode: -1)
        let token = directAPIKeyValue()
        for candidate in attempts {
            var req = URLRequest(url: candidate)
            req.httpMethod = "GET"
            if lower.contains("anthropic") {
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
            if let token {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let isMessagesProbe = candidate.path.lowercased().contains("/messages")
                let allow404 =
                    isMessagesProbe
                    && lower.contains("anthropic")
                    && code == 404
                let ok = (200...299).contains(code) || code == 401 || code == 403 || code == 405 || allow404
                let message = "\(label): HTTP \(code) \(ok ? "(reachable)" : "(unexpected)")"
                let result = EndpointCheck(message: message, ok: ok, statusCode: code)
                if ok { return result }
                last = result
            } catch {
                last = EndpointCheck(message: "\(label): \(error.localizedDescription)", ok: false, statusCode: -1)
            }
        }
        return last
    }

    private func formattedLine(for result: EndpointCheck) -> String {
        var line = result.message
        guard !result.ok else { return line }
        switch result.statusCode {
        case 401, 403:
            line += " – Check the API key or token permissions."
        case 404:
            line += " – Verify the base URL and wire API. Some vendors return 404 for a GET on the base path; Codex requires the chat endpoints to be reachable."
            if let docs = providerDocsURL {
                line += " Docs: \(docs.absoluteString)"
            }
        default:
            if let docs = providerDocsURL {
                line += " – See docs: \(docs.absoluteString)"
            }
        }
        return line
    }

}
