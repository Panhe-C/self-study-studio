import Foundation

public struct PracticeRoutineStatistics: Equatable, Sendable {
    public let todayActiveSeconds: Int
    public let weekCompletionCount: Int
    public let weekActiveSeconds: Int
    public let allTimeActiveSeconds: Int

    public init(
        todayActiveSeconds: Int,
        weekCompletionCount: Int,
        weekActiveSeconds: Int,
        allTimeActiveSeconds: Int
    ) {
        self.todayActiveSeconds = todayActiveSeconds
        self.weekCompletionCount = weekCompletionCount
        self.weekActiveSeconds = weekActiveSeconds
        self.allTimeActiveSeconds = allTimeActiveSeconds
    }
}

public enum PracticeStatistics {
    public static func calculate(
        routine: PracticeRoutine,
        sessions: [PracticeSession],
        now: Date,
        calendar: Calendar
    ) -> PracticeRoutineStatistics {
        let activeSessions = sessions.filter {
            $0.routineId == routine.id && $0.deletedAt == nil
        }
        let secondsByDay = activeSessions.reduce(into: [Date: Int]()) { result, session in
            for (day, seconds) in activeSecondsByDay(
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                activeDurationSeconds: session.activeDurationSeconds,
                calendar: calendar
            ) {
                result[day, default: 0] += seconds
            }
        }
        let today = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let targetSeconds = routine.targetMinutes * 60

        let weekDays = secondsByDay.filter { day, _ in
            week?.contains(day) ?? false
        }
        let weekActiveSeconds = weekDays.values.reduce(0, +)
        let weekCompletionCount = weekDays.values.filter { $0 >= targetSeconds }.count

        return PracticeRoutineStatistics(
            todayActiveSeconds: secondsByDay[today, default: 0],
            weekCompletionCount: weekCompletionCount,
            weekActiveSeconds: weekActiveSeconds,
            allTimeActiveSeconds: activeSessions.reduce(0) { $0 + $1.activeDurationSeconds }
        )
    }

    public static func activeSeconds(
        on date: Date,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        calendar: Calendar
    ) -> Int {
        activeSecondsByDay(
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: activeDurationSeconds,
            calendar: calendar
        )[calendar.startOfDay(for: date), default: 0]
    }

    public static func activeSecondsByDay(
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        calendar: Calendar
    ) -> [Date: Int] {
        guard activeDurationSeconds > 0, endedAt >= startedAt else { return [:] }
        let wallClockSeconds = endedAt.timeIntervalSince(startedAt)
        guard wallClockSeconds > 0 else {
            return [calendar.startOfDay(for: startedAt): activeDurationSeconds]
        }

        var slices: [(day: Date, duration: TimeInterval)] = []
        var cursor = startedAt
        while cursor < endedAt {
            let day = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? endedAt
            let sliceEnd = min(nextDay, endedAt)
            let duration = sliceEnd.timeIntervalSince(cursor)
            guard duration > 0 else { break }
            slices.append((day, duration))
            cursor = sliceEnd
        }

        var remainingSeconds = activeDurationSeconds
        var remainingWallClock = slices.reduce(0) { $0 + $1.duration }
        return slices.enumerated().reduce(into: [Date: Int]()) { result, item in
            let (index, slice) = item
            let seconds: Int
            if index == slices.indices.last {
                seconds = remainingSeconds
            } else {
                seconds = Int(
                    (Double(remainingSeconds) * slice.duration / remainingWallClock).rounded(.down)
                )
            }
            result[slice.day, default: 0] += seconds
            remainingSeconds -= seconds
            remainingWallClock -= slice.duration
        }
    }
}
