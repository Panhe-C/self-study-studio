import XCTest
@testable import PersonalLearningJournal

final class LearningRecordServiceTests: XCTestCase {
    private var root: URL!
    private var captureStore: PendingStudyCaptureStore!
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        captureStore = PendingStudyCaptureStore(
            directory: root.appendingPathComponent("captures", isDirectory: true),
            now: { [timestamp] in timestamp }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeProject() -> Project {
        Project(
            name: "CS336",
            area: "AI",
            goal: "Explain attention",
            currentNextStep: "Write notes"
        )
    }

    private func makePlannedSession(projectID: UUID) throws -> PlannedSession {
        try PlannedSession(
            planId: UUID(),
            phaseId: UUID(),
            projectId: projectID,
            title: "Read chapter 3",
            actionType: .reading,
            durationMinutes: 45,
            status: .scheduled
        )
    }

    private func makeAnswers() -> CompletionCheckAnswers {
        CompletionCheckAnswers(
            progress: .mostlyCompleted,
            completedCriterionIDs: ["c1"],
            understanding: .mostlyUnderstood,
            blocker: "Exercise 5 unclear"
        )
    }

    private func makeRecordDraft() -> LearningRecordDraft {
        LearningRecordDraft(
            summary: "Read chapter 3 and solved most exercises.",
            result: "Exercises 1-4 done",
            blockers: "Exercise 5 unclear",
            suggestedNextStep: "Review exercise 5",
            adjustmentSignal: .ordinary,
            source: .ai
        )
    }

    private func makeService(
        repository: InMemoryJournalRepository,
        attachmentStore: AttachmentStore? = nil
    ) -> LearningRecordService {
        LearningRecordService(
            repository: repository,
            captureStore: captureStore,
            attachmentStore: attachmentStore ?? AttachmentStore(rootDirectory: root),
            now: { [timestamp] in timestamp }
        )
    }

    private func makeReadyCapture(
        projectID: UUID,
        plannedSessionID: UUID? = nil,
        activeSeconds: Int = 45 * 60
    ) throws -> PendingStudyCapture {
        let capture = try captureStore.begin(
            projectID: projectID,
            plannedSessionID: plannedSessionID,
            source: .timer
        )
        try captureStore.noteElapsed(id: capture.id, activeDurationSeconds: activeSeconds)
        _ = try captureStore.end(id: capture.id)
        _ = try captureStore.recordAnswers(id: capture.id, answers: makeAnswers())
        return try captureStore.attachRecordDraft(id: capture.id, draft: makeRecordDraft())
    }

    // MARK: - Ending the timer is not a journal fact

    func testEndingTimerLeavesJournalUnchanged() throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id)
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned])
        )
        _ = makeService(repository: repository)

        let capture = try captureStore.begin(
            projectID: project.id,
            plannedSessionID: planned.id,
            source: .timer
        )
        _ = try captureStore.end(id: capture.id)

        let snapshot = try repository.snapshot()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.trailEvents.isEmpty)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .scheduled)
        XCTAssertNil(snapshot.plannedSessions.first?.completedSessionId)
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, "Write notes")
    }

    // MARK: - Confirm happy path

    func testConfirmCreatesSessionCompletesPlannedSessionAndAppliesNextStepInOneCommit() throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id)
        var committedTransactions: [JournalTransaction] = []
        let observingRepository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned]),
            commitHook: { committedTransactions.append($0) }
        )
        let observingService = makeService(repository: observingRepository)
        let capture = try makeReadyCapture(projectID: project.id, plannedSessionID: planned.id)
        let session = try observingService.confirm(capture: capture)

        // One single atomic transaction carried every write.
        XCTAssertEqual(committedTransactions.count, 1)

        let snapshot = try observingRepository.snapshot()
        XCTAssertEqual(snapshot.sessions.count, 1)
        let stored = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(stored.id, session.id)
        XCTAssertEqual(stored.projectId, project.id)
        XCTAssertEqual(stored.source, .timer)
        XCTAssertEqual(stored.actionType, .reading)
        XCTAssertEqual(stored.durationMinutes, 45)
        XCTAssertTrue(stored.note.contains("Read chapter 3 and solved most exercises."))
        XCTAssertTrue(stored.note.contains("Exercises 1-4 done"))
        XCTAssertTrue(stored.note.contains("Exercise 5 unclear"))
        XCTAssertEqual(stored.nextStepBefore, "Write notes")
        XCTAssertEqual(stored.nextStepAfter, "Review exercise 5")

        let assessment = try XCTUnwrap(stored.assessment)
        XCTAssertEqual(assessment.progress, .mostlyCompleted)
        XCTAssertEqual(assessment.completedCriterionIDs, ["c1"])
        XCTAssertEqual(assessment.understanding, .mostlyUnderstood)
        XCTAssertEqual(assessment.blocker, "Exercise 5 unclear")
        XCTAssertTrue(assessment.aiDraftedSummary)
        XCTAssertFalse(assessment.userEditedSummary)
        XCTAssertEqual(assessment.confirmedAt, timestamp)
        XCTAssertEqual(assessment.revision, 1)
        XCTAssertEqual(assessment.captureID, capture.id)

        let storedPlanned = try XCTUnwrap(snapshot.plannedSessions.first)
        XCTAssertEqual(storedPlanned.status, .completed)
        XCTAssertEqual(storedPlanned.completedSessionId, session.id)

        let storedProject = try XCTUnwrap(snapshot.projects.first)
        XCTAssertEqual(storedProject.currentNextStep, "Review exercise 5")
        XCTAssertEqual(storedProject.lastActionType, .reading)

        let trailTypes = snapshot.trailEvents.map(\.type)
        XCTAssertTrue(trailTypes.contains(.session))
        XCTAssertTrue(trailTypes.contains(.nextStepChange))
        XCTAssertEqual(snapshot.trailEvents.count, 2)

        // The pending capture became a journal fact and was removed.
        XCTAssertTrue(try captureStore.allCaptures().isEmpty)
    }

    func testConfirmIsIdempotentWhenCaptureCleanupFailsAndRetryRestarts() throws {
        var shouldFailWrites = false
        captureStore = PendingStudyCaptureStore(
            directory: root.appendingPathComponent("captures", isDirectory: true),
            now: { [timestamp] in timestamp },
            writeData: { data, url in
                if shouldFailWrites { throw InjectedCaptureWriteFailure() }
                try data.write(to: url, options: [.atomic])
            }
        )
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = makeService(repository: repository)
        let capture = try makeReadyCapture(projectID: project.id)
        shouldFailWrites = true

        let first = try service.confirm(capture: capture)
        XCTAssertEqual(try repository.snapshot().sessions.count, 1)
        XCTAssertEqual(try XCTUnwrap(try repository.snapshot().sessions.first?.assessment?.captureID), capture.id)
        XCTAssertEqual(try captureStore.allCaptures().first?.id, capture.id)

        // A process restart/retry can pass the stale capture again. The
        // durable assessment key returns the original session and never
        // creates a second Trail/Proof/session aggregate.
        let second = try service.confirm(capture: capture)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try repository.snapshot().sessions.count, 1)

        shouldFailWrites = false
        _ = try service.confirm(capture: capture)
        XCTAssertTrue(try captureStore.allCaptures().isEmpty)
    }

    func testConfirmKeepsCurrentNextStepWithoutTrailWhenUnchanged() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = makeService(repository: repository)
        let capture = try makeReadyCapture(projectID: project.id)

        let session = try service.confirm(capture: capture, confirmedNextStep: "Write notes")

        let snapshot = try repository.snapshot()
        XCTAssertEqual(session.nextStepAfter, "Write notes")
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, "Write notes")
        XCTAssertEqual(snapshot.trailEvents.map(\.type), [.session])
    }

    func testQuickLogCannotBypassPendingCaptureAndCompletedPlanIsNotConfirmedAgain() throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id)
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned])
        )
        let journal = JournalService(
            repository: repository,
            now: { [timestamp] in timestamp },
            pendingCaptureStore: captureStore
        )
        let activeCapture = try captureStore.begin(
            projectID: project.id,
            plannedSessionID: planned.id,
            source: .timer
        )
        XCTAssertThrowsError(try journal.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "Bypass attempt",
            plannedSessionId: planned.id
        )) { error in
            XCTAssertEqual(error as? LearningRecordError, .pendingCaptureExists(activeCapture.id))
        }
        try captureStore.discard(id: activeCapture.id)

        _ = try journal.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "Historical backfill",
            plannedSessionId: planned.id
        )
        let guidedCapture = try makeReadyCapture(
            projectID: project.id,
            plannedSessionID: planned.id
        )
        let service = makeService(repository: repository)
        let completedSessionID = try XCTUnwrap(
            try repository.snapshot().plannedSessions.first?.completedSessionId
        )
        XCTAssertThrowsError(try service.confirm(capture: guidedCapture)) { error in
            XCTAssertEqual(
                error as? LearningRecordError,
                .plannedSessionAlreadyCompleted(completedSessionID)
            )
        }
        XCTAssertEqual(try repository.snapshot().sessions.count, 1)
    }

    func testProjectOnlyQuickLogMustResolvePendingGuidedCaptureBeforeBackfill() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project])
        )
        let journal = JournalService(
            repository: repository,
            now: { [timestamp] in timestamp },
            pendingCaptureStore: captureStore
        )
        let pending = try captureStore.begin(
            projectID: project.id,
            source: .timer
        )

        XCTAssertThrowsError(try journal.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "Backfill while guided capture is pending"
        )) { error in
            XCTAssertEqual(error as? LearningRecordError, .pendingCaptureExists(pending.id))
        }
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)

        // Historical backfill remains available after the pending guided work
        // is explicitly discarded.
        try captureStore.discard(id: pending.id)
        _ = try journal.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "Historical backfill after discard"
        )
        XCTAssertEqual(try repository.snapshot().sessions.count, 1)
    }

    func testConfirmAcceptsSavedForLaterCaptureWithDraft() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = makeService(repository: repository)
        var capture = try makeReadyCapture(projectID: project.id)
        capture = try captureStore.saveForLater(id: capture.id)

        _ = try service.confirm(capture: capture)

        XCTAssertEqual(try repository.snapshot().sessions.count, 1)
        XCTAssertTrue(try captureStore.allCaptures().isEmpty)
    }

    func testConfirmRejectsCaptureWithoutRecordDraft() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = makeService(repository: repository)
        let capture = try captureStore.begin(projectID: project.id, source: .timer)
        _ = try captureStore.end(id: capture.id)
        let checking = try captureStore.recordAnswers(id: capture.id, answers: makeAnswers())

        XCTAssertThrowsError(try service.confirm(capture: checking)) { error in
            XCTAssertEqual(
                error as? LearningRecordError,
                .invalidCaptureStage(.awaitingCheck)
            )
        }
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)
    }

    func testConfirmRequiresProgressAnswer() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = makeService(repository: repository)
        let capture = try captureStore.begin(projectID: project.id, source: .timer)
        _ = try captureStore.end(id: capture.id)
        _ = try captureStore.recordAnswers(
            id: capture.id,
            answers: CompletionCheckAnswers(progress: nil)
        )
        let ready = try captureStore.attachRecordDraft(id: capture.id, draft: makeRecordDraft())

        XCTAssertThrowsError(try service.confirm(capture: ready)) { error in
            XCTAssertEqual(error as? LearningRecordError, .missingProgress)
        }
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)
    }

    func testShortCaptureConfirmsWithOneMinute() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = makeService(repository: repository)
        let capture = try makeReadyCapture(projectID: project.id, activeSeconds: 30)

        let session = try service.confirm(capture: capture)

        XCTAssertEqual(session.durationMinutes, 1)
        XCTAssertEqual(try repository.snapshot().sessions.first?.durationMinutes, 1)
    }

    func testConfirmAfterCaptureRemovedThrowsCaptureNotFound() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = makeService(repository: repository)
        let capture = try makeReadyCapture(projectID: project.id)

        _ = try service.confirm(capture: capture)
        XCTAssertThrowsError(try service.confirm(capture: capture)) { error in
            XCTAssertEqual(error as? PendingStudyCaptureError, .captureNotFound(capture.id))
        }
        XCTAssertEqual(try repository.snapshot().sessions.count, 1)
    }

    // MARK: - Atomicity

    func testConfirmCommitFailureLeavesJournalUnchangedAndCapturePreserved() throws {
        struct CommitFailure: Error {}
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id)
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned]),
            commitHook: { _ in throw CommitFailure() }
        )
        let service = makeService(repository: repository)
        let capture = try makeReadyCapture(projectID: project.id, plannedSessionID: planned.id)

        XCTAssertThrowsError(try service.confirm(capture: capture))

        let snapshot = try repository.snapshot()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.trailEvents.isEmpty)
        XCTAssertTrue(snapshot.proofs.isEmpty)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .scheduled)
        XCTAssertNil(snapshot.plannedSessions.first?.completedSessionId)
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, "Write notes")

        let captures = try captureStore.allCaptures()
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.stage, .awaitingRecordConfirmation)
    }

    // MARK: - Attachments

    func testConfirmMovesStagedAttachmentsIntoProofsInSameCommit() throws {
        let project = makeProject()
        var committedTransactions: [JournalTransaction] = []
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project]),
            commitHook: { committedTransactions.append($0) }
        )
        let attachmentStore = AttachmentStore(rootDirectory: root)
        let service = makeService(repository: repository, attachmentStore: attachmentStore)

        let stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagedFile = stagingDirectory.appendingPathComponent("screenshot.png")
        try Data("png-bytes".utf8).write(to: stagedFile)

        let capture = try makeReadyCapture(projectID: project.id)
        let ready = try captureStore.stageAttachment(
            id: capture.id,
            attachment: PendingAttachmentReference(
                id: UUID(),
                kind: .image,
                localPath: stagedFile.path,
                displayName: "screenshot.png"
            )
        )

        let session = try service.confirm(capture: ready)

        XCTAssertEqual(committedTransactions.count, 1)
        let snapshot = try repository.snapshot()
        let proof = try XCTUnwrap(snapshot.proofs.first)
        XCTAssertEqual(proof.sessionId, session.id)
        XCTAssertEqual(proof.type, .image)
        let storedPath = try XCTUnwrap(proof.localPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedPath))
        XCTAssertTrue(storedPath.contains("Attachments"))
        // The staged file was moved out of staging.
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path))
    }

    func testConfirmAttachmentStagingFailureThrowsBeforeCommit() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = makeService(repository: repository)
        let missingPath = root.appendingPathComponent("missing.png").path

        let capture = try makeReadyCapture(projectID: project.id)
        let attachmentID = UUID()
        let ready = try captureStore.stageAttachment(
            id: capture.id,
            attachment: PendingAttachmentReference(
                id: attachmentID,
                kind: .image,
                localPath: missingPath,
                displayName: "missing.png"
            )
        )

        XCTAssertThrowsError(try service.confirm(capture: ready)) { error in
            XCTAssertEqual(
                error as? LearningRecordError,
                .attachmentStagingFailed([attachmentID])
            )
        }

        let snapshot = try repository.snapshot()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.proofs.isEmpty)
        XCTAssertTrue(snapshot.trailEvents.isEmpty)
        XCTAssertEqual(try captureStore.allCaptures().count, 1)
    }

    // MARK: - Amend

    private func makeConfirmedSession(
        repository: InMemoryJournalRepository,
        project: Project
    ) throws -> LearningSession {
        let service = makeService(repository: repository)
        let capture = try makeReadyCapture(projectID: project.id)
        return try service.confirm(capture: capture)
    }

    func testAmendAppendsRevisionSnapshotAndBumpsRevision() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let session = try makeConfirmedSession(repository: repository, project: project)
        let service = makeService(repository: repository)
        let originalNote = session.note
        let originalConfirmedAt = try XCTUnwrap(session.assessment).confirmedAt

        let amended = try service.amend(
            sessionID: session.id,
            note: "Updated summary after re-reading.",
            progress: .completed,
            completedCriterionIDs: ["c1", "c2"],
            understanding: .canExplainOrApply,
            blocker: nil
        )

        XCTAssertEqual(amended.note, "Updated summary after re-reading.")
        let assessment = try XCTUnwrap(amended.assessment)
        XCTAssertEqual(assessment.revision, 2)
        XCTAssertEqual(assessment.progress, .completed)
        XCTAssertEqual(assessment.completedCriterionIDs, ["c1", "c2"])
        XCTAssertEqual(assessment.understanding, .canExplainOrApply)
        XCTAssertNil(assessment.blocker)
        XCTAssertEqual(assessment.confirmedAt, originalConfirmedAt)
        XCTAssertTrue(assessment.userEditedSummary)

        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.sessions.first?.note, "Updated summary after re-reading.")
        XCTAssertEqual(snapshot.sessions.first?.assessment?.revision, 2)

        let revision = try XCTUnwrap(snapshot.learningRecordRevisions.first)
        XCTAssertEqual(snapshot.learningRecordRevisions.count, 1)
        XCTAssertEqual(revision.sessionID, session.id)
        XCTAssertEqual(revision.revision, 1)
        XCTAssertEqual(revision.previousNote, originalNote)
        XCTAssertEqual(revision.previousAssessment?.revision, 1)
        XCTAssertEqual(revision.previousAssessment?.progress, .mostlyCompleted)
        XCTAssertEqual(revision.revisedAt, timestamp)
    }

    func testAmendSecondTimeAppendsBothSnapshots() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let session = try makeConfirmedSession(repository: repository, project: project)
        let service = makeService(repository: repository)

        let first = try service.amend(
            sessionID: session.id,
            note: "First amendment.",
            progress: .completed
        )
        let second = try service.amend(
            sessionID: session.id,
            note: "Second amendment.",
            progress: .completed
        )

        XCTAssertEqual(second.assessment?.revision, 3)
        let revisions = try repository.snapshot().learningRecordRevisions
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(revisions.map(\.revision).sorted(), [1, 2])
        XCTAssertEqual(revisions.first { $0.revision == 2 }?.previousNote, first.note)
    }

    func testAmendDoesNotMutatePlanNextStepOrTrail() throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id)
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned])
        )
        let service = makeService(repository: repository)
        let capture = try makeReadyCapture(projectID: project.id, plannedSessionID: planned.id)
        let session = try service.confirm(capture: capture)

        let before = try repository.snapshot()
        _ = try service.amend(
            sessionID: session.id,
            note: "Corrected note with a different next step remark.",
            progress: .partial
        )
        let after = try repository.snapshot()

        XCTAssertEqual(after.trailEvents, before.trailEvents)
        XCTAssertEqual(after.plannedSessions, before.plannedSessions)
        XCTAssertEqual(
            after.projects.first?.currentNextStep,
            before.projects.first?.currentNextStep
        )
        XCTAssertEqual(
            after.projects.first?.updatedAt,
            before.projects.first?.updatedAt
        )
    }

    func testAmendRequiresExistingAssessment() throws {
        let project = makeProject()
        let legacySession = try LearningSession(
            projectId: project.id,
            source: .quickLog,
            actionType: .course,
            startedAt: timestamp.addingTimeInterval(-1800),
            endedAt: timestamp,
            durationMinutes: 30,
            note: "Legacy quick log",
            nextStepBefore: "Write notes",
            nextStepAfter: "Write notes"
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], sessions: [legacySession])
        )
        let service = makeService(repository: repository)

        XCTAssertThrowsError(
            try service.amend(sessionID: legacySession.id, note: "New", progress: .partial)
        ) { error in
            XCTAssertEqual(error as? LearningRecordError, .missingAssessment)
        }
        XCTAssertTrue(try repository.snapshot().learningRecordRevisions.isEmpty)
    }

    func testAmendRejectsEmptyNoteAndMissingSession() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let session = try makeConfirmedSession(repository: repository, project: project)
        let service = makeService(repository: repository)

        XCTAssertThrowsError(
            try service.amend(sessionID: session.id, note: "   ", progress: .partial)
        ) { error in
            XCTAssertEqual(error as? LearningRecordError, .emptyNote)
        }
        XCTAssertThrowsError(
            try service.amend(sessionID: UUID(), note: "New", progress: .partial)
        ) { error in
            XCTAssertEqual(error as? LearningRecordError, .missingSession)
        }
        XCTAssertEqual(try repository.snapshot().sessions.first?.note, session.note)
    }
}

private struct InjectedCaptureWriteFailure: Error {}
