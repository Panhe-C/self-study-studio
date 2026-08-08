import Foundation

public protocol JournalRepository: AnyObject {
    func snapshot() throws -> JournalSnapshot
    func commit(_ transaction: JournalTransaction) throws
    func pendingMutations(limit: Int) throws -> [PendingMutation]
    /// Terminal mutations remain available for a deliberate recovery UI but
    /// are never returned by the automatic pending queue.
    func terminalMutations(limit: Int) throws -> [PendingMutation]
    /// Re-enables selected terminal mutations after a user has resolved the
    /// conflict or refreshed its guard expectation.
    func requeueTerminalMutations(_ mutationIDs: Set<UUID>) throws
    /// Atomically replaces terminal payloads and requeues them with the
    /// caller's freshly captured revision expectations.
    func replaceTerminalMutations(_ replacements: [TerminalMutationReplacement]) throws
    /// Discards selected terminal mutations without changing the local entity.
    func discardTerminalMutations(_ mutationIDs: Set<UUID>) throws
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
    func saveCalendarBinding(_ binding: CalendarBinding) throws
    func calendarBinding(for plannedSessionID: UUID) throws -> CalendarBinding?
    func calendarBindings() throws -> [CalendarBinding]
    func removeCalendarBinding(for plannedSessionID: UUID) throws
    func targetCalendarIdentifier() throws -> String?
    func saveTargetCalendarIdentifier(_ identifier: String?) throws
}

public extension JournalRepository {
    func terminalMutations(limit: Int) throws -> [PendingMutation] { [] }
    func requeueTerminalMutations(_ mutationIDs: Set<UUID>) throws {}
    func replaceTerminalMutations(_ replacements: [TerminalMutationReplacement]) throws {}
    func discardTerminalMutations(_ mutationIDs: Set<UUID>) throws {}

    func replaceTerminalMutation(_ replacement: TerminalMutationReplacement) throws {
        try replaceTerminalMutations([replacement])
    }

    func discardTerminalMutation(_ mutationID: UUID) throws {
        try discardTerminalMutations([mutationID])
    }

    func resolveTerminalMutations(_ mutationIDs: Set<UUID>) throws {
        try discardTerminalMutations(mutationIDs)
    }

    func resolveTerminalMutation(_ mutationID: UUID) throws {
        try discardTerminalMutations([mutationID])
    }

    func saveCalendarBinding(_ binding: CalendarBinding) throws {}
    func calendarBinding(for plannedSessionID: UUID) throws -> CalendarBinding? { nil }
    func calendarBindings() throws -> [CalendarBinding] { [] }
    func removeCalendarBinding(for plannedSessionID: UUID) throws {}
    func targetCalendarIdentifier() throws -> String? { nil }
    func saveTargetCalendarIdentifier(_ identifier: String?) throws {}
}

public final class InMemoryJournalRepository: JournalRepository {
    public typealias CommitHook = (JournalTransaction) throws -> Void
    public typealias SnapshotHook = (JournalSnapshot) throws -> JournalSnapshot?

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
    private var storedCalendarBindings: [UUID: CalendarBinding]
    private var storedTargetCalendarIdentifier: String?
    private let commitHook: CommitHook?
    private let snapshotHook: SnapshotHook?

    public init(
        snapshot: JournalSnapshot = JournalSnapshot(),
        now: @escaping () -> Date = Date.init,
        commitHook: CommitHook? = nil,
        snapshotHook: SnapshotHook? = nil
    ) {
        self.now = now
        let initialEntities: [JournalEntity] =
            snapshot.projects.map(JournalEntity.project)
            + snapshot.sessions.map(JournalEntity.session)
            + snapshot.proofs.map(JournalEntity.proof)
            + snapshot.reviews.map(JournalEntity.review)
            + snapshot.evidenceContracts.map(JournalEntity.evidenceContract)
            + snapshot.evidenceAcceptances.map(JournalEntity.evidenceAcceptance)
            + snapshot.proofRevisions.map(JournalEntity.proofRevision)
            + snapshot.reviewDecisions.map(JournalEntity.reviewDecision)
            + snapshot.trailEvents.map(JournalEntity.trailEvent)
            + snapshot.coursePlans.map(JournalEntity.coursePlan)
            + snapshot.planPhases.map(JournalEntity.planPhase)
            + snapshot.plannedSessions.map(JournalEntity.plannedSession)
            + snapshot.availabilityRules.map(JournalEntity.availabilityRule)
            + snapshot.schedulingPreferences.map(JournalEntity.schedulingPreferences)
            + snapshot.practiceRoutines.map(JournalEntity.practiceRoutine)
            + snapshot.practiceSessions.map(JournalEntity.practiceSession)
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
        self.storedCalendarBindings = [:]
        self.storedTargetCalendarIdentifier = nil
        self.commitHook = commitHook
        self.snapshotHook = snapshotHook
    }

