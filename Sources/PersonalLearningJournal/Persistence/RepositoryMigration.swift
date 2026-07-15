import Foundation

public struct RepositoryMigration {
    public static let legacySnapshotIdentifier = "journal-v1-snapshot"

    public init() {}

    public func migrateIfNeeded(
        from legacyStore: any JournalStore,
        to repository: any JournalRepository,
        backupDirectory: URL? = nil
    ) throws {
        guard try !repository.hasCompletedMigration(
            identifier: Self.legacySnapshotIdentifier
        ) else {
            return
        }

        let snapshot = try legacyStore.load()
        if let backupDirectory {
            try FileManager.default.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true
            )
            let backupURL = backupDirectory
                .appendingPathComponent("journal-v1-backup.json")
            let data = try JSONEncoder.journal.encode(snapshot)
            try data.write(to: backupURL, options: [.atomic])
        }

        let entities: [JournalEntity] =
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
        try repository.commit(
            JournalTransaction(
                upserts: entities,
                origin: .migration,
                stateMetadata: JournalStateMetadata(snapshot: snapshot),
                completedMigrationIdentifier: Self.legacySnapshotIdentifier
            )
        )
    }

    @discardableResult
    public func convergeIfNeeded(
        repository: any JournalRepository,
        resolutions: [MigrationResolution],
        backupDirectory: URL
    ) throws -> MigrationValidationReport? {
        guard try !repository.hasCompletedMigration(
            identifier: ProductConvergenceMigration.identifier
        ) else {
            return nil
        }
        return try ProductConvergenceMigration().execute(
            snapshot: repository.snapshot(),
            resolutions: resolutions,
            repository: repository,
            backupDirectory: backupDirectory
        )
    }
}
