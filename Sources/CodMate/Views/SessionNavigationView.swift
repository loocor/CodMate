import SwiftUI

struct SessionNavigationView: View {
    let totalCount: Int
    let isLoading: Bool
    @EnvironmentObject private var viewModel: SessionListViewModel

    @State private var monthStart: Date = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var dimension: DateDimension = .updated

    var body: some View {
        VStack(spacing: 0) {
            // 顶部固定：All Sessions
            allSessionsRow
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            Divider()

            // 中部可滚动：目录树
            PathTreeView(
                root: viewModel.pathTreeRoot,
                selectedPath: $viewModel.selectedPath
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)  // Add 8pt spacing below divider
            .frame(maxHeight: .infinity)

            // 底部固定：日历区域（与目录树间隔 8pt）
            calendarSection
                .padding(.top, 8)
        }
        .frame(idealWidth: 260)
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
        let isSelected = viewModel.selectedPath == nil && viewModel.selectedDay == nil

        return HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.caption)

            Text("All Sessions")
                .font(.caption)

            Spacer(minLength: 8)

            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text(totalCount > 0 ? "\(totalCount)" : "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 16)
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.5) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.clearAllFilters()
        }
    }

    private var calendarSection: some View {
        return VStack(spacing: 4) {
            calendarHeader

            Picker("", selection: $dimension) {
                ForEach(DateDimension.allCases) { dim in
                    Text(dim.title).tag(dim)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: dimension) { _, newDim in
                viewModel.dateDimension = newDim
            }

            CalendarMonthView(
                monthStart: monthStart,
                counts: viewModel.calendarCounts(for: monthStart, dimension: dimension),
                selectedDay: viewModel.selectedDay
            ) { picked in
                viewModel.setSelectedDay(picked)
            }
        }
        .frame(height: 280)
        .padding(8)
    }

    private var calendarHeader: some View {
        let cal = Calendar.current
        let monthTitle: String = {
            let df = DateFormatter()
            df.dateFormat = "MMM yyyy"
            return df.string(from: monthStart)
        }()
        return GeometryReader { geometry in
            let columnWidth = geometry.size.width / 16
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
        viewModel.setSelectedDay(start)
        viewModel.dateDimension = dimension
    }
}

#Preview {
    // Mock ViewModel for preview
    let mockPreferences = SessionPreferencesStore()
    let mockViewModel = SessionListViewModel(preferences: mockPreferences)

    return SessionNavigationView(
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
        totalCount: 0,
        isLoading: true
    )
    .environmentObject(mockViewModel)
    .frame(width: 280, height: 600)
}

#Preview("Calendar Day Selected") {
    let mockPreferences = SessionPreferencesStore()
    let mockViewModel = SessionListViewModel(preferences: mockPreferences)
    mockViewModel.setSelectedDay(Date())

    return SessionNavigationView(
        totalCount: 8,
        isLoading: false
    )
    .environmentObject(mockViewModel)
    .frame(width: 280, height: 600)
}

#Preview("Path Selected") {
    let mockPreferences = SessionPreferencesStore()
    let mockViewModel = SessionListViewModel(preferences: mockPreferences)
    mockViewModel.setSelectedPath("/Users/developer/projects")

    return SessionNavigationView(
        totalCount: 5,
        isLoading: false
    )
    .environmentObject(mockViewModel)
    .frame(width: 280, height: 600)
}
