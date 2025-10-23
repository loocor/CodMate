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
    var ascending: Bool = false
    var branding: SessionSourceBranding = SessionSource.codex.branding

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                let pos = ascending ? (index + 1) : (turns.count - index)
                ConversationTurnRow(
                    turn: turn,
                    position: pos,
                    isFirst: index == turns.startIndex,
                    isLast: index == turns.count - 1,
                    isExpanded: expandedTurnIDs.contains(turn.id),
                    branding: branding,
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
    let branding: SessionSourceBranding
    let toggleExpanded: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TimelineMarker(
                position: position,
                timeText: timelineTimeFormatter.string(from: turn.timestamp),
                isFirst: isFirst,
                isLast: isLast
            )

            ConversationCard(
                turn: turn,
                isExpanded: isExpanded,
                branding: branding,
                toggle: toggleExpanded
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TimelineMarker: View {
    let position: Int
    let timeText: String
    let isFirst: Bool
    let isLast: Bool

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

            Text(timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.accentColor)

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
    let branding: SessionSourceBranding
    let toggle: () -> Void

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
            Text(turn.actorSummary(using: branding.displayName))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .hoverHand()
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
            EventSegmentView(event: user, branding: branding)
        }

        ForEach(Array(turn.outputs.enumerated()), id: \.offset) { index, event in
            if index > 0 || turn.userMessage != nil {
                Divider()
            }
            EventSegmentView(event: event, branding: branding)
        }
    }
}

private struct EventSegmentView: View {
    let event: TimelineEvent
    let branding: SessionSourceBranding
    @State private var isHover = false

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

            HStack(spacing: 6) {
                if isHover {
                    Button(action: copyEvent) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Copy")
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    .transition(.opacity)
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
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .onHover { inside in withAnimation(.easeInOut(duration: 0.12)) { isHover = inside } }
    }

    private func copyEvent() {
        var lines: [String] = []
        // Role/title
        lines.append("**\(roleTitle)**")
        if let title = event.title, !title.isEmpty, event.actor != .user {
            lines.append(title)
        }
        // Body
        if let text = event.text, !text.isEmpty { lines.append(text) }
        // Metadata
        if let metadata = event.metadata, !metadata.isEmpty {
            for key in metadata.keys.sorted() {
                if let value = metadata[key], !value.isEmpty { lines.append("- \(key): \(value)") }
            }
        }
        let s = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private var roleTitle: String {
        if isAgentReasoning { return "Reasoning" }
        if case .info = event.actor {
            if isTokenUsage { return "Token Usage" }
            if isEnvironment { return "Environment" }
            if isContextUpdate { return "Syncing" }
            return "Info"
        }
        switch event.actor {
        case .user: return "User"
        case .assistant: return branding.displayName
        case .tool: return "Tool"
        case .info: return "Info"
        }
    }

    private var roleIcon: String {
        if isAgentReasoning { return "brain" }
        if case .info = event.actor {
            if isTokenUsage { return "gauge" }
            if isEnvironment { return "macwindow" }
            if isContextUpdate { return "arrow.triangle.2.circlepath" }
            return "info.circle"
        }
        switch event.actor {
        case .user: return "person.fill"
        case .assistant: return branding.symbolName
        case .tool: return "hammer.fill"
        case .info: return "info.circle"
        }
    }

    private var roleColor: Color {
        if isAgentReasoning { return .purple }
        if case .info = event.actor {
            if isTokenUsage { return .orange }
            if isEnvironment { return .gray }
            if isContextUpdate { return .gray }
            return .gray
        }
        switch event.actor {
        case .user: return .accentColor
        case .assistant: return branding.iconColor
        case .tool: return .yellow
        case .info: return .gray
        }
    }

    private var isAgentReasoning: Bool {
        (event.title?.localizedCaseInsensitiveContains("agent reasoning") ?? false)
    }

    private var isTokenUsage: Bool {
        (event.title?.localizedCaseInsensitiveContains("token usage") ?? false)
    }

    private var isEnvironment: Bool {
        (event.title == TimelineEvent.environmentContextTitle)
    }

    private var isContextUpdate: Bool {
        (event.title?.localizedCaseInsensitiveCompare("Context Updated") == .orderedSame)
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
            text: "Please outline a multi-tenant design for the MCP Mate project.",
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
            text: "Certainly. Here are the key considerations for a multi-tenant design...",
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
            expandedTurnIDs: $expanded,
            branding: SessionSource.codex.branding
        )
        .padding()
        .frame(width: 540)
    }
}

// Provide a handy pointer extension to keep cursor behavior consistent on clickable areas
extension View {
    func hoverHand() -> some View {
        self.onHover { inside in
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}
