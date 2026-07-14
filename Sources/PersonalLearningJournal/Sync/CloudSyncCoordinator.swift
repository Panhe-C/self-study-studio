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
    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch
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
        let pending = try repository.pendingMutations(limit: 100)
        currentStatus = .syncing(pending: pending.count)
        do {
            try await client.ensureZone(named: Self.zoneName)
            try await push(pending)
            try await pullRemoteChanges()
            currentStatus = .synced(lastSuccess: now())
        } catch {
            let remaining = (try? repository.pendingMutations(limit: 100).count) ?? pending.count
            let conflicts = (try? repository.conflicts().count) ?? 0
            currentStatus = .failed(
                pending: remaining,
                conflicts: conflicts,
                message: error.localizedDescription
            )
            throw error
        }
    }

    private func push(_ pending: [PendingMutation]) async throws {
        let mutations = try pending.compactMap { mutation -> CloudMutation? in
            switch mutation.operation {
            case .save:
                guard let entity = try repository.entity(for: mutation.entity) else { return nil }
                return .save(mutationID: mutation.id, entity: entity)
            case .delete:
                return .delete(mutationID: mutation.id, entity: mutation.entity)
            }
        }
        guard !mutations.isEmpty else { return }

        let result = try await client.send(mutations)
        if !result.acknowledgedMutationIDs.isEmpty {
            try repository.acknowledge(
                result.acknowledgedMutationIDs,
                metadata: result.metadata
            )
        }
        if !result.retryableErrors.isEmpty || !result.terminalErrors.isEmpty {
            try repository.recordSyncFailures(
                retryable: result.retryableErrors,
                terminal: result.terminalErrors
            )
        }
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

        for change in changes {
            switch change {
            case let .save(record):
                let remote = try mapper.entity(from: record)
                let reference = remote.reference
                guard let local = try repository.entity(for: reference),
                      let metadata = try repository.metadata(for: reference),
                      let basePayload = metadata.lastSyncedPayload,
                      let base = try? JSONDecoder.journal.decode(JournalEntity.self, from: basePayload) else {
                    upserts.append(remote)
                    continue
                }
                switch try merger.merge(base: base, local: local, server: remote, now: now()) {
                case let .merged(entity): upserts.append(entity)
                case let .conflict(conflict): conflicts.append(conflict)
                }
            case let .delete(recordID):
                if let reference = reference(for: recordID) {
                    deletions.append(reference)
                }
            }
        }

        guard !upserts.isEmpty || !deletions.isEmpty || !conflicts.isEmpty else { return }
        try repository.applyRemote(
            JournalTransaction(
                upserts: upserts,
                deletions: deletions,
                origin: .remote
            ),
            conflicts: conflicts
        )
    }

    private func reference(for recordID: CKRecord.ID) -> JournalEntityReference? {
        try? repository.reference(recordName: recordID.recordName)
    }
}
