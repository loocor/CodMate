import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gear") }
            llmTab
                .tabItem { Label("LLM", systemImage: "brain") }
        }
        .frame(width: 520, height: 360)
        .padding()
    }

    private var generalTab: some View {
        Form {
            LabeledContent("Sessions 目录") {
                HStack {
                    Text(preferences.sessionsRoot.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("更改…", action: { /* 留待实现 */ })
                        .disabled(true)
                }
            }
            LabeledContent("Codex CLI 路径") {
                HStack {
                    Text(preferences.codexExecutableURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("更改…", action: { /* 留待实现 */ })
                        .disabled(true)
                }
            }
        }
    }

    private var llmTab: some View {
        Form {
            LabeledContent("API Base URL") {
                TextField("例如 https://api.openai.com", text: $preferences.llmBaseURL)
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
            Toggle("自动生成标题与摘要", isOn: $preferences.llmAutoGenerate)
        }
    }
}
