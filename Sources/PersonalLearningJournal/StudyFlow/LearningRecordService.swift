import Foundation

public enum LearningRecordError: Error, Equatable, Sendable {
    case missingProject
    case invalidCaptureStage(PendingStudyCaptureStage)
    case missingRecordDraft
    case missingProgress
    case missingSession
    case missingAssessment
    case emptyNote
    case attachmentStagingFailed([UUID])
    /// A legacy/manual path already completed the planned activity while a
    /// guided capture was waiting for confirmation. The user must resolve
    /// the pending capture instead of creating a second session.
    case plannedSessionAlreadyCompleted(UUID)
    /// A manual/backfill path attempted to finish an activity while its
    /// guided capture is still unresolved.
    case pendingCaptureExists(UUID)
}

extension LearningRecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingProject:
            return "This Project is no longer available."
        case let .invalidCaptureStage(stage):
            return "A capture in \(stage.rawValue) cannot be confirmed as a learning record yet."
        case .missingRecordDraft:
            return "Confirm the learning record draft before recording it."
        case .missingProgress:
            return "Answer the completion progress question before recording."
        case .missingSession:
            return "This learning record is no longer available."
        case .missingAssessment:
            return "Only records confirmed through the guided study flow can be amended."
        case .emptyNote:
            return "The record summary cannot be empty."
        case let .attachmentStagingFailed(ids):
            return "These attachments could not be saved: \(ids.map(\.uuidString).joined(separator: ", ")). Retry or remove them before recording."
        case let .plannedSessionAlreadyCompleted(sessionID):
            return "This planned activity was already recorded as session \(sessionID.uuidString). Resolve the pending capture before recording it again."
        case let .pendingCaptureExists(captureID):
            return "A guided study capture (\(captureID.uuidString)) is still waiting for confirmation. Finish or discard it before using Quick Log for this activity."
        }
    }
}

/// Atomic confirmation and correction service for guided study records
/// (spec 3.4, 9.4, 10).
///
/// A pending capture is never a journal fact: ending the timer, answering the
/// completion check, and editing the record draft all stay inside the
/// device-local `PendingStudyCaptureStore`. Only `confirm(capture:)` publishes
/// — and it does so in ONE `JournalTransaction` carrying the session (with
/// its `LearningRecordAssessment`), the project Next Step, the completed
/// planned session, and the trail events, so the repository can never expose
/// a half-confirmed record. The pending capture is removed only after the
/// commit succeeds; on failure it stays in the store for retry.
///
/// Attachments are moved into the `AttachmentStore` BEFORE the commit. If any
/// move fails, `attachmentStagingFailed` is thrown before anything is
/// committed and the journal stays untouched. If the commit itself fails
/// after files were moved, the moved paths are enqueued in the attachment
/// cleanup queue so no orphan files accumulate.
///
/// `amend(sessionID:...)` first appends an immutable `LearningRecordRevision`
/// snapshot of the previous values, then updates the session in the same
/// transaction. It never rewrites trail, plan, or Next Step state, and never
/// re-triggers historical adjustment suggestions.
///
/// Concurrency: unlike Stage Review this service does not set
/// `revisionExpectations`. Confirm creates a brand-new session (no existing
/// record to guard), and amend is a single-device local flow where the
/// repository transaction is already atomic; adding a guard would only
/// surface as spurious stale-revision errors without a recovery UI.
public final class LearningRecordService {
    private let repository: any JournalRepository
    private let captureStore: PendingStudyCaptureStore
    private let attachmentStore: AttachmentStore
    private let cleanupQueue: AttachmentCleanupQueue?
    private let now: () -> Date

    /// The store this service confirms from, exposed so the view layer can
    /// orchestrate the same device-local captures.
    public var store: PendingStudyCaptureStore { captureStore }

    public init(
        repository: any JournalRepository,
        captureStore: PendingStudyCaptureStore,
        attachmentStore: AttachmentStore = .defaultStore(),
        cleanupQueue: AttachmentCleanupQueue? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.captureStore = captureStore
        self.attachmentStore = attachmentStore
        self.cleanupQueue = cleanupQueue
            ?? AttachmentCleanupQueue(rootDirectory: attachmentStore.rootDirectory)
        self.now = now
    }

