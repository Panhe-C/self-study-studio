import Foundation
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class PracticeTimerRuntimeTests: XCTestCase {
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
        clock.advance(by: 11)
        runtime.refresh()

        XCTAssertTrue(runtime.consumeTargetCrossing())
        XCTAssertFalse(runtime.consumeTargetCrossing())
        XCTAssertTrue(runtime.snapshot.isRunning)
        XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 11)
        XCTAssertFalse(PracticeTimerRuntime(store: store, now: clock.now).consumeTargetCrossing())
    }

    func testFinishReturnsImmutableCompletionAndClearsActiveState() throws {
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
        XCTAssertNil(store.data)
        XCTAssertNil(runtime.finish())
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
