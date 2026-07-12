import Foundation
import XCTest
@testable import PersonalLearningJournal

final class StudioPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func testWeekRhythmCountsSessionMinutesByCalendarDay() throws {
        let monday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9))
        )
        let monday30 = try makeSession(startedAt: monday, durationMinutes: 30)
        let monday45 = try makeSession(
            startedAt: try XCTUnwrap(calendar.date(byAdding: .hour, value: 2, to: monday)),
            durationMinutes: 45
        )

        let days = StudioPresentation.weekRhythm(
            sessions: [monday30, monday45],
            weekContaining: monday30.endedAt,
            calendar: calendar
        )

        XCTAssertEqual(days.map(\.minutes), [75, 0, 0, 0, 0, 0, 0])
    }

    func testProjectProgressUsesCompletedPlannedSessions() {
        XCTAssertEqual(StudioPresentation.progress(completed: 2, total: 5), 0.4)
    }

    func testLibraryFilterMatchesProjectAndProofTextCaseInsensitively() throws {
        let proof = try Proof(
            projectId: UUID(),
            type: .link,
            title: "Lecture notes",
            statement: "Transformer architecture review"
        )

        XCTAssertTrue(
            StudioPresentation.proofMatches(
                query: "cs336",
                proof: proof,
                projectName: "CS336"
            )
        )
    }

    private func makeSession(startedAt: Date, durationMinutes: Int) throws -> LearningSession {
        try LearningSession(
            projectId: UUID(),
            source: .quickLog,
            actionType: .course,
            startedAt: startedAt,
            endedAt: try XCTUnwrap(
                calendar.date(byAdding: .minute, value: durationMinutes, to: startedAt)
            ),
            durationMinutes: durationMinutes,
            note: "Study session",
            nextStepBefore: "Read",
            nextStepAfter: "Practice"
        )
    }
}
