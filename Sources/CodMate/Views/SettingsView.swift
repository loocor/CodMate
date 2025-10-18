import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @Binding private var selectedCategory: SettingCategory

    init(preferences: SessionPreferencesStore, selection: Binding<SettingCategory>) {
        self._preferences = ObservedObject(wrappedValue: preferences)
        self._selectedCategory = selection
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hidden view for window configuration
            WindowConfigurator { window in
                window.isMovableByWindowBackground = true
            }
            .frame(width: 0, height: 0)

            HStack(spacing: 0) {
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
                    .padding(.vertical, 8)
                    .tag(category)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 200, idealWidth: 200, maxWidth: 200, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)

                ScrollView {
                    selectedCategoryView
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 560)
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
        case .about:
            aboutSettings
        }
    }

    private var generalSettings: some View {
        ScrollView {
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
                                Label("Codex CLI Path", systemImage: "terminal")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Path to the codex executable")
                                    .font(.caption).foregroundColor(.secondary)
                            }

                            Text(preferences.codexExecutableURL.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Button("Change…", action: selectExecutable)
                                .buttonStyle(.bordered)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Button("Reset All Settings to Defaults") { resetToDefaults() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    Text("Restores sessions root, CLI path, and command options to factory defaults.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var terminalSettings: some View {
        ScrollView {
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
        ScrollView {
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
        ScrollView {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("CodMate is a macOS companion for managing Codex CLI sessions.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
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

    private static let buildDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df
    }()

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
            preferences.sessionsRoot = url
        }
    }

    private func selectExecutable() {
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

    private func resetToDefaults() {
        preferences.sessionsRoot = SessionPreferencesStore.defaultSessionsRoot(
            for: FileManager.default.homeDirectoryForCurrentUser)
        preferences.codexExecutableURL = SessionPreferencesStore.defaultExecutableURL()
        preferences.defaultResumeUseEmbeddedTerminal = true
        preferences.defaultResumeCopyToClipboard = true
        preferences.defaultResumeExternalApp = .terminal
        preferences.defaultResumeSandboxMode = .workspaceWrite
        preferences.defaultResumeApprovalPolicy = .onRequest
        preferences.defaultResumeFullAuto = false
        preferences.defaultResumeDangerBypass = false
    }
}

#Preview {
    let mockPreferences = SessionPreferencesStore()
    return SettingsView(preferences: mockPreferences, selection: .constant(.general))
}

#Preview("With Custom Paths") {
    let mockPreferences = SessionPreferencesStore()
    mockPreferences.sessionsRoot = URL(fileURLWithPath: "/Users/developer/.codex/sessions")
    mockPreferences.codexExecutableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")

    return SettingsView(preferences: mockPreferences, selection: .constant(.command))
}
