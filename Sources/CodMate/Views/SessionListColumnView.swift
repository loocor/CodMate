import SwiftUI

struct SessionListColumnView: View {
    let sections: [SessionDaySection]
    @Binding var selection: Set<SessionSummary.ID>
    @Binding var sortOrder: SessionSortOrder
    let isLoading: Bool
    let isEnriching: Bool
    let enrichmentProgress: Int
    let enrichmentTotal: Int
    let onResume: (SessionSummary) -> Void
    let onReveal: (SessionSummary) -> Void
    let onDeleteRequest: (SessionSummary) -> Void
    let onExportMarkdown: (SessionSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 0)
                .padding(.bottom, 8)

            if isLoading {
                ProgressView("Scanning…")
                    .padding(.vertical)
            } else if isEnriching {
                VStack(spacing: 8) {
                    ProgressView(value: Double(enrichmentProgress), total: Double(enrichmentTotal))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)

                    Text("Enriching session data… \(enrichmentProgress)/\(enrichmentTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical)
            }

            List(selection: $selection) {
                if sections.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Sessions", systemImage: "tray",
                        description: Text(
                            "Adjust directories or launch Codex CLI to generate new session logs."))
                } else {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.sessions, id: \.id) { session in
                                SessionListRowView(summary: session)
                                    .tag(session.id)
                                    .listRowInsets(EdgeInsets())
                                    .contextMenu {
                                        Button {
                                            onResume(session)
                                        } label: {
                                            Label("Resume", systemImage: "play.fill")
                                        }
                                        Button {
                                            onReveal(session)
                                        } label: {
                                            Label("Reveal in Finder", systemImage: "folder")
                                        }
                                        Button {
                                            onExportMarkdown(session)
                                        } label: {
                                            Label(
                                                "Export Markdown",
                                                systemImage: "square.and.arrow.down")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            onDeleteRequest(session)
                                        } label: {
                                            Label("Delete Session", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                Spacer()
                                Label(
                                    section.totalDuration.readableFormattedDuration,
                                    systemImage: "clock")
                                Label("\(section.totalEvents)", systemImage: "chart.bar")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("", selection: $sortOrder) {
                ForEach(SessionSortOrder.allCases) { order in
                    Text(order.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .tag(order)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

extension TimeInterval {
    fileprivate var readableFormattedDuration: String {
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

#Preview {
    // Mock SessionDaySection data
    let mockSections = [
        SessionDaySection(
            id: Date().addingTimeInterval(-86400),  // Yesterday
            title: "Yesterday",
            totalDuration: 7200,  // 2 hours
            totalEvents: 15,
            sessions: [
                SessionSummary(
                    id: "session-1",
                    fileURL: URL(
                        fileURLWithPath: "/Users/developer/.codex/sessions/session-1.json"),
                    fileSizeBytes: 12340,
                    startedAt: Date().addingTimeInterval(-7200),
                    endedAt: Date().addingTimeInterval(-3600),
                    cliVersion: "1.2.3",
                    cwd: "/Users/developer/projects/codmate",
                    originator: "developer",
                    instructions: "Optimize SwiftUI list performance",
                    model: "gpt-4o-mini",
                    approvalPolicy: "auto",
                    userMessageCount: 3,
                    assistantMessageCount: 2,
                    toolInvocationCount: 1,
                    responseCounts: [:],
                    turnContextCount: 5,
                    eventCount: 6,
                    lineCount: 89,
                    lastUpdatedAt: Date().addingTimeInterval(-3600)
                ),
                SessionSummary(
                    id: "session-2",
                    fileURL: URL(
                        fileURLWithPath: "/Users/developer/.codex/sessions/session-2.json"),
                    fileSizeBytes: 8900,
                    startedAt: Date().addingTimeInterval(-10800),
                    endedAt: Date().addingTimeInterval(-9000),
                    cliVersion: "1.2.3",
                    cwd: "/Users/developer/projects/test",
                    originator: "developer",
                    instructions: "Create a to-do app",
                    model: "gpt-4o",
                    approvalPolicy: "manual",
                    userMessageCount: 4,
                    assistantMessageCount: 3,
                    toolInvocationCount: 2,
                    responseCounts: ["reasoning": 1],
                    turnContextCount: 7,
                    eventCount: 9,
                    lineCount: 120,
                    lastUpdatedAt: Date().addingTimeInterval(-9000)
                ),
            ]
        ),
        SessionDaySection(
            id: Date().addingTimeInterval(-172800),  // Day before yesterday
            title: "Dec 15, 2024",
            totalDuration: 5400,  // 1.5 hours
            totalEvents: 12,
            sessions: [
                SessionSummary(
                    id: "session-3",
                    fileURL: URL(
                        fileURLWithPath: "/Users/developer/.codex/sessions/session-3.json"),
                    fileSizeBytes: 15600,
                    startedAt: Date().addingTimeInterval(-172800),
                    endedAt: Date().addingTimeInterval(-158400),
                    cliVersion: "1.2.2",
                    cwd: "/Users/developer/documents",
                    originator: "developer",
                    instructions: "Write technical documentation",
                    model: "gpt-4o-mini",
                    approvalPolicy: "auto",
                    userMessageCount: 6,
                    assistantMessageCount: 5,
                    toolInvocationCount: 3,
                    responseCounts: ["reasoning": 2],
                    turnContextCount: 11,
                    eventCount: 14,
                    lineCount: 200,
                    lastUpdatedAt: Date().addingTimeInterval(-158400)
                )
            ]
        ),
    ]

    return SessionListColumnView(
        sections: mockSections,
        selection: .constant(Set<String>()),
        sortOrder: .constant(.mostRecent),
        isLoading: false,
        isEnriching: false,
        enrichmentProgress: 0,
        enrichmentTotal: 0,
        onResume: { session in print("Resume: \(session.displayName)") },
        onReveal: { session in print("Reveal: \(session.displayName)") },
        onDeleteRequest: { session in print("Delete: \(session.displayName)") },
        onExportMarkdown: { session in print("Export: \(session.displayName)") }
    )
    .frame(width: 500, height: 600)
}

#Preview("Loading State") {
    SessionListColumnView(
        sections: [],
        selection: .constant(Set<String>()),
        sortOrder: .constant(.mostRecent),
        isLoading: true,
        isEnriching: false,
        enrichmentProgress: 0,
        enrichmentTotal: 0,
        onResume: { _ in },
        onReveal: { _ in },
        onDeleteRequest: { _ in },
        onExportMarkdown: { _ in }
    )
    .frame(width: 500, height: 600)
}

#Preview("Empty State") {
    SessionListColumnView(
        sections: [],
        selection: .constant(Set<String>()),
        sortOrder: .constant(.mostRecent),
        isLoading: false,
        isEnriching: false,
        enrichmentProgress: 0,
        enrichmentTotal: 0,
        onResume: { _ in },
        onReveal: { _ in },
        onDeleteRequest: { _ in },
        onExportMarkdown: { _ in }
    )
    .frame(width: 500, height: 600)
}
