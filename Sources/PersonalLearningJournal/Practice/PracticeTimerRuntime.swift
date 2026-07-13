import Combine
import Foundation

@MainActor
public protocol PracticeTimerStateStore: AnyObject {
    func load() -> Data?
    func save(_ data: Data?) throws
}

@MainActor
public final class UserDefaultsPracticeTimerStateStore: PracticeTimerStateStore {
    private let userDefaults: UserDefaults
    private let key: String

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = "PersonalLearningJournal.activePracticeTimer"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func load() -> Data? {
        userDefaults.data(forKey: key)
    }

    public func save(_ data: Data?) throws {
        if let data {
            userDefaults.set(data, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }
}

public struct PracticeTimerSnapshot: Equatable, Sendable {
    public let activeRoutineId: UUID?
    public let startedAt: Date?
    public let activeElapsedSeconds: Int
    public let isRunning: Bool
    public let targetSeconds: Int

    public init(
        activeRoutineId: UUID?,
        startedAt: Date?,
        activeElapsedSeconds: Int,
        isRunning: Bool,
        targetSeconds: Int
    ) {
        self.activeRoutineId = activeRoutineId
        self.startedAt = startedAt
        self.activeElapsedSeconds = activeElapsedSeconds
        self.isRunning = isRunning
        self.targetSeconds = targetSeconds
    }

    static let inactive = PracticeTimerSnapshot(
        activeRoutineId: nil,
        startedAt: nil,
        activeElapsedSeconds: 0,
        isRunning: false,
        targetSeconds: 0
    )
}

public struct PracticeTimerCompletion: Equatable, Sendable {
    public let routineId: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let activeDurationSeconds: Int

    public init(
        routineId: UUID,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int
    ) {
        self.routineId = routineId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationSeconds = activeDurationSeconds
    }
}

public enum PracticeTimerRuntimeError: Error, Equatable, Sendable {
    case invalidTargetSeconds
    case activeTimerAlreadyExists
}

struct PersistedPracticeTimerState: Codable, Equatable {
    let routineId: UUID
    let startedAt: Date
    var accumulatedActiveSeconds: Int
    var resumedAt: Date?
    let targetSeconds: Int
    var targetFeedbackConsumed: Bool
}

@MainActor
public final class PracticeTimerRuntime: ObservableObject {
    private let store: any PracticeTimerStateStore
    private let now: @MainActor () -> Date
    private let encoder = JSONEncoder()

    @Published private var activeState: PersistedPracticeTimerState?

    public var snapshot: PracticeTimerSnapshot {
        makeSnapshot(for: activeState, at: now())
    }

    public init(
        store: any PracticeTimerStateStore,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
        let persistedData = store.load()
        activeState = Self.recoverState(from: persistedData, at: now())

        if persistedData != nil, activeState == nil {
            try? store.save(nil)
        }
    }

    public func start(routineId: UUID, targetSeconds: Int) throws {
        guard targetSeconds > 0 else {
            throw PracticeTimerRuntimeError.invalidTargetSeconds
        }
        guard activeState == nil else {
            throw PracticeTimerRuntimeError.activeTimerAlreadyExists
        }

        let timestamp = now()
        let state = PersistedPracticeTimerState(
            routineId: routineId,
            startedAt: timestamp,
            accumulatedActiveSeconds: 0,
            resumedAt: timestamp,
            targetSeconds: targetSeconds,
            targetFeedbackConsumed: false
        )
        try save(state)
        activeState = state
    }

    public func pause() {
        guard var state = activeState, let resumedAt = state.resumedAt else {
            return
        }

        state.accumulatedActiveSeconds += elapsedSeconds(since: resumedAt, until: now())
        state.resumedAt = nil
        replaceStateAfterTransition(state)
    }

    public func resume() {
        guard var state = activeState, state.resumedAt == nil else {
            return
        }

        state.resumedAt = now()
        replaceStateAfterTransition(state)
    }

    public func refresh() {
        objectWillChange.send()
    }

    public func consumeTargetCrossing() -> Bool {
        guard var state = activeState,
              !state.targetFeedbackConsumed,
              elapsedSeconds(for: state, at: now()) >= state.targetSeconds else {
            return false
        }

        state.targetFeedbackConsumed = true
        replaceStateAfterTransition(state)
        return true
    }

    public func finish() -> PracticeTimerCompletion? {
        guard let state = activeState else {
            return nil
        }

        let endedAt = max(now(), state.startedAt)
        let completion = PracticeTimerCompletion(
            routineId: state.routineId,
            startedAt: state.startedAt,
            endedAt: endedAt,
            activeDurationSeconds: elapsedSeconds(for: state, at: endedAt)
        )
        activeState = nil
        try? store.save(nil)
        return completion
    }

    public func discard() {
        activeState = nil
        try? store.save(nil)
    }

    private func replaceStateAfterTransition(_ state: PersistedPracticeTimerState) {
        activeState = state
        try? save(state)
    }

    private func save(_ state: PersistedPracticeTimerState) throws {
        try store.save(encoder.encode(state))
    }

    private func makeSnapshot(
        for state: PersistedPracticeTimerState?,
        at timestamp: Date
    ) -> PracticeTimerSnapshot {
        guard let state else {
            return .inactive
        }

        return PracticeTimerSnapshot(
            activeRoutineId: state.routineId,
            startedAt: state.startedAt,
            activeElapsedSeconds: elapsedSeconds(for: state, at: timestamp),
            isRunning: state.resumedAt != nil,
            targetSeconds: state.targetSeconds
        )
    }

    private func elapsedSeconds(for state: PersistedPracticeTimerState, at timestamp: Date) -> Int {
        state.accumulatedActiveSeconds + (state.resumedAt.map {
            elapsedSeconds(since: $0, until: timestamp)
        } ?? 0)
    }

    private func elapsedSeconds(since start: Date, until end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start)))
    }

    private static func recoverState(from data: Data?, at now: Date) -> PersistedPracticeTimerState? {
        guard let data,
              let state = try? JSONDecoder().decode(PersistedPracticeTimerState.self, from: data),
              isValid(state, at: now) else {
            return nil
        }
        return state
    }

    private static func isValid(_ state: PersistedPracticeTimerState, at now: Date) -> Bool {
        guard state.startedAt <= now,
              state.accumulatedActiveSeconds >= 0,
              state.targetSeconds > 0 else {
            return false
        }

        if let resumedAt = state.resumedAt {
            guard resumedAt >= state.startedAt, resumedAt <= now else {
                return false
            }
        }

        let activeElapsed = Double(state.accumulatedActiveSeconds) + (state.resumedAt.map {
            max(0, now.timeIntervalSince($0))
        } ?? 0)
        return activeElapsed <= now.timeIntervalSince(state.startedAt) + 1
    }
}
