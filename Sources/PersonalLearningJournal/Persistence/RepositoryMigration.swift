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
            + snapshot.trailEvents.map(JournalEntity.trailEvent)
        try repository.commit(
            JournalTransaction(
                upserts: entities,
                origin: .migration,
                stateMetadata: JournalStateMetadata(snapshot: snapshot),
                completedMigrationIdentifier: Self.legacySnapshotIdentifier
            )
        )
    }
}
