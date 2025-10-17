import SwiftUI

struct SessionListColumnView: View {
    let sections: [SessionDaySection]
    @Binding var selection: Set<SessionSummary.ID>
    @Binding var sortOrder: SessionSortOrder
    let isLoading: Bool
    let onResume: (SessionSummary) -> Void
    let onReveal: (SessionSummary) -> Void
    let onDeleteRequest: (SessionSummary) -> Void

    var body: some View {
        VStack(spacing: 8) {
            header

            if isLoading {
                ProgressView("正在扫描…")
                    .padding(.vertical)
            }

            List(selection: $selection) {
                if sections.isEmpty && !isLoading {
                    ContentUnavailableView("暂无会话", systemImage: "tray", description: Text("调整目录或启动 Codex CLI 以生成新的会话日志。"))
                } else {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.sessions, id: \.id) { session in
                                SessionListRowView(summary: session)
                                    .tag(session.id)
                                    .contextMenu {
                                        Button {
                                            onResume(session)
                                        } label: {
                                            Label("恢复该会话", systemImage: "play.fill")
                                        }
                                        Button {
                                            onReveal(session)
                                        } label: {
                                            Label("在访达中显示", systemImage: "folder")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            onDeleteRequest(session)
                                        } label: {
                                            Label("删除会话", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                Spacer()
                                Label(section.totalDuration.readableFormattedDuration, systemImage: "clock")
                                Label("\(section.totalEvents)", systemImage: "chart.bar")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("排序", selection: $sortOrder) {
                ForEach(SessionSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension TimeInterval {
    var readableFormattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = durationUnits
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: self) ?? "—"
    }

    private var durationUnits: NSCalendar.Unit {
        if self >= 3600 {
            return [.hour, .minute]
        } else if self >= 60 {
            return [.minute, .second]
        }
        return [.second]
    }
}
