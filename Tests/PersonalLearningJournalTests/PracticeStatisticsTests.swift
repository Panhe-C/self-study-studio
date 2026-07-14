import XCTest
@testable import PersonalLearningJournal

final class PracticeStatisticsTests: XCTestCase {
    func testSameDaySessionsCombineToCompleteTarget() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let routine = makeRoutine(targetMinutes: 30)
        let sessions = [
            makeSession(routine.id, "2026-07-13T00:30:00Z", 1_200),
            makeSession(routine.id, "2026-07-13T10:00:00Z", 600)
        ]

        let result = PracticeStatistics.calculate(
            routine: routine,
            sessions: sessions,
            now: isoDate("2026-07-13T12:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(result.todayActiveSeconds, 1_800)
        XCTAssertEqual(result.weekCompletionCount, 1)
        XCTAssertEqual(result.weekActiveSeconds, 1_800)
        XCTAssertEqual(result.allTimeActiveSeconds, 1_800)
    }

    func testWeekAndTimeZoneUseInjectedCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        calendar.firstWeekday = 2
        let routine = makeRoutine(targetMinutes: 15)
        let sessions = [
            makeSession(routine.id, "2026-07-12T15:30:00Z", 900),
            makeSession(routine.id, "2026-07-12T16:30:00Z", 900)
        ]

        let result = PracticeStatistics.calculate(
            routine: routine,
            sessions: sessions,
            now: isoDate("2026-07-13T00:30:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(result.weekCompletionCount, 1)
        XCTAssertEqual(result.todayActiveSeconds, 900)
        XCTAssertEqual(result.weekActiveSeconds, 900)
        XCTAssertEqual(result.allTimeActiveSeconds, 1_800)
    }

    func testDeletedAndOtherRoutineSessionsDoNotContribute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let routine = makeRoutine(targetMinutes: 10)
        let otherRoutine = makeRoutine(targetMinutes: 10)
        let now = isoDate("2026-07-13T12:00:00Z")
        let deleted = PracticeSession(
            routineId: routine.id,
            startedAt: now,
            endedAt: now.addingTimeInterval(600),
            activeDurationSeconds: 600,
            deletedAt: now
        )
        let sessions = [
            makeSession(routine.id, "2026-07-13T10:00:00Z", 600),
            deleted,
            makeSession(otherRoutine.id, "2026-07-13T10:00:00Z", 1_000)
        ]

        let result = PracticeStatistics.calculate(
            routine: routine,
            sessions: sessions,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.todayActiveSeconds, 600)
        XCTAssertEqual(result.weekCompletionCount, 1)
        XCTAssertEqual(result.weekActiveSeconds, 600)
        XCTAssertEqual(result.allTimeActiveSeconds, 600)
    }

    func testCrossMidnightSessionSplitsSavedAndLiveSecondsByCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let routine = makeRoutine(targetMinutes: 10)
        let startedAt = isoDate("2026-07-12T23:50:00Z")
        let endedAt = isoDate("2026-07-13T00:10:00Z")
        let session = PracticeSession(
            routineId: routine.id,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: 1_200
        )

        let result = PracticeStatistics.calculate(
            routine: routine,
            sessions: [session],
            now: isoDate("2026-07-13T00:30:00Z"),
            calendar: calendar
        )
        let liveTodaySeconds = PracticeStatistics.activeSeconds(
            on: isoDate("2026-07-13T00:30:00Z"),
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: 1_200,
            calendar: calendar
        )

        XCTAssertEqual(result.todayActiveSeconds, 600)
        XCTAssertEqual(result.weekActiveSeconds, 600)
        XCTAssertEqual(result.weekCompletionCount, 1)
        XCTAssertEqual(result.allTimeActiveSeconds, 1_200)
        XCTAssertEqual(liveTodaySeconds, result.todayActiveSeconds)
    }
}

private func makeRoutine(targetMinutes: Int) -> PracticeRoutine {
    PracticeRoutine(
        name: "Guitar",
        symbolName: "guitars",
        color: .coral,
        targetMinutes: targetMinutes,
        weekdays: [2]
    )
}

private func makeSession(
    _ routineID: UUID,
    _ startedAt: String,
    _ activeDurationSeconds: Int
) -> PracticeSession {
    let date = isoDate(startedAt)
    return PracticeSession(
        routineId: routineID,
        startedAt: date,
        endedAt: date.addingTimeInterval(TimeInterval(activeDurationSeconds)),
        activeDurationSeconds: activeDurationSeconds
    )
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}
