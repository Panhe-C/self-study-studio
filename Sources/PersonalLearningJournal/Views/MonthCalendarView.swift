import SwiftUI

public struct MonthCalendarView: View {
    @ObservedObject private var viewModel: CalendarViewModel

    private let columns = Array(repeating: GridItem(.flexible(minimum: 40), spacing: 1), count: 7)

    public init(viewModel: CalendarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }

                ForEach(gridDays, id: \.self) { day in
                    dayCell(day)
                }
            }
            .background(Color.secondary.opacity(0.12))
        }
    }

    private var weekdaySymbols: [String] {
        var symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let offset = max(0, Calendar.current.firstWeekday - 1)
        symbols = Array(symbols[offset...] + symbols[..<offset])
        return symbols
    }

    private var gridDays: [Date] {
        let calendar = Calendar.current
        let monthStart = viewModel.visibleRange.start
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) ?? monthStart
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func dayCell(_ day: Date) -> some View {
        let workload = viewModel.workloadMinutes(on: day)
        let deadlines = viewModel.deadlines(on: day)
        let isInMonth = Calendar.current.isDate(day, equalTo: viewModel.focusedDate, toGranularity: .month)
        let hasConflict = deadlines.contains {
            $0.bindingState == .externallyModified || $0.bindingState == .externallyDeleted
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(day, format: .dateTime.day())
                    .font(.caption.weight(Calendar.current.isDateInToday(day) ? .bold : .regular))
                Spacer(minLength: 0)
                if hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if workload > 0 {
                Label("\(workload)m", systemImage: "clock")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
            }
            if !deadlines.isEmpty {
                Label("\(deadlines.count)", systemImage: "flag.fill")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.indigo)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(isInMonth ? Color.primary.opacity(0.04) : Color.clear)
        .foregroundStyle(isInMonth ? .primary : .tertiary)
    }
}
