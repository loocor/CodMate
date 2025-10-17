import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            llmTab
                .tabItem { Label("LLM", systemImage: "brain") }
        }
        .frame(width: 520, height: 360)
        .padding()
    }

    private var generalTab: some View {
        Form {
            LabeledContent("Sessions Directory") {
                HStack {
                    Text(preferences.sessionsRoot.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…", action: { /* to be implemented */  })
                        .disabled(true)
                }
            }
            LabeledContent("Codex CLI Path") {
                HStack {
                    Text(preferences.codexExecutableURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…", action: { /* to be implemented */  })
                        .disabled(true)
                }
            }
        }
    }

    private var llmTab: some View {
        Form {
            LabeledContent("API Base URL") {
                TextField("e.g. https://api.openai.com", text: $preferences.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            LabeledContent("API Key") {
                SecureField("sk-...", text: $preferences.llmAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            LabeledContent("Model") {
                TextField("gpt-4o-mini", text: $preferences.llmModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            Toggle("Auto-generate title & summary", isOn: $preferences.llmAutoGenerate)
        }
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
