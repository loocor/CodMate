import SwiftUI

struct CalendarMonthView: View {
    let monthStart: Date
    let counts: [Int: Int]
    let onSelectDay: (Date) -> Void

    private var title: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy年MM月"
        return df.string(from: monthStart)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            let cal = Calendar.current
            let weekdaySymbols = cal.shortStandaloneWeekdaySymbols
            HStack {
                ForEach(weekdaySymbols, id: \.self) { w in
                    Text(w).frame(maxWidth: .infinity).foregroundStyle(.secondary).font(.caption)
                }
            }

            let grid = monthGrid()
            VStack(spacing: 4) {
                ForEach(0..<grid.count, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(grid[row], id: \.self) { day in
                            Button {
                                if day > 0 {
                                    let date = cal.date(bySetting: .day, value: day, of: monthStart)!
                                    onSelectDay(cal.startOfDay(for: date))
                                }
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(day > 0 ? Color.secondary.opacity(0.06) : Color.clear)
                                    VStack(spacing: 2) {
                                        Text(day > 0 ? "\(day)" : "")
                                            .font(.caption)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Group {
                                            if day > 0, let c = counts[day], c > 0 {
                                                Text("\(c)")
                                                    .font(.caption2.bold())
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                                            } else { EmptyView() }
                                        }
                                    }
                                    .padding(6)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: 34)
                        }
                    }
                }
            }
        }
    }

    private func monthGrid() -> [[Int]] {
        let cal = Calendar.current
        let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<29
        let firstWeekdayIndex = cal.component(.weekday, from: monthStart) - cal.firstWeekday
        let leading = (firstWeekdayIndex + 7) % 7
        var days = Array(repeating: 0, count: leading) + Array(range)
        while days.count % 7 != 0 { days.append(0) }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0+7]) }
    }
}
