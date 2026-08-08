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

public struct PracticeTimerBlockSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let targetMinutes: Int
    public let ordinal: Int
    public let focus: String?
    public let nextFocusCandidates: [String]
    public let activeDurationSeconds: Int
    public let visitCount: Int
    public let wasSkipped: Bool
    public let wasExtended: Bool

    public init(
        id: UUID,
        name: String,
        targetMinutes: Int,
        ordinal: Int,
        focus: String? = nil,
        nextFocusCandidates: [String] = [],
        activeDurationSeconds: Int = 0,
        visitCount: Int = 0,
        wasSkipped: Bool = false,
        wasExtended: Bool = false
    ) {
        self.id = id
        self.name = name
        self.targetMinutes = targetMinutes
        self.ordinal = ordinal
        self.focus = focus
        self.nextFocusCandidates = nextFocusCandidates
        self.activeDurationSeconds = activeDurationSeconds
        self.visitCount = visitCount
        self.wasSkipped = wasSkipped
        self.wasExtended = wasExtended
    }

    public init(
        block: PracticeBlock,
        activeDurationSeconds: Int = 0,
        visitCount: Int = 0,
        wasSkipped: Bool = false
    ) {
        self.init(
            id: block.id,
            name: block.name,
            targetMinutes: block.targetMinutes,
            ordinal: block.ordinal,
            focus: block.focus,
            nextFocusCandidates: block.nextFocusCandidates,
            activeDurationSeconds: activeDurationSeconds,
            visitCount: visitCount,
            wasSkipped: wasSkipped,
            wasExtended: activeDurationSeconds > block.targetMinutes * 60
        )
    }
}

public struct PracticeTimerSnapshot: Equatable, Sendable {
    public let activeRoutineId: UUID?
    public let startedAt: Date?
    public let activeElapsedSeconds: Int
    public let isRunning: Bool
    public let targetSeconds: Int
    public let blocks: [PracticeTimerBlockSnapshot]
    public let activeBlockID: UUID?

    public var currentBlockID: UUID? { activeBlockID }
    public var currentBlock: PracticeTimerBlockSnapshot? {
        guard let activeBlockID else { return nil }
        return blocks.first { $0.id == activeBlockID }
    }

    public init(
        activeRoutineId: UUID?,
        startedAt: Date?,
        activeElapsedSeconds: Int,
        isRunning: Bool,
        targetSeconds: Int,
        blocks: [PracticeTimerBlockSnapshot] = [],
        activeBlockID: UUID? = nil
    ) {
        self.activeRoutineId = activeRoutineId
        self.startedAt = startedAt
        self.activeElapsedSeconds = activeElapsedSeconds
        self.isRunning = isRunning
        self.targetSeconds = targetSeconds
        self.blocks = blocks
        self.activeBlockID = activeBlockID
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
    public let blocks: [PracticeBlock]
    public let segments: [PracticeSegment]
    public let summary: PracticeSummary?

    public init(
        routineId: UUID,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        blocks: [PracticeBlock] = [],
        segments: [PracticeSegment] = [],
        summary: PracticeSummary? = nil
    ) {
        self.routineId = routineId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationSeconds = activeDurationSeconds
        self.blocks = blocks
        self.segments = segments
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case routineId, startedAt, endedAt, activeDurationSeconds
        case blocks, segments, summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            routineId: try container.decode(UUID.self, forKey: .routineId),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decode(Date.self, forKey: .endedAt),
            activeDurationSeconds: try container.decode(Int.self, forKey: .activeDurationSeconds),
            blocks: try container.decodeIfPresent([PracticeBlock].self, forKey: .blocks) ?? [],
            segments: try container.decodeIfPresent([PracticeSegment].self, forKey: .segments) ?? [],
            summary: try container.decodeIfPresent(PracticeSummary.self, forKey: .summary)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(routineId, forKey: .routineId)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(activeDurationSeconds, forKey: .activeDurationSeconds)
        if !blocks.isEmpty { try container.encode(blocks, forKey: .blocks) }
        if !segments.isEmpty { try container.encode(segments, forKey: .segments) }
        try container.encodeIfPresent(summary, forKey: .summary)
    }
}

public struct PracticeRoutinePresentationSnapshot: Codable, Equatable, Sendable {
    public let routineId: UUID
    public let name: String
    public let symbolName: String
    public let color: PracticeSemanticColor

