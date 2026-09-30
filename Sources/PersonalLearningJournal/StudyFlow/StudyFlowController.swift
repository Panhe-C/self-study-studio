import Foundation

/// Orchestrates the guided study flow for the views (spec 5.1, 9). Owns the
/// pending-capture store, the completion-check and record-draft providers,
/// the running elapsed time, and the `StudyFlowViewState` the views render.
///
/// Every state change goes through `StudyFlowReducer` first, and the reducer
/// only allows transitions that have a legal `PendingStudyCaptureStore`
/// counterpart — the store's `illegalTransition` should therefore be
/// unreachable from this controller. Nothing here writes to the journal:
/// ending the timer, answering the check, and editing the draft stay inside
/// the device-local store; only `confirm` publishes, via
/// `JournalViewModel.confirmPendingCapture`.
@MainActor
public final class StudyFlowController: ObservableObject {
    @Published public private(set) var state: StudyFlowViewState = .idle
    /// Running elapsed seconds while the timer owns the slot; frozen at the
    /// last tick otherwise. Updated by `tick()` — memory only, never disk.
    @Published public private(set) var elapsedSeconds = 0

    private let store: PendingStudyCaptureStore
    private let checkProvider: any CompletionCheckProvider
    private let recordDraftGenerator: LearningRecordDraftGenerator
    private let viewModel: JournalViewModel
    private let now: () -> Date

    /// Seconds accumulated before the current running segment.
    private var accumulatedSeconds = 0
    /// Start of the current running segment; `nil` while paused/ended.
    private var runStartedAt: Date?

    public init(
        store: PendingStudyCaptureStore,
        checkProvider: any CompletionCheckProvider,
        recordDraftGenerator: LearningRecordDraftGenerator,
        viewModel: JournalViewModel,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.checkProvider = checkProvider
        self.recordDraftGenerator = recordDraftGenerator
        self.viewModel = viewModel
        self.now = now
    }

    /// The current persisted capture, read fresh from the store.
    public var currentCapture: PendingStudyCapture? {
        guard let captureID = state.captureID else { return nil }
        return try? store.allCaptures().first { $0.id == captureID }
    }

    // MARK: - Timer lifecycle

    /// Starts a new capture for a project (optionally a planned session).
    /// Illegal when any capture already occupies the timer slot — the
    /// reducer rejects it before the store is touched.
    public func begin(project: Project, plannedSession: PlannedSession? = nil) {
        do {
            let capture = try store.begin(
                projectID: project.id,
                plannedSessionID: plannedSession?.id,
                source: .timer
            )
            let context = StudyFlowContext(
                captureID: capture.id,
                projectID: project.id,
                plannedSessionID: plannedSession?.id
            )
            state = try StudyFlowReducer.reduce(state: state, event: .begin(context))
            accumulatedSeconds = 0
            elapsedSeconds = 0
            runStartedAt = now()
        } catch {
            fail(with: error)
        }
    }

    /// Per-second tick from the view's `TimelineView`. Memory only — the
    /// store's `noteElapsed` never writes to disk.
    public func tick() {
        guard case .active = state, let runStartedAt else { return }
        elapsedSeconds = accumulatedSeconds + Int(now().timeIntervalSince(runStartedAt))
        if let captureID = state.captureID {
            try? store.noteElapsed(id: captureID, activeDurationSeconds: elapsedSeconds)
        }
    }

    public func pause() {
        guard case let .active(context) = state else { return }
        do {
            tick()
            _ = try store.pause(id: context.captureID)
            accumulatedSeconds = elapsedSeconds
            runStartedAt = nil
            state = try StudyFlowReducer.reduce(state: state, event: .pause)
        } catch {
            fail(with: error)
        }
    }

    public func resume() {
        guard case let .paused(context) = state else { return }
        do {
            _ = try store.resume(id: context.captureID)
            runStartedAt = now()
            state = try StudyFlowReducer.reduce(state: state, event: .resume)
        } catch {
            fail(with: error)
        }
    }

