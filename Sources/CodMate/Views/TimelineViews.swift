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
            text: "请帮我优化这个 SwiftUI 应用的性能，特别是列表滚动时的卡顿问题。",
            metadata: nil
        ),
        TimelineEvent(
            id: "event-2",
            timestamp: Date().addingTimeInterval(-3500),
            actor: .assistant,
            title: nil,
            text:
                "我来帮你优化 SwiftUI 列表的性能。主要可以从以下几个方面入手：\n\n1. 使用 LazyVStack 或 LazyVGrid 替代 VStack\n2. 实现视图的复用机制\n3. 优化数据源结构\n4. 使用 @State 和 @Binding 合理管理状态",
            metadata: nil
        ),
        TimelineEvent(
            id: "event-3",
            timestamp: Date().addingTimeInterval(-3400),
            actor: .tool,
            title: "代码分析",
            text: "正在分析当前代码结构...",
            metadata: ["lines": "156", "complexity": "medium"]
        ),
        TimelineEvent(
            id: "event-4",
            timestamp: Date().addingTimeInterval(-3300),
            actor: .info,
            title: "性能建议",
            text: "检测到可能的性能瓶颈：\n- 列表项过于复杂\n- 缺少视图复用\n- 状态更新过于频繁",
            metadata: ["severity": "high", "category": "performance"]
        ),
        TimelineEvent(
            id: "event-5",
            timestamp: Date().addingTimeInterval(-3200),
            actor: .assistant,
            title: nil,
            text:
                "基于分析结果，我建议你采用以下优化方案：\n\n```swift\nstruct OptimizedListView: View {\n    @State private var items: [Item] = []\n    \n    var body: some View {\n        LazyVStack {\n            ForEach(items) { item in\n                OptimizedRowView(item: item)\n            }\n        }\n    }\n}\n```",
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
        text: "这是一个简单的用户消息，用于测试单条时间线事件的显示效果。",
        metadata: nil
    )

    return TimelineView(events: [singleEvent])
        .frame(width: 500, height: 200)
        .padding()
}
