import Combine
import Foundation
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class PracticeTimerRuntimeTests: XCTestCase {
    func testRefreshCoalescesDuplicateCallsWithinSameWallClockSecond() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100.1))
        let runtime = PracticeTimerRuntime(
            store: InMemoryPracticeTimerStateStore(),
            now: clock.now
        )
        let lifecycle = PracticeTimerLifecycleCoordinator(runtime: runtime)

        try runtime.start(routineId: UUID(), targetSeconds: 30)

        var publicationCount = 0
        let observation = runtime.objectWillChange.sink {
            publicationCount += 1
        }

        lifecycle.refresh(deliverFeedback: true)
        clock.advance(by: 0.2)
        lifecycle.refresh(deliverFeedback: true)

        XCTAssertEqual(publicationCount, 0)

        clock.advance(by: 0.8)
        lifecycle.refresh(deliverFeedback: true)

        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 1)

        clock.advance(by: 1)
        lifecycle.refresh(deliverFeedback: true)
        XCTAssertEqual(publicationCount, 2)
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 2)

        clock.advance(by: 1)
        lifecycle.refresh(deliverFeedback: true)
        XCTAssertEqual(publicationCount, 3)
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 3)
        withExtendedLifetime(observation) {}
    }

    func testStartRejectsInvalidTargetsAndASecondActiveTimer() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let runtime = PracticeTimerRuntime(store: InMemoryPracticeTimerStateStore(), now: clock.now)

        XCTAssertThrowsError(try runtime.start(routineId: UUID(), targetSeconds: 0))

        try runtime.start(routineId: UUID(), targetSeconds: 30)
        XCTAssertThrowsError(try runtime.start(routineId: UUID(), targetSeconds: 30))
    }

    func testPauseResumeAndBackgroundTimeAreDerivedFromDates() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)
        let routineID = UUID()

        try runtime.start(routineId: routineID, targetSeconds: 30)
        clock.advance(by: 20)
        runtime.pause()
        clock.advance(by: 100)
        runtime.refresh()
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 20)
        XCTAssertFalse(runtime.snapshot.isRunning)

        runtime.resume()
        clock.advance(by: 10)
        runtime.refresh()
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 30)
        XCTAssertTrue(runtime.snapshot.isRunning)
        XCTAssertEqual(runtime.snapshot.activeRoutineId, routineID)
    }

    func testTargetCrossingFiresOnceWithoutStoppingTimer() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)

        try runtime.start(routineId: UUID(), targetSeconds: 10)
        var publicationCount = 0
        let observation = runtime.objectWillChange.sink {
            publicationCount += 1
        }
        clock.advance(by: 11)
        runtime.refresh()

        XCTAssertTrue(runtime.consumeTargetCrossing())
        XCTAssertEqual(publicationCount, 1)
        XCTAssertFalse(runtime.consumeTargetCrossing())
        XCTAssertTrue(runtime.snapshot.isRunning)
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 11)
        XCTAssertFalse(PracticeTimerRuntime(store: store, now: clock.now).consumeTargetCrossing())
        withExtendedLifetime(observation) {}
    }

    func testFinishReturnsImmutableCompletionAndPersistsPendingDraft() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)
        let routineID = UUID()

        try runtime.start(routineId: routineID, targetSeconds: 30)
        clock.advance(by: 12)

        XCTAssertEqual(
            runtime.finish(),
            PracticeTimerCompletion(
                routineId: routineID,
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 112),
                activeDurationSeconds: 12
            )
        )
        XCTAssertNil(runtime.snapshot.activeRoutineId)
        XCTAssertNotNil(store.data)
        XCTAssertEqual(runtime.pendingCompletion?.completion.activeDurationSeconds, 12)
        XCTAssertNil(runtime.finish())

        XCTAssertTrue(runtime.clearPendingCompletion())
        XCTAssertNil(store.data)
    }

    func testPendingCompletionPreservesOptionalNoteAndAttentionMarker() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)

        try runtime.start(routineId: UUID(), targetSeconds: 30)
        clock.advance(by: 12)
        XCTAssertNotNil(runtime.finish())

        XCTAssertTrue(
            runtime.updatePendingCompletion(
                note: "Intervals felt steady",
                linkedProjectId: nil,
                attentionMarker: "Keep the final cadence relaxed"
            )
        )

        let recovered = PracticeTimerRuntime(store: store, now: clock.now)
        XCTAssertEqual(recovered.pendingCompletion?.note, "Intervals felt steady")
        XCTAssertEqual(
            recovered.pendingCompletion?.attentionMarker,
            "Keep the final cadence relaxed"
        )
    }

    func testDiscardClearsActiveStateWithoutCompletion() throws {
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: { Date(timeIntervalSince1970: 100) })

        try runtime.start(routineId: UUID(), targetSeconds: 30)
        runtime.discard()

        XCTAssertNil(runtime.snapshot.activeRoutineId)
        XCTAssertNil(store.data)
    }

    func testRelaunchRecoversValidPersistedState() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = InMemoryPracticeTimerStateStore()
        let routineID = UUID()

        let firstRuntime = PracticeTimerRuntime(store: store, now: clock.now)
        try firstRuntime.start(routineId: routineID, targetSeconds: 60)
        clock.advance(by: 15)

        let recoveredRuntime = PracticeTimerRuntime(store: store, now: clock.now)
        recoveredRuntime.refresh()
        XCTAssertEqual(recoveredRuntime.snapshot.activeRoutineId, routineID)
        XCTAssertEqual(recoveredRuntime.snapshot.activeElapsedSeconds, 15)
        XCTAssertTrue(recoveredRuntime.snapshot.isRunning)
    }

    func testRecoveryRejectsCorruptionAndImpossibleTimestamps() throws {
        let now = Date(timeIntervalSince1970: 100)
        let store = InMemoryPracticeTimerStateStore()
        store.data = Data("not-json".utf8)
        XCTAssertNil(PracticeTimerRuntime(store: store, now: { now }).snapshot.activeRoutineId)
        XCTAssertNil(store.data)

        let invalidStates = [
            PersistedPracticeTimerState(
                routineId: UUID(),
                startedAt: Date(timeIntervalSince1970: 101),
                accumulatedActiveSeconds: 0,
                resumedAt: Date(timeIntervalSince1970: 101),
                targetSeconds: 30,
                targetFeedbackConsumed: false
            ),
            PersistedPracticeTimerState(
                routineId: UUID(),
                startedAt: Date(timeIntervalSince1970: 90),
                accumulatedActiveSeconds: -1,
                resumedAt: nil,
                targetSeconds: 30,
                targetFeedbackConsumed: false
            ),
            PersistedPracticeTimerState(
                routineId: UUID(),
                startedAt: Date(timeIntervalSince1970: 90),
                accumulatedActiveSeconds: 0,
                resumedAt: nil,
                targetSeconds: 0,
                targetFeedbackConsumed: false
            ),
            PersistedPracticeTimerState(
                routineId: UUID(),
                startedAt: Date(timeIntervalSince1970: 90),
                accumulatedActiveSeconds: 20,
                resumedAt: Date(timeIntervalSince1970: 101),
                targetSeconds: 30,
                targetFeedbackConsumed: false
            ),
            PersistedPracticeTimerState(
                routineId: UUID(),
                startedAt: Date(timeIntervalSince1970: 95),
                accumulatedActiveSeconds: 20,
                resumedAt: nil,
                targetSeconds: 30,
                targetFeedbackConsumed: false
            )
        ]

        for state in invalidStates {
            store.data = try JSONEncoder().encode(state)
            XCTAssertNil(PracticeTimerRuntime(store: store, now: { now }).snapshot.activeRoutineId)
            XCTAssertNil(store.data)
        }
    }

    func testUserDefaultsStateStoreRoundTripsAndClearsData() throws {
        let suiteName = "PracticeTimerRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPracticeTimerStateStore(userDefaults: defaults)
        let data = Data("timer-state".utf8)

        try store.save(data)
        XCTAssertEqual(store.load(), data)

        try store.save(nil)
        XCTAssertNil(store.load())
    }

    func testFailedPauseKeepsRunningStateAndRelaunchUsesDurableState() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = ThrowingPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)
        let routineID = UUID()

        try runtime.start(routineId: routineID, targetSeconds: 30)
        clock.advance(by: 10)
        store.shouldFailSaves = true

        runtime.pause()
        runtime.refresh()

        XCTAssertTrue(runtime.snapshot.isRunning)
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 10)

        let relaunchedRuntime = PracticeTimerRuntime(store: store, now: clock.now)
        relaunchedRuntime.refresh()
        XCTAssertTrue(relaunchedRuntime.snapshot.isRunning)
        XCTAssertEqual(relaunchedRuntime.snapshot.activeRoutineId, routineID)
    }

    func testFailedTargetConsumptionDoesNotConsumeMemoryOrDurableState() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = ThrowingPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)

        try runtime.start(routineId: UUID(), targetSeconds: 10)
        clock.advance(by: 11)
        store.shouldFailSaves = true

        XCTAssertFalse(runtime.consumeTargetCrossing())

        store.shouldFailSaves = false
        let relaunchedRuntime = PracticeTimerRuntime(store: store, now: clock.now)
        XCTAssertTrue(relaunchedRuntime.consumeTargetCrossing())
    }

    func testFailedFinishKeepsActiveStateAndRelaunchUsesDurableState() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = ThrowingPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)
        let routineID = UUID()

        try runtime.start(routineId: routineID, targetSeconds: 30)
        clock.advance(by: 12)
        store.shouldFailSaves = true

        XCTAssertNil(runtime.finish())
        runtime.refresh()
        XCTAssertEqual(runtime.snapshot.activeRoutineId, routineID)

        let relaunchedRuntime = PracticeTimerRuntime(store: store, now: clock.now)
        relaunchedRuntime.refresh()
        XCTAssertEqual(relaunchedRuntime.snapshot.activeRoutineId, routineID)
    }

    func testFailedDiscardKeepsActiveStateAndRelaunchUsesDurableState() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = ThrowingPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)
        let routineID = UUID()

        try runtime.start(routineId: routineID, targetSeconds: 30)
        store.shouldFailSaves = true

        runtime.discard()
        XCTAssertEqual(runtime.snapshot.activeRoutineId, routineID)

        let relaunchedRuntime = PracticeTimerRuntime(store: store, now: clock.now)
        XCTAssertEqual(relaunchedRuntime.snapshot.activeRoutineId, routineID)
    }

    func testBackwardClockDuringFinishClearsStateAndReturnsNil() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)

        try runtime.start(routineId: UUID(), targetSeconds: 30)
        clock.set(to: Date(timeIntervalSince1970: 99))

        XCTAssertNil(runtime.finish())
        XCTAssertNil(runtime.snapshot.activeRoutineId)
        XCTAssertNil(store.data)
    }

    func testBackwardClockBeforeResumeClearsImpossiblePausedState() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)

        try runtime.start(routineId: UUID(), targetSeconds: 30)
        clock.advance(by: 10)
        runtime.pause()
        clock.set(to: Date(timeIntervalSince1970: 100))

        runtime.resume()

        XCTAssertNil(runtime.snapshot.activeRoutineId)
        XCTAssertNil(store.data)
    }

    func testBackwardClockBeforeTargetConsumptionClearsStateWithoutFeedback() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)

        try runtime.start(routineId: UUID(), targetSeconds: 10)
        clock.set(to: Date(timeIntervalSince1970: 99))

        XCTAssertFalse(runtime.consumeTargetCrossing())
        XCTAssertNil(runtime.snapshot.activeRoutineId)
        XCTAssertNil(store.data)
    }

    func testGuidedStartPersistsOrderedBlocksAndCurrentFocus() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let first = PracticeBlock(name: "Theory", targetMinutes: 5, ordinal: 0, focus: "I-IV-V")
        let second = PracticeBlock(name: "Technique", targetMinutes: 10, ordinal: 1, focus: "G-C-D")
        let routine = PracticeRoutine(
            id: UUID(),
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 15,
            weekdays: [2],
            blocks: [second, first]
        )
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)

        try runtime.start(routine: routine)

        XCTAssertEqual(runtime.snapshot.activeRoutineId, routine.id)
        XCTAssertEqual(runtime.snapshot.blocks.map(\.id), [first.id, second.id])
        XCTAssertEqual(runtime.snapshot.activeBlockID, first.id)
        XCTAssertEqual(runtime.snapshot.currentBlock?.focus, "I-IV-V")
        XCTAssertNotNil(store.data)
    }

    func testPauseExcludesWallClockAndFinishCombinesRevisitedBlockSegments() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let first = PracticeBlock(name: "Theory", targetMinutes: 5, ordinal: 0)
        let second = PracticeBlock(name: "Technique", targetMinutes: 10, ordinal: 1)
        let routine = PracticeRoutine(
            id: UUID(),
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 15,
            weekdays: [2],
            blocks: [first, second]
        )
        let runtime = PracticeTimerRuntime(
            store: InMemoryPracticeTimerStateStore(),
            now: clock.now
        )

        try runtime.start(routine: routine)
        clock.advance(by: 10)
        runtime.pause()
        clock.advance(by: 100)
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 10)

        runtime.resume()
        clock.advance(by: 5)
        XCTAssertTrue(runtime.selectBlock(second.id))
        clock.advance(by: 20)
        XCTAssertTrue(runtime.selectBlock(first.id))
        clock.advance(by: 5)

        let completion = try XCTUnwrap(runtime.finish())
        XCTAssertEqual(completion.activeDurationSeconds, 40)
        XCTAssertEqual(completion.segments.map(\.blockID), [first.id, first.id, second.id, first.id])
        XCTAssertEqual(
            completion.summary?.blockSummaries.first { $0.blockID == first.id }?.activeDurationSeconds,
            20
        )
        XCTAssertEqual(
            completion.summary?.blockSummaries.first { $0.blockID == second.id }?.activeDurationSeconds,
            20
        )
    }

    func testSkipMovesToNextBlockAndRevisitKeepsCombinedHistoryAfterRelaunch() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let first = PracticeBlock(name: "Theory", targetMinutes: 5, ordinal: 0)
        let second = PracticeBlock(name: "Technique", targetMinutes: 10, ordinal: 1)
        let routine = PracticeRoutine(
            id: UUID(),
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 15,
            weekdays: [2],
            blocks: [first, second]
        )
        let store = InMemoryPracticeTimerStateStore()
        let runtime = PracticeTimerRuntime(store: store, now: clock.now)

        try runtime.start(routine: routine)
        XCTAssertTrue(runtime.skipCurrentBlock())
        XCTAssertEqual(runtime.snapshot.activeBlockID, second.id)
        XCTAssertTrue(runtime.snapshot.blocks.first { $0.id == first.id }?.wasSkipped == true)
        clock.advance(by: 12)
        XCTAssertTrue(runtime.selectBlock(first.id))
        clock.advance(by: 3)

        let recovered = PracticeTimerRuntime(store: store, now: clock.now)
        XCTAssertEqual(recovered.snapshot.activeBlockID, first.id)
        XCTAssertEqual(recovered.snapshot.blocks.first { $0.id == second.id }?.activeDurationSeconds, 12)
        let completion = try XCTUnwrap(recovered.finish())
        XCTAssertEqual(completion.summary?.blockSummaries.first { $0.blockID == first.id }?.visitCount, 1)
        XCTAssertEqual(completion.summary?.blockSummaries.first { $0.blockID == second.id }?.visitCount, 1)
    }

    func testLegacyFlatTimerStateRecoversIntoSingleGuidedBlock() throws {
        let now = Date(timeIntervalSince1970: 100)
        let store = InMemoryPracticeTimerStateStore()
        let routineID = UUID()
        store.data = try JSONEncoder().encode(
            PersistedPracticeTimerState(
                routineId: routineID,
                startedAt: Date(timeIntervalSince1970: 90),
                accumulatedActiveSeconds: 5,
                resumedAt: Date(timeIntervalSince1970: 95),
                targetSeconds: 60,
                targetFeedbackConsumed: false
            )
        )

        let runtime = PracticeTimerRuntime(store: store, now: { now })
        XCTAssertEqual(runtime.snapshot.activeRoutineId, routineID)
        XCTAssertEqual(runtime.snapshot.blocks.count, 1)
        XCTAssertEqual(runtime.snapshot.activeBlockID, routineID)
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 10)
    }

    func testNextBlockResetsRunningSegmentStartAndDoesNotDoubleCount() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        let first = PracticeBlock(name: "Theory", targetMinutes: 5, ordinal: 0)
        let second = PracticeBlock(name: "Technique", targetMinutes: 5, ordinal: 1)
        let routine = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 10,
            weekdays: [2],
            blocks: [first, second]
        )
        let runtime = PracticeTimerRuntime(
            store: InMemoryPracticeTimerStateStore(),
            now: clock.now
        )

        try runtime.start(routine: routine)
        clock.advance(by: 10)
        XCTAssertTrue(runtime.nextBlock())
        clock.advance(by: 5)

        let completion = try XCTUnwrap(runtime.finish())
        XCTAssertEqual(completion.activeDurationSeconds, 15)
        XCTAssertEqual(completion.segments.map(\.blockID), [first.id, second.id])
        XCTAssertEqual(completion.segments.map(\.activeDurationSeconds), [10, 5])
    }

    func testLegacyAccumulatedSecondsBecomeRecoveredSegmentAndSummaryTime() throws {
        let now = Date(timeIntervalSince1970: 100)
        let store = InMemoryPracticeTimerStateStore()
        let routineID = UUID()
        store.data = try JSONEncoder().encode(
            PersistedPracticeTimerState(
                routineId: routineID,
                startedAt: Date(timeIntervalSince1970: 90),
                accumulatedActiveSeconds: 5,
                resumedAt: nil,
                targetSeconds: 60,
                targetFeedbackConsumed: false
            )
        )

        let runtime = PracticeTimerRuntime(store: store, now: { now })
        let completion = try XCTUnwrap(runtime.finish())

        XCTAssertEqual(completion.activeDurationSeconds, 5)
        XCTAssertEqual(completion.segments.count, 1)
        XCTAssertEqual(completion.segments.first?.blockID, routineID)
        XCTAssertEqual(completion.segments.first?.activeDurationSeconds, 5)
        XCTAssertEqual(
            completion.summary?.blockSummaries.first?.activeDurationSeconds,
            5
        )
        XCTAssertFalse(completion.summary?.blockSummaries.first?.wasSkipped == true)
    }
}

@MainActor
private final class TestClock {
    private(set) var current: Date

    init(now: Date) {
        current = now
    }

    func now() -> Date {
        current
    }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }

    func set(to date: Date) {
        current = date
    }
}

@MainActor
private final class InMemoryPracticeTimerStateStore: PracticeTimerStateStore {
    var data: Data?

    func load() -> Data? {
        data
    }

    func save(_ data: Data?) throws {
        self.data = data
    }
}

@MainActor
private final class ThrowingPracticeTimerStateStore: PracticeTimerStateStore {
    var data: Data?
    var shouldFailSaves = false

    func load() -> Data? {
        data
    }

    func save(_ data: Data?) throws {
        if shouldFailSaves {
            throw TestStoreError.saveFailed
        }
        self.data = data
    }
}

private enum TestStoreError: Error {
    case saveFailed
}
