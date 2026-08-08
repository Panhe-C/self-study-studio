import XCTest
@testable import PersonalLearningJournal

final class ProjectStatusMigrationTests: XCTestCase {
    func testCanonicalProjectStatusCasesExcludeLegacyStorageValues() {
        XCTAssertEqual(
            ProjectStatus.allCases,
            [.idea, .active, .paused, .completed, .abandoned]
        )
        XCTAssertTrue(ProjectStatus.lowFrequency.isLegacy)
        XCTAssertTrue(ProjectStatus.archived.isLegacy)
        XCTAssertTrue(ProjectStatus.trash.isLegacy)
        XCTAssertEqual(ProjectStatus.lowFrequency.canonicalStatus, .active)
        XCTAssertNil(ProjectStatus.archived.canonicalStatus)
        XCTAssertNil(ProjectStatus.trash.canonicalStatus)
    }

    func testLegacyProjectStatusesRemainReadableFromJSONAndCloudRawValues() throws {
        for rawValue in ["low-frequency", "archived", "trash"] {
            let data = Data(
                #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","area":"Test","goal":"Keep history","status":"\#(rawValue)","currentNextStep":"Review","lastActionType":"course","defaultDurationMinutes":30,"createdAt":"2001-01-01T00:00:00Z","updatedAt":"2001-01-01T00:00:00Z"}"#.utf8
            )
            let project = try JSONDecoder.journal.decode(Project.self, from: data)
            XCTAssertEqual(project.status.rawValue, rawValue)
        }
    }

