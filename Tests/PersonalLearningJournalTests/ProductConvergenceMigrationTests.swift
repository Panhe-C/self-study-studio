import XCTest
@testable import PersonalLearningJournal

final class ProductConvergenceMigrationTests: XCTestCase {
    func testDryRunClassifiesEveryApprovedAmbiguityWithoutMutatingSnapshot() throws {
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
        let practice = PracticeSession(
            routineId: routine.id,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            activeDurationSeconds: 100
        )
        let legacy = JournalSnapshot(
            projects: [project],
            proofs: [proof],
            practiceRoutines: [routine],
            practiceSessions: [practice]
        )

        let report = ProductConvergenceMigration().dryRun(snapshot: legacy)

        XCTAssertTrue(report.issues.contains(.proofNeedsEvidence(proof.id)))
        XCTAssertTrue(report.issues.contains(.practiceNeedsProject(routine.id)))
        XCTAssertTrue(report.issues.contains(.projectNeedsSetup(project.id)))
        XCTAssertEqual(legacy.projects.first?.commitmentState, .ready)
    }

    func testExecutionRequiresExplicitAmbiguityResolutionsAndNeverInventsEvidence() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let practice = PracticeSession(
            routineId: routine.id,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            activeDurationSeconds: 100
        )
        let legacy = JournalSnapshot(
            projects: [project], proofs: [proof],
            practiceRoutines: [routine], practiceSessions: [practice],
            hasCompletedOnboarding: false, pendingFirstRecordProjectId: project.id
        )
        let repository = InMemoryJournalRepository(snapshot: legacy)
        let migration = ProductConvergenceMigration()

        XCTAssertThrowsError(
            try migration.execute(
                snapshot: legacy,
                resolutions: [],
                repository: repository,
                backupDirectory: root
            )
        ) { error in
            XCTAssertEqual(error as? ProductConvergenceMigrationError, .unresolvedIssues)
        }

        let validation = try migration.execute(
            snapshot: legacy,
            resolutions: [
                .proof(proof.id, .keepNeedsEvidence),
                .practice(routine.id, .linkToProject(project.id))
            ],
            repository: repository,
            backupDirectory: root
        )
        let migrated = try repository.snapshot()

        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(migrated.projects.first?.commitmentState, .needsSetup)
        XCTAssertNil(migrated.pendingFirstRecordProjectId)
        XCTAssertEqual(migrated.practiceSessions.first?.linkedProjectId, project.id)
        XCTAssertTrue(migrated.evidenceContracts.isEmpty)
        XCTAssertTrue(migrated.evidenceAcceptances.isEmpty)
        XCTAssertEqual(migrated.proofs.first?.integrity, .needsEvidence)
        XCTAssertTrue(try repository.hasCompletedMigration(identifier: ProductConvergenceMigration.identifier))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("evidence-first-backup.json").path
        ))
        let backup = try JSONDecoder.journal.decode(
            JournalExport.self,
            from: Data(contentsOf: root.appendingPathComponent("evidence-first-backup.json"))
        )
        XCTAssertEqual(backup.proofs.map(\.id), [proof.id])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
