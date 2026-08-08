import Foundation

/// Coordinates the user-facing recovery actions for terminal outbox items.
/// The service always derives a new guard from persisted server metadata before
/// retrying; it never revives the stale expectation that caused the terminal
/// failure.
public final class SyncConflictRecoveryService: @unchecked Sendable {
    private let repository: any JournalRepository

    public init(repository: any JournalRepository) {
        self.repository = repository
    }

    public func terminalMutations(limit: Int = 100) throws -> [PendingMutation] {
        try repository.terminalMutations(limit: limit)
    }

    public func freshRevisionExpectation(
        for mutation: PendingMutation
    ) throws -> RevisionGuardExpectation {
        if let original = mutation.revisionExpectation {
            let baseMetadata: SyncRecordMetadata?
            if let baseID = original.baseRevisionID {
                baseMetadata = try repository.metadata(
                    for: JournalEntityReference(mutation.entity.kind, baseID)
                )
            } else {
                baseMetadata = nil
            }
            let targetMetadata = try repository.metadata(for: mutation.entity)
            // A create guarded by `.newRecord` can become terminal after the
            // target was created elsewhere (or by an earlier partial attempt).
            // Once metadata proves that target exists, retry as a guarded
            // update against its current tag rather than repeating create.
            if original.recordState == .newRecord,
               let targetMetadata {
                return .existingTarget(
                    revisionID: mutation.entity.id,
                    recordChangeTag: targetMetadata.recordChangeTag
                )
            }
            let refreshedBaseTag: String?
            switch original.recordState {
            case .newRecord:
                refreshedBaseTag = nil
            case .existingRecord:
                // If a pull has not populated metadata for the base yet,
                // retain the captured tag rather than replacing it with nil
                // (which would turn a valid guard into a guaranteed mismatch).
                refreshedBaseTag = baseMetadata?.recordChangeTag
                    ?? original.baseRecordChangeTag
                    ?? original.recordChangeTag
            }

            let refreshedTargetState: RevisionGuardRecordState
            let refreshedTargetTag: String?
            switch original.targetRecordState {
            case .newRecord:
                if let targetMetadata {
                    // The target may have been created by an earlier partial
                    // attempt. Promote only the target guard to existing and
                    // keep the base identity/tag independent.
                    refreshedTargetState = .existingRecord
                    refreshedTargetTag = targetMetadata.recordChangeTag
                } else {
                    refreshedTargetState = .newRecord
                    refreshedTargetTag = nil
                }
            case .existingRecord:
                refreshedTargetState = .existingRecord
                // Preserve an existing target guard if metadata is currently
                // unavailable; unlike the base tag, it must never be replaced
                // with the base record's tag.
                refreshedTargetTag = targetMetadata?.recordChangeTag
                    ?? original.targetRecordChangeTag
            }
            return RevisionGuardExpectation(
                baseRevisionID: original.baseRevisionID,
                baseRecordChangeTag: refreshedBaseTag,
                targetRecordChangeTag: refreshedTargetTag,
                recordState: original.recordState,
                targetRecordState: refreshedTargetState
            )
        }

        if let metadata = try repository.metadata(for: mutation.entity) {
            return .existingTarget(
                revisionID: mutation.entity.id,
                recordChangeTag: metadata.recordChangeTag
            )
        }
        return .newRecord()
    }

    /// Replaces one or more terminal mutations in one repository transaction.
    /// Local payloads are read before any writes so a missing entity cannot
    /// leave a partially requeued group.
    public func retryTerminalMutations(_ mutationIDs: Set<UUID>) throws {
        guard !mutationIDs.isEmpty else { return }
        let terminal = try repository.terminalMutations(limit: 100_000)
        let byID = Dictionary(uniqueKeysWithValues: terminal.map { ($0.id, $0) })
        let requested = try mutationIDs.sorted { $0.uuidString < $1.uuidString }.map { id -> PendingMutation in
            guard let mutation = byID[id] else {
                throw TerminalMutationRecoveryError.mutationNotFound(id)
            }
            return mutation
        }
        // A CloudKit atomic transaction is represented by one transaction ID.
        // A UI row may identify only one terminal mutation, but recovering a
        // subset would leave its siblings blocked and could replay a partial
        // dependency chain. Expand the request to every terminal sibling.
        let transactionIDs = Set(requested.map(\.transactionID))
        let selected = terminal
            .filter { transactionIDs.contains($0.transactionID) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let replacements = try selected.map { mutation -> TerminalMutationReplacement in
            guard let entity = try repository.entity(for: mutation.entity) else {
                throw TerminalMutationRecoveryError.missingLocalEntity(mutation.entity)
            }
            return TerminalMutationReplacement(
                mutationID: mutation.id,
                entity: entity,
                revisionExpectation: try freshRevisionExpectation(for: mutation),
                operation: mutation.operation
            )
        }
        try repository.replaceTerminalMutations(replacements)
    }

    public func retryTerminalMutation(id: UUID) throws {
        try retryTerminalMutations([id])
    }

    public func discardTerminalMutations(_ mutationIDs: Set<UUID>) throws {
        guard !mutationIDs.isEmpty else { return }
        let terminal = try repository.terminalMutations(limit: 100_000)
        let terminalIDs = Set(terminal.map(\.id))
        for id in mutationIDs where !terminalIDs.contains(id) {
            throw TerminalMutationRecoveryError.mutationNotFound(id)
        }
        let requested = terminal.filter { mutationIDs.contains($0.id) }
        let transactionIDs = Set(requested.map(\.transactionID))
        let expanded = Set(
            terminal
                .filter { transactionIDs.contains($0.transactionID) }
                .map(\.id)
        )
        try repository.discardTerminalMutations(expanded)
    }

    public func discardTerminalMutation(id: UUID) throws {
        try discardTerminalMutations([id])
    }

    public func resolveTerminalMutations(_ mutationIDs: Set<UUID>) throws {
        try discardTerminalMutations(mutationIDs)
    }

    public func resolveTerminalMutation(id: UUID) throws {
        try discardTerminalMutation(id: id)
    }
}
