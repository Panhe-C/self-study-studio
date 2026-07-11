import Foundation

public protocol JournalRepository: AnyObject {
    func snapshot() throws -> JournalSnapshot
    func commit(_ transaction: JournalTransaction) throws
    func pendingMutations(limit: Int) throws -> [PendingMutation]
    func acknowledge(_ mutationIDs: Set<UUID>, metadata: [SyncRecordMetadata]) throws
    func conflicts() throws -> [SyncConflict]
    func resolveConflict(id: UUID, with entity: JournalEntity) throws
    func hasCompletedMigration(identifier: String) throws -> Bool
    func entity(for reference: JournalEntityReference) throws -> JournalEntity?
    func metadata(for reference: JournalEntityReference) throws -> SyncRecordMetadata?
    func reference(recordName: String) throws -> JournalEntityReference?
    func recordSyncFailures(
        retryable: [UUID: String],
        terminal: [UUID: String]
    ) throws
    func syncChangeToken() throws -> Data?
    func storeSyncChangeToken(_ token: Data?) throws
    func applyRemote(
        _ transaction: JournalTransaction,
        conflicts: [SyncConflict]
    ) throws
}

public final class InMemoryJournalRepository: JournalRepository {
    private let lock = NSLock()
    private let now: () -> Date
    private var entities: [JournalEntityReference: JournalEntity]
    private var entityOrder: [JournalEntityReference]
    private var outbox: [PendingMutation]
    private var recordMetadata: [JournalEntityReference: SyncRecordMetadata]
    private var storedConflicts: [SyncConflict]
    private var stateMetadata: JournalStateMetadata
    private var completedMigrations: Set<String>
    private var changeToken: Data?

    public init(
        snapshot: JournalSnapshot = JournalSnapshot(),
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        let initialEntities: [JournalEntity] =
            snapshot.projects.map(JournalEntity.project)
            + snapshot.sessions.map(JournalEntity.session)
            + snapshot.proofs.map(JournalEntity.proof)
            + snapshot.reviews.map(JournalEntity.review)
            + snapshot.trailEvents.map(JournalEntity.trailEvent)
            + snapshot.coursePlans.map(JournalEntity.coursePlan)
            + snapshot.planPhases.map(JournalEntity.planPhase)
            + snapshot.plannedSessions.map(JournalEntity.plannedSession)
        self.entities = Dictionary(
            uniqueKeysWithValues: initialEntities.map { ($0.reference, $0) }
        )
        self.entityOrder = initialEntities.map(\.reference)
        self.outbox = []
        self.recordMetadata = [:]
        self.storedConflicts = []
        self.stateMetadata = JournalStateMetadata(snapshot: snapshot)
        self.completedMigrations = []
        self.changeToken = nil
    }

    public func snapshot() throws -> JournalSnapshot {
        withLock {
            let visibleEntities = entityOrder.compactMap { reference in
                entities[reference].flatMap { $0.isDeleted ? nil : $0 }
            }
            return JournalSnapshot(
                projects: visibleEntities.compactMap {
                    guard case let .project(value) = $0 else { return nil }
                    return value
                },
                sessions: visibleEntities.compactMap {
                    guard case let .session(value) = $0 else { return nil }
                    return value
                },
                proofs: visibleEntities.compactMap {
                    guard case let .proof(value) = $0 else { return nil }
                    return value
                },
                reviews: visibleEntities.compactMap {
                    guard case let .review(value) = $0 else { return nil }
                    return value
                },
                trailEvents: visibleEntities.compactMap {
                    guard case let .trailEvent(value) = $0 else { return nil }
                    return value
                },
                coursePlans: visibleEntities.compactMap {
                    guard case let .coursePlan(value) = $0 else { return nil }
                    return value
                },
                planPhases: visibleEntities.compactMap {
                    guard case let .planPhase(value) = $0 else { return nil }
                    return value
                },
                plannedSessions: visibleEntities.compactMap {
                    guard case let .plannedSession(value) = $0 else { return nil }
                    return value
                },
                hasCompletedOnboarding: stateMetadata.hasCompletedOnboarding,
                pendingFirstRecordProjectId: stateMetadata.pendingFirstRecordProjectId
            )
        }
    }

    public func commit(_ transaction: JournalTransaction) throws {
        withLock {
            for entity in transaction.upserts {
                let reference = entity.reference
                if entities[reference] == nil {
                    entityOrder.append(reference)
                }
                entities[reference] = entity
                enqueueIfNeeded(reference, operation: .save, origin: transaction.origin)
            }

            for reference in transaction.deletions {
                if let entity = entities[reference] {
                    entities[reference] = entity.deleting(at: now())
                }
                enqueueIfNeeded(reference, operation: .delete, origin: transaction.origin)
            }
            if let metadata = transaction.stateMetadata {
                stateMetadata = metadata
            }
            if let identifier = transaction.completedMigrationIdentifier {
                completedMigrations.insert(identifier)
            }
        }
    }

    public func pendingMutations(limit: Int) throws -> [PendingMutation] {
        withLock { Array(outbox.prefix(max(0, limit))) }
    }

    public func acknowledge(
        _ mutationIDs: Set<UUID>,
        metadata: [SyncRecordMetadata]
    ) throws {
        withLock {
            outbox.removeAll { mutationIDs.contains($0.id) }
            for value in metadata {
                recordMetadata[value.entity] = value
            }
        }
    }

    public func conflicts() throws -> [SyncConflict] {
        withLock { storedConflicts.filter { $0.resolvedAt == nil } }
    }

    public func resolveConflict(id: UUID, with entity: JournalEntity) throws {
        withLock {
            guard let index = storedConflicts.firstIndex(where: { $0.id == id }) else {
                return
            }
            storedConflicts[index].resolvedAt = now()
            let reference = entity.reference
            if entities[reference] == nil {
                entityOrder.append(reference)
            }
            entities[reference] = entity
            enqueueIfNeeded(reference, operation: .save, origin: .user)
        }
    }

    public func hasCompletedMigration(identifier: String) throws -> Bool {
        withLock { completedMigrations.contains(identifier) }
    }

    public func entity(for reference: JournalEntityReference) throws -> JournalEntity? {
        withLock { entities[reference] }
    }

    public func metadata(for reference: JournalEntityReference) throws -> SyncRecordMetadata? {
        withLock { recordMetadata[reference] }
    }

    public func reference(recordName: String) throws -> JournalEntityReference? {
        withLock {
            recordMetadata.values.first { $0.recordName == recordName }?.entity
        }
    }

    public func recordSyncFailures(
        retryable: [UUID: String],
        terminal: [UUID: String]
    ) throws {
        withLock {
            for index in outbox.indices {
                if let message = retryable[outbox[index].id] {
                    outbox[index].retryCount += 1
                    outbox[index].lastError = message
                } else if let message = terminal[outbox[index].id] {
                    outbox[index].lastError = message
                }
            }
        }
    }

    public func syncChangeToken() throws -> Data? {
        withLock { changeToken }
    }

    public func storeSyncChangeToken(_ token: Data?) throws {
        withLock { changeToken = token }
    }

    public func applyRemote(
        _ transaction: JournalTransaction,
        conflicts: [SyncConflict]
    ) throws {
        try commit(transaction)
        withLock { storedConflicts.append(contentsOf: conflicts) }
    }

    private func enqueueIfNeeded(
        _ entity: JournalEntityReference,
        operation: SyncOperation,
        origin: MutationOrigin
    ) {
        guard case .user = origin else { return }
        outbox.append(
            PendingMutation(
                entity: entity,
                operation: operation,
                enqueuedAt: now()
            )
        )
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
