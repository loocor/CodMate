import AppKit
import SwiftUI

@available(macOS 15.0, *)
struct SettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @Binding private var selectedCategory: SettingCategory
    @StateObject private var codexVM = CodexVM()
    @EnvironmentObject private var viewModel: SessionListViewModel
    @State private var showLicensesSheet = false
    @State private var availableRemoteHosts: [SSHHost] = []

    init(preferences: SessionPreferencesStore, selection: Binding<SettingCategory>) {
        self._preferences = ObservedObject(wrappedValue: preferences)
        self._selectedCategory = selection
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowConfigurator { window in
                window.isMovableByWindowBackground = true
                if window.toolbar == nil {
                    let toolbar = NSToolbar(identifier: "CodMateSettingsToolbar")
                    SettingsToolbarCoordinator.shared.configure(toolbar: toolbar)
                    window.toolbar = toolbar
                }
                window.title = "Settings"

                var minSize = window.contentMinSize
                minSize.width = max(minSize.width, 800)
                minSize.height = max(minSize.height, 560)
                window.contentMinSize = minSize

                var maxSize = window.contentMaxSize
                if maxSize.width > 0 { maxSize.width = max(maxSize.width, 2000) }
                if maxSize.height > 0 { maxSize.height = max(maxSize.height, 1400) }
                window.contentMaxSize = maxSize
            }
            .frame(width: 0, height: 0)

            NavigationSplitView {
                List(SettingCategory.allCases, selection: $selectedCategory) { category in
                    let isSelected = (category == selectedCategory)
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: category.icon)
                            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                                .font(.headline)
                            Text(category.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .tag(category)
                }
                .listStyle(.sidebar)
                .controlSize(.small)
                .environment(\.defaultMinListRowHeight, 18)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
            } detail: {
                selectedCategoryView
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .task { await codexVM.loadAll() }
                    .navigationSplitViewColumnWidth(min: 460, ideal: 640, max: 1200)
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(removing: .sidebarToggle)
        }
        .frame(minWidth: 800, minHeight: 560)
    }

    private final class SettingsToolbarCoordinator: NSObject, NSToolbarDelegate {
        static let shared = SettingsToolbarCoordinator()
        private let spacerID = NSToolbarItem.Identifier("CodMateSettingsSpacer")

        func configure(toolbar: NSToolbar) {
            toolbar.delegate = self
            toolbar.allowsUserCustomization = false
            toolbar.allowsExtensionItems = false
            toolbar.displayMode = .iconOnly
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [spacerID]
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [spacerID]
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            guard itemIdentifier == spacerID else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let view = NSView(frame: .zero)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
            view.heightAnchor.constraint(equalToConstant: 1).isActive = true
            item.view = view
            return item
        }
    }

    @ViewBuilder
    private var selectedCategoryView: some View {
        switch selectedCategory {
        case .general:
            generalSettings
        case .terminal:
            terminalSettings
        case .command:
            commandSettings
        case .codex:
            codexSettings
        case .dialectics:
            dialecticsSettings
        case .mcpServer:
            mcpServerSettings
        case .about:
            aboutSettings
        }
    }

    private var generalSettings: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("General Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure basic application settings and file paths")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("File Paths")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Sessions Directory", systemImage: "folder")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Directory where Codex session files are stored")
                                    .font(.caption).foregroundColor(.secondary)
                            }

                            Text(preferences.sessionsRoot.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Button("Change…", action: selectSessionsRoot)
                                .buttonStyle(.bordered)
                        }

                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Notes Directory", systemImage: "text.book.closed")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Where session titles and comments are saved")
                                    .font(.caption).foregroundColor(.secondary)
                            }

                            Text(preferences.notesRoot.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Button("Change…", action: selectNotesRoot)
                                .buttonStyle(.bordered)
                        }

                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Codex CLI Path", systemImage: "terminal")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Path to the codex executable")
                                    .font(.caption).foregroundColor(.secondary)
                            }

                            Text(preferences.codexExecutableURL.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Button("Change…", action: selectCodexExecutable)
                                .buttonStyle(.bordered)
                        }

                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Claude CLI Path", systemImage: "terminal")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Path to the claude executable")
                                    .font(.caption).foregroundColor(.secondary)
                            }

                            Text(preferences.claudeExecutableURL.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Button("Change…", action: selectClaudeExecutable)
                                .buttonStyle(.bordered)
                        }
                    }
                }

                // Timeline & Markdown visibility
                VStack(alignment: .leading, spacing: 16) {
                    Text("Timeline & Markdown")
                        .font(.headline)
                        .foregroundColor(.primary)

                    // Timeline visibility section (full-width header + wrapping options)
                    visibilitySection(
                        title: "Timeline visibility",
                        systemImage: "text.bubble",
                        description:
                            "Choose which message types appear in the conversation timeline",
                        selection: $preferences.timelineVisibleKinds,
                        defaults: MessageVisibilityKind.timelineDefault
                    )

                    // Markdown export section (same layout)
                    visibilitySection(
                        title: "Markdown export",
                        systemImage: "doc.text",
                        description:
                            "Choose which message types are included when exporting Markdown",
                        selection: $preferences.markdownVisibleKinds,
                        defaults: MessageVisibilityKind.markdownDefault
                    )
                }

                // Diagnostics (moved to Dialectics page)
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Visibility Section (full-width header + wrapping options)
    @ViewBuilder
    private func visibilitySection(
        title: String,
        systemImage: String,
        description: String,
        selection: Binding<Set<MessageVisibilityKind>>,
        defaults: Set<MessageVisibilityKind>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header block: title + description with tighter spacing to match File Paths (4pt)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline).fontWeight(.medium)
                    Spacer(minLength: 8)
                    Button("Restore Defaults") { selection.wrappedValue = defaults }
                        .buttonStyle(.bordered)
                }
                Text(description)
                    .font(.caption).foregroundColor(.secondary)
            }

            // Options: left-to-right, equal spacing, wrap to next line naturally
            let order: [MessageVisibilityKind] = [
                .user, .assistant, .tool, .syncing, .environment, .reasoning, .tokenUsage,
                .infoOther,
            ]
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 120), alignment: .leading),
                    count: 4
                ),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(order, id: \.self) { kind in
                    Toggle(kind.title, isOn: binding(selection, kind))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding(
        _ selection: Binding<Set<MessageVisibilityKind>>, _ kind: MessageVisibilityKind
    ) -> Binding<Bool> {
        Binding<Bool>(
            get: { selection.wrappedValue.contains(kind) },
            set: { newVal in
                var s = selection.wrappedValue
                if newVal { s.insert(kind) } else { s.remove(kind) }
                selection.wrappedValue = s
            }
        )
    }

    private var codexSettings: some View {
        settingsScroll {
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
                Tab("Providers", systemImage: "server.rack") { providersPane }
                Tab("Runtime", systemImage: "gearshape.2") { runtimePane }
                Tab("Remote Hosts", systemImage: "antenna.radiowaves.left.and.right") { remoteHostsPane }
                Tab("Notifications", systemImage: "bell") { notificationsPane }
                Tab("Privacy", systemImage: "lock.shield") { privacyPane }
                Tab("Raw Config", systemImage: "doc.text") { rawConfigPane }
            }
            .controlSize(.regular)
            .padding(.bottom, 16)
        }
        }
    }

    // MARK: - Dialectics
    private var dialecticsSettings: some View {
        settingsScroll {
            DialecticsPane(preferences: preferences)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Providers Pane
    private var providersPane: some View {
        codexTabContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Menu {
                        Button("K2") { codexVM.presentAddProviderPreset(.k2) }
                        Button("GLM") { codexVM.presentAddProviderPreset(.glm) }
                        Button("DeepSeek") { codexVM.presentAddProviderPreset(.deepseek) }
                        Divider()
                        Button("Other") { codexVM.presentAddProvider() }
                    } label: {
                        Label("Add Provider", systemImage: "plus")
                    }
                }
                Divider()

                providerRow(
                    index: 0, id: nil, name: "Codex Default (built-in)", url: "Built‑in",
                    editable: false)
                Divider()

                ForEach(Array(codexVM.providers.enumerated()), id: \.1.id) { idx, p in
                    let rowIndex = idx + 1
                    providerRow(
                        index: rowIndex,
                        id: p.id,
                        name: (p.name?.isEmpty == false ? p.name! : p.id),
                        url: p.baseURL ?? "",
                        editable: true,
                        onEdit: { codexVM.presentEditProvider(p) })
                    if idx < codexVM.providers.count - 1 { Divider() }
                }
            }
        }
        .sheet(isPresented: $codexVM.showProviderEditor) {
            ProviderEditor(
                draft: $codexVM.providerDraft,
                isNew: codexVM.editingKindIsNew,
                apiKeyApplyURL: codexVM.providerKeyApplyURL,
                onCancel: { codexVM.dismissEditor() },
                onSave: { Task { await codexVM.saveProviderDraft() } },
                onDelete: { Task { await codexVM.deleteEditingProviderViaEditor() } }
            )
            .frame(minWidth: 560)
            .padding(16)
        }
    }

    // One-line provider list row with radio + name + URL + optional edit button
    @ViewBuilder
    private func providerRow(
        index: Int, id: String?, name: String, url: String, editable: Bool,
        onEdit: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // Radio
            Button(action: {
                codexVM.activeProviderId = id
                Task { await codexVM.applyActiveProvider() }
            }) {
                Image(
                    systemName: codexVM.activeProviderId == id
                        ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)

            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(url.isEmpty ? "" : url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360, alignment: .trailing)
            if editable, let onEdit {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .help("Edit")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            codexVM.activeProviderId = id
            Task { await codexVM.applyActiveProvider() }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    // MARK: - Runtime Pane
    private var runtimePane: some View {
        codexTabContent {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model").font(.subheadline).fontWeight(.medium)
                        Text("Default model used by Codex CLI.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("gpt-5-codex", text: $codexVM.model)
                        .onSubmit { Task { await codexVM.applyModel() } }
                        .onChange(of: codexVM.model) { _, _ in codexVM.runtimeDirty = true }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning Effort").font(.subheadline).fontWeight(.medium)
                        Text("Controls depth of reasoning for supported models.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("", selection: $codexVM.reasoningEffort) {
                        ForEach(CodexVM.ReasoningEffort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: codexVM.reasoningEffort) { _, _ in
                        Task { await codexVM.applyReasoning() }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning Summary").font(.subheadline).fontWeight(.medium)
                        Text("Summary verbosity for reasoning-capable models.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("", selection: $codexVM.reasoningSummary) {
                        ForEach(CodexVM.ReasoningSummary.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: codexVM.reasoningSummary) { _, _ in
                        Task { await codexVM.applyReasoning() }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Verbosity").font(.subheadline).fontWeight(.medium)
                        Text("Text output verbosity for GPT‑5 family (Responses API).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("", selection: $codexVM.modelVerbosity) {
                        ForEach(CodexVM.ModelVerbosity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: codexVM.modelVerbosity) { _, _ in
                        Task { await codexVM.applyReasoning() }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
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
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
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
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto-assign new sessions to same project").font(.subheadline)
                            .fontWeight(.medium)
                        Text(
                            "When starting New from detail, auto-assign the created session to that project."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: $preferences.autoAssignNewToSameProject)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var remoteHostsPane: some View {
        codexTabContent {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Remote Hosts")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Choose which SSH hosts CodMate should mirror for remote Codex/Claude sessions.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 10) {
                        Button(role: .none) {
                            DispatchQueue.main.async {
                                preferences.enabledRemoteHosts = []
                            }
                        } label: {
                            Text("Clear All")
                        }
                        .buttonStyle(.bordered)
                        .disabled(preferences.enabledRemoteHosts.isEmpty)
                        Button {
                            reloadRemoteHosts()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                let hosts = availableRemoteHosts
                if hosts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No SSH hosts were found in ~/.ssh/config.")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Text("Add host aliases to your SSH config, then refresh to enable remote session mirroring.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(hosts, id: \.alias) { host in
                            Toggle(isOn: bindingForRemoteHost(alias: host.alias)) {
                                Text(host.alias)
                                    .font(.body)
                                    .fontWeight(.medium)
                            }
                            .toggleStyle(.switch)
                        }
                    }
                    .padding(.vertical, 4)
                }

                let hostAliases = Set(hosts.map { $0.alias })
                let dangling = preferences.enabledRemoteHosts.subtracting(hostAliases)
                if !dangling.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unavailable Hosts")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("The following host aliases are enabled but not present in your current SSH config:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(Array(dangling).sorted(), id: \.self) { alias in
                            Text("• \(alias)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Text("CodMate mirrors only the hosts you enable. Hosts that prompt for passwords will open interactively when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                if availableRemoteHosts.isEmpty {
                    DispatchQueue.main.async { reloadRemoteHosts() }
                }
            }
        }
    }

    // MARK: - Notifications Pane
    private var notificationsPane: some View {
        codexTabContent {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TUI Notifications").font(.subheadline).fontWeight(.medium)
                        Text(
                            "Show in-terminal notifications during TUI sessions (supported terminals only)."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: $codexVM.tuiNotifications)
                        .labelsHidden()
                        .onChange(of: codexVM.tuiNotifications) { _, _ in
                            Task { await codexVM.applyTuiNotifications() }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System Notifications").font(.subheadline).fontWeight(.medium)
                        Text(
                            "Forward Codex turn-complete events to macOS notifications via notify."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: $codexVM.systemNotifications)
                        .labelsHidden()
                        .onChange(of: codexVM.systemNotifications) { _, _ in
                            Task { await codexVM.applySystemNotifications() }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let path = codexVM.notifyBridgePath {
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notify bridge: \(path)").font(.caption).foregroundStyle(
                                .secondary
                            )
                            .frame(alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Privacy Pane
    private var privacyPane: some View {
        codexTabContent {
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
                            .onChange(of: codexVM.hideAgentReasoning) { _, _ in
                                Task { await codexVM.applyHideReasoning() }
                            }
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
                            .onChange(of: codexVM.showRawAgentReasoning) { _, _ in
                                Task { await codexVM.applyShowRawReasoning() }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("File Opener").font(.subheadline).fontWeight(.medium)
                            Text("Editor scheme for clickable file citations.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("", selection: $codexVM.fileOpener) {
                            ForEach(
                                ["vscode", "vscode-insiders", "windsurf", "cursor", "none"],
                                id: \.self
                            ) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .onChange(of: codexVM.fileOpener) { _, _ in
                            Task { await codexVM.applyFileOpener() }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenTelemetry (OTEL)").font(.subheadline).fontWeight(.medium)
                            Text("Export structured logs to your collector.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Enable", isOn: $codexVM.otelEnabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exporter").font(.subheadline).fontWeight(.medium)
                            Text("Transport protocol for OTEL logs.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("", selection: $codexVM.otelKind) {
                            Text("otlp-http").tag(CodexVM.OtelKind.http)
                            Text("otlp-grpc").tag(CodexVM.OtelKind.grpc)
                        }
                        .labelsHidden()
                        .disabled(!codexVM.otelEnabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Endpoint").font(.subheadline).fontWeight(.medium)
                            Text("Collector endpoint URL.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("https://otel.example.com/v1/logs", text: $codexVM.otelEndpoint)
                            .disabled(!codexVM.otelEnabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        Text("")
                        Button("Save OTEL") { Task { await codexVM.applyOtel() } }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }

        }
    }

    // MARK: - Raw Config Pane (read-only preview + open in editor)
    private var rawConfigPane: some View {
        codexTabContent {
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

    // Consistent insets for all tabs
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

    private func codexTabContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func reloadRemoteHosts() {
        let resolver = SSHConfigResolver()
        let hosts = resolver.resolvedHosts().sorted { $0.alias.lowercased() < $1.alias.lowercased() }
        availableRemoteHosts = hosts
        let hostAliases = Set(hosts.map { $0.alias })
        let filtered = preferences.enabledRemoteHosts.filter { hostAliases.contains($0) }
        if filtered.count != preferences.enabledRemoteHosts.count {
            DispatchQueue.main.async {
                preferences.enabledRemoteHosts = Set(filtered)
            }
        }
    }

    private func bindingForRemoteHost(alias: String) -> Binding<Bool> {
        Binding(
            get: { preferences.enabledRemoteHosts.contains(alias) },
            set: { isOn in
                DispatchQueue.main.async {
                    var hosts = preferences.enabledRemoteHosts
                    if isOn {
                        hosts.insert(alias)
                    } else {
                        hosts.remove(alias)
                    }
                    preferences.enabledRemoteHosts = hosts
                }
            }
        )
    }

    private var terminalSettings: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Terminal Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure terminal behavior and resume preferences")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Resume Defaults")
                        .font(.headline)
                        .foregroundColor(.primary)

                    // Two-column grid for aligned controls
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                        // Row: Embedded terminal toggle
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Run in embedded terminal")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Use the built-in terminal instead of an external one")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Toggle("", isOn: $preferences.defaultResumeUseEmbeddedTerminal)
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .gridColumnAlignment(.trailing)
                        }

                        // Row: Copy to clipboard
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Copy resume commands to clipboard")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Automatically copy the resume command when resuming")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Toggle("", isOn: $preferences.defaultResumeCopyToClipboard)
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .gridColumnAlignment(.trailing)
                        }

                        // Row: Default external app
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Open external terminal")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Choose the terminal app for external sessions")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Picker("", selection: $preferences.defaultResumeExternalApp) {
                                ForEach(TerminalApp.allCases) { app in
                                    Text(app.title).tag(app)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                            .gridCellAnchor(.trailing)
                        }
                    }
                }

            }
        }
    }

    private var commandSettings: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command Options")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Default sandbox and approval policies for Codex commands")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sandbox policy (-s, --sandbox)")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Filesystem access level for generated commands")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Picker("", selection: $preferences.defaultResumeSandboxMode) {
                            ForEach(SandboxMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                    }

                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Approval policy (-a, --ask-for-approval)")
                                .font(.subheadline).fontWeight(.medium)
                            Text("When human confirmation is required")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Picker("", selection: $preferences.defaultResumeApprovalPolicy) {
                            ForEach(ApprovalPolicy.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                    }

                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable full-auto (--full-auto)")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Alias for on-failure approvals with workspace-write sandbox")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Toggle("", isOn: $preferences.defaultResumeFullAuto)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                    }

                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bypass approvals & sandbox")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundColor(.red)
                            Text("--dangerously-bypass-approvals-and-sandbox (use with care)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Toggle("", isOn: $preferences.defaultResumeDangerBypass)
                            .labelsHidden()
                            .tint(.red)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    private var aboutSettings: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About CodMate")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Build information and project links")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Version") { Text(versionString) }
                    LabeledContent("Build Timestamp") { Text(buildTimestampString) }
                    LabeledContent("Project URL") {
                        Link(projectURL.absoluteString, destination: projectURL)
                    }
                    LabeledContent("Repository") {
                        Link(repoURL.absoluteString, destination: repoURL)
                    }
                    LabeledContent("Open Source Licenses") {
                        Button("View…") { showLicensesSheet = true }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("CodMate is a macOS companion for managing Codex CLI sessions.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showLicensesSheet) {
            OpenSourceLicensesView(repoURL: repoURL)
                .frame(minWidth: 600, minHeight: 480)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var buildTimestampString: String {
        guard let executableURL = Bundle.main.executableURL,
            let attrs = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
            let date = attrs[.modificationDate] as? Date
        else { return "Unavailable" }
        return Self.buildDateFormatter.string(from: date)
    }

    private var projectURL: URL { URL(string: "https://umate.ai/codmate")! }
    private var repoURL: URL { URL(string: "https://github.com/loocor/CodMate")! }
    private var mcpMateURL: URL { URL(string: "https://mcpmate.io/")! }
    private let mcpMateTagline = "Dedicated MCP orchestration for Codex workflows."

    private static let buildDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df
    }()

    private var mcpServerSettings: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MCP Server Integration")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Connect Codex sessions with managed MCP endpoints")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Image("MCPMateLogo")
                            .resizable()
                            .frame(width: 48, height: 48)
                            .cornerRadius(12)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("MCPMate")
                                .font(.headline)
                            Text(
                                "A 'Maybe All-in-One' MCP service manager for developers and creators."
                            )
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        }
                    }

                    Text(
                        "MCPMate now manages Codex MCP configuration and lifecycle. CodMate no longer bundles MCP controls—download MCPMate and reuse the same working directory and model defaults."
                    )
                    .font(.body)
                    .foregroundColor(.secondary)

                    Text("Quickly download MCPMate to configure MCP servers alongside CodMate.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
           
                    Button(action: openMCPMateDownload) {
                        Label("Download MCPMate", systemImage: "arrow.down.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .font(.body.weight(.semibold))
                }
                .frame(alignment: .leading)
            }
        }
    }

    private func selectSessionsRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.sessionsRoot
        panel.message = "Select the directory where session files are stored"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await viewModel.updateSessionsRoot(to: url) }
        }
    }

    private func selectCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable, .executable]
        panel.directoryURL = preferences.codexExecutableURL.deletingLastPathComponent()
        panel.message = "Select the codex executable"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            preferences.codexExecutableURL = url
        }
    }

    private func selectClaudeExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable, .executable]
        panel.directoryURL = preferences.claudeExecutableURL.deletingLastPathComponent()
        panel.message = "Select the claude executable"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            preferences.claudeExecutableURL = url
        }
    }

    private func selectNotesRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.notesRoot
        panel.message = "Select the directory where session notes are stored"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await viewModel.updateNotesRoot(to: url) }
        }
    }

    private func resetToDefaults() {
        preferences.sessionsRoot = SessionPreferencesStore.defaultSessionsRoot(
            for: FileManager.default.homeDirectoryForCurrentUser)
        preferences.codexExecutableURL = SessionPreferencesStore.defaultExecutableURL()
        preferences.claudeExecutableURL = SessionPreferencesStore.defaultClaudeExecutableURL()
        preferences.defaultResumeUseEmbeddedTerminal = true
        preferences.defaultResumeCopyToClipboard = true
        preferences.defaultResumeExternalApp = .terminal
        preferences.defaultResumeSandboxMode = .workspaceWrite
        preferences.defaultResumeApprovalPolicy = .onRequest
        preferences.defaultResumeFullAuto = false
        preferences.defaultResumeDangerBypass = false
    }

    private func openMCPMateDownload() {
        NSWorkspace.shared.open(mcpMateURL)
    }
}

