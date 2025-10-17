import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionDetailView: View {
    let summary: SessionSummary
    let isProcessing: Bool
    let onResume: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var events: [TimelineEvent] = []
    @State private var loadingTimeline = false
    private let loader = SessionTimelineLoader()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                metaSection
                instructionsSection

                Divider()

                Group {
                    if loadingTimeline {
                        ProgressView("Loading session content…")
                    } else if events.isEmpty {
                        ContentUnavailableView("No messages to display", systemImage: "text.bubble")
                    } else {
                        TimelineView(events: events)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: summary.id) {
            loadingTimeline = true
            defer { loadingTimeline = false }
            do { events = try loader.load(url: summary.fileURL) } catch { events = [] }
        }
    }

    // moved actions to fixed top bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.displayName)
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 12) {
                Label(
                    summary.startedAt.formatted(date: .numeric, time: .shortened),
                    systemImage: "calendar")
                Label(summary.readableDuration, systemImage: "clock")
                if let model = summary.model {
                    Label(model, systemImage: "cpu")
                }
                if let approval = summary.approvalPolicy {
                    Label(approval, systemImage: "checkmark.shield")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    // metrics moved to list row per request

    private var metaSection: some View {
        GroupBox("Session Info") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow(title: "CLI VERSION", value: summary.cliVersion, icon: "terminal")
                infoRow(title: "Originator", value: summary.originator, icon: "person.circle")
                infoRow(title: "WORKING DIRECTORY", value: summary.cwd, icon: "folder")
                infoRow(title: "FILE SIZE", value: summary.fileSizeDisplay, icon: "externaldrive")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
            }
        }
    }

    @State private var instructionsExpanded = false
    @State private var instructionsLoading = false
    @State private var instructionsText: String?

    private var instructionsSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $instructionsExpanded) {
                Group {
                    if instructionsLoading {
                        ProgressView("Loading instructions…")
                    } else if let text = instructionsText ?? summary.instructions, !text.isEmpty {
                        Text(text)
                            .font(.system(.body, design: .rounded))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    } else {
                        Text("No instructions found.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .task(id: instructionsExpanded) {
                    guard instructionsExpanded else { return }
                    if instructionsText == nil
                        && (summary.instructions == nil || summary.instructions?.isEmpty == true)
                    {
                        instructionsLoading = true
                        defer { instructionsLoading = false }
                        if let loaded = try? loader.loadInstructions(url: summary.fileURL) {
                            instructionsText = loaded
                        }
                    }
                }
            } label: {
                Label("Task Instructions", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

// MARK: - Export
extension SessionDetailView {
    private func exportMarkdown() {
        let md = buildMarkdown()
        let panel = NSSavePanel()
        panel.title = "Export Markdown"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = summary.displayName + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? md.data(using: .utf8)?.write(to: url)
        }
    }

    private func buildMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(summary.displayName)")
        lines.append("")
        lines.append("- Started: \(summary.startedAt)")
        if let end = summary.lastUpdatedAt { lines.append("- Last Updated: \(end)") }
        if let model = summary.model { lines.append("- Model: \(model)") }
        if let approval = summary.approvalPolicy { lines.append("- Approval Policy: \(approval)") }
        lines.append("")
        for e in events {
            let prefix: String
            switch e.actor {
            case .user: prefix = "**User**"
            case .assistant: prefix = "**Assistant**"
            case .tool: prefix = "**Tool**"
            case .info: prefix = "**Info**"
            }
            lines.append("\(prefix) · \(e.timestamp)\n")
            if let title = e.title { lines.append("> \(title)") }
            if let text = e.text, !text.isEmpty { lines.append(text) }
            if let meta = e.metadata, !meta.isEmpty {
                lines.append("")
                for k in meta.keys.sorted() {
                    lines.append("- \(k): \(meta[k] ?? "")")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

#Preview {
    // Mock SessionSummary data
    let mockSummary = SessionSummary(
        id: "session-123",
        fileURL: URL(fileURLWithPath: "/Users/developer/.codex/sessions/session-123.json"),
        fileSizeBytes: 15420,
        startedAt: Date().addingTimeInterval(-3600),  // 1 hour ago
        endedAt: Date().addingTimeInterval(-1800),  // 30 minutes ago
        cliVersion: "1.2.3",
        cwd: "/Users/developer/projects/codmate",
        originator: "developer",
        instructions: "Please help optimize this SwiftUI app's performance, especially list scroll stutter.",
        model: "gpt-4o-mini",
        approvalPolicy: "auto",
        userMessageCount: 5,
        assistantMessageCount: 4,
        toolInvocationCount: 3,
        responseCounts: ["reasoning": 2],
        turnContextCount: 8,
        eventCount: 12,
        lineCount: 156,
        lastUpdatedAt: Date().addingTimeInterval(-1800)
    )

    return SessionDetailView(
        summary: mockSummary,
        isProcessing: false,
        onResume: { print("Resume session") },
        onReveal: { print("Reveal in Finder") },
        onDelete: { print("Delete session") }
    )
    .frame(width: 600, height: 800)
}

#Preview("Processing State") {
    let mockSummary = SessionSummary(
        id: "session-456",
        fileURL: URL(fileURLWithPath: "/Users/developer/.codex/sessions/session-456.json"),
        fileSizeBytes: 8200,
        startedAt: Date().addingTimeInterval(-7200),
        endedAt: nil,
        cliVersion: "1.2.3",
        cwd: "/Users/developer/projects/test",
        originator: "developer",
        instructions: "Create a simple to-do app",
        model: "gpt-4o",
        approvalPolicy: "manual",
        userMessageCount: 3,
        assistantMessageCount: 2,
        toolInvocationCount: 1,
        responseCounts: [:],
        turnContextCount: 5,
        eventCount: 6,
        lineCount: 89,
        lastUpdatedAt: Date().addingTimeInterval(-300)
    )

    return SessionDetailView(
        summary: mockSummary,
        isProcessing: true,
        onResume: { print("Resume session") },
        onReveal: { print("Reveal in Finder") },
        onDelete: { print("Delete session") }
    )
    .frame(width: 600, height: 800)
}