    /// Captures waiting on user confirmation, including ones saved for later.
    public func pendingConfirmations() throws -> [PendingStudyCapture] {
        try captureStore.pendingConfirmations()
    }

    // MARK: - Confirm

    /// Confirms a pending capture into the journal in one atomic transaction.
    ///
    /// - Parameters:
    ///   - capture: the capture to confirm. Must be in
    ///     `awaitingRecordConfirmation`, or `savedForLater` with a record
    ///     draft attached.
    ///   - editedDraft: the user's edited draft. When `nil`, the capture's
    ///     stored draft is used.
    ///   - userEditedSummary: whether the user modified the draft summary.
    ///     The UI computes this by comparing the edited draft with the stored
    ///     one.
    ///   - confirmedNextStep: the user's final Next Step choice. When `nil`,
    ///     the draft's suggestion is kept; when that is also empty, the
    ///     project's current Next Step carries over unchanged.
    @discardableResult
    public func confirm(
        capture: PendingStudyCapture,
        editedDraft: LearningRecordDraft? = nil,
        userEditedSummary: Bool = false,
        confirmedNextStep: String? = nil
    ) throws -> LearningSession {
        // Idempotency guard: the capture must still be pending in the store.
        // A capture may remain pending when its journal commit succeeded but
        // deleting/replacing the local file failed. The committed assessment
        // below is the durable source of truth for that retry.
        guard let storedCapture = try captureStore.allCaptures().first(where: { $0.id == capture.id }) else {
            throw PendingStudyCaptureError.captureNotFound(capture.id)
        }
        let capture = storedCapture

        let existingSnapshot = try repository.snapshot()
        if let existing = existingSnapshot.sessions.first(where: {
            // Reconfirming a still-pending capture must never create a second
            // Session/Trail/Proof for the same durable capture id. The key is
            // carried by the confirmed assessment rather than the local file.
            $0.assessment?.captureID == capture.id
        }) {
            // The journal transaction already published this capture. Cleanup
            // is deliberately best-effort: if local persistence is still
            // unavailable, returning the existing session keeps retries
            // idempotent and the pending file can be removed later.
            try? captureStore.remove(id: capture.id)
            return existing
        }

        guard capture.stage == .awaitingRecordConfirmation
                || (capture.stage == .savedForLater && capture.recordDraft != nil) else {
            throw LearningRecordError.invalidCaptureStage(capture.stage)
        }
        guard let draft = editedDraft ?? capture.recordDraft else {
            throw LearningRecordError.missingRecordDraft
        }
        guard let progress = capture.answers.progress else {
            throw LearningRecordError.missingProgress
        }

        let snapshot = existingSnapshot
        guard let project = snapshot.projects.first(where: {
            $0.id == capture.projectID && $0.deletedAt == nil
        }) else {
            throw LearningRecordError.missingProject
        }
        let plannedSession = capture.plannedSessionID.flatMap { id in
            snapshot.plannedSessions.first {
                $0.id == id && $0.projectId == project.id && $0.deletedAt == nil
            }
        }

        if let plannedSession,
           plannedSession.status == .completed,
           let completedSessionID = plannedSession.completedSessionId {
            throw LearningRecordError.plannedSessionAlreadyCompleted(completedSessionID)
        }

        let endedAt = capture.endedAt ?? now()
        let actionType = plannedSession?.actionType ?? project.lastActionType
        let durationMinutes = max(1, (capture.activeDurationSeconds + 59) / 60)
        let note = Self.composeNote(draft: draft, progress: progress)
        let resolvedNextStep = Self.resolveNextStep(
            confirmedNextStep: confirmedNextStep,
            draft: draft,
            current: project.currentNextStep
        )

        var session = try LearningSession(
            projectId: project.id,
            source: capture.source,
            actionType: actionType,
            startedAt: capture.startedAt,
            endedAt: endedAt,
            durationMinutes: durationMinutes,
            note: note,
            nextStepBefore: project.currentNextStep,
            nextStepAfter: resolvedNextStep,
            createdAt: endedAt,
            updatedAt: endedAt
        )
        session.assessment = LearningRecordAssessment(
            captureID: capture.id,
            progress: progress,
            completedCriterionIDs: capture.answers.completedCriterionIDs,
            understanding: capture.answers.understanding,
            blocker: Self.resolveBlocker(answers: capture.answers, draft: draft),
            aiDraftedSummary: draft.source == .ai,
            userEditedSummary: userEditedSummary,
            confirmedAt: now(),
            revision: 1
        )

        // Move staged attachments BEFORE committing anything. A failure here
        // leaves the journal untouched so the user can retry or remove the
        // attachment (spec 14).
        let movedAttachments = try moveStagedAttachments(
            capture.stagedAttachments,
            projectID: project.id,
            sessionID: session.id
        )
        let proofs = try movedAttachments.map { moved in
            try Proof(
                id: moved.reference.id,
                projectId: project.id,
                sessionId: session.id,
                type: moved.reference.kind,
                title: moved.reference.displayName,
                statement: Self.proofStatement(for: moved.reference),
                localPath: moved.stored.fileURL.path,
                fileSize: moved.stored.fileSize,
                createdAt: endedAt,
                updatedAt: endedAt
            )
        }

        var updatedProject = project
        updatedProject.lastActionType = actionType
        updatedProject.currentNextStep = resolvedNextStep
        updatedProject.updatedAt = endedAt

        var trailEvents = [
            TrailEvent(
                projectId: project.id,
                type: .session,
                sourceId: session.id,
                occurredAt: endedAt,
                title: "\(durationMinutes) min · \(actionType.rawValue)",
                detail: session.note
            )
        ]
        if project.currentNextStep != resolvedNextStep {
            trailEvents.append(
                TrailEvent(
                    projectId: project.id,
                    type: .nextStepChange,
                    sourceId: session.id,
                    occurredAt: endedAt,
                    title: "Next Step updated",
                    detail: "Next Step changed from \(project.currentNextStep) to \(resolvedNextStep)"
                )
            )
        }

        var upserts: [JournalEntity] = [
            .project(updatedProject),
            .session(session)
        ]
        upserts.append(contentsOf: trailEvents.map(JournalEntity.trailEvent))
        upserts.append(contentsOf: proofs.map(JournalEntity.proof))
        if var completed = plannedSession {
            completed.status = .completed
            completed.completedSessionId = session.id
            completed.updatedAt = endedAt
            upserts.append(.plannedSession(completed))
        }

        do {
            try repository.commit(JournalTransaction(upserts: upserts, origin: .user))
        } catch {
            // The commit failed after files were moved; queue them for
            // cleanup so retried confirmations never accumulate orphans.
            let movedPaths = movedAttachments.map { $0.stored.fileURL.path }
            try? cleanupQueue?.enqueue(projectID: project.id, paths: movedPaths)
            throw error
        }

        // The capture is now a journal fact; remove it only after success.
        // A failed local replace must not turn a successful journal commit
        // into a retry that creates another session. The capture id embedded
        // in the assessment makes the next call take the idempotent branch.
        try? captureStore.remove(id: capture.id)
        return session
    }