// MARK: - Open Source Licenses Sheet
@available(macOS 15.0, *)
private struct OpenSourceLicensesView: View {
    let repoURL: URL
    @State private var content: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Open Source Licenses")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Open on GitHub") { openOnGitHub() }
            }
            .padding(.bottom, 4)

            if content.isEmpty {
                ProgressView()
                    .task { await loadContent() }
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openOnGitHub() {
        // Point to the file in the default branch
        let url = URL(string: repoURL.absoluteString + "/blob/main/THIRD-PARTY-NOTICES.md")!
        NSWorkspace.shared.open(url)
    }

    private func candidateLocalURLs() -> [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") {
            urls.append(bundled)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(cwd.appendingPathComponent("THIRD-PARTY-NOTICES.md"))
        // When running from Xcode/DerivedData, try a few parents
        let execDir = Bundle.main.bundleURL
        urls.append(execDir.appendingPathComponent("Contents/Resources/THIRD-PARTY-NOTICES.md"))
        return urls
    }

    private func loadContent() async {
        for url in candidateLocalURLs() {
            if FileManager.default.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)
            {
                await MainActor.run { self.content = text }
                return
            }
        }
        // Fallback to remote raw file on GitHub if local not found
        if let remote = URL(
            string: "https://raw.githubusercontent.com/loocor/CodMate/main/THIRD-PARTY-NOTICES.md")
        {
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                if let text = String(data: data, encoding: .utf8) {
                    await MainActor.run { self.content = text }
                }
            } catch {
                await MainActor.run {
                    self.content =
                        "Unable to load licenses. Please see THIRD-PARTY-NOTICES.md in the repository."
                }
            }
        }
    }
}

