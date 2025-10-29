import SwiftUI

struct CodexSettingsView: View {
    @ObservedObject var codexVM: CodexVM
    @ObservedObject var preferences: SessionPreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header for visual consistency with other settings pages
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codex Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(
                        "Configure Codex CLI: providers, runtime defaults, notifications, and privacy."
                    )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Link(
                    destination: URL(
                        string: "https://github.com/openai/codex/blob/main/docs/config.md")!
                ) {
                    Label("Docs", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }

            // Tabs
            TabView {
                Tab("Provider", systemImage: "server.rack") { providerPane }
                Tab("Runtime", systemImage: "gearshape.2") { runtimePane }
                Tab("Notifications", systemImage: "bell") { notificationsPane }
                Tab("Privacy", systemImage: "lock.shield") { privacyPane }
                Tab("Raw Config", systemImage: "doc.text") { rawConfigPane }
            }
            .controlSize(.regular)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Provider Pane
    private var providerPane: some View {
        SettingsTabContent {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Active Provider").font(.subheadline).fontWeight(.medium)
                        Text("Choose built-in or a configured provider")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("", selection: $codexVM.registryActiveProviderId) {
                        Text("(Built-in)").tag(String?.none)
                        ForEach(codexVM.registryProviders, id: \.id) { provider in
                            Text(codexVM.registryDisplayName(for: provider))
                                .tag(String?(provider.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onChange(of: codexVM.registryActiveProviderId) { _, _ in
                        codexVM.scheduleApplyRegistryProviderSelectionDebounced()
                    }
                }
                gridDivider
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Model").font(.subheadline).fontWeight(.medium)
                        Text("Default model used by Codex CLI.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if codexVM.registryActiveProviderId == nil {
                        Picker("", selection: $codexVM.model) {
                            ForEach(codexVM.builtinModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .onChange(of: codexVM.model) { _, _ in codexVM.scheduleApplyModelDebounced() }
                    } else {
                        let modelIds = codexVM.modelsForActiveRegistryProvider()
                        if modelIds.isEmpty {
                            Text("No models configured for this provider. Add models in Providers → Models tab.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            Picker("", selection: $codexVM.model) {
                                ForEach(modelIds, id: \.self) { modelId in
                                    Text(modelId).tag(modelId)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .onChange(of: codexVM.model) { _, _ in codexVM.scheduleApplyModelDebounced() }
                        }
                    }
                }
                // Base URL and API Key Env rows are hidden to reduce redundancy
            }
        }
        .task { await codexVM.loadRegistryBindings() }
    }

    // MARK: - Runtime Pane
    private var runtimePane: some View {
        SettingsTabContent {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Reasoning Effort").font(.subheadline).fontWeight(.medium)
                                Text("Controls depth of reasoning for supported models.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Picker("", selection: $codexVM.reasoningEffort) {
                                ForEach(CodexVM.ReasoningEffort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: codexVM.reasoningEffort) { _, _ in codexVM.scheduleApplyReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Reasoning Summary").font(.subheadline).fontWeight(.medium)
                                Text("Summary verbosity for reasoning-capable models.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Picker("", selection: $codexVM.reasoningSummary) {
                                ForEach(CodexVM.ReasoningSummary.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: codexVM.reasoningSummary) { _, _ in codexVM.scheduleApplyReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Verbosity").font(.subheadline).fontWeight(.medium)
                                Text("Text output verbosity for GPT‑5 family (Responses API).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Picker("", selection: $codexVM.modelVerbosity) {
                                ForEach(CodexVM.ModelVerbosity.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: codexVM.modelVerbosity) { _, _ in codexVM.scheduleApplyReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Sandbox").font(.subheadline).fontWeight(.medium)
                                Text("Default sandbox for sessions launched from CodMate only.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Picker("", selection: $preferences.defaultResumeSandboxMode) {
                                ForEach(SandboxMode.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Approval Policy").font(.subheadline).fontWeight(.medium)
                                Text("Default approval prompts for sessions launched from CodMate only.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Picker("", selection: $preferences.defaultResumeApprovalPolicy) {
                                ForEach(ApprovalPolicy.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Auto-assign new sessions to same project").font(.subheadline)
                                    .fontWeight(.medium)
                                Text(
                                    "When starting New from detail, auto-assign the created session to that project."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                                Toggle("", isOn: $preferences.autoAssignNewToSameProject)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
        }
    }

    // MARK: - Notifications Pane
    private var notificationsPane: some View {
        SettingsTabContent {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("TUI Notifications").font(.subheadline).fontWeight(.medium)
                                Text(
                                    "Show in-terminal notifications during TUI sessions (supported terminals only)."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                                Toggle("", isOn: $codexVM.tuiNotifications)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            .onChange(of: codexVM.tuiNotifications) { _, _ in codexVM.scheduleApplyTuiNotificationsDebounced() }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("System Notifications").font(.subheadline).fontWeight(.medium)
                                Text(
                                    "Forward Codex turn-complete events to macOS notifications via notify."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                                Toggle("", isOn: $codexVM.systemNotifications)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                .onChange(of: codexVM.systemNotifications) { _, _ in codexVM.scheduleApplySystemNotificationsDebounced() }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        if let path = codexVM.notifyBridgePath {
                            gridDivider
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Notify bridge: \(path)").font(.caption).foregroundStyle(
                                        .secondary
                                    )
                                    .frame(alignment: .leading)
                                }
                            }
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Self-test").font(.subheadline).fontWeight(.medium)
                                Text("Send a sample event through the notify bridge.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                if codexVM.notifyBridgeHealthy {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                                Button("Run Self-test") { Task { await codexVM.runNotifySelfTest() } }
                                    .controlSize(.small)
                                if let r = codexVM.notifySelfTestResult {
                                    Text(r).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
        }
    }

    // MARK: - Privacy Pane
    private var privacyPane: some View {
        SettingsTabContent {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inherit").font(.subheadline).fontWeight(.medium)
                            Text("Start from full, core, or empty environment.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("", selection: $codexVM.envInherit) {
                            ForEach(["all", "core", "none"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ignore default excludes").font(.subheadline).fontWeight(.medium)
                            Text("Keep vars containing KEY/SECRET/TOKEN unless unchecked.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("", isOn: $codexVM.envIgnoreDefaults)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Include Only").font(.subheadline).fontWeight(.medium)
                            Text("Whitelist patterns (comma separated). Example: PATH, HOME")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("PATH, HOME", text: $codexVM.envIncludeOnly)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exclude").font(.subheadline).fontWeight(.medium)
                            Text("Blacklist patterns (comma separated). Example: AWS_*, AZURE_*")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("AWS_*, AZURE_*", text: $codexVM.envExclude)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Set Variables").font(.subheadline).fontWeight(.medium)
                            Text("KEY=VALUE per line. These override inherited values.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextEditor(text: $codexVM.envSetPairs)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 90)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        Text("")
                        HStack {
                            Button("Save Environment Policy") {
                                Task { await codexVM.applyEnvPolicy() }
                            }
                            if codexVM.lastError != nil {
                                Text(codexVM.lastError!).foregroundStyle(.red).font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hide Agent Reasoning").font(.subheadline).fontWeight(.medium)
                            Text("Suppress reasoning events in TUI and exec outputs.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("", isOn: $codexVM.hideAgentReasoning)
                            .labelsHidden()
                            .onChange(of: codexVM.hideAgentReasoning) { _, _ in codexVM.scheduleApplyHideReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show Raw Reasoning").font(.subheadline).fontWeight(.medium)
                            Text(
                                "Expose raw chain-of-thought when provider supports it (use with caution)."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("", isOn: $codexVM.showRawAgentReasoning)
                            .labelsHidden()
                            .onChange(of: codexVM.showRawAgentReasoning) { _, _ in codexVM.scheduleApplyShowRawReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Raw Config Pane
    private var rawConfigPane: some View {
        SettingsTabContent {
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    Text(
                        codexVM.rawConfigText.isEmpty
                            ? "(empty config.toml)" : codexVM.rawConfigText
                    )
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await codexVM.reloadRawConfig() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload")
                    .buttonStyle(.borderless)
                    Button {
                        codexVM.openConfigInEditor()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("Open in default editor")
                    .buttonStyle(.borderless)
                }
            }
            .task { await codexVM.reloadRawConfig() }
        }
    }

    // MARK: - Helper Views

    // codexTabContent has been replaced by the shared SettingsTabContent component

    @ViewBuilder
    private var gridDivider: some View {
        Divider()
    }

}
