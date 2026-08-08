@preconcurrency import CloudKit
import Foundation

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing(pending: Int)
    case synced(lastSuccess: Date)
    case failed(pending: Int, conflicts: Int, message: String)
}

public enum CloudMutation: Sendable {
    case save(mutationID: UUID, entity: JournalEntity)
    case delete(mutationID: UUID, entity: JournalEntityReference)
}

/// Caller-supplied server tag used by a guarded save. The mutation enum stays
/// source-compatible with existing clients; guarded expectations travel as a
/// separate map so old fakes and adapters continue to compile.
public struct CloudRevisionExpectation: Equatable, Sendable {
    public let entity: JournalEntityReference
    public let baseRevisionID: UUID?
    public let recordChangeTag: String?
    public let recordState: RevisionGuardRecordState
    public let targetRecordState: RevisionGuardRecordState

    public init(entity: JournalEntityReference, recordChangeTag: String) {
        self.init(
            entity: entity,
            baseRevisionID: nil,
            recordChangeTag: recordChangeTag,
            recordState: .existingRecord,
            targetRecordState: .existingRecord
        )
    }

    public init(
        entity: JournalEntityReference,
        revisionExpectation: RevisionGuardExpectation
    ) {
        self.init(
            entity: entity,
            baseRevisionID: revisionExpectation.baseRevisionID,
            recordChangeTag: revisionExpectation.recordChangeTag,
            recordState: revisionExpectation.recordState,
            targetRecordState: revisionExpectation.targetRecordState
        )
    }

    public init(
        entity: JournalEntityReference,
        baseRevisionID: UUID?,
        recordChangeTag: String?,
        recordState: RevisionGuardRecordState,
        targetRecordState: RevisionGuardRecordState
    ) {
        self.entity = entity
        self.baseRevisionID = baseRevisionID
        self.recordChangeTag = recordChangeTag
        self.recordState = recordState
        self.targetRecordState = targetRecordState
    }
}

public enum CloudRevisionGuardError: Error, Equatable, Sendable {
    case stale(
        entity: JournalEntityReference,
        expectedRecordChangeTag: String?,
        actualRecordChangeTag: String?
    )
}

public struct CloudSendResult: Sendable {
    public var acknowledgedMutationIDs: Set<UUID>
    public var metadata: [SyncRecordMetadata]
    public var retryableErrors: [UUID: String]
    public var terminalErrors: [UUID: String]

    public init(
        acknowledgedMutationIDs: Set<UUID> = [],
        metadata: [SyncRecordMetadata] = [],
        retryableErrors: [UUID: String] = [:],
        terminalErrors: [UUID: String] = [:]
    ) {
        self.acknowledgedMutationIDs = acknowledgedMutationIDs
        self.metadata = metadata
        self.retryableErrors = retryableErrors
        self.terminalErrors = terminalErrors
    }
}

private struct CloudSyncPushSummary: Sendable {
    var terminalErrors: [UUID: String] = [:]
}

public enum CloudRemoteChange: @unchecked Sendable {
    case save(CKRecord)
    case delete(CKRecord.ID)
}

public struct CloudChangeBatch: @unchecked Sendable {
    public var changes: [CloudRemoteChange]
    public var tokenData: Data?
    public var moreComing: Bool

    public init(
        changes: [CloudRemoteChange] = [],
        tokenData: Data? = nil,
        moreComing: Bool = false
    ) {
        self.changes = changes
        self.tokenData = tokenData
        self.moreComing = moreComing
    }
}

public protocol CloudDatabaseClient: Sendable {
    func ensureZone(named: String) async throws
    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult
    func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: CloudRevisionExpectation]
    ) async throws -> CloudSendResult
    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch
}

public extension CloudDatabaseClient {
    func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: CloudRevisionExpectation]
    ) async throws -> CloudSendResult {
        // Legacy adapters that only implement the unguarded API remain
        // source-compatible; the production CK client overrides this method.
        try await send(mutations)
    }

    func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: String]
    ) async throws -> CloudSendResult {
        let converted = Dictionary(uniqueKeysWithValues: revisionExpectations.map { key, value in
            (key, CloudRevisionExpectation(entity: key, recordChangeTag: value))
        })
        return try await send(mutations, revisionExpectations: converted)
    }
}

public protocol CloudSyncCoordinating: AnyObject, Sendable {
    var status: SyncStatus { get async }
    func start() async
    func syncNow() async throws
}

@MainActor
public final class CloudSyncCoordinator: CloudSyncCoordinating {
    public nonisolated static let zoneName = "LearningJournalZone"

    private let repository: any JournalRepository
    private let client: any CloudDatabaseClient
    private let mapper: CloudRecordMapper
    private let merger: SyncMergeService
    private let now: () -> Date
    private var currentStatus: SyncStatus = .idle
    private var inFlightSync: Task<Void, Error>?

