import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore
    
    var body: some View {
        Form {
            Section {
                LabeledContent("Sessions Root:") {
                    HStack {
                        Text(preferences.sessionsRoot.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button("Choose...") {
                            selectSessionsRoot()
                        }
                    }
                }
                
                LabeledContent("Codex Executable:") {
                    HStack {
                        Text(preferences.codexExecutableURL.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button("Choose...") {
                            selectExecutable()
                        }
                    }
                }
            } header: {
                Text("Paths")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sessions Root: Directory where session files are stored")
                    Text("Codex Executable: Path to the codex command-line tool")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .navigationTitle("Settings")
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
}

#Preview {
    SettingsView(preferences: SessionPreferencesStore())
}
