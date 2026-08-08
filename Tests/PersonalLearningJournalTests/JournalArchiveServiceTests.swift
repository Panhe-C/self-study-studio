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
        let reviewID = UUID()
        let decision = ReviewDecision(
            reviewId: reviewID,
            projectId: otherProject.id,
            kind: .continueUnchanged
        )
        let review = Review(
            id: reviewID,
            periodStart: Date(timeIntervalSince1970: 1_000),
            periodEnd: Date(timeIntervalSince1970: 2_000),
            facts: [],
            patterns: [],
            decisions: [],
            projectRecommendations: [project.id: .active],
            nextSteps: [:],
            aiSourceSummary: [],
            confirmedDecisionIds: [decision.id]
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

        XCTAssertFalse(impact.references.contains(.init(.review, review.id)))
        XCTAssertFalse(impact.references.contains(.init(.reviewDecision, decision.id)))
        XCTAssertEqual(impact.reviewUpdateCount, 1)
        XCTAssertEqual(impact.decisionCount, 0)
    }

    func testPurgePreservesSharedReviewAndOtherProjectDecision() throws {
        let target = Project(
            name: "Target Project",
            area: "Learning",
            goal: "Preserve target",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let other = Project(
            name: "Other Project",
            area: "Learning",
            goal: "Preserve other",
            status: .active,
            currentNextStep: "Review"
        )
        let targetSession = try LearningSession(
            projectId: target.id,
            source: .quickLog,
            actionType: .course,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            durationMinutes: 1,
            note: "Target session",
            nextStepBefore: "",
            nextStepAfter: ""
        )
        let otherSession = try LearningSession(
            projectId: other.id,
            source: .quickLog,
            actionType: .course,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            durationMinutes: 1,
            note: "Other session",
            nextStepBefore: "",
            nextStepAfter: ""
        )
        let targetDecision = ReviewDecision(
            reviewId: UUID(),
            projectId: target.id,
            kind: .continueUnchanged
        )
        let otherDecision = ReviewDecision(
            reviewId: targetDecision.reviewId,
            projectId: other.id,
            kind: .continueUnchanged
        )
        let targetFact = "Target fact"
        let otherFact = "Other fact"
        let review = Review(
            periodStart: Date(timeIntervalSince1970: 900),
            periodEnd: Date(timeIntervalSince1970: 2_000),
            facts: [targetFact, otherFact],
            patterns: ["Target pattern", "Other pattern"],
            decisions: ["Target decision", "Other decision"],
            projectRecommendations: [target.id: .active, other.id: .paused],
            nextSteps: [target.id: "Target next", other.id: "Other next"],
            aiSourceSummary: [
                "session \(targetSession.id.uuidString.prefix(8)): Target session",
                "session \(otherSession.id.uuidString.prefix(8)): Other session"
            ],
            sourceReferences: [
                targetFact: ["session \(targetSession.id.uuidString.prefix(8)): Target session"],
                otherFact: ["session \(otherSession.id.uuidString.prefix(8)): Other session"],
                "Target pattern": ["session \(targetSession.id.uuidString.prefix(8)): Target session"],
                "Other pattern": ["session \(otherSession.id.uuidString.prefix(8)): Other session"],
                "Target decision": ["session \(targetSession.id.uuidString.prefix(8)): Target session"],
                "Other decision": ["session \(otherSession.id.uuidString.prefix(8)): Other session"]
            ],
            confirmedDecisionIds: [targetDecision.id, otherDecision.id]
        )
        var targetDecisionWithReview = targetDecision
        targetDecisionWithReview.reviewId = review.id
        var otherDecisionWithReview = otherDecision
        otherDecisionWithReview.reviewId = review.id
        let snapshot = JournalSnapshot(
            projects: [target, other],
            sessions: [targetSession, otherSession],
            reviews: [review],
            reviewDecisions: [targetDecisionWithReview, otherDecisionWithReview]
        )
        let repository = InMemoryJournalRepository(snapshot: snapshot)

        let impact = try JournalArchiveService(derivationRounds: 20).purge(
            projectID: target.id,
            snapshot: snapshot,
            from: repository
        )
        let remaining = try repository.snapshot()

        XCTAssertEqual(impact.reviewCount, 0)
        XCTAssertEqual(impact.reviewUpdateCount, 1)
        XCTAssertEqual(impact.decisionCount, 1)
        XCTAssertFalse(impact.references.contains(.init(.review, review.id)))
        XCTAssertTrue(remaining.reviews.contains { review in
            review.projectRecommendations == [other.id: .paused]
                && review.nextSteps == [other.id: "Other next"]
                && review.facts == [otherFact]
                && review.patterns == ["Other pattern"]
                && review.confirmedDecisionIds == [otherDecisionWithReview.id]
        })
        XCTAssertFalse(remaining.reviewDecisions.contains { $0.id == targetDecisionWithReview.id })
        XCTAssertTrue(remaining.reviewDecisions.contains { $0.id == otherDecisionWithReview.id })
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
        let project = Project(
            name: "Archived project",
            area: "Test",
            goal: "Keep history",
            status: .idea,
            currentNextStep: "Review"
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        try repository.commit(
            JournalTransaction(
                deletions: [.init(.project, project.id)],
                origin: .user
            )
        )
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
            try service.retryAttachmentCleanup(
                projectID: project.id,
                paths: [attachmentURL.path],
                repository: repository
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))
        XCTAssertNoThrow(
            try service.retryAttachmentCleanup(
                projectID: project.id,
                paths: [attachmentURL.path],
                repository: repository
            )
        )
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
