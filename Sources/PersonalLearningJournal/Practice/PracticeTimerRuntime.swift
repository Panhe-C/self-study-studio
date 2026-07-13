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

public struct PracticeTimerCompletion: Codable, Equatable, Sendable {
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

public struct PracticePendingCompletionDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let completion: PracticeTimerCompletion
    public var note: String
    public var linkedProjectId: UUID?

    public init(
        id: UUID = UUID(),
        completion: PracticeTimerCompletion,
        note: String = "",
        linkedProjectId: UUID? = nil
    ) {
        self.id = id
        self.completion = completion
        self.note = note
        self.linkedProjectId = linkedProjectId
    }
}

public enum PracticeTimerRuntimeError: Error, Equatable, Sendable {
    case invalidTargetSeconds
    case activeTimerAlreadyExists
    case pendingCompletionExists
    case pendingCompletionCouldNotClear
}

@MainActor
public final class PracticeTimerLifecycleCoordinator {
    private let runtime: PracticeTimerRuntime
    private let feedback: @MainActor () -> Void

    public init(
        runtime: PracticeTimerRuntime,
        feedback: @escaping @MainActor () -> Void = {}
    ) {
        self.runtime = runtime
        self.feedback = feedback
    }

    public func refresh(deliverFeedback: Bool) {
        runtime.refresh()
        if deliverFeedback, runtime.consumeTargetCrossing() {
            feedback()
        }
    }
}

struct PersistedPracticeTimerState: Codable, Equatable {
    let routineId: UUID
    let startedAt: Date
    var accumulatedActiveSeconds: Int
    var resumedAt: Date?
    let targetSeconds: Int
    var targetFeedbackConsumed: Bool
}

private struct PersistedPracticeTimerLocalState: Codable, Equatable {
    let version: Int
    var active: PersistedPracticeTimerState?
    var pending: PracticePendingCompletionDraft?

    init(active: PersistedPracticeTimerState?, pending: PracticePendingCompletionDraft?) {
        version = 1
        self.active = active
        self.pending = pending
    }
}

@MainActor
public final class PracticeTimerRuntime: ObservableObject {
    private let store: any PracticeTimerStateStore
    private let now: @MainActor () -> Date
    private let encoder = JSONEncoder()

    private var activeState: PersistedPracticeTimerState?
    @Published public private(set) var snapshot: PracticeTimerSnapshot
    @Published public private(set) var pendingCompletion: PracticePendingCompletionDraft?
    @Published public private(set) var lastRefreshDate: Date

    public init(
        store: any PracticeTimerStateStore,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
        let timestamp = now()
        let persistedData = store.load()
        let recoveredState = Self.recoverLocalState(from: persistedData, at: timestamp)
        activeState = recoveredState?.active
        pendingCompletion = recoveredState?.pending
        snapshot = Self.makeSnapshot(for: recoveredState?.active, at: timestamp)
        lastRefreshDate = timestamp

        if persistedData != nil, recoveredState == nil {
            try? store.save(nil)
        }
    }

    public func start(routineId: UUID, targetSeconds: Int) throws {
        guard targetSeconds > 0 else {
            throw PracticeTimerRuntimeError.invalidTargetSeconds
        }
        guard pendingCompletion == nil else {
            throw PracticeTimerRuntimeError.pendingCompletionExists
        }
        if activeState != nil {
            let timestamp = now()
            lastRefreshDate = timestamp
            _ = validActiveState(at: timestamp)
            if activeState != nil {
                throw PracticeTimerRuntimeError.activeTimerAlreadyExists
            }
        }

        let timestamp = now()
        lastRefreshDate = timestamp
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
        lastRefreshDate = timestamp
        guard var state = validActiveState(at: timestamp), let resumedAt = state.resumedAt else {
            return
        }

        state.accumulatedActiveSeconds += Self.elapsedSeconds(since: resumedAt, until: timestamp)
        state.resumedAt = nil
        persistTransition(state, at: timestamp)
    }