    public init(
        repository: any JournalRepository,
        client: any CloudDatabaseClient,
        mapper: CloudRecordMapper = CloudRecordMapper(),
        merger: SyncMergeService = SyncMergeService(),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.client = client
        self.mapper = mapper
        self.merger = merger
        self.now = now
    }

    public var status: SyncStatus { currentStatus }

    public func start() async {
        try? await syncNow()
    }

    public func syncNow() async throws {
        if let inFlightSync {
            return try await inFlightSync.value
        }

        let operation = Task { @MainActor [self] in
            try await performSync()
        }
        inFlightSync = operation
        do {
            try await operation.value
            inFlightSync = nil
        } catch {
            inFlightSync = nil
            throw error
        }
    }

    private func performSync() async throws {
        // Never let a fixed page boundary bisect a transaction. Fetching with
        // an expanding limit keeps the existing repository API source
        // compatible while ensuring all pending mutations are available for
        // transaction grouping before the first CloudKit call.
        let pending = try allPendingMutations()
        currentStatus = .syncing(pending: pending.count)
        do {
            try await client.ensureZone(named: Self.zoneName)
            let pushSummary = try await push(pending)
            try await pullRemoteChanges()
            // Re-read after pull/recovery. A terminal item may have been
            // replaced or discarded while the network operation was in
            // flight; retaining the initial snapshot would leave a resolved
            // conflict stuck in `.failed` until another unrelated sync.
            let remainingTerminal = try repository.terminalMutations(limit: 100)
            if !remainingTerminal.isEmpty {
                let conflicts = (try? repository.conflicts().count) ?? 0
                let messages = (
                    pushSummary.terminalErrors.values + remainingTerminal.compactMap(\.lastError)
                ).sorted()
                let message = messages.isEmpty
                    ? "Terminal sync item requires review"
                    : messages.joined(separator: "; ")
                currentStatus = .failed(
                    pending: (try? allPendingMutations().count) ?? 0,
                    conflicts: conflicts,
                    message: message
                )
                return
            }
            currentStatus = .synced(lastSuccess: now())
        } catch {
            let remaining = (try? allPendingMutations().count) ?? pending.count
            let conflicts = (try? repository.conflicts().count) ?? 0
            currentStatus = .failed(
                pending: remaining,
                conflicts: conflicts,
                message: error.localizedDescription
            )
            throw error
        }
    }

    private func allPendingMutations() throws -> [PendingMutation] {
        var limit = 100
        while true {
            let page = try repository.pendingMutations(limit: limit)
            guard page.count >= limit else { return page }
            // A repository returning exactly Int.max items is already at the
            // largest representable request; returning that complete page is
            // safer than overflowing the doubling arithmetic.
            guard limit <= Int.max / 2 else { return page }
            limit *= 2
        }
    }

    private func push(_ pending: [PendingMutation]) async throws -> CloudSyncPushSummary {
        let groups = Dictionary(grouping: pending, by: \.transactionID)
            .sorted { $0.key.uuidString < $1.key.uuidString }
        var acknowledgedMutationIDs: Set<UUID> = []
        var metadata: [SyncRecordMetadata] = []
        var retryableErrors: [UUID: String] = [:]
        var terminalErrors: [UUID: String] = [:]

        for (_, group) in groups {
            // A planning dependency chain intentionally keeps Project writes
            // append-only locally while sharing one transaction ID with its
            // plan/trail records. CloudKit modifyRecords cannot receive the
            // same record ID twice in one atomic batch, so collapse duplicate
            // references to the final local mutation. Trail events have
            // distinct IDs and therefore remain append-only in the payload.
            let effectiveGroup = Self.coalescedMutations(group)
            var revisionExpectations: [JournalEntityReference: CloudRevisionExpectation] = [:]
            var missingLocalEntity = false
            let mutations = try effectiveGroup.compactMap { mutation -> CloudMutation? in
                switch mutation.operation {
                case .save:
                    guard let entity = try repository.entity(for: mutation.entity) else {
                        missingLocalEntity = true
                        return nil
                    }
                    if let expectation = mutation.revisionExpectation {
                        revisionExpectations[mutation.entity] = CloudRevisionExpectation(
                            entity: mutation.entity,
                            revisionExpectation: expectation
                        )
                    }
                    return .save(mutationID: mutation.id, entity: entity)
                case .delete:
                    return .delete(mutationID: mutation.id, entity: mutation.entity)
                }
            }
            if missingLocalEntity {
                // A transaction cannot be split safely after one of its
                // records disappeared locally. Retain every mutation as a
                // terminal recovery item instead of silently retrying the
                // surviving subset forever.
                for mutation in group {
                    terminalErrors[mutation.id] = "missing local entity (\(mutation.entity.id.uuidString))"
                }
                continue
            }
            guard !mutations.isEmpty else { continue }

            do {
                let result = try await client.send(
                    mutations,
                    revisionExpectations: revisionExpectations
                )
                let acknowledgedReferences = Set(
                    effectiveGroup.compactMap { mutation in
                        result.acknowledgedMutationIDs.contains(mutation.id)
                            ? mutation.entity
                            : nil
                    }
                )
                acknowledgedMutationIDs.formUnion(
                    group.filter { acknowledgedReferences.contains($0.entity) }.map(\.id)
                )
                metadata.append(contentsOf: result.metadata)
                retryableErrors.merge(
                    Self.expandErrors(result.retryableErrors, from: effectiveGroup, group: group),
                    uniquingKeysWith: { _, new in new }
                )
                terminalErrors.merge(
                    Self.expandErrors(result.terminalErrors, from: effectiveGroup, group: group),
                    uniquingKeysWith: { _, new in new }
                )
            } catch let guardError as CloudRevisionGuardError {
                let message = String(describing: guardError)
                for mutation in group {
                    terminalErrors[mutation.id] = message
                }
            }
        }

        if !acknowledgedMutationIDs.isEmpty {
            try repository.acknowledge(
                acknowledgedMutationIDs,
                metadata: metadata
            )
        }
        if !retryableErrors.isEmpty || !terminalErrors.isEmpty {
            try repository.recordSyncFailures(
                retryable: retryableErrors,
                terminal: terminalErrors
            )
        }
        return CloudSyncPushSummary(terminalErrors: terminalErrors)
    }

