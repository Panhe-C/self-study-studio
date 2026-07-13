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

    func testPendingCompletionUsesStableSessionIDAndHandlesMissingProjectFallback() throws {
        let fixture = makeEndToEndFixture(now: Date(timeIntervalSince1970: 100))
        let routine = try fixture.viewModel.createPracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [fixture.calendar.component(.weekday, from: fixture.clock.now())]
        )
        let projectID = UUID()
        try fixture.viewModel.startPractice(routine)
        fixture.clock.advance(by: 120)
        let completion = try XCTUnwrap(fixture.viewModel.practiceTimer.finish())
        XCTAssertTrue(
            fixture.viewModel.practiceTimer.updatePendingCompletion(
                note: "Scales",
                linkedProjectId: projectID
            )
        )
        let pendingID = try XCTUnwrap(fixture.viewModel.practiceTimer.pendingCompletion?.id)

        let result = try fixture.viewModel.savePracticeCompletion(
            completion,
            linkedProjectId: projectID,
            note: "Scales"
        )

        XCTAssertEqual(result.session.id, pendingID)
        XCTAssertNil(result.session.linkedProjectId)
        XCTAssertTrue(result.didDropMissingProjectLink)
        XCTAssertNil(fixture.viewModel.practiceTimer.pendingCompletion)
    }

    func testRepositoryFailureKeepsPendingCompletionForRecreationAndRetry() throws {
        let clock = EndToEndClock(now: Date(timeIntervalSince1970: 100))
        let repository = FailingPracticeSessionRepository(now: clock.now)
        let store = EndToEndTimerStateStore()
        let timer = PracticeTimerRuntime(store: store, now: clock.now)
        let journalService = JournalService(repository: repository, now: clock.now)
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository, now: clock.now),
            practiceTimer: timer
        )
        let routine = try viewModel.createPracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        try viewModel.startPractice(routine)
        clock.advance(by: 120)
        let completion = try XCTUnwrap(timer.finish())
        XCTAssertTrue(timer.updatePendingCompletion(note: "Scales", linkedProjectId: nil))
        let pendingID = try XCTUnwrap(timer.pendingCompletion?.id)

        repository.failPracticeSessionCommits = true
        XCTAssertThrowsError(
            try viewModel.savePracticeCompletion(
                completion,
                linkedProjectId: nil,
                note: "Scales"
            )
        )
        XCTAssertEqual(timer.pendingCompletion?.id, pendingID)
        XCTAssertEqual(timer.pendingCompletion?.note, "Scales")
        XCTAssertEqual(PracticeTimerRuntime(store: store, now: clock.now).pendingCompletion?.id, pendingID)

        repository.failPracticeSessionCommits = false
        let result = try viewModel.savePracticeCompletion(
            completion,
            linkedProjectId: nil,
            note: "Scales"
        )
        XCTAssertEqual(result.session.id, pendingID)
        XCTAssertNil(timer.pendingCompletion)
        XCTAssertEqual(viewModel.practiceSessions.map(\.id), [pendingID])
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

    func testLifecycleRefreshUpdatesElapsedDayAndConsumesTargetFeedbackOnce() throws {
        let clock = EndToEndClock(now: isoDate("2026-07-13T23:59:50Z"))
        let runtime = PracticeTimerRuntime(
            store: EndToEndTimerStateStore(),
            now: clock.now
        )
        var feedbackCount = 0
        let lifecycle = PracticeTimerLifecycleCoordinator(runtime: runtime) {
            feedbackCount += 1
        }

        try runtime.start(routineId: UUID(), targetSeconds: 10)
        clock.advance(by: 20)
        lifecycle.refresh(deliverFeedback: true)
        lifecycle.refresh(deliverFeedback: true)

        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 20)
        XCTAssertEqual(runtime.lastRefreshDate, isoDate("2026-07-14T00:00:10Z"))
        XCTAssertEqual(feedbackCount, 1)
    }

    func testPendingCompletionDraftSurvivesRecreationUntilCleared() throws {
        let clock = EndToEndClock(now: Date(timeIntervalSince1970: 100))
        let store = EndToEndTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)
        let routineID = UUID()
        let projectID = UUID()

        try runtime.start(routineId: routineID, targetSeconds: 60)
        clock.advance(by: 30)
        let completion = try XCTUnwrap(runtime.finish())
        XCTAssertEqual(runtime.pendingCompletion?.completion, completion)
        XCTAssertTrue(runtime.updatePendingCompletion(note: "Arpeggios", linkedProjectId: projectID))

        let recreated = PracticeTimerRuntime(store: store, now: clock.now)
        XCTAssertEqual(recreated.pendingCompletion?.completion, completion)
        XCTAssertEqual(recreated.pendingCompletion?.note, "Arpeggios")
        XCTAssertEqual(recreated.pendingCompletion?.linkedProjectId, projectID)
        XCTAssertThrowsError(try recreated.start(routineId: UUID(), targetSeconds: 60)) { error in
            XCTAssertEqual(error as? PracticeTimerRuntimeError, .pendingCompletionExists)
        }

        XCTAssertTrue(recreated.clearPendingCompletion())
        XCTAssertNil(PracticeTimerRuntime(store: store, now: clock.now).pendingCompletion)
    }

    func testPendingCompletionDoesNotEnterJournalSnapshotOrSyncOutboxUntilSave() throws {
        let fixture = makeEndToEndFixture(now: Date(timeIntervalSince1970: 100))
        let routine = try fixture.viewModel.createPracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let outboxBeforeTimer = try fixture.repository.pendingMutations(limit: 10)

        try fixture.viewModel.startPractice(routine)
        fixture.clock.advance(by: 120)
        _ = try XCTUnwrap(fixture.viewModel.practiceTimer.finish())
        XCTAssertTrue(
            fixture.viewModel.practiceTimer.updatePendingCompletion(
                note: "Local draft only",
                linkedProjectId: nil
            )
        )

        XCTAssertTrue(try fixture.repository.snapshot().practiceSessions.isEmpty)
        XCTAssertEqual(try fixture.repository.pendingMutations(limit: 10), outboxBeforeTimer)
        XCTAssertEqual(fixture.viewModel.practiceTimer.pendingCompletion?.note, "Local draft only")
    }

    func testActiveRoutineCannotPassEditorValidation() {
        let routine = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let draft = PracticeRoutineDraft(routine: routine)

        XCTAssertFalse(
            draft.canSave(comparedWith: [routine], activeRoutineId: routine.id)
        )
        XCTAssertTrue(
            draft.canSave(comparedWith: [routine], activeRoutineId: nil)
        )
    }

    func testActiveTimerBlocksRoutineMutationsUntilTimerEnds() throws {
        let fixture = makeEndToEndFixture(now: Date(timeIntervalSince1970: 100))
        let routine = try fixture.viewModel.createPracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        try fixture.viewModel.startPractice(routine)

        XCTAssertThrowsError(
            try fixture.viewModel.updatePracticeRoutine(
                routineId: routine.id,
                name: "Guitar",
                symbolName: "guitars",
                color: .coral,
                targetMinutes: 45,
                weekdays: [2]
            )
        ) { error in
            XCTAssertEqual(error as? PracticeServiceError, .activeRoutineCannotBeModified)
        }
        XCTAssertThrowsError(try fixture.viewModel.archivePracticeRoutine(routine.id))
        XCTAssertThrowsError(try fixture.viewModel.deletePracticeRoutineIfUnused(routine.id))

        fixture.viewModel.discardPractice()
        let updated = try fixture.viewModel.updatePracticeRoutine(
            routineId: routine.id,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 45,
            weekdays: [2]
        )
        XCTAssertEqual(updated.targetMinutes, 45)
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
        return EndToEndFixture(
            viewModel: viewModel,
            clock: clock,
            calendar: calendar,
            repository: repository
        )
    }
}