// MARK: - Codex Settings ViewModel (inline to avoid project wiring churn)
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

// MARK: - Dialectics Pane
@available(macOS 15.0, *)
private struct DialecticsPane: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @StateObject private var vm = DialecticsVM()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dialectics")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Deep diagnostics for sessions, providers, and environment")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await vm.runAll(preferences: preferences) }
                    } label: {
                        Label("Run Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        vm.saveReport(preferences: preferences)
                    } label: {
                        Label("Save Report…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }

                // App & OS
                Group {
                    Text("Environment").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("App Version").font(.subheadline)
                            Text(vm.appVersion).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("Build Time").font(.subheadline)
                            Text(vm.buildTime).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("macOS").font(.subheadline)
                            Text(vm.osVersion).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }

                Divider()

                // Sessions diagnostics
                Group {
                    Text("Sessions Root").font(.headline)
                    if let s = vm.sessions {
                        DiagnosticsReportView(result: s)
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }

                Divider()

                // Providers diagnostics
                Group {
                    Text("Providers").font(.headline)
                    if let p = vm.providers {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("Config Path").font(.subheadline)
                                Text(p.configPath).font(.caption).frame(
                                    maxWidth: .infinity, alignment: .trailing)
                            }
                            GridRow {
                                Text("Providers Count").font(.subheadline)
                                Text("\(p.providers.count)").frame(
                                    maxWidth: .infinity, alignment: .trailing)
                            }
                            GridRow {
                                Text("Duplicate IDs").font(.subheadline)
                                let d = p.duplicateIDs
                                Text(d.isEmpty ? "(none)" : d.joined(separator: ", "))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            GridRow {
                                Text("Stray Bodies").font(.subheadline)
                                Text("\(p.strayManagedBodies)").frame(
                                    maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        HStack(spacing: 8) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p.canonicalRegion, forType: .string)
                            } label: {
                                Label("Copy Canonical Region", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: p.configPath))
                            } label: {
                                Label("Open config.toml", systemImage: "square.and.pencil")
                            }
                            .buttonStyle(.bordered)
                        }
                        ScrollView {
                            Text(
                                p.canonicalRegion.isEmpty
                                    ? "(no providers configured)" : p.canonicalRegion
                            )
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(
                                    Color(nsColor: .textBackgroundColor))
                            )
                        }.frame(maxHeight: 220)
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }

                Divider()

                // CLI diagnostics
                Group {
                    Text("CLI & PATH").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Preferred").font(.subheadline)
                            Text(preferences.codexExecutableURL.path).font(.caption).frame(
                                maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("Resolved").font(.subheadline)
                            Text(vm.resolvedCodexPath ?? "(not found)").font(.caption).frame(
                                maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("PATH").font(.subheadline)
                            Text(vm.pathEnv).font(.caption).lineLimit(2).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .task { await vm.runAll(preferences: preferences) }
    }
}

@available(macOS 15.0, *)
@MainActor
private final class DialecticsVM: ObservableObject {
    @Published var sessions: SessionsDiagnostics? = nil
    @Published var providers: CodexConfigService.ProviderDiagnostics? = nil
    @Published var resolvedCodexPath: String? = nil
    @Published var pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? ""

    private let sessionsSvc = SessionsDiagnosticsService()
    private let configSvc = CodexConfigService()
    private let actions = SessionActions()

    func runAll(preferences: SessionPreferencesStore) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defRoot = SessionPreferencesStore.defaultSessionsRoot(for: home)
        let s = await sessionsSvc.run(currentRoot: preferences.sessionsRoot, defaultRoot: defRoot)
        let p = await configSvc.diagnoseProviders()
        let resolved = actions.resolveExecutableURL(
            preferred: preferences.codexExecutableURL)?.path
        self.sessions = s
        self.providers = p
        self.resolvedCodexPath = resolved
        self.pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
    }

    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
    var buildTime: String {
        guard let exe = Bundle.main.executableURL,
            let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
            let date = attrs[.modificationDate] as? Date
        else { return "Unavailable" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df.string(from: date)
    }
    var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - Report
    struct ProviderSummary: Codable {
        let id: String
        let name: String?
        let baseURL: String?
        let managedByCodMate: Bool
    }
    struct ProvidersReport: Codable {
        let configPath: String
        let providers: [ProviderSummary]
        let duplicateIDs: [String]
        let strayManagedBodies: Int
        let headerCounts: [String: Int]
        let canonicalRegion: String  // sanitized env_key values
    }
    struct CombinedReport: Codable {
        let timestamp: Date
        let appVersion: String
        let buildTime: String
        let osVersion: String
        let sessions: SessionsDiagnostics?
        let providers: ProvidersReport?
        let cli: [String: String?]
    }

    func saveReport(preferences: SessionPreferencesStore) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        panel.nameFieldStringValue = "CodMate-Diagnostics-\(df.string(from: now)).json"
        panel.beginSheetModal(
            for: NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first!
        ) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let report = self.buildReport(preferences: preferences, now: now)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(report) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    @MainActor private func buildReport(preferences: SessionPreferencesStore, now: Date)
        -> CombinedReport
    {
        let p = providers
        let pr: ProvidersReport? = p.map { d in
            let list = d.providers.map {
                ProviderSummary(
                    id: $0.id, name: $0.name, baseURL: $0.baseURL,
                    managedByCodMate: $0.managedByCodMate)
            }
            return ProvidersReport(
                configPath: d.configPath,
                providers: list,
                duplicateIDs: d.duplicateIDs,
                strayManagedBodies: d.strayManagedBodies,
                headerCounts: d.headerCounts,
                canonicalRegion: sanitizeCanonicalRegion(d.canonicalRegion)
            )
        }
        let cli: [String: String?] = [
            "preferredPath": preferences.codexExecutableURL.path,
            "resolvedPath": resolvedCodexPath,
            "PATH": pathEnv,
        ]
        return CombinedReport(
            timestamp: now,
            appVersion: appVersion,
            buildTime: buildTime,
            osVersion: osVersion,
            sessions: sessions,
            providers: pr,
            cli: cli
        )
    }

    private func sanitizeCanonicalRegion(_ text: String) -> String {
        // Redact env_key values to avoid leaking secrets
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("env_key") {
                out.append("env_key = \"***\"")
            } else {
                out.append(raw)
            }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Provider Editor
private struct ProviderEditor: View {
    @Binding var draft: CodexProvider
    let isNew: Bool
    var apiKeyApplyURL: String? = nil
    var onCancel: () -> Void
    var onSave: () -> Void
    var onDelete: (() -> Void)? = nil
    @State private var showDeleteAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Provider" : "Edit Provider").font(.title2).fontWeight(.semibold)
            Text("Configure a model provider compatible with OpenAI APIs.")
                .font(.subheadline).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name *").font(.subheadline).fontWeight(.medium)
                        Text("Display name for this provider.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    TextField(
                        "OpenAI", text: Binding(get: { draft.name ?? "" }, set: { draft.name = $0 })
                    )
                    .frame(maxWidth: .infinity)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL *").font(.subheadline).fontWeight(.medium)
                        Text("API base URL, e.g., https://api.openai.com/v1").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "https://api.openai.com/v1",
                        text: Binding(get: { draft.baseURL ?? "" }, set: { draft.baseURL = $0 })
                    )
                    .frame(maxWidth: .infinity)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key").font(.subheadline).fontWeight(.medium)
                        Text("Environment variable for API key (optional). Example: OPENAI_API_KEY")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField(
                            "OPENAI_API_KEY",
                            text: Binding(get: { draft.envKey ?? "" }, set: { draft.envKey = $0 }))
                        if let apiKeyApplyURL, let url = URL(string: apiKeyApplyURL) {
                            Link("Get key", destination: url)
                                .font(.caption)
                        }
                    }
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wire API").font(.subheadline).fontWeight(.medium)
                        Text("Protocol: chat or responses (optional).").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "responses",
                        text: Binding(get: { draft.wireAPI ?? "" }, set: { draft.wireAPI = $0 }))
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("query_params").font(.subheadline).fontWeight(.medium)
                        Text("Inline TOML. Example: { api-version = \"2025-04-01-preview\" }").font(
                            .caption
                        ).foregroundStyle(.secondary)
                    }
                    TextField(
                        "{ api-version = \"2025-04-01-preview\" }",
                        text: Binding(
                            get: { draft.queryParamsRaw ?? "" }, set: { draft.queryParamsRaw = $0 })
                    )
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("http_headers").font(.subheadline).fontWeight(.medium)
                        Text("Inline TOML map. Example: { X-Header = \"abc\" }").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "{ X-Header = \"abc\" }",
                        text: Binding(
                            get: { draft.httpHeadersRaw ?? "" }, set: { draft.httpHeadersRaw = $0 })
                    )
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("env_http_headers").font(.subheadline).fontWeight(.medium)
                        Text("Header values from env. Example: { X-Token = \"MY_ENV\" }").font(
                            .caption
                        ).foregroundStyle(.secondary)
                    }
                    TextField(
                        "{ X-Token = \"MY_ENV\" }",
                        text: Binding(
                            get: { draft.envHttpHeadersRaw ?? "" },
                            set: { draft.envHttpHeadersRaw = $0 }))
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("request_max_retries").font(.subheadline).fontWeight(.medium)
                        Text("HTTP retry count (optional).").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    TextField(
                        "4",
                        text: Binding(
                            get: { (draft.requestMaxRetries?.description) ?? "" },
                            set: { draft.requestMaxRetries = Int($0) }))
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("stream_max_retries").font(.subheadline).fontWeight(.medium)
                        Text("SSE reconnect attempts (optional).").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    TextField(
                        "5",
                        text: Binding(
                            get: { (draft.streamMaxRetries?.description) ?? "" },
                            set: { draft.streamMaxRetries = Int($0) }))
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("stream_idle_timeout_ms").font(.subheadline).fontWeight(.medium)
                        Text("Idle timeout for streaming (optional).").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "300000",
                        text: Binding(
                            get: { (draft.streamIdleTimeoutMs?.description) ?? "" },
                            set: { draft.streamIdleTimeoutMs = Int($0) }))
                }
            }
            HStack {
                if !isNew, onDelete != nil {
                    Button("Delete", role: .destructive) { showDeleteAlert = true }
                }
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Save", action: onSave).buttonStyle(.borderedProminent)
            }
        }
        .alert("Delete provider?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { showDeleteAlert = false }
            Button("Delete", role: .destructive) {
                showDeleteAlert = false
                onDelete?()
            }
        } message: {
            Text("This will remove the provider from config.toml.")
        }
    }
}