    /// Ends the timer: freezes the accumulated seconds, moves the capture to
    /// `awaitingCheck`, then builds and attaches the completion-check draft.
    /// Writes ONLY to the pending-capture store — never to the journal.
    public func end() async {
        switch state {
        case .active, .paused:
            break
        default:
            return
        }
        guard let context = state.context else { return }
        do {
            tick()
            if runStartedAt != nil {
                accumulatedSeconds = elapsedSeconds
                runStartedAt = nil
            }
            _ = try store.end(id: context.captureID)
            state = try StudyFlowReducer.reduce(state: state, event: .end)
            let draft = try await checkProvider.makeCheckDraft(
                input: makeCheckInput(context: context)
            )
            _ = try store.attachCheckDraft(id: context.captureID, draft: draft)
            state = try StudyFlowReducer.reduce(state: state, event: .checkDraftAttached)
        } catch {
            fail(with: error)
        }
    }

    // MARK: - Completion check

    /// Records the user's answers and generates the record draft. Allowed
    /// from the check and again when the user came back from the draft to
    /// revise answers.
    public func submitAnswers(_ answers: CompletionCheckAnswers) async {
        switch state {
        case .awaitingCheck, .awaitingRecordConfirmation:
            break
        default:
            return
        }
        guard let context = state.context else { return }
        do {
            _ = try store.recordAnswers(id: context.captureID, answers: answers)
            state = try StudyFlowReducer.reduce(state: state, event: .answersSubmitted)
            guard let capture = try store.allCaptures().first(where: { $0.id == context.captureID }) else {
                throw PendingStudyCaptureError.captureNotFound(context.captureID)
            }
            let input = LearningRecordDraftInput(
                capture: capture,
                activityTitle: activityTitle(for: context, capture: capture),
                currentNextStep: project(for: context)?.currentNextStep ?? ""
            )
            // Draft generation crosses the async boundary with Sendable
            // values only; attaching stays on the main actor with the store.
            let draft = try await recordDraftGenerator.makeDraft(input: input)
            _ = try store.attachRecordDraft(id: context.captureID, draft: draft)
            state = try StudyFlowReducer.reduce(state: state, event: .recordDraftAttached)
        } catch {
            fail(with: error)
        }
    }

    /// Returns from the record draft to the completion check so the user can
    /// revise answers (spec 9.3: 返回修改检查).
    public func backToCheck() {
        guard case .awaitingRecordConfirmation = state else { return }
        state = (try? StudyFlowReducer.reduce(state: state, event: .backToCheck)) ?? state
    }

    /// Stages a device-local attachment reference on the capture. Attachment
    /// staging is always optional and never blocks the check.
    public func stageAttachment(_ attachment: PendingAttachmentReference) {
        guard let captureID = state.captureID else { return }
        do {
            _ = try store.stageAttachment(id: captureID, attachment: attachment)
        } catch {
            fail(with: error)
        }
    }

    // MARK: - Record draft

    /// Confirms the record draft into the journal through the atomic
    /// confirmation transaction. On failure the capture stays in the store
    /// and the state carries the message back to the draft screen.
    public func confirm(
        editedDraft: LearningRecordDraft,
        confirmedNextStep: String? = nil
    ) {
        guard case .awaitingRecordConfirmation = state, let context = state.context else { return }
        do {
            guard let capture = try store.allCaptures().first(where: { $0.id == context.captureID }) else {
                throw PendingStudyCaptureError.captureNotFound(context.captureID)
            }
            let userEditedSummary = editedDraft.summary != capture.recordDraft?.summary
            let session = try viewModel.confirmPendingCapture(
                capture,
                editedDraft: editedDraft,
                userEditedSummary: userEditedSummary,
                confirmedNextStep: confirmedNextStep
            )
            state = try StudyFlowReducer.reduce(
                state: state,
                event: .confirmSucceeded(sessionID: session.id)
            )
        } catch let error as StudyFlowViewStateError {
            fail(with: error)
        } catch {
            state = (try? StudyFlowReducer.reduce(
                state: state,
                event: .confirmFailed(message: error.localizedDescription)
            )) ?? .failed(message: error.localizedDescription, returnTo: state)
        }
    }

    /// Persists the user's in-progress draft edits without confirming, then
    /// parks the capture for later (spec 9.3: 保存稍后处理).
    public func saveForLater(editedDraft: LearningRecordDraft? = nil) {
        switch state {
        case .awaitingCheck, .awaitingRecordConfirmation:
            break
        default:
            return
        }
        guard let context = state.context else { return }
        do {
            if let editedDraft {
                _ = try store.attachRecordDraft(id: context.captureID, draft: editedDraft)
            }
            _ = try store.saveForLater(id: context.captureID)
            state = try StudyFlowReducer.reduce(state: state, event: .saveForLater)
        } catch {
            fail(with: error)
        }
    }