    func testLegacyLowFrequencyKeepsActiveAttentionSemanticsUntilMigration() throws {
        let projectID = UUID()
        let contract = try EvidenceContract.weekly(
            projectId: projectID,
            expectedArtifact: .audio,
            acceptanceCriteria: "One complete recording",
            startsAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let project = Project(
            id: projectID,
            name: "Guitar",
            area: "Music",
            goal: "Play one song",
            status: .lowFrequency,
            currentNextStep: "Practice the chorus",
            activeEvidenceContractId: contract.id
        )

        XCTAssertTrue(project.countsTowardAttentionBudget)
        XCTAssertTrue(project.canContinue)
    }

    func testArchivedProjectCannotExecuteWithoutExplicitLearnerResolution() throws {
        let archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Archived project",
            area: "Test",
            goal: "Preserve history",
            status: .archived,
            currentNextStep: "Review",
            archivedAt: archivedAt
        )
        let snapshot = JournalSnapshot(projects: [project])
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backupDirectory) }

        let dryRun = ProductConvergenceMigration().dryRun(snapshot: snapshot)
        XCTAssertTrue(dryRun.issues.contains(.projectNeedsStatusResolution(project.id)))

        XCTAssertThrowsError(
            try ProductConvergenceMigration().execute(
                snapshot: snapshot,
                resolutions: [],
                repository: repository,
                backupDirectory: backupDirectory
            )
        ) { error in
            XCTAssertEqual(error as? ProductConvergenceMigrationError, .unresolvedIssues)
        }
    }

    func testArchivedCompletionUsesArchivedDateAndKeepsMigrationProvenance() throws {
        let archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Archived project",
            area: "Test",
            goal: "Preserve history",
            status: .archived,
            currentNextStep: "Review",
            archivedAt: archivedAt
        )
        let snapshot = JournalSnapshot(projects: [project])
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backupDirectory) }

        let report = try ProductConvergenceMigration().execute(
            snapshot: snapshot,
            resolutions: [.project(project.id, .complete)],
            repository: repository,
            backupDirectory: backupDirectory
        )

        XCTAssertTrue(report.isValid)
        let migrated = try XCTUnwrap(repository.snapshot().projects.first)
        XCTAssertEqual(migrated.status, .completed)
        XCTAssertEqual(migrated.completedAt, archivedAt)
        XCTAssertEqual(migrated.statusMigrationProvenance?.sourceStatus, "archived")
        XCTAssertEqual(migrated.statusMigrationProvenance?.decision, .completed)
    }

    func testTrashIsIndependentFromLifecycleAndRestoresCanonicalPreviousStatus() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [Project(
                    name: "Guitar",
                    area: "Music",
                    goal: "Play",
                    status: .active,
                    currentNextStep: "Practice",
                    activeEvidenceContractId: UUID()
                )]
            )
        )
        let service = JournalService(repository: repository, now: { timestamp })
        let projectID = try XCTUnwrap(service.snapshot().projects.first?.id)

        try service.moveToTrash(projectId: projectID)
        let trashed = try XCTUnwrap(service.project(id: projectID))
        XCTAssertEqual(trashed.status, .active)
        XCTAssertTrue(trashed.isTrashed)
        XCTAssertEqual(trashed.previousStatusBeforeTrash, .active)

        try service.restoreFromTrash(projectId: projectID)
        let restored = try XCTUnwrap(service.project(id: projectID))
        XCTAssertEqual(restored.status, .active)
        XCTAssertFalse(restored.isTrashed)
        XCTAssertNil(restored.previousStatusBeforeTrash)
    }

    func testMigrationCanonicalizesLowFrequencyAndTrashWithoutDroppingDependencies() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let activeID = UUID()
        let contract = try EvidenceContract.weekly(
            projectId: activeID,
            expectedArtifact: .text,
            acceptanceCriteria: "One explanation",
            startsAt: timestamp
        )
        let active = Project(
            id: activeID,
            name: "Low frequency",
            area: "Test",
            goal: "Keep going",
            status: .lowFrequency,
            currentNextStep: "Write",
            commitmentState: .ready,
            activeEvidenceContractId: contract.id
        )
        let trashedID = UUID()
        let trashed = Project(
            id: trashedID,
            name: "Trashed",
            area: "Test",
            goal: "Keep history",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: timestamp,
            previousStatusBeforeTrash: .lowFrequency
        )
        let session = try LearningSession(
            projectId: activeID,
            source: .quickLog,
            actionType: .course,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(1_800),
            durationMinutes: 30,
            note: "Kept the history",
            nextStepBefore: "Write",
            nextStepAfter: "Review"
        )
        let snapshot = JournalSnapshot(
            projects: [active, trashed],
            sessions: [session],
            evidenceContracts: [contract]
        )
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backupDirectory) }

        _ = try ProductConvergenceMigration().execute(
            snapshot: snapshot,
            resolutions: [],
            repository: repository,
            backupDirectory: backupDirectory
        )
        let migrated = try repository.snapshot()

        XCTAssertEqual(migrated.projects.first(where: { $0.id == activeID })?.status, .active)
        XCTAssertTrue(migrated.projects.first(where: { $0.id == activeID })?.countsTowardAttentionBudget == true)
        let migratedTrash: Project = try XCTUnwrap(migrated.projects.first(where: { $0.id == trashedID }))
        XCTAssertEqual(migratedTrash.status, .active)
        XCTAssertTrue(migratedTrash.isTrashed)
        XCTAssertEqual(migratedTrash.previousStatusBeforeTrash, .active)
        XCTAssertEqual(migrated.sessions.map(\LearningSession.id), [session.id])
        XCTAssertEqual(migrated.evidenceContracts.map(\EvidenceContract.id), [contract.id])
    }

    func testMigrationWritesStatusBackupAndMarkerAndIsIdempotent() throws {
        let project = Project(
            name: "Archived project",
            area: "Test",
            goal: "Keep history",
            status: .archived,
            currentNextStep: "Review",
            archivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = JournalSnapshot(projects: [project])
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backupDirectory) }
        let migration = ProductConvergenceMigration()

        _ = try migration.execute(
            snapshot: snapshot,
            resolutions: [.project(project.id, .pause)],
            repository: repository,
            backupDirectory: backupDirectory
        )
        let first = try repository.snapshot()
        _ = try migration.execute(
            snapshot: first,
            resolutions: [],
            repository: repository,
            backupDirectory: backupDirectory
        )

        XCTAssertEqual(try repository.snapshot(), first)
        XCTAssertTrue(try repository.hasCompletedMigration(identifier: ProductConvergenceMigration.statusMigrationIdentifier))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDirectory.appendingPathComponent("project-status-backup.json").path))
    }

    func testMigrationRollbackKeepsOriginalSnapshotWhenValidationFails() throws {
        let project = Project(
            name: "Archived project",
            area: "Test",
            goal: "Keep history",
            status: .archived,
            currentNextStep: "Review"
        )
        let orphanProof = try Proof(
            projectId: UUID(),
            type: .text,
            title: "Orphan",
            statement: "Needs review"
        )
        let snapshot = JournalSnapshot(projects: [project], proofs: [orphanProof])
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backupDirectory) }

        XCTAssertThrowsError(
            try ProductConvergenceMigration().execute(
                snapshot: snapshot,
                resolutions: [
                    .project(project.id, .abandon),
                    .proof(orphanProof.id, .keepNeedsEvidence)
                ],
                repository: repository,
                backupDirectory: backupDirectory
            )
        ) { error in
            XCTAssertEqual(error as? ProductConvergenceMigrationError, .invalidRelationship)
        }
        XCTAssertEqual(try repository.snapshot(), snapshot)
        XCTAssertFalse(try repository.hasCompletedMigration(identifier: ProductConvergenceMigration.statusMigrationIdentifier))
    }
}