@MainActor
private struct EndToEndFixture {
    let viewModel: JournalViewModel
    let clock: EndToEndClock
    let calendar: Calendar
    let repository: InMemoryJournalRepository
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

private final class FailingPracticeSessionRepository: JournalRepository {
    private let backing: InMemoryJournalRepository
    var failPracticeSessionCommits = false

    init(now: @escaping () -> Date) {
        backing = InMemoryJournalRepository(now: now)
    }

    func snapshot() throws -> JournalSnapshot { try backing.snapshot() }

    func commit(_ transaction: JournalTransaction) throws {
        if failPracticeSessionCommits,
           transaction.upserts.contains(where: {
               if case .practiceSession = $0 { return true }
               return false
           }) {
            throw EndToEndError.repositoryFailure
        }
        try backing.commit(transaction)
    }

    func pendingMutations(limit: Int) throws -> [PendingMutation] {
        try backing.pendingMutations(limit: limit)
    }

    func acknowledge(_ mutationIDs: Set<UUID>, metadata: [SyncRecordMetadata]) throws {
        try backing.acknowledge(mutationIDs, metadata: metadata)
    }

    func conflicts() throws -> [SyncConflict] { try backing.conflicts() }
    func resolveConflict(id: UUID, with entity: JournalEntity) throws {
        try backing.resolveConflict(id: id, with: entity)
    }
    func hasCompletedMigration(identifier: String) throws -> Bool {
        try backing.hasCompletedMigration(identifier: identifier)
    }
    func entity(for reference: JournalEntityReference) throws -> JournalEntity? {
        try backing.entity(for: reference)
    }
    func metadata(for reference: JournalEntityReference) throws -> SyncRecordMetadata? {
        try backing.metadata(for: reference)
    }
    func reference(recordName: String) throws -> JournalEntityReference? {
        try backing.reference(recordName: recordName)
    }
    func recordSyncFailures(retryable: [UUID: String], terminal: [UUID: String]) throws {
        try backing.recordSyncFailures(retryable: retryable, terminal: terminal)
    }
    func syncChangeToken() throws -> Data? { try backing.syncChangeToken() }
    func storeSyncChangeToken(_ token: Data?) throws { try backing.storeSyncChangeToken(token) }
    func applyRemote(_ transaction: JournalTransaction, conflicts: [SyncConflict]) throws {
        try backing.applyRemote(transaction, conflicts: conflicts)
    }
}

private enum EndToEndError: Error {
    case repositoryFailure
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}
