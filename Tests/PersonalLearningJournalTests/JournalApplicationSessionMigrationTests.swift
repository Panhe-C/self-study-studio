import XCTest
import CloudKit
@testable import PersonalLearningJournal

@MainActor
final class JournalApplicationSessionMigrationTests: XCTestCase {
    func testMigrationGateAcceptsExplicitProofAndPracticeResolutions() throws {
        let project = Project(name: "Guitar", area: "Music", goal: "Play", currentNextStep: "Practice")
        let proof = try Proof(
            projectId: project.id,
            type: .audio,
            title: "Old claim",
            statement: "I can play it"
        )
        let routine = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 20,
            weekdays: [2]
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], proofs: [proof], practiceRoutines: [routine])
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = JournalApplicationSession(
            documentsDirectory: root,
            accountProvider: LocalOnlyAccountProvider(),
            repositoryOverride: repository
        )

        XCTAssertTrue(session.pendingMigration?.issues.contains(.proofNeedsEvidence(proof.id)) == true)
        XCTAssertTrue(session.pendingMigration?.issues.contains(.practiceNeedsProject(routine.id)) == true)
        XCTAssertTrue(session.isMigrationBlockingSync)

        session.resolveProof(proofID: proof.id, resolution: .keepNeedsEvidence)
        session.resolvePractice(routineID: routine.id, resolution: .keepUnlinked)
        session.continueMigration()

        XCTAssertNil(session.migrationError)
        XCTAssertNil(session.pendingMigration)
        XCTAssertFalse(session.isMigrationBlockingSync)
        XCTAssertEqual(try repository.snapshot().proofs.first?.integrity, .needsEvidence)
        XCTAssertTrue(try repository.hasCompletedMigration(identifier: ProductConvergenceMigration.identifier))
    }

    func testMigrationGateFailsClosedWithVisibleRetryWhenSnapshotCannotBeRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = JournalApplicationSession(
            documentsDirectory: root,
            accountProvider: LocalOnlyAccountProvider(),
            repositoryOverride: FailingSnapshotRepository()
        )

        XCTAssertTrue(session.migrationGateBlocked)
        XCTAssertNotNil(session.migrationError)
        XCTAssertNil(session.pendingMigration)

        session.retryMigrationGate()
        XCTAssertTrue(session.migrationGateBlocked)
        XCTAssertNotNil(session.migrationError)
    }

    func testPracticeBlocksMigrationGateRequiresExplicitSurvivorAndWritesBackup() throws {
        let project = Project(name: "Guitar", area: "Music", goal: "Play", currentNextStep: "Practice")
        let first = PracticeRoutine(
            projectId: project.id,
            name: "Technique",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 20,
            weekdays: [2]
        )
        let second = PracticeRoutine(
            projectId: project.id,
            name: "Repertoire",
            symbolName: "music.note",
            color: .teal,
            targetMinutes: 30,
            weekdays: [4]
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project],
                practiceRoutines: [first, second]
            )
        )
        try repository.commit(
            JournalTransaction(
                origin: .migration,
                completedMigrationIdentifiers: [
                    ProductConvergenceMigration.identifier,
                    ProductConvergenceMigration.statusMigrationIdentifier,
                    PlanRevisionMigration.identifier
                ]
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = JournalApplicationSession(
            documentsDirectory: root,
            accountProvider: LocalOnlyAccountProvider(),
            repositoryOverride: repository
        )

        XCTAssertEqual(
            session.pendingPracticeBlocksMigration?.issues,
            [.multipleActiveRoutines(project.id, [first.id, second.id].sorted { $0.uuidString < $1.uuidString })]
        )
        XCTAssertTrue(session.isMigrationBlockingSync)

        session.continuePracticeBlocksMigration(
            with: [.merge(survivorID: first.id)]
        )

        XCTAssertNil(session.migrationError)
        XCTAssertNil(session.pendingPracticeBlocksMigration)
        XCTAssertFalse(session.isMigrationBlockingSync)
        XCTAssertTrue(try repository.hasCompletedMigration(identifier: PracticeBlocksMigration.identifier))
        let migrated = try repository.snapshot()
        let active = migrated.practiceRoutines.filter { !$0.isArchived && $0.deletedAt == nil }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, first.id)
        XCTAssertEqual(active.first?.orderedBlocks.count, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("LearningJournal/Migrations/B3/practice-blocks-v1-backup.json")
                    .path
            )
        )
    }

}

private actor LocalOnlyAccountProvider: CloudAccountProviding {
    func accountStatus() async throws -> CKAccountStatus { .noAccount }

    func currentUserRecordName() async throws -> String? { nil }
}

private final class FailingSnapshotRepository: JournalRepository {
    private let backing = InMemoryJournalRepository()

    func snapshot() throws -> JournalSnapshot {
        throw ProductConvergenceMigrationError.repositoryValidationFailed
    }
    func commit(_ transaction: JournalTransaction) throws { try backing.commit(transaction) }
    func pendingMutations(limit: Int) throws -> [PendingMutation] { try backing.pendingMutations(limit: limit) }
    func acknowledge(_ mutationIDs: Set<UUID>, metadata: [SyncRecordMetadata]) throws { try backing.acknowledge(mutationIDs, metadata: metadata) }
    func conflicts() throws -> [SyncConflict] { try backing.conflicts() }
    func resolveConflict(id: UUID, with entity: JournalEntity) throws { try backing.resolveConflict(id: id, with: entity) }
    func hasCompletedMigration(identifier: String) throws -> Bool { try backing.hasCompletedMigration(identifier: identifier) }
    func entity(for reference: JournalEntityReference) throws -> JournalEntity? { try backing.entity(for: reference) }
    func metadata(for reference: JournalEntityReference) throws -> SyncRecordMetadata? { try backing.metadata(for: reference) }
    func reference(recordName: String) throws -> JournalEntityReference? { try backing.reference(recordName: recordName) }
    func recordSyncFailures(retryable: [UUID: String], terminal: [UUID: String]) throws { try backing.recordSyncFailures(retryable: retryable, terminal: terminal) }
    func syncChangeToken() throws -> Data? { try backing.syncChangeToken() }
    func storeSyncChangeToken(_ token: Data?) throws { try backing.storeSyncChangeToken(token) }
    func applyRemote(_ transaction: JournalTransaction, conflicts: [SyncConflict]) throws { try backing.applyRemote(transaction, conflicts: conflicts) }
}
