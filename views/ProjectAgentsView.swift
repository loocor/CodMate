import SwiftUI

struct ProjectAgentsView: View {
    let projectDirectory: String
    let preferences: SessionPreferencesStore

    @State private var markdownContent: String = ""
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var viewMode: ViewMode = .preview

    enum ViewMode {
        case code
        case preview
    }

    // Markdown content should always wrap for readability
    private var wrapText: Bool { preferences.gitWrapText }
    private var showLineNumbers: Bool { preferences.gitShowLineNumbers }

    var body: some View {
        VStack(spacing: 0) {
            // Header with mode switcher
            HStack(spacing: 12) {
                Image(systemName: "book.pages")
                    .foregroundStyle(.secondary)
                Text("Agents.md")
                    .font(.headline)

                Spacer()

                // Mode switcher - Preview first, Code second
                Picker("", selection: $viewMode) {
                    Text("Preview").tag(ViewMode.preview)
                    Text("Code").tag(ViewMode.code)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .controlSize(.small)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.trailing, 0) // Align segment with window edge like other workspace modes

            Divider()

            // Content area
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading Agents.md...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                contentView
            }
        }
        .onAppear {
            loadAgentsFile()
        }
        .onChange(of: projectDirectory) { _, _ in
            loadAgentsFile()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .code:
            codeView
        case .preview:
            previewView
        }
    }

    private var codeView: some View {
        detailContainer {
            AttributedTextView(
                text: markdownContent.isEmpty ? "No content" : markdownContent,
                isDiff: false,
                wrap: true, // Markdown should always wrap for readability
                showLineNumbers: showLineNumbers,
                fontSize: 12
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id("agents-code:\(projectDirectory)|wrap:1|ln:\(showLineNumbers ? 1 : 0)")
    }

    private func detailContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
            )
            .padding(16)
    }

    private var previewView: some View {
        detailContainer {
            ScrollView {
                // Use AttributedString for better Markdown rendering
                if let attributed = try? AttributedString(markdown: markdownContent, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    // Fallback to basic Text rendering
                    Text(.init(markdownContent))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }

    private func loadAgentsFile() {
        isLoading = true
        errorMessage = nil

        let agentsURL = URL(fileURLWithPath: projectDirectory).appendingPathComponent("Agents.md")

        // Check if file exists
        guard FileManager.default.fileExists(atPath: agentsURL.path) else {
            isLoading = false
            errorMessage = "Agents.md not found in project directory.\n\nCreate an Agents.md file in your project root to define guidelines, conventions, and context for AI assistants."
            markdownContent = ""
            return
        }

        // Read file content
        do {
            let content = try String(contentsOf: agentsURL, encoding: .utf8)
            markdownContent = content
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = "Failed to read Agents.md:\n\(error.localizedDescription)"
            markdownContent = ""
        }
    }
}