    private static func coalescedMutations(_ group: [PendingMutation]) -> [PendingMutation] {
        var latestByReference: [JournalEntityReference: PendingMutation] = [:]
        for mutation in group {
            latestByReference[mutation.entity] = mutation
        }
        return group.filter { latestByReference[$0.entity]?.id == $0.id }
    }

    private static func expandErrors(
        _ errors: [UUID: String],
        from effectiveGroup: [PendingMutation],
        group: [PendingMutation]
    ) -> [UUID: String] {
        guard !errors.isEmpty else { return [:] }
        var expanded: [UUID: String] = [:]
        for (mutationID, message) in errors {
            guard let effective = effectiveGroup.first(where: { $0.id == mutationID }) else {
                expanded[mutationID] = message
                continue
            }
            for original in group where original.entity == effective.entity {
                expanded[original.id] = message
            }
        }
        return expanded
    }

    private func pullRemoteChanges() async throws {
        var token = try repository.syncChangeToken()
        var moreComing = true
        while moreComing {
            let batch = try await client.fetchChanges(after: token)
            try apply(batch.changes)
            if let nextToken = batch.tokenData {
                try repository.storeSyncChangeToken(nextToken)
                token = nextToken
            }
            moreComing = batch.moreComing
        }
    }

    private func apply(_ changes: [CloudRemoteChange]) throws {
        var upserts: [JournalEntity] = []
        var deletions: [JournalEntityReference] = []
        var conflicts: [SyncConflict] = []
        var remoteMetadata: [SyncRecordMetadata] = []

        for change in changes {
            switch change {
            case let .save(record):
                let remote = try mapper.entity(from: record)
                let reference = remote.reference
                var metadataState: SyncState = .synced
                remoteMetadata.append(
                    SyncRecordMetadata(
                        entity: reference,
                        zoneName: record.recordID.zoneID.zoneName,
                        recordName: record.recordID.recordName,
                        recordChangeTag: record.recordChangeTag,
                        lastSyncedPayload: try JSONEncoder.journal.encode(remote),
                        lastSyncedAt: now(),
                        state: .synced
                    )
                )
                guard let local = try repository.entity(for: reference),
                      let metadata = try repository.metadata(for: reference),
                      let basePayload = metadata.lastSyncedPayload,
                      let base = try? JSONDecoder.journal.decode(JournalEntity.self, from: basePayload) else {
                    upserts.append(remote)
                    continue
                }
                switch try merger.merge(base: base, local: local, server: remote, now: now()) {
                case let .merged(entity): upserts.append(entity)
                case let .conflict(conflict):
                    conflicts.append(conflict)
                    metadataState = .conflict
                }
                if metadataState == .conflict,
                   let index = remoteMetadata.lastIndex(where: { $0.entity == reference }) {
                    remoteMetadata[index].state = .conflict
                }
            case let .delete(recordID):
                if let reference = reference(for: recordID) {
                    deletions.append(reference)
                }
            }
        }

        if !upserts.isEmpty || !deletions.isEmpty || !conflicts.isEmpty {
            try repository.applyRemote(
                JournalTransaction(
                    upserts: upserts,
                    deletions: deletions,
                    origin: .remote
                ),
                conflicts: conflicts
            )
        }
        // Persist the server change tag even when a remote record was merged
        // into local state or resulted in a conflict. Never synthesize a new
        // tag by fetching and overwriting the server record.
        if !remoteMetadata.isEmpty {
            try repository.acknowledge([], metadata: remoteMetadata)
        }
    }

    private func reference(for recordID: CKRecord.ID) -> JournalEntityReference? {
        try? repository.reference(recordName: recordID.recordName)
    }
}