    // MARK: - Amend

    /// Amends a confirmed record: appends a revision snapshot of the current
    /// values first, then updates the session in the same transaction. Never
    /// rewrites trail events, planned sessions, or the project's Next Step,
    /// and never re-triggers adjustment suggestions (spec 10).
    @discardableResult
    public func amend(
        sessionID: UUID,
        note: String,
        progress: CompletionProgress,
        completedCriterionIDs: [String] = [],
        understanding: UnderstandingLevel? = nil,
        blocker: String? = nil
    ) throws -> LearningSession {
        let trimmedNote = note.trimmedForJournal
        guard !trimmedNote.isEmpty else { throw LearningRecordError.emptyNote }

        let snapshot = try repository.snapshot()
        guard var session = snapshot.sessions.first(where: {
            $0.id == sessionID && $0.deletedAt == nil
        }) else {
            throw LearningRecordError.missingSession
        }
        guard let currentAssessment = session.assessment else {
            throw LearningRecordError.missingAssessment
        }

        let revisedAt = now()
        let revision = LearningRecordRevision(
            session: session,
            revision: currentAssessment.revision,
            revisedAt: revisedAt
        )

        var newAssessment = currentAssessment
        newAssessment.progress = progress
        newAssessment.completedCriterionIDs = completedCriterionIDs
        newAssessment.understanding = understanding
        newAssessment.blocker = blocker?.trimmedForJournal.isEmpty == false
            ? blocker?.trimmedForJournal
            : nil
        newAssessment.userEditedSummary = currentAssessment.userEditedSummary
            || trimmedNote != session.note
        newAssessment.revision = currentAssessment.revision + 1
        // `confirmedAt` is preserved; the revision record carries `revisedAt`.

        session.note = trimmedNote
        session.assessment = newAssessment
        session.updatedAt = revisedAt

        try repository.commit(
            JournalTransaction(
                upserts: [
                    .learningRecordRevision(revision),
                    .session(session)
                ],
                origin: .user
            )
        )
        return session
    }