    public func snapshot() throws -> JournalSnapshot {
        let stored = withLock {
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
                evidenceContracts: visibleEntities.compactMap {
                    guard case let .evidenceContract(value) = $0 else { return nil }
                    return value
                },
                evidenceAcceptances: visibleEntities.compactMap {
                    guard case let .evidenceAcceptance(value) = $0 else { return nil }
                    return value
                },
                proofRevisions: visibleEntities.compactMap {
                    guard case let .proofRevision(value) = $0 else { return nil }
                    return value
                },
                reviewDecisions: visibleEntities.compactMap {
                    guard case let .reviewDecision(value) = $0 else { return nil }
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
                availabilityRules: visibleEntities.compactMap {
                    guard case let .availabilityRule(value) = $0 else { return nil }
                    return value
                },
                schedulingPreferences: visibleEntities.compactMap {
                    guard case let .schedulingPreferences(value) = $0 else { return nil }
                    return value
                },
                practiceRoutines: visibleEntities.compactMap {
                    guard case let .practiceRoutine(value) = $0 else { return nil }
                    return value
                },
                practiceSessions: visibleEntities.compactMap {
                    guard case let .practiceSession(value) = $0 else { return nil }
                    return value
                },
                hasCompletedOnboarding: stateMetadata.hasCompletedOnboarding,
                pendingFirstRecordProjectId: stateMetadata.pendingFirstRecordProjectId
            )
        }
        return try snapshotHook?(stored) ?? stored
    }

    public func commit(_ transaction: JournalTransaction) throws {
        try withLock {
            try commitHook?(transaction)
            for entity in transaction.upserts {
                let reference = entity.reference
                if entities[reference] == nil {
                    entityOrder.append(reference)
                }
                entities[reference] = entity
                enqueueIfNeeded(
                    reference,
                    operation: .save,
                    origin: transaction.origin,
                    transactionID: transaction.transactionID,
                    revisionExpectation: transaction.revisionExpectations[reference]
                )
            }

            for reference in transaction.deletions {
                if let entity = entities[reference] {
                    entities[reference] = entity.deleting(at: now())
                }
                enqueueIfNeeded(
                    reference,
                    operation: .delete,
                    origin: transaction.origin,
                    transactionID: transaction.transactionID,
                    revisionExpectation: transaction.revisionExpectations[reference]
                )
            }
            if let metadata = transaction.stateMetadata {
                stateMetadata = metadata
            }
            for identifier in transaction.removedMigrationIdentifiers {
                completedMigrations.remove(identifier)
            }
            for identifier in transaction.completedMigrationIdentifiers {
                completedMigrations.insert(identifier)
            }
        }
    }

    public func pendingMutations(limit: Int) throws -> [PendingMutation] {
        withLock {
            Array(outbox.filter { !$0.isTerminal }.prefix(max(0, limit)))
        }
    }

    public func terminalMutations(limit: Int) throws -> [PendingMutation] {
        withLock {
            Array(outbox.filter(\.isTerminal).prefix(max(0, limit)))
        }
    }

    public func requeueTerminalMutations(_ mutationIDs: Set<UUID>) throws {
        // Keep the legacy entry point safe: requeueing now refreshes the
        // persisted guard and payload through the recovery service instead of
        // reviving the stale expectation that caused the terminal failure.
        try SyncConflictRecoveryService(repository: self)
            .retryTerminalMutations(mutationIDs)
    }

    public func replaceTerminalMutations(_ replacements: [TerminalMutationReplacement]) throws {
        guard !replacements.isEmpty else { return }
        try withLock {
            var indexes: [UUID: Int] = [:]
            for replacement in replacements {
                guard indexes[replacement.mutationID] == nil else {
                    throw TerminalMutationRecoveryError.mutationNotFound(replacement.mutationID)
                }
                guard let index = outbox.firstIndex(where: { $0.id == replacement.mutationID }) else {
                    throw TerminalMutationRecoveryError.mutationNotFound(replacement.mutationID)
                }
                guard outbox[index].isTerminal else {
                    throw TerminalMutationRecoveryError.mutationNotTerminal(replacement.mutationID)
                }
                guard outbox[index].entity == replacement.entity.reference else {
                    throw TerminalMutationRecoveryError.entityMismatch(
                        mutationID: replacement.mutationID,
                        expected: outbox[index].entity,
                        actual: replacement.entity.reference
                    )
                }
                indexes[replacement.mutationID] = index
            }

            for replacement in replacements {
                guard let index = indexes[replacement.mutationID] else { continue }
                let reference = replacement.entity.reference
                if entities[reference] == nil {
                    entityOrder.append(reference)
                }
                entities[reference] = replacement.entity
                outbox[index].operation = replacement.operation ?? outbox[index].operation
                outbox[index].revisionExpectation = replacement.revisionExpectation
                outbox[index].retryCount = 0
                outbox[index].lastError = nil
                outbox[index].isTerminal = false
            }
        }
    }

