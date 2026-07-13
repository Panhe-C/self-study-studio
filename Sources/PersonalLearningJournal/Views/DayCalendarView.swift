import SwiftUI

public struct DayCalendarView: View {
    @ObservedObject private var viewModel: CalendarViewModel

    private let hourHeight: CGFloat = 64
    private let labelWidth: CGFloat = 48

    public init(viewModel: CalendarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, height: hourHeight, alignment: .topTrailing)
                            .padding(.trailing, 6)
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(height: hourHeight)
                                    .overlay(alignment: .top) { Divider() }
                            }
                        }

                        ForEach(viewModel.items(in: viewModel.visibleRange)) { item in
                            if let start = item.start, let end = item.end {
                                dayEvent(item, start: start, end: end, width: proxy.size.width)
                            }
                        }

                        ForEach(Array(viewModel.busyIntervals.enumerated()), id: \.offset) { _, interval in
                            busyBlock(interval, dayStart: Calendar.current.startOfDay(for: viewModel.focusedDate), width: proxy.size.width)
                        }
                    }
                }
                .frame(height: hourHeight * 24)
            }
        }
    }

    private func busyBlock(_ interval: BusyInterval, dayStart: Date, width: CGFloat) -> some View {
        let minute = interval.start.timeIntervalSince(dayStart) / 60
        let duration = max(15, interval.end.timeIntervalSince(interval.start) / 60)
        return RoundedRectangle(cornerRadius: 6)
            .fill(StudioTheme.mutedSurface.opacity(0.8))
            .overlay { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            .frame(width: max(80, width - 12), height: max(24, duration / 60 * hourHeight))
            .offset(x: 6, y: minute / 60 * hourHeight)
            .accessibilityLabel("Busy time")
    }

    private func dayEvent(
        _ item: CalendarStudyItem,
        start: Date,
        end: Date,
        width: CGFloat
    ) -> some View {
        let dayStart = Calendar.current.startOfDay(for: viewModel.focusedDate)
        let minute = start.timeIntervalSince(dayStart) / 60
        let duration = max(15, end.timeIntervalSince(start) / 60)

        return VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: max(80, width - 12), height: max(32, duration / 60 * hourHeight), alignment: .topLeading)
        .background(eventColor(item).opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(eventColor(item).opacity(0.65))
        }
        .offset(x: 6, y: minute / 60 * hourHeight)
    }

    private func eventColor(_ item: CalendarStudyItem) -> Color {
        if item.bindingState == .externallyModified || item.bindingState == .externallyDeleted {
            return StudioTheme.notice
        }
        return item.status == .completed ? StudioTheme.completed : StudioTheme.planned
    }
}
