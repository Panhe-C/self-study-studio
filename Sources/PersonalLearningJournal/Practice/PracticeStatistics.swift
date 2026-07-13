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
            let day = calendar.startOfDay(for: session.startedAt)
            result[day, default: 0] += session.activeDurationSeconds
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
}