    public func discardTerminalMutations(_ mutationIDs: Set<UUID>) throws {
        guard !mutationIDs.isEmpty else { return }
        withLock {
            let transactionIDs = Set(
                outbox
                    .filter { mutationIDs.contains($0.id) && $0.isTerminal }
                    .map(\.transactionID)
            )
            outbox.removeAll {
                $0.isTerminal && (
                    mutationIDs.contains($0.id) || transactionIDs.contains($0.transactionID)
                )
            }
        }
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
            enqueueIfNeeded(
                reference,
                operation: .save,
                origin: .user,
                transactionID: UUID(),
                revisionExpectation: nil
            )
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
                    outbox[index].isTerminal = true
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

    public func saveCalendarBinding(_ binding: CalendarBinding) throws {
        withLock { storedCalendarBindings[binding.plannedSessionId] = binding }
    }

    public func calendarBinding(for plannedSessionID: UUID) throws -> CalendarBinding? {
        withLock { storedCalendarBindings[plannedSessionID] }
    }

    public func calendarBindings() throws -> [CalendarBinding] {
        withLock { storedCalendarBindings.values.sorted { $0.plannedSessionId.uuidString < $1.plannedSessionId.uuidString } }
    }

    public func removeCalendarBinding(for plannedSessionID: UUID) throws {
        _ = withLock { storedCalendarBindings.removeValue(forKey: plannedSessionID) }
    }

    public func targetCalendarIdentifier() throws -> String? {
        withLock { storedTargetCalendarIdentifier }
    }

    public func saveTargetCalendarIdentifier(_ identifier: String?) throws {
        withLock { storedTargetCalendarIdentifier = identifier }
    }

    private func enqueueIfNeeded(
        _ entity: JournalEntityReference,
        operation: SyncOperation,
        origin: MutationOrigin,
        transactionID: UUID,
        revisionExpectation: RevisionGuardExpectation?
    ) {
        guard case .user = origin else { return }
        // A reflection update is part of the base practice-session dependency
        // chain when that base mutation is still pending. Reusing its
        // transaction ID keeps Project/LearningSession/TrailEvent siblings
        // ahead of the final PracticeSession payload on CloudKit.
        let effectiveTransactionID: UUID
        if entity.kind == .practiceSession,
           let pendingBase = outbox.last(where: {
               $0.entity == entity && !$0.isTerminal
           }) {
            effectiveTransactionID = pendingBase.transactionID
        } else {
            effectiveTransactionID = transactionID
        }
        let effectiveRevisionExpectation: RevisionGuardExpectation?
        if entity.kind == .practiceSession,
           revisionExpectation == nil,
           let pendingBase = outbox.last(where: {
               $0.entity == entity && !$0.isTerminal
           }) {
            effectiveRevisionExpectation = pendingBase.revisionExpectation
        } else {
            effectiveRevisionExpectation = revisionExpectation
        }
        // Planning drafts and activation are separate local transactions but
        // represent one final payload per planning record. Practice base and
        // reflection writes have the same latest-payload requirement. Other
        // journal entities retain their historical append-only outbox
        // semantics. Terminal entries are retained for manual recovery and
        // are intentionally not coalesced.
        if Self.shouldCoalesce(entity.kind),
           let index = outbox.lastIndex(where: {
               $0.entity == entity && !$0.isTerminal
           }) {
            outbox.remove(at: index)
        }
        outbox.append(
            PendingMutation(
                transactionID: effectiveTransactionID,
                entity: entity,
                operation: operation,
                revisionExpectation: effectiveRevisionExpectation,
                enqueuedAt: now()
            )
        )
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func shouldCoalesce(_ kind: JournalEntityKind) -> Bool {
        switch kind {
        case .coursePlan, .planPhase, .plannedSession, .practiceRoutine:
            return true
        case .practiceSession:
            return true
        default:
            return false
        }
    }
}
