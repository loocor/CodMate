import SwiftUI

struct CodexSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                section(title: "Providers") {
                    Text("Manage model providers, choose the active provider, and edit connection details. (Scaffold)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                section(title: "Model & Reasoning") {
                    Text("Select model defaults and reasoning options. (Scaffold)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                section(title: "Sandbox & Approvals") {
                    Text("Choose default sandbox and approval policies for Codex.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                section(title: "Notifications") {
                    Text("Enable TUI notifications and bridge turn-complete events to macOS notifications. (Scaffold)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                section(title: "Privacy") {
                    Text("Configure environment propagation, OTEL export, and reasoning visibility. (Scaffold)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                section(title: "Profiles") {
                    Text("Create and manage profiles. Projects can auto-create and sync profiles on rename. (Scaffold)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex Settings")
                .font(.title2)
                .fontWeight(.bold)
            Text("Centralize Codex CLI configuration: providers, notifications, privacy, and profiles")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

#Preview {
    CodexSettingsView()
}

