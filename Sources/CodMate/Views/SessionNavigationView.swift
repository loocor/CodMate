import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SessionNavigationView: View {
    let totalCount: Int
    let isLoading: Bool
    @EnvironmentObject private var viewModel: SessionListViewModel

    @State private var monthStart: Date = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var dimension: DateDimension = .updated
    @State private var showNewProject = false

    var body: some View {
        VStack(spacing: 0) {
            // Projects list only (clean, simplified)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Projects").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        showNewProject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("New Project")
                }

                VStack(spacing: 8) {
                    let visibleAll = viewModel.visibleAllCountForDateScope()
                    let totalAll = viewModel.totalSessionCount
                    scopeAllRow(
                        title: "All",
                        isSelected: viewModel.selectedProjectId == nil,
                        icon: "square.grid.2x2",
                        count: (visibleAll, totalAll),
                        action: { viewModel.setSelectedProject(nil) }
                    )
                    ProjectsListView()
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .frame(maxHeight: .infinity)

            // Bottom (fixed): calendar section (8pt spacing from middle)
            calendarSection
                .padding(.top, 8)
        }
        .frame(idealWidth: 240)
        .task {
            viewModel.ensureCalendarCounts(for: monthStart, dimension: dimension)
            // Ensure dimension is synced on startup
            viewModel.dateDimension = dimension
        }
        .onChange(of: monthStart) { _, m in
            viewModel.ensureCalendarCounts(for: m, dimension: dimension)
        }
        .onChange(of: dimension) { _, d in
            viewModel.ensureCalendarCounts(for: monthStart, dimension: d)
        }
        .sheet(isPresented: $showNewProject) {
            ProjectEditorSheet(isPresented: $showNewProject, mode: .new)
                .environmentObject(viewModel)
        }
    }

    private func scopeAllRow(title: String, isSelected: Bool, icon: String, count: (visible: Int, total: Int)? = nil, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .font(.caption)
            Text(title)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 8)
            if let pair = count {
                Text("\(pair.visible)/\(pair.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
            }
        }
        .frame(height: 16)
        .padding(8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { action() }
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
                selectedDays: viewModel.selectedDays
            ) { picked in
                // Cmd-click toggles selection; plain click selects single day / clears when same
                #if os(macOS)
                let useToggle = (NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
                #else
                let useToggle = false
                #endif
                if useToggle {
                    viewModel.toggleSelectedDay(picked)
                } else {
                    if let current = viewModel.selectedDay,
                       Calendar.current.isDate(current, inSameDayAs: picked) {
                        viewModel.setSelectedDay(nil)
                    } else {
                        viewModel.setSelectedDay(picked)
                    }
                }
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

private enum SidebarMode: Hashable { case directories, projects }

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