    // MARK: - Internals

    private struct MovedAttachment {
        var reference: PendingAttachmentReference
        var stored: StoredAttachment
    }

    private func moveStagedAttachments(
        _ attachments: [PendingAttachmentReference],
        projectID: UUID,
        sessionID: UUID
    ) throws -> [MovedAttachment] {
        var moved: [MovedAttachment] = []
        var failedIDs: [UUID] = []
        for attachment in attachments {
            let sourceURL = URL(fileURLWithPath: attachment.localPath)
            do {
                let stored = try attachmentStore.copyFile(
                    from: sourceURL,
                    projectId: projectID,
                    sessionId: sessionID,
                    proofId: attachment.id,
                    mimeType: nil
                )
                try? FileManager.default.removeItem(at: sourceURL)
                moved.append(MovedAttachment(reference: attachment, stored: stored))
            } catch {
                failedIDs.append(attachment.id)
            }
        }
        guard failedIDs.isEmpty else {
            // Roll back already-moved files; nothing was committed yet.
            for entry in moved {
                try? attachmentStore.removeAttachment(at: entry.stored.fileURL)
            }
            throw LearningRecordError.attachmentStagingFailed(failedIDs)
        }
        return moved
    }

    private static func composeNote(
        draft: LearningRecordDraft,
        progress: CompletionProgress
    ) -> String {
        let summary = draft.summary.trimmedForJournal
        let result = draft.result.trimmedForJournal
        let blockers = draft.blockers.trimmedForJournal
        var lines: [String] = [summary.isEmpty ? "Progress: \(progress.rawValue)" : summary]
        if !result.isEmpty { lines.append("Result: \(result)") }
        if !blockers.isEmpty { lines.append("Blockers: \(blockers)") }
        return lines.joined(separator: "\n")
    }

    private static func resolveNextStep(
        confirmedNextStep: String?,
        draft: LearningRecordDraft,
        current: String
    ) -> String {
        if let override = confirmedNextStep?.trimmedForJournal, !override.isEmpty {
            return override
        }
        if let suggestion = draft.suggestedNextStep?.trimmedForJournal, !suggestion.isEmpty {
            return suggestion
        }
        return current
    }

    private static func resolveBlocker(
        answers: CompletionCheckAnswers,
        draft: LearningRecordDraft
    ) -> String? {
        if let blocker = answers.blocker?.trimmedForJournal, !blocker.isEmpty {
            return blocker
        }
        let draftBlockers = draft.blockers.trimmedForJournal
        return draftBlockers.isEmpty ? nil : draftBlockers
    }

    private static func proofStatement(for attachment: PendingAttachmentReference) -> String {
        let name = attachment.displayName.trimmedForJournal
        return name.isEmpty ? attachment.kind.rawValue.capitalized : name
    }
}
