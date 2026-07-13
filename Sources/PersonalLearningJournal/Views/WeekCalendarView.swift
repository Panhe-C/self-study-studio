import SwiftUI

public struct CalendarTimelineFrame: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}

public struct WeekTimelineLayout: Equatable, Sendable {
    public var pointsPerMinute: Double
    public var minimumDurationMinutes: Int
    public var snapMinutes: Int

    public init(
        pointsPerMinute: Double,
        minimumDurationMinutes: Int = 15,
        snapMinutes: Int = 15
    ) {
        self.pointsPerMinute = max(0.1, pointsPerMinute)
        self.minimumDurationMinutes = max(1, minimumDurationMinutes)
        self.snapMinutes = max(1, snapMinutes)
    }

    public func move(_ frame: CalendarTimelineFrame, byY offset: Double) -> CalendarTimelineFrame {
        let minutes = snappedMinutes(forPoints: offset)
        let delta = TimeInterval(minutes * 60)
        return CalendarTimelineFrame(
            start: frame.start.addingTimeInterval(delta),
            end: frame.end.addingTimeInterval(delta)
        )
    }

    public func resize(_ frame: CalendarTimelineFrame, byY offset: Double) -> CalendarTimelineFrame {
        let currentMinutes = Int(frame.duration / 60)
        let resizedMinutes = max(
            minimumDurationMinutes,
            currentMinutes + snappedMinutes(forPoints: offset)
        )
        return CalendarTimelineFrame(
            start: frame.start,
            end: frame.start.addingTimeInterval(TimeInterval(resizedMinutes * 60))
        )
    }

    public func yOffset(for date: Date, dayStart: Date) -> Double {
        date.timeIntervalSince(dayStart) / 60 * pointsPerMinute
    }

    public func height(for frame: CalendarTimelineFrame) -> Double {
        max(Double(minimumDurationMinutes), frame.duration / 60) * pointsPerMinute
    }

    private func snappedMinutes(forPoints points: Double) -> Int {
        let rawMinutes = points / pointsPerMinute
        return Int((rawMinutes / Double(snapMinutes)).rounded()) * snapMinutes
    }
}

public struct WeekCalendarView: View {
    @ObservedObject private var viewModel: CalendarViewModel

    private let hourHeight: CGFloat = 60
    private let hourLabelWidth: CGFloat = 44
    private let dayWidth: CGFloat = 112

    public init(viewModel: CalendarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 0) {
                dayHeader
                HStack(alignment: .top, spacing: 0) {
                    hourLabels
                    ForEach(days, id: \.self) { day in
                        dayColumn(day)
                    }
                }
            }
        }
        .scrollIndicators(.visible)
    }

    private var days: [Date] {
        let calendar = Calendar.current
        return (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: viewModel.visibleRange.start)
        }
    }

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: hourLabelWidth, height: 46)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(day, format: .dateTime.day())
                        .font(.headline)
                }
                .frame(width: dayWidth, height: 46)
                .background(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.12) : Color.clear)
            }
        }
        .background(.bar)
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d", hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: hourLabelWidth, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 6)
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let range = DateInterval(start: dayStart, end: dayEnd)
        let items = viewModel.items(in: range)

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: dayWidth, height: hourHeight)
                        .overlay(alignment: .top) {
                            Divider()
                        }
                }
            }

            ForEach(items) { item in
                if let start = item.start, let end = item.end {
                    eventBlock(item, start: start, end: end, dayStart: dayStart)
                }
            }
        }
        .frame(width: dayWidth, height: hourHeight * 24)
        .overlay(alignment: .leading) { Divider() }
    }

    private func eventBlock(
        _ item: CalendarStudyItem,
        start: Date,
        end: Date,
        dayStart: Date
    ) -> some View {
        let layout = WeekTimelineLayout(pointsPerMinute: 1)
        let frame = CalendarTimelineFrame(start: start, end: end)
        let y = layout.yOffset(for: start, dayStart: dayStart)
        let height = max(24, layout.height(for: frame))

        return VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Text(start, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 24, height: 3)
                .frame(maxWidth: .infinity)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onEnded { value in
                            let resized = layout.resize(frame, byY: value.translation.height)
                            viewModel.resizePlacement(
                                item.plannedSessionID,
                                toMinutes: Int(resized.duration / 60)
                            )
                        }
                )
        }
        .padding(5)
        .frame(width: dayWidth - 8, height: height, alignment: .topLeading)
        .background(eventColor(item).opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(eventColor(item).opacity(0.55), lineWidth: 1)
        }
        .offset(x: 4, y: y)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    let moved = layout.move(frame, byY: value.translation.height)
                    viewModel.movePlacement(
                        item.plannedSessionID,
                        byMinutes: Int(moved.start.timeIntervalSince(frame.start) / 60)
                    )
                }
        )
    }

    private func eventColor(_ item: CalendarStudyItem) -> Color {
        switch item.bindingState {
        case .externallyModified, .externallyDeleted:
            return StudioTheme.notice
        default:
            return item.status == .completed ? StudioTheme.completed : StudioTheme.planned
        }
    }
}