    /// Explicitly abandons the unconfirmed capture (spec 9.3: 放弃草稿).
    public func discard() {
        guard let context = state.context else { return }
        do {
            _ = try store.discard(id: context.captureID)
            state = try StudyFlowReducer.reduce(state: state, event: .discard)
        } catch {
            fail(with: error)
        }
    }

    /// Closes the flow UI without touching the capture: pending captures stay
    /// in the store and resurface through `pendingStudyCaptures()`.
    public func dismiss() {
        state = (try? StudyFlowReducer.reduce(state: state, event: .dismiss)) ?? .idle
    }

    /// Returns to a failed step after reading the error.
    public func recoverFromFailure() {
        guard case let .failed(_, returnTo) = state else { return }
        state = returnTo
    }

    // MARK: - Reopen persisted captures

    /// Reopens a persisted capture (from `pendingStudyCaptures()` or the
    /// recovered timer slot). `savedForLater` is resolved through the store
    /// first — its landing stage depends on whether a record draft exists.
    public func reopen(_ capture: PendingStudyCapture) {
        guard case .idle = state else { return }
        do {
            // The caller may hold a stale copy; the store's version is truth.
            var resolvedCapture = try store.allCaptures().first { $0.id == capture.id } ?? capture
            var stage = resolvedCapture.stage
            if stage == .savedForLater {
                resolvedCapture = try store.reopen(id: capture.id)
                stage = resolvedCapture.stage
            }
            if stage == .recovered {
                _ = try store.resume(id: capture.id)
                stage = .active
            }
            let context = StudyFlowContext(
                captureID: capture.id,
                projectID: capture.projectID,
                plannedSessionID: capture.plannedSessionID
            )
            state = try StudyFlowReducer.reduce(
                state: state,
                event: .reopen(context, stage: stage)
            )
            switch stage {
            case .active:
                accumulatedSeconds = resolvedCapture.activeDurationSeconds
                elapsedSeconds = resolvedCapture.activeDurationSeconds
                runStartedAt = now()
            case .paused:
                accumulatedSeconds = resolvedCapture.activeDurationSeconds
                elapsedSeconds = resolvedCapture.activeDurationSeconds
                runStartedAt = nil
            default:
                accumulatedSeconds = resolvedCapture.activeDurationSeconds
                elapsedSeconds = resolvedCapture.activeDurationSeconds
                runStartedAt = nil
            }
        } catch {
            fail(with: error)
        }
    }

    // MARK: - Internals

    private func project(for context: StudyFlowContext) -> Project? {
        viewModel.snapshot.projects.first { $0.id == context.projectID }
    }

    private func plannedSession(for context: StudyFlowContext) -> PlannedSession? {
        context.plannedSessionID.flatMap { id in
            viewModel.snapshot.plannedSessions.first { $0.id == id }
        }
    }

    private func activityTitle(
        for context: StudyFlowContext,
        capture: PendingStudyCapture
    ) -> String {
        if let draftTitle = capture.checkDraft?.activityTitle, !draftTitle.isEmpty {
            return draftTitle
        }
        return plannedSession(for: context)?.title ?? project(for: context)?.name ?? ""
    }

    /// The check input carries only the activity's own facts: its title,
    /// completion criteria, expected proof, phase objective, and the
    /// remembered planning prerequisites (spec 12.2).
    private func makeCheckInput(context: StudyFlowContext) -> CompletionCheckInput {
        let planned = plannedSession(for: context)
        let phase = planned.flatMap { session in
            viewModel.snapshot.planPhases.first { $0.id == session.phaseId }
        }
        let prerequisites = viewModel.rememberedCoursePlanningInput(for: context.projectID)?
            .prerequisites
        return CompletionCheckInput(
            activityTitle: planned?.title ?? project(for: context)?.name ?? "",
            completionCriteria: planned?.completionCriteria ?? [],
            expectedProof: planned?.expectedProof,
            phaseObjective: phase?.objective,
            prerequisitesSummary: prerequisites?.isEmpty == false ? prerequisites : nil
        )
    }

    private func fail(with error: Error) {
        state = .failed(message: error.localizedDescription, returnTo: state)
    }
}
