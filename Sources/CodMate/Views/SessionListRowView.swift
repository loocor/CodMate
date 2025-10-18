import SwiftUI

struct SessionListRowView: View {
    let summary: SessionSummary
    var isRunning: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "rectangle.and.text.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(iconForeground)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.effectiveTitle)
                    .font(.headline)
                HStack(spacing: 12) {
                    Text(summary.startedAt.formatted(date: .numeric, time: .shortened))
                    Text(summary.readableDuration)
                    if let model = summary.model {
                        Text(model)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(summary.commentSnippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                // Compact metrics moved from detail view
                HStack(spacing: 12) {
                    metric(icon: "person", value: summary.userMessageCount)
                    metric(icon: "sparkles", value: summary.assistantMessageCount)
                    metric(icon: "hammer", value: summary.toolInvocationCount)
                    if let reasoning = summary.responseCounts["reasoning"], reasoning > 0 {
                        metric(icon: "brain", value: reasoning)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 8)
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if isRunning {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(Color.green)
                    .font(.system(size: 28, weight: .semibold))
                    .padding(.trailing, 8)
            }
        }
    }
}

private extension SessionListRowView {
    var iconForeground: some ShapeStyle {
        isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.accentColor)
    }
}

private func metric(icon: String, value: Int) -> some View {
    HStack(spacing: 4) {
        Image(systemName: icon)
        Text("\(value)")
    }
}

#Preview {
    let mockSummary = SessionSummary(
        id: "session-preview",
        fileURL: URL(fileURLWithPath: "/Users/developer/.codex/sessions/session-preview.json"),
        fileSizeBytes: 12340,
        startedAt: Date().addingTimeInterval(-3600),
        endedAt: Date().addingTimeInterval(-1800),
        cliVersion: "1.2.3",
        cwd: "/Users/developer/projects/codmate",
        originator: "developer",
        instructions:
            "Please help optimize this SwiftUI app's performance, especially scroll stutter in lists. It should remain smooth with large datasets.",
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

    return SessionListRowView(summary: mockSummary)
        .frame(width: 400, height: 120)
        .padding()
}

#Preview("Short Instructions") {
    let mockSummary = SessionSummary(
        id: "session-short",
        fileURL: URL(fileURLWithPath: "/Users/developer/.codex/sessions/session-short.json"),
        fileSizeBytes: 5600,
        startedAt: Date().addingTimeInterval(-7200),
        endedAt: Date().addingTimeInterval(-6900),
        cliVersion: "1.2.3",
        cwd: "/Users/developer/projects/test",
        originator: "developer",
        instructions: "Create a to-do app",
        model: "gpt-4o",
        approvalPolicy: "manual",
        userMessageCount: 2,
        assistantMessageCount: 1,
        toolInvocationCount: 0,
        responseCounts: [:],
        turnContextCount: 3,
        eventCount: 3,
        lineCount: 45,
        lastUpdatedAt: Date().addingTimeInterval(-6900)
    )

    return SessionListRowView(summary: mockSummary)
        .frame(width: 400, height: 100)
        .padding()
}

#Preview("No Instructions") {
    let mockSummary = SessionSummary(
        id: "session-no-instructions",
        fileURL: URL(
            fileURLWithPath: "/Users/developer/.codex/sessions/session-no-instructions.json"),
        fileSizeBytes: 3200,
        startedAt: Date().addingTimeInterval(-10800),
        endedAt: Date().addingTimeInterval(-10500),
        cliVersion: "1.2.2",
        cwd: "/Users/developer/documents",
        originator: "developer",
        instructions: nil,
        model: "gpt-4o-mini",
        approvalPolicy: "auto",
        userMessageCount: 1,
        assistantMessageCount: 1,
        toolInvocationCount: 0,
        responseCounts: [:],
        turnContextCount: 2,
        eventCount: 2,
        lineCount: 20,
        lastUpdatedAt: Date().addingTimeInterval(-10500)
    )

    return SessionListRowView(summary: mockSummary)
        .frame(width: 400, height: 100)
        .padding()
}