    public init(routine: PracticeRoutine) {
        routineId = routine.id
        name = routine.name
        symbolName = routine.symbolName
        color = routine.color
    }
}

public struct PracticePendingCompletionDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let completion: PracticeTimerCompletion
    public let routinePresentation: PracticeRoutinePresentationSnapshot?
    public var note: String
    public var linkedProjectId: UUID?

    public init(
        id: UUID = UUID(),
        completion: PracticeTimerCompletion,
        routinePresentation: PracticeRoutinePresentationSnapshot? = nil,
        note: String = "",
        linkedProjectId: UUID? = nil
    ) {
        self.id = id
        self.completion = completion
        self.routinePresentation = routinePresentation
        self.note = note
        self.linkedProjectId = linkedProjectId
    }
}

public enum PracticeTimerRuntimeError: Error, Equatable, Sendable {
    case invalidTargetSeconds
    case activeTimerAlreadyExists
    case pendingCompletionExists
    case pendingCompletionCouldNotClear
    case invalidRoutineBlocks
    case unknownBlock
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
    let routinePresentation: PracticeRoutinePresentationSnapshot?
    var blocks: [PracticeBlock]
    var currentBlockID: UUID?
    var segments: [PracticeSegment]
    var skippedBlockIDs: Set<UUID>

    init(
        routineId: UUID,
        startedAt: Date,
        accumulatedActiveSeconds: Int,
        resumedAt: Date?,
        targetSeconds: Int,
        targetFeedbackConsumed: Bool,
        routinePresentation: PracticeRoutinePresentationSnapshot? = nil,
        blocks: [PracticeBlock] = [],
        currentBlockID: UUID? = nil,
        segments: [PracticeSegment] = [],
        skippedBlockIDs: Set<UUID> = []
    ) {
        self.routineId = routineId
        self.startedAt = startedAt
        self.accumulatedActiveSeconds = accumulatedActiveSeconds
        self.resumedAt = resumedAt
        self.targetSeconds = targetSeconds
        self.targetFeedbackConsumed = targetFeedbackConsumed
        self.routinePresentation = routinePresentation
        self.blocks = blocks
        self.currentBlockID = currentBlockID
        self.segments = segments
        self.skippedBlockIDs = skippedBlockIDs
    }

    private enum CodingKeys: String, CodingKey {
        case routineId, startedAt, accumulatedActiveSeconds, resumedAt, targetSeconds
        case targetFeedbackConsumed, routinePresentation, blocks, currentBlockID
        case segments, skippedBlockIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            routineId: try container.decode(UUID.self, forKey: .routineId),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            accumulatedActiveSeconds: try container.decode(Int.self, forKey: .accumulatedActiveSeconds),
            resumedAt: try container.decodeIfPresent(Date.self, forKey: .resumedAt),
            targetSeconds: try container.decode(Int.self, forKey: .targetSeconds),
            targetFeedbackConsumed: try container.decodeIfPresent(Bool.self, forKey: .targetFeedbackConsumed) ?? false,
            routinePresentation: try container.decodeIfPresent(
                PracticeRoutinePresentationSnapshot.self,
                forKey: .routinePresentation
            ),
            blocks: try container.decodeIfPresent([PracticeBlock].self, forKey: .blocks) ?? [],
            currentBlockID: try container.decodeIfPresent(UUID.self, forKey: .currentBlockID),
            segments: try container.decodeIfPresent([PracticeSegment].self, forKey: .segments) ?? [],
            skippedBlockIDs: try container.decodeIfPresent(Set<UUID>.self, forKey: .skippedBlockIDs) ?? []
        )
    }
}

private struct PersistedPracticeTimerLocalState: Codable, Equatable {
    let version: Int
    var active: PersistedPracticeTimerState?
    var pending: PracticePendingCompletionDraft?

