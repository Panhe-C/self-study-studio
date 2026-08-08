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
            let refreshedTag: String?
            switch original.recordState {
            case .newRecord:
                refreshedTag = nil
            case .existingRecord:
                // If a pull has not populated metadata for the base yet,
                // retain the captured tag rather than replacing it with nil
                // (which would turn a valid guard into a guaranteed mismatch).
                refreshedTag = baseMetadata?.recordChangeTag
                    ?? targetMetadata?.recordChangeTag
                    ?? original.recordChangeTag
            }
            return RevisionGuardExpectation(
                baseRevisionID: original.baseRevisionID,
                recordChangeTag: refreshedTag,
                recordState: original.recordState,
                targetRecordState: original.targetRecordState
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
        let selected = try mutationIDs.sorted { $0.uuidString < $1.uuidString }.map { id -> PendingMutation in
            guard let mutation = byID[id] else {
                throw TerminalMutationRecoveryError.mutationNotFound(id)
            }
            return mutation
        }
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
        let terminalIDs = Set(
            try repository.terminalMutations(limit: 100_000).map(\.id)
        )
        for id in mutationIDs where !terminalIDs.contains(id) {
            throw TerminalMutationRecoveryError.mutationNotFound(id)
        }
        try repository.discardTerminalMutations(mutationIDs)
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
