import SwiftUI

struct TimelineView: View {
    let events: [TimelineEvent]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(events) { e in
                TimelineBubble(event: e)
            }
        }
    }
}

struct TimelineBubble: View {
    let event: TimelineEvent

    var body: some View {
        HStack {
            if event.actor == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 6) {
                if let title = event.title, event.actor != .assistant && event.actor != .user {
                    Label(title, systemImage: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let text = event.text, !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let meta = event.metadata, !meta.isEmpty {
                    ForEach(meta.keys.sorted(), id: \.self) { k in
                        HStack(spacing: 6) {
                            Text(k + ":").foregroundStyle(.secondary)
                            Text(meta[k] ?? "")
                        }.font(.caption2)
                    }
                }
            }
            .padding(10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 0.5)
            }

            if event.actor == .assistant { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
    }

    private var background: some ShapeStyle {
        switch event.actor {
        case .user:
            return AnyShapeStyle(Color.accentColor.opacity(0.15))
        case .assistant:
            return AnyShapeStyle(Color.secondary.opacity(0.08))
        case .tool:
            return AnyShapeStyle(Color.yellow.opacity(0.12))
        case .info:
            return AnyShapeStyle(Color.gray.opacity(0.08))
        }
    }

    private var border: Color {
        switch event.actor {
        case .user: return .accentColor.opacity(0.25)
        case .assistant: return .secondary.opacity(0.2)
        case .tool: return .yellow.opacity(0.25)
        case .info: return .gray.opacity(0.25)
        }
    }

    private var icon: String {
        switch event.actor {
        case .user: return "person"
        case .assistant: return "sparkles"
        case .tool: return "hammer"
        case .info: return "info.circle"
        }
    }
}
