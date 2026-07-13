import Foundation
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class PracticeTimerEndToEndTests: XCTestCase {
    func testCreateStartPauseResumeAndSavePracticeWorkflow() throws {
        let fixture = makeEndToEndFixture(now: Date(timeIntervalSince1970: 1_000))
        let weekday = fixture.calendar.component(.weekday, from: fixture.clock.now())
        let routine = try fixture.viewModel.createPracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [weekday]
        )

        try fixture.viewModel.startPractice(routine)
        fixture.clock.advance(by: 900)
        fixture.viewModel.practiceTimer.pause()
        fixture.viewModel.practiceTimer.resume()
        fixture.clock.advance(by: 900)

        let completion = try XCTUnwrap(fixture.viewModel.practiceTimer.finish())
        _ = try fixture.viewModel.savePracticeCompletion(
            completion,
            linkedProjectId: nil,
            note: "Chord changes"
        )

        let card = try XCTUnwrap(
            fixture.viewModel.practiceCards(
                now: fixture.clock.now(),
                calendar: fixture.calendar
            ).first
        )
        XCTAssertEqual(card.statistics.todayActiveSeconds, 1_800)
        XCTAssertEqual(card.statistics.weekCompletionCount, 1)
    }

    func testFinishDraftRetainsCompletionAndInputsAfterSaveFailure() throws {
        let completion = PracticeTimerCompletion(
            routineId: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 220),
            activeDurationSeconds: 120
        )
        let projectID = UUID()
        var draft = PracticeFinishDraft(
            completion: completion,
            note: "  Chord changes  ",
            linkedProjectId: projectID
        )

        XCTAssertFalse(draft.submit { _, _, _ in
            throw EndToEndError.repositoryFailure
        })
        XCTAssertEqual(draft.completion, completion)
        XCTAssertEqual(draft.note, "  Chord changes  ")
        XCTAssertEqual(draft.linkedProjectId, projectID)
        XCTAssertNotNil(draft.errorMessage)
    }

    func testFinishDraftReportsMissingProjectFallbackAfterSuccessfulSave() throws {
        let completion = PracticeTimerCompletion(
            routineId: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 220),
            activeDurationSeconds: 120
        )
        let projectID = UUID()
        let session = PracticeSession(
            routineId: completion.routineId,
            startedAt: completion.startedAt,
            endedAt: completion.endedAt,
            activeDurationSeconds: completion.activeDurationSeconds
        )
        var draft = PracticeFinishDraft(
            completion: completion,
            note: "Scales",
            linkedProjectId: projectID
        )

        XCTAssertTrue(draft.submit { _, _, _ in
            PracticeSessionSaveResult(session: session, didDropMissingProjectLink: true)
        })
        XCTAssertNil(draft.linkedProjectId)
        XCTAssertNotNil(draft.fallbackExplanation)
        XCTAssertNil(draft.errorMessage)
    }

    func testRoutineDraftValidationUsesTrimmedCaseInsensitiveActiveNames() {
        let existing = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        var draft = PracticeRoutineDraft()
        draft.name = "  guitar  "

        XCTAssertFalse(draft.canSave(comparedWith: [existing]))

        draft.name = "Piano"
        XCTAssertTrue(draft.canSave(comparedWith: [existing]))

        draft.weekdays = []
        XCTAssertFalse(draft.canSave(comparedWith: [existing]))
    }

    private func makeEndToEndFixture(now: Date) -> EndToEndFixture {
        let clock = EndToEndClock(now: now)
        let repository = InMemoryJournalRepository(now: clock.now)
        let journalService = JournalService(repository: repository, now: clock.now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository, now: clock.now),
            practiceTimer: PracticeTimerRuntime(
                store: EndToEndTimerStateStore(),
                now: clock.now
            )
        )
        return EndToEndFixture(viewModel: viewModel, clock: clock, calendar: calendar)
    }
}

@MainActor
private struct EndToEndFixture {
    let viewModel: JournalViewModel
    let clock: EndToEndClock
    let calendar: Calendar
}

@MainActor
private final class EndToEndClock {
    private var current: Date

    init(now: Date) {
        current = now
    }

    func now() -> Date {
        current
    }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

@MainActor
private final class EndToEndTimerStateStore: PracticeTimerStateStore {
    private var data: Data?

    func load() -> Data? {
        data
    }

    func save(_ data: Data?) throws {
        self.data = data
    }
}

private enum EndToEndError: LocalizedError {
    case repositoryFailure

    var errorDescription: String? {
        "The practice session could not be saved."
    }
}
