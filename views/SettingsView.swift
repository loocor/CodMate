import AppKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 15.0, *)
struct SettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @Binding private var selectedCategory: SettingCategory
    @StateObject private var codexVM = CodexVM()
    @StateObject private var claudeVM = ClaudeCodeVM()
    @EnvironmentObject private var viewModel: SessionListViewModel
    @State private var showLicensesSheet = false

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
                // Ensure the system titlebar bottom hairline is shown to unify
                // appearance across all settings pages.
                window.titlebarSeparatorStyle = .line

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
                        VStack(alignment: .leading, spacing: 0) {
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
                    .navigationSplitViewColumnWidth(min: 640, ideal: 800, max: 1800)
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(removing: .sidebarToggle)
        }
        .frame(minWidth: 900, minHeight: 520)
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
        case .providers:
            ProvidersSettingsView()
        case .codex:
            codexSettings
        case .claudeCode:
            claudeCodeSettings
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("File Paths").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label("Projects Directory", systemImage: "folder")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("Directory where CodMate stores projects data")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Text(preferences.projectsRoot.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button("Change…", action: selectProjectsRoot)
                                    .buttonStyle(.bordered)
                            }
                            gridDivider
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
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
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Timeline & Markdown").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        visibilitySection(
                            title: "Timeline visibility",
                            systemImage: "text.bubble",
                            description:
                                "Choose which message types appear in the conversation timeline",
                            selection: $preferences.timelineVisibleKinds,
                            defaults: MessageVisibilityKind.timelineDefault
                        )
                        gridDivider
                        visibilitySection(
                            title: "Markdown export",
                            systemImage: "doc.text",
                            description:
                                "Choose which message types are included when exporting Markdown",
                            selection: $preferences.markdownVisibleKinds,
                            defaults: MessageVisibilityKind.markdownDefault
                        )
                    }
                }
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
            VStack(alignment: .leading, spacing: 0) {
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
                    HStack(spacing: 8) {
                        Toggle("", isOn: binding(selection, kind))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Text(kind.title)
                            .font(.subheadline)
                    }
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
            CodexSettingsView(codexVM: codexVM, preferences: preferences)
        }
    }

    private var claudeCodeSettings: some View {
        settingsScroll {
            ClaudeCodeSettingsView(vm: claudeVM, preferences: preferences)
        }
    }

    // MARK: - Dialectics
    private var dialecticsSettings: some View {
        settingsScroll {
            DialecticsPane(preferences: preferences)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("Resume Defaults")
                        .font(.headline)
                        .fontWeight(.semibold)

                    settingsCard {
                        // Two-column grid for aligned controls
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                            // Row: Embedded terminal toggle
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Run in embedded terminal")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("Use the built-in terminal instead of an external one")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Toggle("", isOn: $preferences.defaultResumeUseEmbeddedTerminal)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .gridColumnAlignment(.trailing)
                            }

                            gridDivider

                            // Row: Copy to clipboard
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Copy resume commands to clipboard")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("Automatically copy the resume command when resuming")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Toggle("", isOn: $preferences.defaultResumeCopyToClipboard)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .gridColumnAlignment(.trailing)
                            }

                            gridDivider

                            // Row: Default external app
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
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
                                .padding(2)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                                )
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .gridColumnAlignment(.trailing)
                                .gridCellAnchor(.trailing)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("Codex CLI Defaults").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
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

                            gridDivider

                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
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

                            gridDivider

                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Enable full-auto (--full-auto)")
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("Alias for on-failure approvals with workspace-write sandbox")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Toggle("", isOn: $preferences.defaultResumeFullAuto)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .gridColumnAlignment(.trailing)
                            }

                            gridDivider

                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Bypass approvals & sandbox")
                                        .font(.subheadline).fontWeight(.medium)
                                        .foregroundColor(.red)
                                    Text("--dangerously-bypass-approvals-and-sandbox (use with care)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Toggle("", isOn: $preferences.defaultResumeDangerBypass)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .tint(.red)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
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
                    LabeledContent("Latest Release") {
                        Link(releasesURL.absoluteString, destination: releasesURL)
                    }
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
    private var releasesURL: URL { URL(string: "https://github.com/loocor/CodMate/releases/latest")! }
    private var mcpMateURL: URL { URL(string: "https://mcpmate.io/")! }
    private let mcpMateTagline = "Dedicated MCP orchestration for Codex workflows."

    private static let buildDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df
    }()

    private var mcpServerSettings: some View {
        // Avoid wrapping in ScrollView so the inner List controls scrolling
        MCPServersSettingsPane(openMCPMateDownload: openMCPMateDownload)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 24)
            .padding(.horizontal, 24)
            .padding(.bottom,24)
    }


    private func selectProjectsRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.projectsRoot
        panel.message = "Select the directory where CodMate stores projects data"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await viewModel.updateProjectsRoot(to: url) }
        }
    }

    // Removed Codex/Claude executable choosers – rely on PATH

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
        preferences.projectsRoot = SessionPreferencesStore.defaultProjectsRoot(
            for: FileManager.default.homeDirectoryForCurrentUser)
        preferences.notesRoot = SessionPreferencesStore.defaultNotesRoot(
            for: preferences.sessionsRoot)
        // CLI paths are not user-configurable; rely on PATH
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

    // MARK: - Helper Views

    private func settingsScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 24)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        // Allow the scroll view to clip to its bounds so the system
        // titlebar bottom separator (hairline) remains visible consistently.
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

    @ViewBuilder
    private var gridDivider: some View {
        Divider()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let prefs = SessionPreferencesStore()
        let vm = SessionListViewModel(preferences: prefs)
        return SettingsView(preferences: prefs, selection: .constant(.general))
            .environmentObject(vm)
    }
}
