import XCTest
@testable import PersonalLearningJournal

final class JournalArchiveServiceTests: XCTestCase {
    func testArchiveRoundTripRestoresRelationshipsAndAttachments() throws {
        let fixture = try makeFixture()
        let service = JournalArchiveService(
            now: { Date(timeIntervalSince1970: 2_000) },
            derivationRounds: 20
        )

        let envelope = try service.export(
            snapshot: fixture.snapshot,
            attachments: ["attachments/result.txt": Data("result".utf8)],
            password: "correct horse"
        )
        let preview = try service.preview(envelope, password: "correct horse")
        let restored = try service.restore(preview)

        XCTAssertTrue(preview.checksumsValid)
        XCTAssertEqual(restored.snapshot, fixture.snapshot)
        XCTAssertEqual(restored.attachmentData["attachments/result.txt"], Data("result".utf8))
        XCTAssertTrue(preview.duplicateIDs.isEmpty)
    }

    func testWrongPasswordAndTamperingNeverProduceRestorablePreview() throws {
        let fixture = try makeFixture()
        let service = JournalArchiveService(derivationRounds: 20)
        var envelope = try service.export(
            snapshot: fixture.snapshot,
            attachments: [:],
            password: "secret"
        )

        XCTAssertThrowsError(try service.preview(envelope, password: "wrong"))
        envelope.sealedPayload[envelope.sealedPayload.startIndex] ^= 0x01
        XCTAssertThrowsError(try service.preview(envelope, password: "secret"))
    }

    func testRestoreCommitsStableIDsInOneMigrationTransaction() throws {
        let fixture = try makeFixture()
        let service = JournalArchiveService(derivationRounds: 20)
        let envelope = try service.export(snapshot: fixture.snapshot, attachments: [:], password: "secret")
        let preview = try service.preview(envelope, password: "secret")
        let repository = InMemoryJournalRepository()

        try service.restore(preview, into: repository)

        XCTAssertEqual(try repository.snapshot(), fixture.snapshot)
        XCTAssertTrue(try repository.pendingMutations(limit: 100).isEmpty)
    }

    func testUnencryptedExportRequiresExplicitWarningConfirmation() throws {
        let service = JournalArchiveService(derivationRounds: 20)
        XCTAssertThrowsError(
            try service.export(snapshot: JournalSnapshot(), attachments: [:], password: nil)
        )
        XCTAssertNoThrow(
            try service.export(
                snapshot: JournalSnapshot(),
                attachments: [:],
                password: nil,
                allowUnencrypted: true
            )
        )
    }

    func testTrashImpactAndThirtyDayRetentionAreExplicit() throws {
        var fixture = try makeFixture()
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        fixture.snapshot.projects[0].status = .trash
        fixture.snapshot.projects[0].deletedAt = deletedAt
        let service = JournalArchiveService(derivationRounds: 20)

        let impact = service.purgeImpact(
            projectID: fixture.snapshot.projects[0].id,
            snapshot: fixture.snapshot
        )

        XCTAssertEqual(impact.sessionCount, 1)
        XCTAssertEqual(impact.proofCount, 1)
        XCTAssertEqual(impact.attachmentPaths, ["attachments/result.txt"])
        XCTAssertTrue(
            service.automaticPurgeCandidates(
                snapshot: fixture.snapshot,
                now: deletedAt.addingTimeInterval(30 * 86_400)
            ).contains(fixture.snapshot.projects[0].id)
        )
    }

    func testConfirmedPurgeCreatesTombstonesForEveryEnumeratedRecord() throws {
        var fixture = try makeFixture()
        fixture.snapshot.projects[0].status = .trash
        fixture.snapshot.projects[0].deletedAt = Date(timeIntervalSince1970: 1_000)
        let repository = InMemoryJournalRepository(snapshot: fixture.snapshot)
        let service = JournalArchiveService(derivationRounds: 20)

        let impact = try service.purge(
            projectID: fixture.project.id,
            snapshot: fixture.snapshot,
            from: repository
        )

        XCTAssertEqual(impact.references.count, 3)
        XCTAssertTrue(try repository.snapshot().projects.isEmpty)
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)
        XCTAssertTrue(try repository.snapshot().proofs.isEmpty)
        XCTAssertEqual(try repository.pendingMutations(limit: 100).count, 3)
    }

    private func makeFixture() throws -> (snapshot: JournalSnapshot, project: Project) {
        let project = Project(
            name: "Archive Project",
            area: "Learning",
            goal: "Preserve work",
            status: .idea,
            currentNextStep: ""
        )
        let session = try LearningSession(
            projectId: project.id,
            source: .quickLog,
            actionType: .output,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 700),
            durationMinutes: 10,
            note: "Created result",
            nextStepBefore: "",
            nextStepAfter: ""
        )
        let proof = try Proof(
            projectId: project.id,
            sessionId: session.id,
            type: .file,
            title: "Result",
            statement: "Shows the result",
            localPath: "attachments/result.txt"
        )
        return (JournalSnapshot(projects: [project], sessions: [session], proofs: [proof]), project)
    }
}