    public func resume() {
        let timestamp = now()
        lastRefreshDate = timestamp
        guard var state = validActiveState(at: timestamp), state.resumedAt == nil else {
            return
        }

        state.resumedAt = timestamp
        persistTransition(state, at: timestamp)
    }

    public func refresh() {
        let timestamp = now()
        lastRefreshDate = timestamp
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
        lastRefreshDate = timestamp
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
        lastRefreshDate = timestamp
        guard let state = validActiveState(at: timestamp) else {
            return nil
        }

        let completion = PracticeTimerCompletion(
            routineId: state.routineId,
            startedAt: state.startedAt,
            endedAt: timestamp,
            activeDurationSeconds: Self.elapsedSeconds(for: state, at: timestamp)
        )
        let pending = PracticePendingCompletionDraft(completion: completion)
        do {
            try saveLocalState(active: nil, pending: pending)
        } catch {
            snapshot = Self.makeSnapshot(for: state, at: timestamp)
            return nil
        }
        activeState = nil
        pendingCompletion = pending
        snapshot = .inactive
        return completion
    }

    public func discard() {
        let timestamp = now()
        lastRefreshDate = timestamp
        guard let state = validActiveState(at: timestamp) else {
            return
        }
        do {
            try saveLocalState(active: nil, pending: pendingCompletion)
        } catch {
            snapshot = Self.makeSnapshot(for: state, at: timestamp)
            return
        }
        clearActiveState()
    }

    @discardableResult
    public func updatePendingCompletion(note: String, linkedProjectId: UUID?) -> Bool {
        let timestamp = now()
        lastRefreshDate = timestamp
        guard var pendingCompletion else { return false }
        pendingCompletion.note = note
        pendingCompletion.linkedProjectId = linkedProjectId
        do {
            try saveLocalState(active: activeState, pending: pendingCompletion)
        } catch {
            return false
        }
        self.pendingCompletion = pendingCompletion
        return true
    }

    @discardableResult
    public func clearPendingCompletion() -> Bool {
        let timestamp = now()
        lastRefreshDate = timestamp
        guard pendingCompletion != nil else { return true }
        do {
            try saveLocalState(active: activeState, pending: nil)
        } catch {
            return false
        }
        pendingCompletion = nil
        return true
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
        try saveLocalState(active: state, pending: pendingCompletion)
    }

    private func saveLocalState(
        active: PersistedPracticeTimerState?,
        pending: PracticePendingCompletionDraft?
    ) throws {
        if active == nil, pending == nil {
            try store.save(nil)
            return
        }
        try store.save(encoder.encode(PersistedPracticeTimerLocalState(active: active, pending: pending)))
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
            try saveLocalState(active: nil, pending: pendingCompletion)
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

    private static func recoverLocalState(
        from data: Data?,
        at now: Date
    ) -> PersistedPracticeTimerLocalState? {
        guard let data else {
            return PersistedPracticeTimerLocalState(active: nil, pending: nil)
        }

        if let localState = try? JSONDecoder().decode(PersistedPracticeTimerLocalState.self, from: data),
           isValid(localState, at: now) {
            return localState
        }

        if let legacyActive = try? JSONDecoder().decode(PersistedPracticeTimerState.self, from: data),
           isValid(legacyActive, at: now) {
            return PersistedPracticeTimerLocalState(active: legacyActive, pending: nil)
        }
        return nil
    }

    private static func isValid(_ state: PersistedPracticeTimerLocalState, at now: Date) -> Bool {
        guard state.version == 1, state.active == nil || state.pending == nil else { return false }
        let activeIsValid = state.active.map { isValid($0, at: now) } ?? true
        let pendingIsValid = state.pending.map { isValid($0) } ?? true
        return activeIsValid && pendingIsValid
    }

    private static func isValid(_ pending: PracticePendingCompletionDraft) -> Bool {
        let completion = pending.completion
        let wallClockDuration = completion.endedAt.timeIntervalSince(completion.startedAt)
        return wallClockDuration >= 0
            && completion.activeDurationSeconds >= 0
            && Double(completion.activeDurationSeconds) <= wallClockDuration + 1
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
