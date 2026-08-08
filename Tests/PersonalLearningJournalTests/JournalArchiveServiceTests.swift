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

    func testPurgeImpactIncludesPracticeDependenciesWithoutTouchingOtherProjects() throws {
        let project = Project(
            name: "Archive Project",
            area: "Learning",
            goal: "Preserve work",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let otherProject = Project(
            name: "Other Project",
            area: "Learning",
            goal: "Preserve work",
            status: .active,
            currentNextStep: "Review"
        )
        let routine = PracticeRoutine(
            projectId: project.id,
            name: "Archive routine",
            symbolName: "book",
            color: .blue,
            targetMinutes: 30,
            weekdays: [2]
        )
        let practiceSession = PracticeSession(
            routineId: routine.id,
            linkedProjectId: project.id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            activeDurationSeconds: 600
        )
        let otherRoutine = PracticeRoutine(
            projectId: otherProject.id,
            name: "Other routine",
            symbolName: "book",
            color: .green,
            targetMinutes: 30,
            weekdays: [2]
        )
        let otherSession = PracticeSession(
            routineId: otherRoutine.id,
            linkedProjectId: otherProject.id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            activeDurationSeconds: 600
        )
        let snapshot = JournalSnapshot(
            projects: [project, otherProject],
            practiceRoutines: [routine, otherRoutine],
            practiceSessions: [practiceSession, otherSession]
        )
        let service = JournalArchiveService(derivationRounds: 20)
        let impact = service.purgeImpact(projectID: project.id, snapshot: snapshot)

        XCTAssertEqual(impact.routineCount, 1)
        XCTAssertEqual(impact.practiceSessionCount, 1)
        XCTAssertTrue(impact.references.contains(.init(.practiceRoutine, routine.id)))
        XCTAssertTrue(impact.references.contains(.init(.practiceSession, practiceSession.id)))
        XCTAssertFalse(impact.references.contains(.init(.practiceRoutine, otherRoutine.id)))
        XCTAssertFalse(impact.references.contains(.init(.practiceSession, otherSession.id)))

        let repository = InMemoryJournalRepository(snapshot: snapshot)
        _ = try service.purge(projectID: project.id, snapshot: snapshot, from: repository)
        let remaining = try repository.snapshot()
        XCTAssertTrue(remaining.practiceRoutines.contains(where: { $0.id == otherRoutine.id }))
        XCTAssertTrue(remaining.practiceSessions.contains(where: { $0.id == otherSession.id }))
        XCTAssertFalse(remaining.practiceRoutines.contains(where: { $0.id == routine.id }))
        XCTAssertFalse(remaining.practiceSessions.contains(where: { $0.id == practiceSession.id }))
    }

    func testPurgeImpactIncludesDecisionsAttachedToDeletedReview() throws {
        let project = Project(
            name: "Archive Project",
            area: "Learning",
            goal: "Preserve work",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let otherProject = Project(
            name: "Other Project",
            area: "Learning",
            goal: "Preserve work",
            status: .active,
            currentNextStep: "Review"
        )
        let review = Review(
            periodStart: Date(timeIntervalSince1970: 1_000),
            periodEnd: Date(timeIntervalSince1970: 2_000),
            facts: [],
            patterns: [],
            decisions: [],
            projectRecommendations: [project.id: .active],
            nextSteps: [:],
            aiSourceSummary: []
        )
        let decision = ReviewDecision(
            reviewId: review.id,
            projectId: otherProject.id,
            kind: .continueUnchanged
        )
        let snapshot = JournalSnapshot(
            projects: [project, otherProject],
            reviews: [review],
            reviewDecisions: [decision]
        )

        let impact = JournalArchiveService(derivationRounds: 20).purgeImpact(
            projectID: project.id,
            snapshot: snapshot
        )

        XCTAssertTrue(impact.references.contains(.init(.review, review.id)))
        XCTAssertTrue(impact.references.contains(.init(.reviewDecision, decision.id)))
    }

    func testConfirmedPurgeCreatesTombstonesForEveryEnumeratedRecord() throws {
        var fixture = try makeFixture()
        fixture.snapshot.projects[0].status = .trash
        fixture.snapshot.projects[0].deletedAt = Date(timeIntervalSince1970: 1_000)
        let repository = InMemoryJournalRepository(snapshot: fixture.snapshot)
        let service = JournalArchiveService(
            derivationRounds: 20,
            removeAttachment: { _ in }
        )

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

    func testPurgeDeletesAttachmentFilesAfterRepositoryCommit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = Project(
            name: "Archive Project",
            area: "Learning",
            goal: "Preserve work",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let attachmentURL = root.appendingPathComponent("record.txt")
        try Data("record".utf8).write(to: attachmentURL)
        let proof = try Proof(
            projectId: project.id,
            type: .file,
            title: "Record",
            statement: "The record",
            localPath: attachmentURL.path
        )
        let snapshot = JournalSnapshot(projects: [project], proofs: [proof])
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let service = JournalArchiveService(
            derivationRounds: 20,
            removeAttachment: { path in
                try FileManager.default.removeItem(atPath: path)
            }
        )

        _ = try service.purge(projectID: project.id, snapshot: snapshot, from: repository)

        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
        XCTAssertTrue(try repository.snapshot().projects.isEmpty)
    }

    func testPurgeReportsAttachmentCleanupFailureAfterRepositoryCommit() throws {
        let project = Project(
            name: "Archive Project",
            area: "Learning",
            goal: "Preserve work",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let proof = try Proof(
            projectId: project.id,
            type: .file,
            title: "Record",
            statement: "The record",
            localPath: "/unavailable/record.txt"
        )
        let snapshot = JournalSnapshot(projects: [project], proofs: [proof])
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let service = JournalArchiveService(
            derivationRounds: 20,
            removeAttachment: { _ in throw InjectedAttachmentDeletionFailure() }
        )

        XCTAssertThrowsError(
            try service.purge(projectID: project.id, snapshot: snapshot, from: repository)
        ) { error in
            XCTAssertEqual(
                error as? JournalArchiveError,
                .attachmentDeletionFailed(["/unavailable/record.txt"])
            )
        }
        XCTAssertTrue(try repository.snapshot().projects.isEmpty)
    }

    func testAttachmentCleanupFailureExposesRetryablePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let attachmentURL = root.appendingPathComponent("record.txt")
        try Data("record".utf8).write(to: attachmentURL)
        var shouldFail = true
        let service = JournalArchiveService(
            derivationRounds: 20,
            removeAttachment: { path in
                if shouldFail {
                    shouldFail = false
                    throw InjectedAttachmentDeletionFailure()
                }
                try FileManager.default.removeItem(atPath: path)
            }
        )

        XCTAssertThrowsError(
            try service.retryAttachmentCleanup(paths: [attachmentURL.path])
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))
        XCTAssertNoThrow(try service.retryAttachmentCleanup(paths: [attachmentURL.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
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

    private struct InjectedAttachmentDeletionFailure: Error {}
}
