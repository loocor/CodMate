import SwiftUI

struct SessionNavigationView: View {
    @Binding var selection: SessionNavigationItem
    let totalCount: Int
    let isLoading: Bool
    @EnvironmentObject private var viewModel: SessionListViewModel

    @State private var monthStart: Date = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var dimension: DateDimension = .updated

    private var selectionBinding: Binding<SessionNavigationItem?> {
        Binding<SessionNavigationItem?>(
            get: { selection },
            set: { selection = $0 ?? .allSessions }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            allSessionsRow
                .tag(SessionNavigationItem.allSessions)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .padding(.horizontal, 6)

            calendarSection

            Section() {
                PathTreeView(root: viewModel.pathTreeRoot) { prefix in
                    selection = .pathPrefix(prefix)
                }
                .frame(minHeight: 200)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
        }
        .listStyle(.sidebar)
        .frame(idealWidth: 260)
        .environment(\.defaultMinListRowHeight, 8)
        .environment(\.controlSize, .small)
        .task {
            viewModel.ensurePathTree()
            _ = viewModel.calendarCounts(for: monthStart, dimension: dimension)
        }
        .onChange(of: monthStart) { _, m in
            _ = viewModel.calendarCounts(for: m, dimension: dimension)
        }
        .onChange(of: dimension) { _, d in
            _ = viewModel.calendarCounts(for: monthStart, dimension: d)
        }
    }

    private var allSessionsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: SessionNavigationItem.allSessions.systemImage)
                .foregroundStyle(.tint)
            Text(SessionNavigationItem.allSessions.title)
                .font(.headline)
            Spacer(minLength: 8)
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text(totalCount > 0 ? "\(totalCount)" : "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = .allSessions }
    }

    private var calendarSection: some View {
        Section {
            VStack(spacing: 12) {
                calendarHeader

                HStack {
                    Spacer()
                    Picker("", selection: $dimension) {
                        ForEach(DateDimension.allCases) { dim in
                            Text(dim.title).tag(dim)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    Spacer()
                }

                CalendarMonthView(
                    monthStart: monthStart,
                    counts: viewModel.calendarCounts(for: monthStart, dimension: dimension)
                ) { picked in
                    selection = .calendarDay(picked)
                    viewModel.dateDimension = dimension
                }
                .frame(height: 280)
            }
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        }
    }

    private var calendarHeader: some View {
        let cal = Calendar.current
        let monthTitle: String = {
            let df = DateFormatter()
            df.dateFormat = "MMM yyyy"
            return df.string(from: monthStart)
        }()
        return GeometryReader { geometry in
            let columnWidth = geometry.size.width / 7
            HStack(spacing: 0) {
                Button {
                    monthStart = cal.date(byAdding: .month, value: -1, to: monthStart)!
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: columnWidth, height: 24)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    jumpToToday()
                } label: {
                    Text(monthTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    monthStart = cal.date(byAdding: .month, value: 1, to: monthStart)!
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: columnWidth, height: 24)
                }
                .buttonStyle(.plain)
            }
            .frame(width: geometry.size.width)
        }
        .frame(height: 24)
    }

    private func jumpToToday() {
        let cal = Calendar.current
        let today = Date()
        monthStart = cal.date(from: cal.dateComponents([.year, .month], from: today))!
        let start = cal.startOfDay(for: today)
        selection = .calendarDay(start)
        viewModel.dateDimension = dimension
    }
}

#Preview {
    // Mock ViewModel for preview
    let mockPreferences = SessionPreferencesStore()
    let mockViewModel = SessionListViewModel(preferences: mockPreferences)

    return SessionNavigationView(
        selection: .constant(.allSessions),
        totalCount: 15,
        isLoading: false
    )
    .environmentObject(mockViewModel)
    .frame(width: 280, height: 600)
}

#Preview("Loading State") {
    let mockPreferences = SessionPreferencesStore()
    let mockViewModel = SessionListViewModel(preferences: mockPreferences)

    return SessionNavigationView(
        selection: .constant(.allSessions),
        totalCount: 0,
        isLoading: true
    )
    .environmentObject(mockViewModel)
    .frame(width: 280, height: 600)
}

#Preview("Calendar Day Selected") {
    let mockPreferences = SessionPreferencesStore()
    let mockViewModel = SessionListViewModel(preferences: mockPreferences)

    return SessionNavigationView(
        selection: .constant(.calendarDay(Date())),
        totalCount: 8,
        isLoading: false
    )
    .environmentObject(mockViewModel)
    .frame(width: 280, height: 600)
}

#Preview("Path Selected") {
    let mockPreferences = SessionPreferencesStore()
    let mockViewModel = SessionListViewModel(preferences: mockPreferences)

    return SessionNavigationView(
        selection: .constant(.pathPrefix("/Users/developer/projects")),
        totalCount: 5,
        isLoading: false
    )
    .environmentObject(mockViewModel)
    .frame(width: 280, height: 600)
}
