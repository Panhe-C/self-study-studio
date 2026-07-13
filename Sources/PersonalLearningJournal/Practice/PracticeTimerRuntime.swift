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

    private var activeState: PersistedPracticeTimerState?
    @Published public private(set) var snapshot: PracticeTimerSnapshot

    public init(
        store: any PracticeTimerStateStore,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
        let persistedData = store.load()
        let recoveredState = Self.recoverState(from: persistedData, at: now())
        activeState = recoveredState
        snapshot = Self.makeSnapshot(for: recoveredState, at: now())

        if persistedData != nil, recoveredState == nil {
            try? store.save(nil)
        }
    }

    public func start(routineId: UUID, targetSeconds: Int) throws {
        guard targetSeconds > 0 else {
            throw PracticeTimerRuntimeError.invalidTargetSeconds
        }
        if activeState != nil {
            let timestamp = now()
            _ = validActiveState(at: timestamp)
            if activeState != nil {
                throw PracticeTimerRuntimeError.activeTimerAlreadyExists
            }
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
        snapshot = Self.makeSnapshot(for: state, at: timestamp)
    }

    public func pause() {
        let timestamp = now()
        guard var state = validActiveState(at: timestamp), let resumedAt = state.resumedAt else {
            return
        }

        state.accumulatedActiveSeconds += Self.elapsedSeconds(since: resumedAt, until: timestamp)
        state.resumedAt = nil
        persistTransition(state, at: timestamp)
    }

    public func resume() {
        let timestamp = now()
        guard var state = validActiveState(at: timestamp), state.resumedAt == nil else {
            return
        }

        state.resumedAt = timestamp
        persistTransition(state, at: timestamp)
    }

    public func refresh() {
        let timestamp = now()
        guard let state = validActiveState(at: timestamp) else {
            if activeState == nil {
                snapshot = .inactive
            }
            return
        }
        snapshot = Self.makeSnapshot(for: state, at: timestamp)
    }

    public func consumeTargetCrossing() -> Bool {
        let timestamp = now()
        guard var state = validActiveState(at: timestamp),
              !state.targetFeedbackConsumed,
              Self.elapsedSeconds(for: state, at: timestamp) >= state.targetSeconds else {
            return false
        }

        state.targetFeedbackConsumed = true
        return persistTransition(state, at: timestamp)
    }

    public func finish() -> PracticeTimerCompletion? {
        let timestamp = now()
        guard let state = validActiveState(at: timestamp) else {
            return nil
        }

        let completion = PracticeTimerCompletion(
            routineId: state.routineId,
            startedAt: state.startedAt,
            endedAt: timestamp,
            activeDurationSeconds: Self.elapsedSeconds(for: state, at: timestamp)
        )
        do {
            try store.save(nil)
        } catch {
            snapshot = Self.makeSnapshot(for: state, at: timestamp)
            return nil
        }
        clearActiveState()
        return completion
    }

    public func discard() {
        let timestamp = now()
        guard let state = validActiveState(at: timestamp) else {
            return
        }
        do {
            try store.save(nil)
        } catch {
            snapshot = Self.makeSnapshot(for: state, at: timestamp)
            return
        }
        clearActiveState()
    }

    @discardableResult
    private func persistTransition(_ state: PersistedPracticeTimerState, at timestamp: Date) -> Bool {
        do {
            try save(state)
        } catch {
            if let activeState {
                snapshot = Self.makeSnapshot(for: activeState, at: timestamp)
            }
            return false
        }
        activeState = state
        snapshot = Self.makeSnapshot(for: state, at: timestamp)
        return true
    }

    private func save(_ state: PersistedPracticeTimerState) throws {
        try store.save(encoder.encode(state))
    }

    private func validActiveState(at timestamp: Date) -> PersistedPracticeTimerState? {
        guard let state = activeState else {
            return nil
        }
        guard Self.isValid(state, at: timestamp) else {
            discardInvalidState()
            return nil
        }
        return state
    }

    private func discardInvalidState() {
        do {
            try store.save(nil)
        } catch {
            snapshot = .inactive
            return
        }
        clearActiveState()
    }

    private func clearActiveState() {
        activeState = nil
        snapshot = .inactive
    }

    private static func makeSnapshot(
        for state: PersistedPracticeTimerState?,
        at timestamp: Date
    ) -> PracticeTimerSnapshot {
        guard let state else {
            return .inactive
        }

        return PracticeTimerSnapshot(
            activeRoutineId: state.routineId,
            startedAt: state.startedAt,
            activeElapsedSeconds: Self.elapsedSeconds(for: state, at: timestamp),
            isRunning: state.resumedAt != nil,
            targetSeconds: state.targetSeconds
        )
    }

    private static func elapsedSeconds(for state: PersistedPracticeTimerState, at timestamp: Date) -> Int {
        state.accumulatedActiveSeconds + (state.resumedAt.map {
            Self.elapsedSeconds(since: $0, until: timestamp)
        } ?? 0)
    }

    private static func elapsedSeconds(since start: Date, until end: Date) -> Int {
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
