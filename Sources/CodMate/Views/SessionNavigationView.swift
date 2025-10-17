import SwiftUI

struct SessionNavigationView: View {
    @Binding var selection: SessionNavigationItem
    let totalCount: Int
    let isLoading: Bool
    @EnvironmentObject private var viewModel: SessionListViewModel

    @State private var monthStart: Date = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var dimension: DateDimension = .updated

    private var selectionBinding: Binding<SessionNavigationItem?> {
        Binding<SessionNavigationItem?>(
            get: { selection },
            set: { selection = $0 ?? .allSessions }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section("筛选") {
                Label {
                    HStack {
                        Text(SessionNavigationItem.allSessions.title)
                        Spacer()
                        if isLoading { ProgressView().controlSize(.small) }
                        else { Text("\(totalCount)").foregroundStyle(.secondary) }
                    }
                } icon: { Image(systemName: SessionNavigationItem.allSessions.systemImage) }
                .tag(SessionNavigationItem.allSessions)
            }

            Section(header: headerForCalendar) {
                CalendarMonthView(
                    monthStart: monthStart,
                    counts: viewModel.calendarCounts(for: monthStart, dimension: dimension)
                ) { picked in
                    selection = .calendarDay(picked)
                    viewModel.dateDimension = dimension
                }
            }

            Section("目录") {
                PathTreeView(root: viewModel.pathTreeRoot) { prefix in
                    selection = .pathPrefix(prefix)
                }
                .frame(minHeight: 200)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 18)
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

    private var headerForCalendar: some View {
        HStack {
            Button { monthStart = Calendar.current.date(byAdding: .month, value: -1, to: monthStart)! } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Spacer()
            Picker("维度", selection: $dimension) {
                ForEach(DateDimension.allCases) { dim in
                    Text(dim.title).tag(dim)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Spacer()
            Button { monthStart = Calendar.current.date(byAdding: .month, value: 1, to: monthStart)! } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
        }
    }
}
