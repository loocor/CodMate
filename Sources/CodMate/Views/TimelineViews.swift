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

#Preview {
    let mockEvents = [
        TimelineEvent(
            id: "event-1",
            timestamp: Date().addingTimeInterval(-3600),
            actor: .user,
            title: nil,
            text: "Please help optimize this SwiftUI app's performance, especially list scrolling stutter.",
            metadata: nil
        ),
        TimelineEvent(
            id: "event-2",
            timestamp: Date().addingTimeInterval(-3500),
            actor: .assistant,
            title: nil,
            text:
                "I'll help optimize SwiftUI list performance. Focus on:\n\n1. Use LazyVStack/LazyVGrid instead of VStack\n2. Reuse views where possible\n3. Optimize data structures\n4. Manage state with @State/@Binding appropriately",
            metadata: nil
        ),
        TimelineEvent(
            id: "event-3",
            timestamp: Date().addingTimeInterval(-3400),
            actor: .tool,
            title: "Code Analysis",
            text: "Analyzing current code structure...",
            metadata: ["lines": "156", "complexity": "medium"]
        ),
        TimelineEvent(
            id: "event-4",
            timestamp: Date().addingTimeInterval(-3300),
            actor: .info,
            title: "Performance Suggestions",
            text: "Potential bottlenecks detected:\n- Rows too heavy\n- Missing view reuse\n- State updates too frequent",
            metadata: ["severity": "high", "category": "performance"]
        ),
        TimelineEvent(
            id: "event-5",
            timestamp: Date().addingTimeInterval(-3200),
            actor: .assistant,
            title: nil,
            text:
                "Based on the analysis, I recommend the following optimizations:\n\n```swift\nstruct OptimizedListView: View {\n    @State private var items: [Item] = []\n    \n    var body: some View {\n        LazyVStack {\n            ForEach(items) { item in\n                OptimizedRowView(item: item)\n            }\n        }\n    }\n}\n```",
            metadata: nil
        ),
    ]

    return TimelineView(events: mockEvents)
        .frame(width: 500, height: 600)
        .padding()
}

#Preview("Empty Timeline") {
    TimelineView(events: [])
        .frame(width: 500, height: 300)
        .padding()
}

#Preview("Single Event") {
    let singleEvent = TimelineEvent(
        id: "single-event",
        timestamp: Date(),
        actor: .user,
        title: nil,
            text: "This is a simple user message to test single timeline event rendering.",
        metadata: nil
    )

    return TimelineView(events: [singleEvent])
        .frame(width: 500, height: 200)
        .padding()
}