    init(
        active: PersistedPracticeTimerState?,
        pending: PracticePendingCompletionDraft?,
        version: Int = 2
    ) {
        self.version = version
        self.active = active
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case version, active, pending }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            active: try container.decodeIfPresent(PersistedPracticeTimerState.self, forKey: .active),
            pending: try container.decodeIfPresent(PracticePendingCompletionDraft.self, forKey: .pending),
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        )
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
    /// The last wall-clock instant observed by the runtime.
    ///
    /// This is intentionally not a second published source of truth. Refreshes update
    /// `snapshot` and `lastRefreshDate` together, so an active timer produces one
    /// observable change per displayed second instead of one publication per property.
    public private(set) var lastRefreshDate: Date

    public var activeRoutinePresentation: PracticeRoutinePresentationSnapshot? {
        activeState?.routinePresentation
    }

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

    public func start(
        routineId: UUID,
        targetSeconds: Int,
        routinePresentation: PracticeRoutinePresentationSnapshot? = nil
    ) throws {
        try start(
            routineId: routineId,
            targetSeconds: targetSeconds,
            blocks: [],
            routinePresentation: routinePresentation
        )
    }

    public func start(
        routine: PracticeRoutine,
        routinePresentation: PracticeRoutinePresentationSnapshot? = nil
    ) throws {
        let blocks = routine.orderedBlocks
        guard !blocks.isEmpty else {
            throw PracticeTimerRuntimeError.invalidRoutineBlocks
        }
        try start(
            routineId: routine.id,
            targetSeconds: routine.targetMinutes * 60,
            blocks: blocks,
            routinePresentation: routinePresentation ?? PracticeRoutinePresentationSnapshot(routine: routine)
        )
    }

    private func start(
        routineId: UUID,
        targetSeconds: Int,
        blocks: [PracticeBlock],
        routinePresentation: PracticeRoutinePresentationSnapshot?
    ) throws {
        guard targetSeconds > 0 else {
            throw PracticeTimerRuntimeError.invalidTargetSeconds
        }
        guard Set(blocks.map(\.id)).count == blocks.count else {
            throw PracticeTimerRuntimeError.invalidRoutineBlocks
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
            targetFeedbackConsumed: false,
            routinePresentation: routinePresentation,
            blocks: blocks.sorted {
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                return $0.id.uuidString < $1.id.uuidString
            },
            currentBlockID: blocks.min {
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                return $0.id.uuidString < $1.id.uuidString
            }?.id
        )
        try save(state)
        activeState = state
        snapshot = Self.makeSnapshot(for: state, at: timestamp)
    }

    public func pause() {
        let timestamp = now()
        lastRefreshDate = timestamp
        guard var state = validActiveState(at: timestamp), state.resumedAt != nil else {
            return
        }

        closeOpenSegment(&state, at: timestamp)
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

    /// Selects a block directly. A running segment is closed before switching
    /// so revisits remain separate segments and are combined only in summary.
    @discardableResult
    public func selectBlock(_ blockID: UUID) -> Bool {
        let timestamp = now()
        lastRefreshDate = timestamp
        guard var state = validActiveState(at: timestamp),
              state.blocks.contains(where: { $0.id == blockID }) else {
            return false
        }
        if state.currentBlockID == blockID {
            return true
        }
        if state.resumedAt != nil {
            closeOpenSegment(&state, at: timestamp)
        }
        state.currentBlockID = blockID
        if state.resumedAt != nil {
            state.resumedAt = timestamp
        }
        return persistTransition(state, at: timestamp)
    }

    /// Marks the current block skipped and advances to the next ordered block.
    /// If there is no next block the timer pauses until the learner chooses a
    /// block again, preventing un-attributed active time.
    @discardableResult
    public func skipCurrentBlock() -> Bool {
        let timestamp = now()
        lastRefreshDate = timestamp
        guard var state = validActiveState(at: timestamp),
              let currentBlockID = state.currentBlockID,
              let currentIndex = state.blocks.firstIndex(where: { $0.id == currentBlockID }) else {
            return false
        }
        let wasRunning = state.resumedAt != nil
        if wasRunning {
            closeOpenSegment(&state, at: timestamp)
        }
        state.skippedBlockIDs.insert(currentBlockID)
        let nextBlock = state.blocks.dropFirst(currentIndex + 1).first {
            !state.skippedBlockIDs.contains($0.id)
        }
        state.currentBlockID = nextBlock?.id
        if nextBlock == nil {
            state.resumedAt = nil
        } else if wasRunning {
            state.resumedAt = timestamp
        }
        return persistTransition(state, at: timestamp)
    }

    @discardableResult
    public func nextBlock() -> Bool {
        let timestamp = now()
        lastRefreshDate = timestamp
        guard var state = validActiveState(at: timestamp),
              let currentBlockID = state.currentBlockID,
              let currentIndex = state.blocks.firstIndex(where: { $0.id == currentBlockID }),
              currentIndex + 1 < state.blocks.count else {
            return false
        }
        if state.resumedAt != nil {
            closeOpenSegment(&state, at: timestamp)
        }
        state.currentBlockID = state.blocks[currentIndex + 1].id
        return persistTransition(state, at: timestamp)
    }

    public func refresh() {
        let timestamp = now()
        let nextSnapshot: PracticeTimerSnapshot
        guard let state = validActiveState(at: timestamp) else {
            if activeState == nil {
                nextSnapshot = .inactive
            } else {
                return
            }
            return publishRefresh(nextSnapshot, at: timestamp)
        }
        nextSnapshot = Self.makeSnapshot(for: state, at: timestamp)
        publishRefresh(nextSnapshot, at: timestamp)
    }

    private func publishRefresh(_ nextSnapshot: PracticeTimerSnapshot, at timestamp: Date) {
        let crossedWallClockSecond = floor(timestamp.timeIntervalSinceReferenceDate)
            != floor(lastRefreshDate.timeIntervalSinceReferenceDate)
        let snapshotChanged = nextSnapshot != snapshot
        guard crossedWallClockSecond || snapshotChanged else { return }

        if snapshotChanged {
            lastRefreshDate = timestamp
            snapshot = nextSnapshot
        } else {
            objectWillChange.send()
            lastRefreshDate = timestamp
        }
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

        var finishedState = state
        closeOpenSegment(&finishedState, at: timestamp)
        let segments = finishedState.segments
        let completion = PracticeTimerCompletion(
            routineId: state.routineId,
            startedAt: state.startedAt,
            endedAt: timestamp,
            activeDurationSeconds: finishedState.accumulatedActiveSeconds,
            blocks: finishedState.blocks,
            segments: segments,
            summary: finishedState.blocks.isEmpty
                ? nil
                : PracticeSummary.from(
                    blocks: finishedState.blocks,
                    segments: segments,
                    attentionMarker: nil
                )
        )
        let pending = PracticePendingCompletionDraft(
            completion: completion,
            routinePresentation: state.routinePresentation
        )
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

    /// Explicit cancellation alias used by the Guided Routine Player. It
    /// never creates a PracticeSession or pending completion.
    public func cancel() {
        discard()
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
                let nextSnapshot = Self.makeSnapshot(for: activeState, at: timestamp)
                if nextSnapshot != snapshot {
                    snapshot = nextSnapshot
                }
            }
            return false
        }
        activeState = state
        let nextSnapshot = Self.makeSnapshot(for: state, at: timestamp)
        if nextSnapshot != snapshot {
            snapshot = nextSnapshot
        }
        return true
    }

    private func closeOpenSegment(
        _ state: inout PersistedPracticeTimerState,
        at timestamp: Date
    ) {
        guard let resumedAt = state.resumedAt else {
            return
        }
        let activeDuration = Self.elapsedSeconds(since: resumedAt, until: timestamp)
        state.accumulatedActiveSeconds += activeDuration
        guard activeDuration > 0, let blockID = state.currentBlockID else { return }
        state.segments.append(
            PracticeSegment(
                blockID: blockID,
                startedAt: resumedAt,
                endedAt: timestamp,
                activeDurationSeconds: activeDuration
            )
        )
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
            targetSeconds: state.targetSeconds,
            blocks: blockSnapshots(for: state, at: timestamp),
            activeBlockID: state.currentBlockID
        )
    }

    private static func blockSnapshots(
        for state: PersistedPracticeTimerState,
        at timestamp: Date
    ) -> [PracticeTimerBlockSnapshot] {
        var durations: [UUID: Int] = [:]
        var visits: [UUID: Int] = [:]
        for segment in state.segments where !segment.isPause {
            durations[segment.blockID, default: 0] += segment.activeDurationSeconds
            if segment.activeDurationSeconds > 0 {
                visits[segment.blockID, default: 0] += 1
            }
        }
        if let resumedAt = state.resumedAt,
           let currentBlockID = state.currentBlockID {
            let openDuration = elapsedSeconds(since: resumedAt, until: timestamp)
            durations[currentBlockID, default: 0] += openDuration
            if openDuration > 0 {
                visits[currentBlockID, default: 0] += 1
            }
        }
        return state.blocks.sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.id.uuidString < $1.id.uuidString
        }.map { block in
            PracticeTimerBlockSnapshot(
                block: block,
                activeDurationSeconds: durations[block.id, default: 0],
                visitCount: visits[block.id, default: 0],
                wasSkipped: state.skippedBlockIDs.contains(block.id)
                    && durations[block.id, default: 0] == 0
            )
        }
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

        let object = try? JSONSerialization.jsonObject(with: data)
        let isLocalState = (object as? [String: Any])?.keys.contains {
            $0 == "version" || $0 == "active" || $0 == "pending"
        } == true
        if isLocalState,
           let localState = try? JSONDecoder().decode(PersistedPracticeTimerLocalState.self, from: data),
           localState.version == 1 || localState.version == 2,
           isValid(localState, at: now) {
            var migrated = localState
            if let active = migrated.active {
                migrated.active = normalized(active)
            }
            return migrated
        }

        if let legacyActive = try? JSONDecoder().decode(PersistedPracticeTimerState.self, from: data),
           isValid(legacyActive, at: now) {
            return PersistedPracticeTimerLocalState(
                active: normalized(legacyActive),
                pending: nil
            )
        }
        return nil
    }

    private static func isValid(_ state: PersistedPracticeTimerLocalState, at now: Date) -> Bool {
        guard (state.version == 1 || state.version == 2),
              state.active == nil || state.pending == nil else { return false }
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
            && pending.routinePresentation.map { $0.routineId == completion.routineId } ?? true
    }

    private static func isValid(_ state: PersistedPracticeTimerState, at now: Date) -> Bool {
        guard state.startedAt <= now,
              state.accumulatedActiveSeconds >= 0,
              state.targetSeconds > 0,
              state.routinePresentation.map({ $0.routineId == state.routineId }) ?? true else {
            return false
        }

        if !state.blocks.isEmpty {
            guard Set(state.blocks.map(\.id)).count == state.blocks.count,
                  state.blocks.allSatisfy({
                      (try? $0.validated()) != nil
                  }),
                  state.currentBlockID == nil
                    || state.blocks.contains(where: { $0.id == state.currentBlockID }),
                  state.skippedBlockIDs.isSubset(of: Set(state.blocks.map(\.id))) else {
                return false
            }
            guard state.segments.allSatisfy({ segment in
                (try? segment.validated()) != nil
                    && state.blocks.contains(where: { $0.id == segment.blockID })
            }) else {
                return false
            }
        }

        if let resumedAt = state.resumedAt {
            guard resumedAt >= state.startedAt, resumedAt <= now else {
                return false
            }
        }

        let activeElapsed = Double(state.accumulatedActiveSeconds) + (state.resumedAt.map {
            max(0, now.timeIntervalSince($0))
        } ?? 0)
        let segmentDuration = state.segments.reduce(0) { $0 + $1.activeDurationSeconds }
        return activeElapsed <= now.timeIntervalSince(state.startedAt) + 1
            && Double(segmentDuration) <= activeElapsed + 1
    }

    private static func normalized(
        _ state: PersistedPracticeTimerState
    ) -> PersistedPracticeTimerState {
        guard state.blocks.isEmpty else { return state }
        var migrated = state
        let block = PracticeBlock(
            id: state.routineId,
            name: state.routinePresentation?.name ?? "Practice",
            targetMinutes: max(1, (state.targetSeconds + 59) / 60),
            ordinal: 0
        )
        migrated.blocks = [block]
        migrated.currentBlockID = state.currentBlockID ?? block.id
        return migrated
    }
}
