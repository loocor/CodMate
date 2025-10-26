import SwiftUI

struct ProviderEditorView: View {
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
                    VStack(alignment: .leading, spacing: 0) {
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
                    VStack(alignment: .leading, spacing: 0) {
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
                    VStack(alignment: .leading, spacing: 0) {
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
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Wire API").font(.subheadline).fontWeight(.medium)
                        Text("Protocol: chat or responses (optional).").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "responses",
                        text: Binding(get: { draft.wireAPI ?? "" }, set: { draft.wireAPI = $0 }))
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
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
                    VStack(alignment: .leading, spacing: 0) {
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
                    VStack(alignment: .leading, spacing: 0) {
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
                    VStack(alignment: .leading, spacing: 0) {
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
                    VStack(alignment: .leading, spacing: 0) {
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
                    VStack(alignment: .leading, spacing: 0) {
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
