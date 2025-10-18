import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @State private var selectedCategory: SettingCategory = .general

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
        .frame(minWidth: 600, minHeight: 460)
    }

    @ViewBuilder
    private var selectedCategoryView: some View {
        switch selectedCategory {
        case .general:
            generalSettings
        case .terminal:
            terminalSettings
        case .llm:
            llmSettings
        case .advanced:
            advancedSettings
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

                    // Use a 3-column Grid: [label+help] | [value] | [button]
                    // so names and values are horizontally aligned across rows.
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        // Row: Sessions Directory
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Sessions Directory", systemImage: "folder")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Directory where Codex session files are stored")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .gridColumnAlignment(.leading)

                            Text(preferences.sessionsRoot.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .gridColumnAlignment(.trailing)

                            Button("Change…", action: selectSessionsRoot)
                                .buttonStyle(.bordered)
                        }

                        // Row: Codex CLI Path
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Codex CLI Path", systemImage: "terminal")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Path to the codex executable")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .gridColumnAlignment(.leading)

                            Text(preferences.codexExecutableURL.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .gridColumnAlignment(.trailing)

                            Button("Change…", action: selectExecutable)
                                .buttonStyle(.bordered)
                        }
                    }
                    // Align grid with the left edge of the section header,
                    // keep top/bottom/trailing breathing room.
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
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
                            .frame(maxWidth: 280)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .gridColumnAlignment(.trailing)
                            .gridCellAnchor(.trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }
            }
        }
    }

    private var llmSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LLM Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure AI model settings for automatic title and summary generation")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("API Configuration")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                        // Base URL
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("API Base URL", systemImage: "globe")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("The base URL for the LLM API endpoint")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            TextField("e.g. https://api.openai.com", text: $preferences.llmBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 400)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        // API Key
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("API Key", systemImage: "key")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Your API key for authentication (stored securely)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            SecureField("sk-...", text: $preferences.llmAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 400)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        // Model
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Model", systemImage: "brain")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("The AI model to use for generation")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            TextField("gpt-4o-mini", text: $preferences.llmModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }

                // 功能设置
                VStack(alignment: .leading, spacing: 16) {
                    Text("Features")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Auto-generate title & summary")
                                    .font(.subheadline).fontWeight(.medium)
                                Text(
                                    "Automatically generate titles and summaries for new sessions using AI"
                                )
                                .font(.caption).foregroundColor(.secondary)
                            }
                            Toggle("", isOn: $preferences.llmAutoGenerate)
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }
            }
        }
    }

    private var advancedSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Advanced Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Advanced options and debugging settings")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Debugging")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Enable debug logging", systemImage: "ladybug")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Enable detailed logging and debugging information")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Toggle("", isOn: .constant(false))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Reset")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Reset All Settings", systemImage: "arrow.clockwise")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Reset all settings to their default values")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Button("Reset to Defaults", action: resetToDefaults)
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }
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
        preferences.llmBaseURL = "https://api.openai.com"
        preferences.llmAPIKey = ""
        preferences.llmModel = "gpt-4o-mini"
        preferences.llmAutoGenerate = false
        preferences.defaultResumeUseEmbeddedTerminal = true
        preferences.defaultResumeCopyToClipboard = true
        preferences.defaultResumeExternalApp = .terminal
    }
}

#Preview {
    let mockPreferences = SessionPreferencesStore()
    return SettingsView(preferences: mockPreferences)
}

#Preview("With Custom Paths") {
    let mockPreferences = SessionPreferencesStore()
    mockPreferences.sessionsRoot = URL(fileURLWithPath: "/Users/developer/.codex/sessions")
    mockPreferences.codexExecutableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    mockPreferences.llmBaseURL = "https://api.openai.com"
    mockPreferences.llmAPIKey = "sk-1234567890abcdef"
    mockPreferences.llmModel = "gpt-4o"
    mockPreferences.llmAutoGenerate = true

    return SettingsView(preferences: mockPreferences)
}
