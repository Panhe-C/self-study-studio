import XCTest
@testable import PersonalLearningJournal

/// View-state reducer tests for the guided study flow (spec 5.1, 9, 16).
/// The reducer must mirror the pending-capture stages and must REFUSE any
/// transition that has no legal `PendingStudyCaptureStore` counterpart, so
/// the controller can never drive the store into an illegal transition.
final class StudyFlowViewStateTests: XCTestCase {
    private let context = StudyFlowContext(
        captureID: UUID(),
        projectID: UUID(),
        plannedSessionID: UUID()
    )

    private func reduce(
        _ state: StudyFlowViewState,
        _ event: StudyFlowEvent
    ) throws -> StudyFlowViewState {
        try StudyFlowReducer.reduce(state: state, event: event)
    }

    private func assertIllegal(
        _ state: StudyFlowViewState,
        _ event: StudyFlowEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try reduce(state, event), file: file, line: line) { error in
            XCTAssertEqual(
                error as? StudyFlowViewStateError,
                .illegalTransition(event: event, state: state),
                file: file,
                line: line
            )
        }
    }

    // MARK: - Timer lifecycle

    func testBeginFromIdleEntersActive() throws {
        let state = try reduce(.idle, .begin(context))
        XCTAssertEqual(state, .active(context))
    }

    func testBeginWhileActiveIsIllegal() {
        assertIllegal(.active(context), .begin(context))
    }

    func testPauseAndResumeRoundTrip() throws {
        let paused = try reduce(.active(context), .pause)
        XCTAssertEqual(paused, .paused(context))
        let resumed = try reduce(paused, .resume)
        XCTAssertEqual(resumed, .active(context))
    }

    func testPauseWhileNotRunningIsIllegal() {
        assertIllegal(.idle, .pause)
        assertIllegal(.paused(context), .pause)
        assertIllegal(.awaitingCheck(context), .pause)
    }

    func testResumeWhileNotPausedIsIllegal() {
        assertIllegal(.idle, .resume)
        assertIllegal(.active(context), .resume)
        assertIllegal(.awaitingCheck(context), .resume)
    }

    func testEndFromActiveEntersAwaitingCheck() throws {
        XCTAssertEqual(try reduce(.active(context), .end), .awaitingCheck(context))
    }

    func testEndFromPausedEntersAwaitingCheck() throws {
        XCTAssertEqual(try reduce(.paused(context), .end), .awaitingCheck(context))
    }

    func testEndOutsideTimerIsIllegal() {
        assertIllegal(.idle, .end)
        assertIllegal(.awaitingCheck(context), .end)
        assertIllegal(.awaitingRecordConfirmation(context), .end)
    }

    // MARK: - Completion check and record draft

    func testCheckDraftAttachedKeepsAwaitingCheck() throws {
        XCTAssertEqual(
            try reduce(.awaitingCheck(context), .checkDraftAttached),
            .awaitingCheck(context)
        )
    }

    func testCheckDraftAttachedBeforeEndIsIllegal() {
        assertIllegal(.active(context), .checkDraftAttached)
        assertIllegal(.idle, .checkDraftAttached)
    }

    func testAnswersSubmittedKeepsCurrentStage() throws {
        XCTAssertEqual(
            try reduce(.awaitingCheck(context), .answersSubmitted),
            .awaitingCheck(context)
        )
        // Answers may be revised while reviewing the record draft; the store
        // stage is unchanged by `recordAnswers`.
        XCTAssertEqual(
            try reduce(.awaitingRecordConfirmation(context), .answersSubmitted),
            .awaitingRecordConfirmation(context)
        )
    }

    func testAnswersSubmittedBeforeCheckIsIllegal() {
        assertIllegal(.idle, .answersSubmitted)
        assertIllegal(.active(context), .answersSubmitted)
        assertIllegal(.paused(context), .answersSubmitted)
    }

    func testRecordDraftAttachedEntersAwaitingRecordConfirmation() throws {
        XCTAssertEqual(
            try reduce(.awaitingCheck(context), .recordDraftAttached),
            .awaitingRecordConfirmation(context)
        )
        // Regenerating a draft while confirming stays put.
        XCTAssertEqual(
            try reduce(.awaitingRecordConfirmation(context), .recordDraftAttached),
            .awaitingRecordConfirmation(context)
        )
    }

    func testRecordDraftAttachedFromTimerIsIllegal() {
        assertIllegal(.idle, .recordDraftAttached)
        assertIllegal(.active(context), .recordDraftAttached)
    }

    func testBackToCheckReturnsToAwaitingCheck() throws {
        XCTAssertEqual(
            try reduce(.awaitingRecordConfirmation(context), .backToCheck),
            .awaitingCheck(context)
        )
    }

    func testBackToCheckOnlyFromConfirmation() {
        assertIllegal(.idle, .backToCheck)
        assertIllegal(.awaitingCheck(context), .backToCheck)
        assertIllegal(.active(context), .backToCheck)
    }

    // MARK: - Confirm

    func testConfirmSucceededCompletes() throws {
        let sessionID = UUID()
        XCTAssertEqual(
            try reduce(.awaitingRecordConfirmation(context), .confirmSucceeded(sessionID: sessionID)),
            .completed(sessionID: sessionID)
        )
    }

    func testConfirmSucceededBeforeDraftIsIllegal() {
        assertIllegal(.awaitingCheck(context), .confirmSucceeded(sessionID: UUID()))
        assertIllegal(.idle, .confirmSucceeded(sessionID: UUID()))
        assertIllegal(.active(context), .confirmSucceeded(sessionID: UUID()))
    }

    func testConfirmFailedKeepsReturnState() throws {
        let failed = try reduce(
            .awaitingRecordConfirmation(context),
            .confirmFailed(message: "commit failed")
        )
        XCTAssertEqual(
            failed,
            .failed(message: "commit failed", returnTo: .awaitingRecordConfirmation(context))
        )
        XCTAssertEqual(failed.captureID, context.captureID)
    }

    func testConfirmFailedOutsideConfirmationIsIllegal() {
        assertIllegal(.idle, .confirmFailed(message: "boom"))
        assertIllegal(.awaitingCheck(context), .confirmFailed(message: "boom"))
    }

    // MARK: - Save for later / discard / dismiss

    func testSaveForLaterFromPendingStagesReturnsToIdle() throws {
        XCTAssertEqual(try reduce(.awaitingCheck(context), .saveForLater), .idle)
        XCTAssertEqual(try reduce(.awaitingRecordConfirmation(context), .saveForLater), .idle)
    }

    func testSaveForLaterFromTimerIsIllegal() {
        assertIllegal(.idle, .saveForLater)
        assertIllegal(.active(context), .saveForLater)
        assertIllegal(.paused(context), .saveForLater)
    }

    func testDiscardFromEveryOpenStageReturnsToIdle() throws {
        XCTAssertEqual(try reduce(.active(context), .discard), .idle)
        XCTAssertEqual(try reduce(.paused(context), .discard), .idle)
        XCTAssertEqual(try reduce(.awaitingCheck(context), .discard), .idle)
        XCTAssertEqual(try reduce(.awaitingRecordConfirmation(context), .discard), .idle)
    }

    func testDismissFromAnyStateReturnsToIdle() throws {
        XCTAssertEqual(try reduce(.active(context), .dismiss), .idle)
        XCTAssertEqual(try reduce(.awaitingCheck(context), .dismiss), .idle)
        XCTAssertEqual(try reduce(.completed(sessionID: UUID()), .dismiss), .idle)
        XCTAssertEqual(
            try reduce(.failed(message: "boom", returnTo: .awaitingCheck(context)), .dismiss),
            .idle
        )
    }

    // MARK: - Reopen persisted captures

    func testReopenMapsStoreStages() throws {
        XCTAssertEqual(
            try reduce(.idle, .reopen(context, stage: .awaitingCheck)),
            .awaitingCheck(context)
        )
        XCTAssertEqual(
            try reduce(.idle, .reopen(context, stage: .awaitingRecordConfirmation)),
            .awaitingRecordConfirmation(context)
        )
        XCTAssertEqual(
            try reduce(.idle, .reopen(context, stage: .paused)),
            .paused(context)
        )
        // A crashed-and-recovered timer reopens as a running timer; the
        // controller calls `store.resume` before emitting this event.
        XCTAssertEqual(
            try reduce(.idle, .reopen(context, stage: .recovered)),
            .active(context)
        )
    }

    func testReopenRejectsUnresolvedOrTerminalStages() {
        // `savedForLater` must be resolved through the store first (the
        // landing stage depends on whether a record draft exists).
        assertIllegal(.idle, .reopen(context, stage: .savedForLater))
        assertIllegal(.idle, .reopen(context, stage: .confirmed))
        assertIllegal(.idle, .reopen(context, stage: .discarded))
        // Reopening is only possible when no flow is on screen.
        assertIllegal(.awaitingCheck(context), .reopen(context, stage: .awaitingCheck))
    }

    // MARK: - Derived properties

    func testRequiresExplicitExitOnlyWhileTimerOwnsSlot() {
        XCTAssertTrue(StudyFlowViewState.active(context).requiresExplicitExit)
        XCTAssertTrue(StudyFlowViewState.paused(context).requiresExplicitExit)
        XCTAssertFalse(StudyFlowViewState.idle.requiresExplicitExit)
        XCTAssertFalse(StudyFlowViewState.awaitingCheck(context).requiresExplicitExit)
        XCTAssertFalse(
            StudyFlowViewState.awaitingRecordConfirmation(context).requiresExplicitExit
        )
        XCTAssertFalse(StudyFlowViewState.completed(sessionID: UUID()).requiresExplicitExit)
    }

    // MARK: - Dynamic Type layout state (spec 16)

    func testPrefersVerticalLayoutAtAccessibilityTextSizes() {
        XCTAssertTrue(StudyFlowViewState.prefersVerticalLayout(isAccessibilitySize: true))
        XCTAssertFalse(StudyFlowViewState.prefersVerticalLayout(isAccessibilitySize: false))
    }

    // MARK: - Accessibility labels are real text (spec 16)

    func testProgressLabelsAreDistinctNonEmptyText() {
        let labels = CompletionProgress.allCases.map(StudyFlowCopy.progressTitle)
        XCTAssertEqual(labels.count, 4)
        XCTAssertEqual(Set(labels).count, 4)
        XCTAssertTrue(labels.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func testUnderstandingLabelsAreDistinctNonEmptyText() {
        let labels = UnderstandingLevel.allCases.map(StudyFlowCopy.understandingTitle)
        XCTAssertEqual(labels.count, 4)
        XCTAssertEqual(Set(labels).count, 4)
        XCTAssertTrue(labels.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func testDraftSourceAndStatusLabelsAreVoiceOverReadableText() {
        XCTAssertEqual(DraftSource.allCases.count, 2)
        for source in DraftSource.allCases {
            XCTAssertFalse(StudyFlowCopy.draftSourceTitle(source).isEmpty)
        }
        XCTAssertFalse(StudyFlowCopy.confirmedStatusTitle.isEmpty)
        XCTAssertFalse(StudyFlowCopy.amendedStatusTitle.isEmpty)
        XCTAssertNotEqual(StudyFlowCopy.confirmedStatusTitle, StudyFlowCopy.amendedStatusTitle)
    }

    func testPendingStageLabelsCoverPresentedStages() {
        for stage in [PendingStudyCaptureStage.active, .paused, .recovered,
                      .awaitingCheck, .awaitingRecordConfirmation, .savedForLater] {
            XCTAssertFalse(StudyFlowCopy.pendingStageTitle(stage).isEmpty)
        }
    }
}

// MARK: - Controller integration tests

/// Controller tests run the real `PendingStudyCaptureStore` (temp directory)
/// and a real `LearningRecordService` over an in-memory repository, with
/// deterministic rule-based providers. They assert the STATE-to-store-call
/// sequencing: ending the timer and answering the check never touch the
/// journal, and only `confirm` publishes.
@MainActor
final class StudyFlowControllerTests: XCTestCase {
    private var captureStore: PendingStudyCaptureStore!
    private var repository: InMemoryJournalRepository!
    private var viewModel: JournalViewModel!
    private var controller: StudyFlowController!
    private var clock: MutableClock!
    private var captureStoreDirectory: URL!
    private let startDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func makeProject() -> Project {
        Project(
            name: "CS336",
            area: "AI",
            goal: "Explain attention",
            currentNextStep: "Write notes"
        )
    }

    private func makeFixtures(project: Project) throws -> (PlannedSession, PlanPhase, LearningPlan) {
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: URL(string: "https://example.com/course"),
            courseTitle: "CS336",
            courseOutline: "Transformers",
            goal: "Explain attention",
            expectedOutcome: "Working notes",
            startsOn: startDate,
            deadline: nil,
            weeklyBudgetMinutes: 300,
            summary: "Plan"
        )
        let phase = try PlanPhase(
            planId: plan.id,
            title: "Phase 1",
            objective: "Build attention intuition",
            expectedProof: "Chapter notes",
            ordinal: 0,
            targetStart: startDate,
            targetEnd: startDate.addingTimeInterval(86_400)
        )
        let session = try PlannedSession(
            planId: plan.id,
            phaseId: phase.id,
            projectId: project.id,
            title: "Read chapter 3",
            actionType: .reading,
            expectedProof: "Chapter summary",
            durationMinutes: 45,
            completionCriteria: ["Read sections 3.1-3.3", "Solve exercises 1-4"],
            recommendationReason: "Next in sequence",
            status: .scheduled
        )
        return (session, phase, plan)
    }

    private func makeController(snapshot: JournalSnapshot) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        captureStoreDirectory = root.appendingPathComponent("captures", isDirectory: true)
        clock = MutableClock(startDate)
        repository = InMemoryJournalRepository(snapshot: snapshot, now: clock.now)
        captureStore = PendingStudyCaptureStore(
            directory: captureStoreDirectory,
            now: clock.now
        )
        let journalService = JournalService(repository: repository, now: clock.now)
        let recordService = LearningRecordService(
            repository: repository,
            captureStore: captureStore,
            attachmentStore: AttachmentStore(
                rootDirectory: root.appendingPathComponent("attachments", isDirectory: true)
            ),
            now: clock.now
        )
        viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            learningRecordService: recordService,
            practiceService: PracticeService(repository: repository, now: clock.now),
            practiceTimer: PracticeTimerRuntime(
                store: StudyFlowPracticeTimerStateStore(),
                now: clock.now
            )
        )
        controller = StudyFlowController(
            store: captureStore,
            checkProvider: RuleBasedCompletionCheckProvider(),
            recordDraftGenerator: LearningRecordDraftGenerator(
                provider: RuleBasedLearningRecordDraftProvider()
            ),
            viewModel: viewModel,
            now: clock.now
        )
    }

    private func advance(seconds: TimeInterval) {
        clock.advance(seconds: seconds)
    }

    // MARK: - End only writes the pending capture

    func testBeginEndAttachesCheckDraftAndLeavesJournalUntouched() async throws {
        let project = makeProject()
        let (planned, phase, plan) = try makeFixtures(project: project)
        try makeController(snapshot: JournalSnapshot(
            projects: [project],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [planned]
        ))

        controller.begin(project: project, plannedSession: planned)
        guard case .active = controller.state else {
            return XCTFail("expected active, got \(controller.state)")
        }

        await controller.end()

        guard case let .awaitingCheck(context) = controller.state else {
            return XCTFail("expected awaitingCheck, got \(controller.state)")
        }
        let capture = try XCTUnwrap(controller.currentCapture)
        XCTAssertEqual(capture.stage, .awaitingCheck)
        XCTAssertEqual(context.captureID, capture.id)

        // The check draft carries the planned session's criteria (rule-based
        // provider uses them directly) and no preselected answers.
        let draft = try XCTUnwrap(capture.checkDraft)
        XCTAssertEqual(draft.activityTitle, "Read chapter 3")
        XCTAssertEqual(draft.criteria.map(\.text), ["Read sections 3.1-3.3", "Solve exercises 1-4"])
        XCTAssertEqual(draft.source, .ruleBased)
        XCTAssertNil(capture.answers.progress)

        // Ending the timer never touches the journal (spec 9.1).
        let snapshot = try repository.snapshot()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.trailEvents.isEmpty)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .scheduled)
        XCTAssertNil(snapshot.plannedSessions.first?.completedSessionId)
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, "Write notes")
    }

    func testSubmitAnswersGeneratesRecordDraftAndLeavesJournalUntouched() async throws {
        let project = makeProject()
        let (planned, phase, plan) = try makeFixtures(project: project)
        try makeController(snapshot: JournalSnapshot(
            projects: [project],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [planned]
        ))
        controller.begin(project: project, plannedSession: planned)
        await controller.end()

        await controller.submitAnswers(CompletionCheckAnswers(
            progress: .mostlyCompleted,
            completedCriterionIDs: ["criterion-1"],
            understanding: .mostlyUnderstood,
            blocker: "Exercise 5 unclear"
        ))

        guard case .awaitingRecordConfirmation = controller.state else {
            return XCTFail("expected awaitingRecordConfirmation, got \(controller.state)")
        }
        let capture = try XCTUnwrap(controller.currentCapture)
        XCTAssertEqual(capture.stage, .awaitingRecordConfirmation)
        XCTAssertEqual(capture.answers.progress, .mostlyCompleted)
        let draft = try XCTUnwrap(capture.recordDraft)
        XCTAssertFalse(draft.summary.isEmpty)
        XCTAssertEqual(draft.source, .ruleBased)

        let snapshot = try repository.snapshot()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .scheduled)
    }

    // MARK: - Confirm publishes atomically

    func testConfirmPublishesSessionCompletesPlannedSessionAndRemovesCapture() async throws {
        let project = makeProject()
        let (planned, phase, plan) = try makeFixtures(project: project)
        try makeController(snapshot: JournalSnapshot(
            projects: [project],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [planned]
        ))
        controller.begin(project: project, plannedSession: planned)
        await controller.end()
        await controller.submitAnswers(CompletionCheckAnswers(
            progress: .completed,
            completedCriterionIDs: ["criterion-1", "criterion-2"]
        ))
        let draft = try XCTUnwrap(controller.currentCapture?.recordDraft)

        controller.confirm(editedDraft: draft)

        guard case .completed = controller.state else {
            return XCTFail("expected completed, got \(controller.state)")
        }
        let snapshot = try repository.snapshot()
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.assessment?.progress, .completed)
        XCTAssertEqual(session.assessment?.revision, 1)
        XCTAssertFalse(session.assessment?.userEditedSummary ?? true)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .completed)
        XCTAssertEqual(snapshot.plannedSessions.first?.completedSessionId, session.id)
        XCTAssertTrue(try captureStore.allCaptures().isEmpty)
    }

    func testConfirmWithEditedSummaryMarksUserEditedSummary() async throws {
        let project = makeProject()
        try makeController(snapshot: JournalSnapshot(projects: [project]))
        controller.begin(project: project)
        await controller.end()
        await controller.submitAnswers(CompletionCheckAnswers(progress: .partial))
        var draft = try XCTUnwrap(controller.currentCapture?.recordDraft)
        draft.summary = "My own summary."

        controller.confirm(editedDraft: draft)

        guard case .completed = controller.state else {
            return XCTFail("expected completed, got \(controller.state)")
        }
        let session = try XCTUnwrap(viewModel.sessions.first)
        XCTAssertEqual(session.assessment?.userEditedSummary, true)
        XCTAssertEqual(session.note, "My own summary.")
    }

    func testConfirmFailureKeepsCaptureAndCanRecoverToDraft() async throws {
        let project = makeProject()
        // The repository does NOT contain the project, so the confirmation
        // transaction must fail and leave the capture pending.
        try makeController(snapshot: JournalSnapshot())
        controller.begin(project: project)
        await controller.end()
        await controller.submitAnswers(CompletionCheckAnswers(progress: .partial))
        let draft = try XCTUnwrap(controller.currentCapture?.recordDraft)

        controller.confirm(editedDraft: draft)

        guard case let .failed(message, returnTo) = controller.state else {
            return XCTFail("expected failed, got \(controller.state)")
        }
        XCTAssertFalse(message.isEmpty)
        guard case .awaitingRecordConfirmation = returnTo else {
            return XCTFail("expected returnTo awaitingRecordConfirmation, got \(returnTo)")
        }
        XCTAssertEqual(try captureStore.allCaptures().count, 1)
        XCTAssertEqual(
            try captureStore.allCaptures().first?.stage,
            .awaitingRecordConfirmation
        )
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)

        controller.recoverFromFailure()
        guard case .awaitingRecordConfirmation = controller.state else {
            return XCTFail("expected recovery to draft, got \(controller.state)")
        }
    }

    // MARK: - Save for later and reopen

    func testSaveForLaterFromCheckThenReopenRestoresCheck() async throws {
        let project = makeProject()
        try makeController(snapshot: JournalSnapshot(projects: [project]))
        controller.begin(project: project)
        await controller.end()
        let capture = try XCTUnwrap(controller.currentCapture)

        controller.saveForLater()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(
            try captureStore.allCaptures().first?.stage,
            .savedForLater
        )

        controller.reopen(capture)

        guard case .awaitingCheck = controller.state else {
            return XCTFail("expected awaitingCheck, got \(controller.state)")
        }
        // The store landed back on awaitingCheck because no record draft
        // exists yet, so answering the check is legal again.
        XCTAssertEqual(
            try captureStore.allCaptures().first?.stage,
            .awaitingCheck
        )
    }

    func testSaveForLaterWithEditedDraftThenReopenRestoresConfirmation() async throws {
        let project = makeProject()
        try makeController(snapshot: JournalSnapshot(projects: [project]))
        controller.begin(project: project)
        await controller.end()
        await controller.submitAnswers(CompletionCheckAnswers(progress: .partial))
        var draft = try XCTUnwrap(controller.currentCapture?.recordDraft)
        draft.summary = "Edited before parking."
        let capture = try XCTUnwrap(controller.currentCapture)

        controller.saveForLater(editedDraft: draft)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(
            try captureStore.allCaptures().first?.recordDraft?.summary,
            "Edited before parking."
        )

        controller.reopen(capture)

        guard case .awaitingRecordConfirmation = controller.state else {
            return XCTFail("expected awaitingRecordConfirmation, got \(controller.state)")
        }
        XCTAssertEqual(
            try captureStore.allCaptures().first?.stage,
            .awaitingRecordConfirmation
        )
        XCTAssertEqual(controller.currentCapture?.recordDraft?.summary, "Edited before parking.")
    }

    func testReopenRecoveredCaptureResumesTimer() throws {
        let project = makeProject()
        try makeController(snapshot: JournalSnapshot(projects: [project]))
        controller.begin(project: project)
        advance(seconds: 120)
        controller.tick()
        // Lifecycle checkpoint before the simulated crash (ticks are
        // memory-only; persist is what carries seconds to disk).
        try captureStore.persist()
        // Simulate a crash: a fresh store instance marks the capture recovered.
        let reloadedStore = PendingStudyCaptureStore(
            directory: captureStoreDirectory,
            now: clock.now
        )
        let recovered = try XCTUnwrap(reloadedStore.allCaptures().first)
        XCTAssertEqual(recovered.stage, .recovered)

        let recoveredController = StudyFlowController(
            store: reloadedStore,
            checkProvider: RuleBasedCompletionCheckProvider(),
            recordDraftGenerator: LearningRecordDraftGenerator(
                provider: RuleBasedLearningRecordDraftProvider()
            ),
            viewModel: viewModel,
            now: clock.now
        )
        recoveredController.reopen(recovered)

        guard case .active = recoveredController.state else {
            return XCTFail("expected active, got \(recoveredController.state)")
        }
        XCTAssertEqual(recoveredController.elapsedSeconds, 120)
        XCTAssertEqual(try reloadedStore.allCaptures().first?.stage, .active)

        // The resumed timer keeps accumulating from the recovered seconds.
        advance(seconds: 30)
        recoveredController.tick()
        XCTAssertEqual(recoveredController.elapsedSeconds, 150)
    }

    // MARK: - Discard and dismiss

    func testDiscardFreesTimerSlotForANewCapture() throws {
        let project = makeProject()
        try makeController(snapshot: JournalSnapshot(projects: [project]))
        controller.begin(project: project)

        controller.discard()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(try captureStore.activeCapture())
        XCTAssertEqual(try captureStore.allCaptures().first?.stage, .discarded)

        // The timer slot is free again.
        controller.begin(project: project)
        guard case .active = controller.state else {
            return XCTFail("expected active after discard, got \(controller.state)")
        }
    }

    func testDismissLeavesCapturePersistedForLaterReopen() async throws {
        let project = makeProject()
        try makeController(snapshot: JournalSnapshot(projects: [project]))
        controller.begin(project: project)
        await controller.end()
        let capture = try XCTUnwrap(controller.currentCapture)

        controller.dismiss()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(
            try captureStore.allCaptures().first?.stage,
            .awaitingCheck
        )

        controller.reopen(capture)
        guard case .awaitingCheck = controller.state else {
            return XCTFail("expected awaitingCheck, got \(controller.state)")
        }
    }

    // MARK: - Timer ticking is memory-only

    func testTickAccumulatesOnlyWhileRunningAndPauseFreezes() throws {
        let project = makeProject()
        try makeController(snapshot: JournalSnapshot(projects: [project]))
        controller.begin(project: project)

        advance(seconds: 60)
        controller.tick()
        XCTAssertEqual(controller.elapsedSeconds, 60)

        controller.pause()
        XCTAssertEqual(controller.elapsedSeconds, 60)

        // Ticks while paused change nothing.
        advance(seconds: 30)
        controller.tick()
        XCTAssertEqual(controller.elapsedSeconds, 60)

        controller.resume()
        advance(seconds: 15)
        controller.tick()
        XCTAssertEqual(controller.elapsedSeconds, 75)
    }

    // MARK: - Back to check

    func testBackToCheckAllowsRevisingAnswersAndRegeneratingDraft() async throws {
        let project = makeProject()
        try makeController(snapshot: JournalSnapshot(projects: [project]))
        controller.begin(project: project)
        await controller.end()
        await controller.submitAnswers(CompletionCheckAnswers(progress: .partial))

        controller.backToCheck()
        guard case .awaitingCheck = controller.state else {
            return XCTFail("expected awaitingCheck, got \(controller.state)")
        }

        await controller.submitAnswers(CompletionCheckAnswers(progress: .completed))
        guard case .awaitingRecordConfirmation = controller.state else {
            return XCTFail("expected awaitingRecordConfirmation, got \(controller.state)")
        }
        XCTAssertEqual(controller.currentCapture?.answers.progress, .completed)
    }
}

@MainActor
private final class StudyFlowPracticeTimerStateStore: PracticeTimerStateStore {
    private var data: Data?

    func load() -> Data? { data }

    func save(_ data: Data?) throws {
        self.data = data
    }
}

/// A controllable clock safe to share with the `@MainActor @Sendable`
/// `now` closures the services require.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}
