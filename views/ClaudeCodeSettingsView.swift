import SwiftUI
import AppKit
import Combine

struct ClaudeCodeSettingsView: View {
    @ObservedObject var vm: ClaudeCodeVM
    @ObservedObject var preferences: SessionPreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude Code Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure provider, model aliases, and review launch environment.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Link(destination: URL(string: "https://docs.claude.com/en/docs/claude-code/settings")!) {
                    Label("Docs", systemImage: "questionmark.circle").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }

            TabView {
                Tab("Provider", systemImage: "server.rack") { SettingsTabContent { providerPane } }
                Tab("Runtime", systemImage: "gearshape.2") { SettingsTabContent { runtimePane } }
                Tab("Raw Config", systemImage: "doc.text") { SettingsTabContent { rawPane } }
            }
            .padding(.bottom, 16)
        }
        .task { await vm.loadAll() }
    }

    // MARK: - Provider
    private var providerPane: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Active Provider").font(.subheadline).fontWeight(.medium)
                        Text("Anthropic-compatible endpoint configured in Providers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("", selection: $vm.activeProviderId) {
                        Text("(Built-in)").tag(String?.none)
                        ForEach(vm.providers, id: \.id) { p in
                            Text(p.name?.isEmpty == false ? p.name! : p.id).tag(String?(p.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onChange(of: vm.activeProviderId) { _, _ in vm.scheduleApplyActiveProviderDebounced() }
                }
                // Default Model row (only for third‑party providers)
                if vm.activeProviderId != nil {
                    gridDivider
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Default Model").font(.subheadline).fontWeight(.medium)
                            Text("Used by Claude Code when starting a session.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let modelIds = vm.availableModels()
                        if modelIds.isEmpty {
                            Text("No models configured for this provider. Manage models in Providers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            Picker("", selection: $vm.aliasDefault) {
                                ForEach(modelIds, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .onChange(of: vm.aliasDefault) { _, newVal in vm.scheduleApplyDefaultAliasDebounced(newVal) }
                        }
                    }
                    gridDivider
                    // Alias rows (like Default Model style)
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Haiku Alias").font(.subheadline).fontWeight(.medium)
                            Text("Optional; leave as Default to inherit.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let options = vm.availableModels()
                        Picker("", selection: $vm.aliasHaiku) {
                            Text("Default").tag("")
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .onChange(of: vm.aliasHaiku) { _, _ in vm.scheduleSaveDebounced() }
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Sonnet Alias").font(.subheadline).fontWeight(.medium)
                            Text("Optional; leave as Default to inherit.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let options = vm.availableModels()
                        Picker("", selection: $vm.aliasSonnet) {
                            Text("Default").tag("")
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .onChange(of: vm.aliasSonnet) { _, _ in vm.scheduleSaveDebounced() }
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Opus Alias").font(.subheadline).fontWeight(.medium)
                            Text("Optional; leave as Default to inherit.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let options = vm.availableModels()
                        Picker("", selection: $vm.aliasOpus) {
                            Text("Default").tag("")
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .onChange(of: vm.aliasOpus) { _, _ in vm.scheduleSaveDebounced() }
                    }
                }
                if vm.activeProviderId == nil {
                gridDivider
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Login Method").font(.subheadline).fontWeight(.medium)
                        Text("Use API Key for third-party endpoints; Claude Subscription uses 'claude login'.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Picker("", selection: $vm.loginMethod) {
                            Text("API Key").tag(ClaudeCodeVM.LoginMethod.api)
                            Text("Claude Subscription").tag(ClaudeCodeVM.LoginMethod.subscription)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: vm.loginMethod) { _, newVal in
                            Task { await vm.setLoginMethod(newVal) }
                        }
                        .disabled(vm.activeProviderId != nil) // third-party must use API Key
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                }
                // Inline warning for missing token in API Key mode (only for Built-in)
                if vm.activeProviderId == nil && vm.tokenMissingForCurrentSelection() {
                    GridRow {
                        Text("")
                        HStack {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                            Text("API token not found in environment; set ANTHROPIC_AUTH_TOKEN or your custom key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                // No inline provider edit link to keep the flow consistent
            }
    }

    // MARK: - Models / Aliases
    // modelsPane removed; Provider pane now includes the default model picker like Codex

    // MARK: - Raw Config (read-only; toolbar mirrors Codex)
    private var rawPane: some View {
        let displayText = vm.rawSettingsText
        
        return ZStack(alignment: .topTrailing) {
            ScrollView {
                Text(displayText.isEmpty ? "(empty settings.json)" : displayText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(spacing: 8) {
                Button { Task { await vm.reloadRawSettings() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
                .buttonStyle(.borderless)
                Button { vm.openSettingsInEditor() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Open in default editor")
                .buttonStyle(.borderless)
            }
        }
        .task { await vm.reloadRawSettings() }
    }
    
    private func buildRawConfigText() -> String {
        // Prefer showing the canonical user settings file in full
        let settingsURL = SessionPreferencesStore.getRealUserHomeURL()
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        
        if let fileText = try? String(contentsOf: settingsURL, encoding: .utf8) {
            return fileText
        }
        
        // Fallback: build preview from current settings
        var lines = vm.launchEnvPreview()
        
        // Append launch/runtime flags preview
        lines.append("\n# Launch flags preview")
        lines.append("permission-mode=\(preferences.claudePermissionMode.rawValue)")
        lines.append("sandbox=\(preferences.defaultResumeSandboxMode.rawValue)")
        lines.append("approvals=\(preferences.defaultResumeApprovalPolicy.rawValue)")
        
        // Debug info
        if preferences.claudeDebug {
            lines.append("debug=true filter=\(preferences.claudeDebugFilter)")
        } else {
            lines.append("debug=false")
        }
        
        lines.append("verbose=\(preferences.claudeVerbose ? "true" : "false")")
        lines.append("ide=\(preferences.claudeIDE ? "true" : "false")")
        lines.append("strictMCP=\(preferences.claudeStrictMCP ? "true" : "false")")
        
        // Tools configuration
        let allowedTools = preferences.claudeAllowedTools.trimmingCharacters(in: .whitespaces)
        if !allowedTools.isEmpty {
            lines.append("allowed-tools=\(allowedTools)")
        }
        
        let disallowedTools = preferences.claudeDisallowedTools.trimmingCharacters(in: .whitespaces)
        if !disallowedTools.isEmpty {
            lines.append("disallowed-tools=\(disallowedTools)")
        }
        
        let fallbackModel = preferences.claudeFallbackModel.trimmingCharacters(in: .whitespaces)
        if !fallbackModel.isEmpty {
            lines.append("fallback-model=\(fallbackModel)")
        }
        
        // Build example command
        let exampleCommand = buildExampleCommand()
        lines.append("\n# Example command")
        lines.append(exampleCommand)
        
        return lines.joined(separator: "\n")
    }
    
    private func buildExampleCommand() -> String {
        var example: [String] = ["claude"]
        
        // Permission mode
        if preferences.claudePermissionMode.rawValue != "default" {
            example.append("--permission-mode \(preferences.claudePermissionMode.rawValue)")
        }
        
        // Debug/Verbose
        if preferences.claudeDebug {
            let debugFilter = preferences.claudeDebugFilter.trimmingCharacters(in: .whitespaces)
            if !debugFilter.isEmpty {
                example.append("--debug \(debugFilter)")
            } else {
                example.append("--debug")
            }
        }
        
        if preferences.claudeVerbose {
            example.append("--verbose")
        }
        
        // Tools
        let allowedTools = preferences.claudeAllowedTools.trimmingCharacters(in: .whitespaces)
        if !allowedTools.isEmpty {
            example.append("--allowed-tools \"\(allowedTools)\"")
        }
        
        let disallowedTools = preferences.claudeDisallowedTools.trimmingCharacters(in: .whitespaces)
        if !disallowedTools.isEmpty {
            example.append("--disallowed-tools \"\(disallowedTools)\"")
        }
        
        // IDE
        if preferences.claudeIDE {
            example.append("--ide")
        }
        
        // Fallback model
        let fallbackModel = preferences.claudeFallbackModel.trimmingCharacters(in: .whitespaces)
        if !fallbackModel.isEmpty {
            example.append("--fallback-model \(fallbackModel)")
        }
        
        // MCP config path
        let mcpPath = SessionPreferencesStore.getRealUserHomeURL()
            .appendingPathComponent(".codmate", isDirectory: true)
            .appendingPathComponent("mcp-enabled-claude.json").path
        
        if FileManager.default.fileExists(atPath: mcpPath) {
            example.append("--mcp-config \(mcpPath)")
        }
        
        return example.joined(separator: " ")
    }

    // MARK: - Runtime (Claude-native)
    private var runtimePane: some View {
        runtimePaneGrid
            .onReceive(preferences.objectWillChange) { _ in
                Task { await vm.scheduleApplyRuntimeSettings(preferences) }
            }
    }
    
    private var runtimePaneGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
            // Claude-native permission mode
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Permission Mode").font(.subheadline).fontWeight(.medium)
                    Text("Affects edit confirmations and planning.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("", selection: $preferences.claudePermissionMode) {
                    ForEach(ClaudePermissionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            // Dangerous permission skips (explicit)
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Skip Permissions (Dangerous)").font(.subheadline).fontWeight(.medium)
                    Text("Bypass permission prompts; use with caution.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Enable", isOn: $preferences.claudeSkipPermissions)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Allow Skip Permissions").font(.subheadline).fontWeight(.medium)
                    Text("Permit using the dangerous skip flag.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Enable", isOn: $preferences.claudeAllowSkipPermissions)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Removed: Unsandboxed commands toggle (no official CLI/setting key)
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Debug").font(.subheadline).fontWeight(.medium)
                    Text("Enable debug output; optional category filter.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Toggle("Enable", isOn: $preferences.claudeDebug)
                    TextField("api,hooks", text: $preferences.claudeDebugFilter)
                        .frame(width: 220)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Verbose Output").font(.subheadline).fontWeight(.medium)
                    Text("Override verbose mode from config.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Enable", isOn: $preferences.claudeVerbose)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Allowed Tools").font(.subheadline).fontWeight(.medium)
                    Text("Comma or space-separated tool names.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Bash(git:*), Edit", text: $preferences.claudeAllowedTools)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Disallowed Tools").font(.subheadline).fontWeight(.medium)
                }
                TextField("Bash(rm:*), Edit", text: $preferences.claudeDisallowedTools)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Other").font(.subheadline).fontWeight(.medium)
                }
                HStack(spacing: 16) {
                    Toggle("IDE auto-connect", isOn: $preferences.claudeIDE)
                    Toggle("Strict MCP config", isOn: $preferences.claudeStrictMCP)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Fallback Model").font(.subheadline).fontWeight(.medium)
                    Text("Optional model when default is overloaded (print mode).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("haiku", text: $preferences.claudeFallbackModel)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // aliasPicker removed
}

private struct SettingsCard<Content: View>: View {
    let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(10)
            .background(Color(nsColor: .separatorColor).opacity(0.35))
            .cornerRadius(10)
    }
}

private func settingsCard<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
    SettingsCard(content: content)
}

private var gridDivider: some View { Divider().opacity(0.5) }

// MARK: - Runtime Settings Change Handler
// Removed complex onChange modifier due to type-checker performance; using a single
// onReceive(preferences.objectWillChange) above to debounce runtime writes.

extension ClaudeCodeVM {
    var selectedClaudeBaseURL: String? {
        guard let id = activeProviderId,
              let p = providers.first(where: { $0.id == id }) else { return nil }
        return p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL
    }
    var selectedClaudeEnvKey: String? {
        guard let id = activeProviderId,
              let p = providers.first(where: { $0.id == id }) else { return nil }
        return p.envKey ?? p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
    }

    func launchEnvPreview() -> [String] {
        var lines: [String] = [
            "# Environment variables applied when launching Claude",
        ]
        if let base = selectedClaudeBaseURL, !base.isEmpty {
            lines.append("export ANTHROPIC_BASE_URL=\(base)")
        } else {
            lines.append("# ANTHROPIC_BASE_URL not set (uses tool default)")
        }
        if !(activeProviderId == nil && loginMethod == .subscription) {
            let key = selectedClaudeEnvKey ?? "ANTHROPIC_AUTH_TOKEN"
            lines.append("export ANTHROPIC_AUTH_TOKEN=$\(key)")
        } else {
            lines.append("# Using Claude subscription login; no token env injected")
        }
        // Aliases (only when a third‑party provider is selected)
        if activeProviderId != nil {
            if !aliasDefault.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("export ANTHROPIC_MODEL=\(aliasDefault)")
            }
            if !aliasHaiku.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("export ANTHROPIC_SMALL_FAST_MODEL=\(aliasHaiku)")
            }
        }
        // MCP config path preview (used via --mcp-config when launching)
        let mcpPath = SessionPreferencesStore.getRealUserHomeURL()
            .appendingPathComponent(".codmate", isDirectory: true)
            .appendingPathComponent("mcp-enabled-claude.json").path
        if FileManager.default.fileExists(atPath: mcpPath) {
            lines.append("# MCP config: \(mcpPath)")
        }
        return lines
    }
}
