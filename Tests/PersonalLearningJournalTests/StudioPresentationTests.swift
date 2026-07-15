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

    func testFocusPrefersPlannedSessionThenFallsBackToActiveProject() throws {
        let plannedProject = Project(
            name: "Planned",
            area: "AI",
            goal: "Learn",
            currentNextStep: "Read"
        )
        let fallbackProject = Project(
            name: "Fallback",
            area: "Music",
            goal: "Practice",
            currentNextStep: "Play",
            activeEvidenceContractId: UUID()
        )
        let plannedSession = try PlannedSession(
            planId: UUID(),
            phaseId: UUID(),
            projectId: plannedProject.id,
            title: "Attention lecture",
            actionType: .course,
            durationMinutes: 45
        )
        let context = PlannedSessionContext(
            session: plannedSession,
            project: plannedProject,
            phase: nil
        )

        XCTAssertEqual(
            StudioPresentation.focus(projects: [fallbackProject], planned: [context])?.project.id,
            plannedProject.id
        )
        XCTAssertEqual(
            StudioPresentation.focus(projects: [fallbackProject], planned: [])?.project.id,
            fallbackProject.id
        )
    }

    func testProjectFilterReturnsOnlySelectedStatus() {
        let active = Project(name: "Active", area: "AI", goal: "Learn", currentNextStep: "Read")
        let paused = Project(name: "Paused", area: "Music", goal: "Play", status: .paused, currentNextStep: "Practice")

        XCTAssertEqual(
            StudioPresentation.projects([active, paused], status: .active).map(\.id),
            [active.id]
        )
    }

    func testTodayPracticeCardsFilterWeekdayAndExposeActiveTimer() throws {
        let monday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 10))
        )
        let mondayRoutine = makeRoutine(name: "Guitar", weekdays: [2])
        let tuesdayRoutine = makeRoutine(name: "Voice", weekdays: [3])

        let cards = StudioPresentation.practiceCards(
            routines: [mondayRoutine, tuesdayRoutine],
            sessions: [],
            activeRoutineId: mondayRoutine.id,
            now: monday,
            calendar: calendar
        )

        XCTAssertEqual(cards.map(\.routine.id), [mondayRoutine.id])
        XCTAssertTrue(cards[0].isActiveTimer)
    }

    func testPracticeCardsExcludeArchivedAndDeletedRoutinesAndSortActiveFirst() throws {
        let monday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 10))
        )
        let first = makeRoutine(
            name: "Guitar",
            weekdays: [2],
            createdAt: monday.addingTimeInterval(-200)
        )
        let active = makeRoutine(
            name: "Voice",
            weekdays: [2],
            createdAt: monday.addingTimeInterval(-100)
        )
        let archived = makeRoutine(name: "Archived", weekdays: [2], isArchived: true)
        let deleted = makeRoutine(name: "Deleted", weekdays: [2], deletedAt: monday)
        let session = PracticeSession(
            routineId: active.id,
            startedAt: monday,
            endedAt: monday.addingTimeInterval(600),
            activeDurationSeconds: 600
        )

        let cards = StudioPresentation.practiceCards(
            routines: [first, active, archived, deleted],
            sessions: [session],
            activeRoutineId: active.id,
            now: monday,
            calendar: calendar
        )

        XCTAssertEqual(cards.map(\.routine.id), [active.id, first.id])
        XCTAssertEqual(cards[0].statistics.todayActiveSeconds, 600)
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

    private func makeRoutine(
        name: String,
        weekdays: Set<Int>,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        isArchived: Bool = false,
        deletedAt: Date? = nil
    ) -> PracticeRoutine {
        PracticeRoutine(
            name: name,
            symbolName: "music.note",
            color: .coral,
            targetMinutes: 30,
            weekdays: weekdays,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: createdAt,
            deletedAt: deletedAt
        )
    }
}
