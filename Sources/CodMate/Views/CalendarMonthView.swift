import SwiftUI

struct CalendarMonthView: View {
    let monthStart: Date
    let counts: [Int: Int]
    let selectedDays: Set<Date>
    let onSelectDay: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let weekdaySymbols = cal.shortStandaloneWeekdaySymbols
        let grid = monthGrid()
        let spacing: CGFloat = 2

        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let columnWidth = (totalWidth - spacing * 6) / 7

            VStack(spacing: 8) {
                weekdayHeader(
                    weekdaySymbols: weekdaySymbols, columnWidth: columnWidth, spacing: spacing)

                calendarGrid(
                    grid: grid,
                    calendar: cal,
                    columnWidth: columnWidth,
                    spacing: spacing
                )
            }
        }
    }

    private func weekdayHeader(weekdaySymbols: [String], columnWidth: CGFloat, spacing: CGFloat)
        -> some View
    {
        HStack(spacing: spacing) {
            ForEach(weekdaySymbols, id: \.self) { w in
                Text(w)
                    .frame(width: columnWidth)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func calendarGrid(
        grid: [[Int]], calendar: Calendar, columnWidth: CGFloat, spacing: CGFloat
    ) -> some View {
        VStack(spacing: spacing) {
            ForEach(0..<grid.count, id: \.self) { row in
                calendarRow(
                    days: grid[row],
                    calendar: calendar,
                    columnWidth: columnWidth,
                    spacing: spacing
                )
            }
        }
    }

    private func calendarRow(
        days: [Int], calendar: Calendar, columnWidth: CGFloat, spacing: CGFloat
    ) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                dayCell(day: day, calendar: calendar, columnWidth: columnWidth)
            }
        }
    }

    private func dayCell(day: Int, calendar: Calendar, columnWidth: CGFloat) -> some View {
        let isSelected = isSelectedDay(day: day, calendar: calendar)

        return Button {
            if day > 0 {
                let date = calendar.date(bySetting: .day, value: day, of: monthStart)!
                onSelectDay(calendar.startOfDay(for: date))
            }
        } label: {
            dayCellContent(day: day, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .frame(width: columnWidth, height: 38)
        .help(day > 0 ? helpText(for: day, isSelected: isSelected) : "")
    }

    private func dayCellContent(day: Int, isSelected: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(day > 0 ? Color.secondary.opacity(0.06) : Color.clear)

            if day > 0 {
                dayNumber(day: day)
            }

            if day > 0, let count = counts[day], count > 0 {
                sessionCount(count: count)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        )
    }

    private func dayNumber(day: Int) -> some View {
        Text("\(day)")
            .font(.caption)
            .foregroundStyle(.secondary.opacity(0.5))
            .padding(4)
    }

    private func sessionCount(count: Int) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("\(count)")
                    .font(.body.bold())
                    .foregroundStyle(.primary)
                    .padding(4)
            }
        }
    }

    private func isSelectedDay(day: Int, calendar: Calendar) -> Bool {
        guard day > 0 else { return false }
        let cellDate = calendar.startOfDay(
            for: calendar.date(bySetting: .day, value: day, of: monthStart)!)
        for d in selectedDays { if calendar.isDate(d, inSameDayAs: cellDate) { return true } }
        return false
    }

    private func helpText(for day: Int, isSelected: Bool) -> String {
        let count = counts[day] ?? 0
        if isSelected {
            return "\(count) sessions • Click again to clear day filter"
        } else {
            return "\(count) sessions • Click to filter by this day"
        }
    }

    private func monthGrid() -> [[Int]] {
        let cal = Calendar.current
        let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<29
        let firstWeekdayIndex = cal.component(.weekday, from: monthStart) - cal.firstWeekday
        let leading = (firstWeekdayIndex + 7) % 7
        var days = Array(repeating: 0, count: leading) + Array(range)
        while days.count % 7 != 0 { days.append(0) }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) }
    }
}

#Preview {
    let calendar = Calendar.current
    let monthStart = calendar.date(from: DateComponents(year: 2024, month: 12, day: 1))!

    // Mock data with some days having session counts
    let mockCounts: [Int: Int] = [
        3: 2,
        7: 1,
        12: 4,
        15: 1,
        18: 3,
        22: 2,
        25: 1,
        28: 5,
    ]

    return CalendarMonthView(
        monthStart: monthStart,
        counts: mockCounts,
        selectedDays: [calendar.date(from: DateComponents(year: 2024, month: 12, day: 15))!]
    ) { selectedDay in
        print("Selected day: \(selectedDay)")
    }
    .padding()
    .frame(width: 300)
}