// MARK: - Diagnostics Section
@available(macOS 15.0, *)
private struct DiagnosticsSection: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @State private var running = false
    @State private var lastResult: SessionsDiagnostics? = nil
    @State private var lastError: String? = nil
    private let service = SessionsDiagnosticsService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.headline)
                .foregroundColor(.primary)

            HStack(spacing: 8) {
                Button(action: runDiagnostics) {
                    if running { ProgressView().controlSize(.small) }
                    Text(running ? "Diagnosing…" : "Diagnose Sessions Directory")
                }
                .disabled(running)

                if let result = lastResult,
                    result.current.enumeratedJsonlCount == 0,
                    result.defaultRoot.enumeratedJsonlCount > 0,
                    preferences.sessionsRoot.path != result.defaultRoot.path
                {
                    Button("Switch to Default Path") {
                        preferences.sessionsRoot = URL(
                            fileURLWithPath: result.defaultRoot.path, isDirectory: true)
                    }
                }

                if lastResult != nil {
                    Button("Save Report…", action: saveReport)
                }
            }

            if let error = lastError { Text(error).foregroundStyle(.red).font(.caption) }

            if let result = lastResult {
                DiagnosticsReportView(result: result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    )
            }
        }
    }

    private func runDiagnostics() {
        running = true
        lastError = nil
        lastResult = nil
        let current = preferences.sessionsRoot
        let home = FileManager.default.homeDirectoryForCurrentUser
        let def = SessionPreferencesStore.defaultSessionsRoot(for: home)
        Task {
            let res = await service.run(currentRoot: current, defaultRoot: def)
            await MainActor.run {
                self.lastResult = res
                self.running = false
            }
        }
    }

    private func saveReport() {
        guard let result = lastResult else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(result)
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            let ts = df.string(from: result.timestamp)
            panel.nameFieldStringValue = "CodMate-Sessions-Diagnostics-\(ts).json"
            panel.begin { resp in
                if resp == .OK, let url = panel.url {
                    do { try data.write(to: url, options: .atomic) } catch {
                        self.lastError = "Failed to save report: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            self.lastError = "Failed to prepare report: \(error.localizedDescription)"
        }
    }
}

@available(macOS 15.0, *)
private struct DiagnosticsReportView: View {
    let result: SessionsDiagnostics
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timestamp: \(formatDate(result.timestamp))").font(.caption)
            let same = result.current.path == result.defaultRoot.path
            Group {
                Text(same ? "Sessions Root (= Default)" : "Current Root")
                    .font(.subheadline).bold()
                DiagnosticsProbeView(p: result.current)
            }
            if !same {
                Group {
                    Text("Default Root").font(.subheadline).bold().padding(.top, 4)
                    DiagnosticsProbeView(p: result.defaultRoot)
                }
            }

            if !result.suggestions.isEmpty {
                Text("Suggestions").font(.subheadline).bold().padding(.top, 4)
                ForEach(result.suggestions, id: \.self) { s in
                    Text("• \(s)").font(.caption)
                }
            }
        }
    }

    private func formatDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df.string(from: d)
    }
}

@available(macOS 15.0, *)
private struct DiagnosticsProbeView: View {
    let p: SessionsDiagnostics.Probe
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Path: \(p.path)").font(.caption)
            Text("Exists: \(p.exists ? "yes" : "no")").font(.caption)
            Text("Directory: \(p.isDirectory ? "yes" : "no")").font(.caption)
            Text(".jsonl files: \(p.enumeratedJsonlCount)").font(.caption)
            if !p.sampleFiles.isEmpty {
                Text("Samples:").font(.caption)
                ForEach(p.sampleFiles.prefix(5), id: \.self) { s in
                    Text("• \(s)").font(.caption2)
                }
                if p.sampleFiles.count > 5 {
                    Text("(\(p.sampleFiles.count - 5) more…)").font(.caption2).foregroundStyle(
                        .secondary)
                }
            }
            if let err = p.enumeratorError {
                Text("Enumerator Error: \(err)").font(.caption).foregroundStyle(.red)
            }
        }
    }
}
@available(macOS 15.0, *)
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let prefs = SessionPreferencesStore()
        let vm = SessionListViewModel(preferences: prefs)
        return SettingsView(preferences: prefs, selection: .constant(.general))
            .environmentObject(vm)
    }
}
