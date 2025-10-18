import AppKit
import SwiftUI

private let timelineTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

struct ConversationTimelineView: View {
    let turns: [ConversationTurn]
    @Binding var expandedTurnIDs: Set<String>

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                ConversationTurnRow(
                    turn: turn,
                    position: index + 1,
                    isFirst: index == turns.startIndex,
                    isLast: index == turns.count - 1,
                    isExpanded: expandedTurnIDs.contains(turn.id),
                    toggleExpanded: { toggle(turn) }
                )
            }
        }
    }

    private func toggle(_ turn: ConversationTurn) {
        if expandedTurnIDs.contains(turn.id) {
            expandedTurnIDs.remove(turn.id)
        } else {
            expandedTurnIDs.insert(turn.id)
        }
    }
}

private struct ConversationTurnRow: View {
    let turn: ConversationTurn
    let position: Int
    let isFirst: Bool
    let isLast: Bool
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TimelineMarker(
                position: position,
                timeText: timelineTimeFormatter.string(from: turn.timestamp),
                isFirst: isFirst,
                isLast: isLast,
                toggle: toggleExpanded
            )

            Button(action: toggleExpanded) {
                ConversationCard(turn: turn, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TimelineMarker: View {
    let position: Int
    let timeText: String
    let isFirst: Bool
    let isLast: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(String(position))
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.accentColor)
                )

            Button(action: toggle) {
                Text(timeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(isFirst ? 0 : 0.25))
                    .frame(width: 2)
                    .frame(height: isFirst ? 0 : 12)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 12)

                Rectangle()
                    .fill(Color.secondary.opacity(isLast ? 0 : 0.25))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 72, alignment: .top)
    }
}

private struct ConversationCard: View {
    let turn: ConversationTurn
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                expandedBody
            } else {
                collapsedBody
            }
        }
        .padding(16)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 14
            )
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 14
            )
            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text(turn.actorSummary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var collapsedBody: some View {
        if let preview = turn.previewText, !preview.isEmpty {
            Text(preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Tap to view details")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        if let user = turn.userMessage {
            EventSegmentView(event: user)
        }

        ForEach(Array(turn.outputs.enumerated()), id: \.offset) { index, event in
            if index > 0 || turn.userMessage != nil {
                Divider()
            }
            EventSegmentView(event: event)
        }
    }
}

private struct EventSegmentView: View {
    let event: TimelineEvent

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(roleTitle)
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: roleIcon)
                        .foregroundStyle(roleColor)
                }
                .labelStyle(.titleAndIcon)

                if let title = event.title, !title.isEmpty, event.actor != .user {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let text = event.text, !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let metadata = event.metadata, !metadata.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(metadata.keys.sorted(), id: \.self) { key in
                            if let value = metadata[key], !value.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(key + ":")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(value)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if event.repeatCount > 1 {
                Text("×\(event.repeatCount)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var roleTitle: String {
        switch event.actor {
        case .user: return "User"
        case .assistant: return "Codex"
        case .tool: return "Tool"
        case .info: return "Info"
        }
    }

    private var roleIcon: String {
        switch event.actor {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .tool: return "hammer.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var roleColor: Color {
        switch event.actor {
        case .user: return .accentColor
        case .assistant: return .blue
        case .tool: return .yellow
        case .info: return .gray
        }
    }
}

#Preview {
    ConversationTimelinePreview()
}

private struct ConversationTimelinePreview: View {
    @State private var expanded: Set<String> = []

    private var sampleTurn: ConversationTurn {
        let now = Date()
        let userEvent = TimelineEvent(
            id: UUID().uuidString,
            timestamp: now,
            actor: .user,
            title: nil,
            text: "请帮我梳理 MCP Mate 项目的多租户设计思路。",
            metadata: nil
        )
        let infoEvent = TimelineEvent(
            id: UUID().uuidString,
            timestamp: now.addingTimeInterval(6),
            actor: .info,
            title: "Context Updated",
            text: "model: gpt-5-codex\npolicy: on-request",
            metadata: nil,
            repeatCount: 3
        )
        let assistantEvent = TimelineEvent(
            id: UUID().uuidString,
            timestamp: now.addingTimeInterval(12),
            actor: .assistant,
            title: nil,
            text: "当然可以，以下是多租户设计需要考虑的关键要点……",
            metadata: nil
        )
        return ConversationTurn(
            id: UUID().uuidString,
            timestamp: now,
            userMessage: userEvent,
            outputs: [infoEvent, assistantEvent]
        )
    }

    var body: some View {
        ConversationTimelineView(
            turns: [sampleTurn],
            expandedTurnIDs: $expanded
        )
        .padding()
        .frame(width: 540)
    }
}
