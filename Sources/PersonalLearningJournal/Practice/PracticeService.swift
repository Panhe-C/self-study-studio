import Foundation

public enum PracticeServiceError: Error, Equatable, Sendable {
    case missingRoutine
    case missingSession
    case sessionIdentityMismatch
    case duplicateActiveRoutineName
    case activeRoutineAlreadyExists
    case routineHasSessions
    case activeRoutineCannotBeModified
    /// Published plan revisions own an immutable routine structure. Learners
    /// must create and activate a new plan revision to change it.
    case lockedRoutineCannotBeModified
}

extension PracticeServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingRoutine:
            "The practice routine is no longer available."
        case .missingSession:
            "The practice session is no longer available for reflection."
        case .sessionIdentityMismatch:
            "The reflection does not match the saved practice session."
        case .duplicateActiveRoutineName:
            "An active practice routine already uses this name."
        case .activeRoutineAlreadyExists:
            "This project already has an active practice routine. Archive or merge it before adding another."
        case .routineHasSessions:
            "This routine has practice history and can only be archived."
        case .activeRoutineCannotBeModified:
            "Finish or discard the active timer before changing this routine."
        case .lockedRoutineCannotBeModified:
            "This routine belongs to a published plan. Create a new plan revision to change its structure."
        }
    }
}

public struct PracticeSessionSaveResult: Equatable, Sendable {
    public let session: PracticeSession
    public let learningSession: LearningSession
    public let didDropMissingProjectLink: Bool

    public init(
        session: PracticeSession,
        learningSession: LearningSession,
        didDropMissingProjectLink: Bool
    ) {
        self.session = session
        self.learningSession = learningSession
        self.didDropMissingProjectLink = didDropMissingProjectLink
    }
}

public final class PracticeService {
    private let repository: any JournalRepository
    private let now: () -> Date

    public init(
        repository: any JournalRepository,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
    }

    @discardableResult
    public func createRoutine(
        name: String,
        symbolName: String,
        color: PracticeSemanticColor,
        targetMinutes: Int,
        weekdays: Set<Int>,
        reminderTime: PracticeReminderTime? = nil,
        blocks: [PracticeBlock] = []
    ) throws -> PracticeRoutine {
        let projects = try repository.snapshot().projects.filter { $0.deletedAt == nil && !$0.isTrashed }
        guard projects.count == 1 else { throw PracticeValidationError.missingProject }
        return try createRoutine(
            projectId: projects[0].id,
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            reminderTime: reminderTime,
            blocks: blocks
        )
    }

    @discardableResult
    public func createRoutine(
        projectId: UUID?,
        name: String,
        symbolName: String,
        color: PracticeSemanticColor,
        targetMinutes: Int,
        weekdays: Set<Int>,
        reminderTime: PracticeReminderTime? = nil,
        blocks: [PracticeBlock] = []
    ) throws -> PracticeRoutine {
        let snapshot = try repository.snapshot()
        guard let projectId,
              snapshot.projects.contains(where: { $0.id == projectId && $0.deletedAt == nil }) else {
            throw PracticeValidationError.missingProject
        }
        let timestamp = now()
        let routine = try PracticeRoutine(
            projectId: projectId,
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            blocks: blocks,
            reminderTime: reminderTime,
            createdAt: timestamp,
            updatedAt: timestamp
        ).validated()
        guard !hasDuplicateActiveName(routine.name, in: snapshot) else {
            throw PracticeServiceError.duplicateActiveRoutineName
        }
        guard !hasOperationalRoutine(
            for: routine.projectId,
            excluding: nil,
            in: snapshot
        ) else {
            throw PracticeServiceError.activeRoutineAlreadyExists
        }

        try repository.commit(
            JournalTransaction(upserts: [.practiceRoutine(routine)], origin: .user)
        )
        return routine
    }

    @discardableResult
    public func updateRoutine(
        routineId: UUID,
        name: String,
        symbolName: String,
        color: PracticeSemanticColor,
        targetMinutes: Int,
        weekdays: Set<Int>,
        reminderTime: PracticeReminderTime? = nil,
        blocks: [PracticeBlock]? = nil
    ) throws -> PracticeRoutine {
        let snapshot = try repository.snapshot()
        guard let existing = liveRoutine(id: routineId, in: snapshot) else {
            throw PracticeServiceError.missingRoutine
        }
        guard !existing.isStructuralLocked else {
            throw PracticeServiceError.lockedRoutineCannotBeModified
        }

        let updated = try PracticeRoutine(
            id: existing.id,
            projectId: existing.projectId,
            planRevisionID: existing.planRevisionID,
            planSeriesID: existing.planSeriesID,
            isStructuralLocked: existing.isStructuralLocked,
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            blocks: blocks ?? existing.blocks,
            reminderTime: reminderTime,
            isArchived: existing.isArchived,
            createdAt: existing.createdAt,
            updatedAt: now(),
            deletedAt: existing.deletedAt,
            schemaVersion: existing.schemaVersion
        ).validated()
        guard updated.isArchived || !hasDuplicateActiveName(
            updated.name,
            excluding: updated.id,
            in: snapshot
        ) else {
            throw PracticeServiceError.duplicateActiveRoutineName
        }
        if !updated.isArchived,
           hasOperationalRoutine(
               for: updated.projectId,
               excluding: updated.id,
               in: snapshot
           ) {
            throw PracticeServiceError.activeRoutineAlreadyExists
        }

        try repository.commit(
            JournalTransaction(upserts: [.practiceRoutine(updated)], origin: .user)
        )
        return updated
    }

    @discardableResult
    public func archiveRoutine(_ routineId: UUID) throws -> PracticeRoutine {
        let snapshot = try repository.snapshot()
        guard var routine = liveRoutine(id: routineId, in: snapshot) else {
            throw PracticeServiceError.missingRoutine
        }
        guard !routine.isStructuralLocked else {
            throw PracticeServiceError.lockedRoutineCannotBeModified
        }

        routine.isArchived = true
        routine.updatedAt = now()
        try repository.commit(
            JournalTransaction(upserts: [.practiceRoutine(routine)], origin: .user)
        )
        return routine
    }

    @discardableResult
    public func saveSession(
        sessionId: UUID = UUID(),
        routineId: UUID,
        recoverDeletedRoutine: Bool = false,
        linkedProjectId: UUID?,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        segments: [PracticeSegment] = [],
        summary: PracticeSummary? = nil,
        note: String?
    ) throws -> PracticeSessionSaveResult {
        let snapshot = try repository.snapshot()
        let liveRoutine = liveRoutine(id: routineId, in: snapshot)
        var recoveredRoutine: PracticeRoutine?
        if liveRoutine == nil,
           recoverDeletedRoutine,
           case var .practiceRoutine(tombstone)? = try repository.entity(
               for: .init(.practiceRoutine, routineId)
           ) {
            tombstone.deletedAt = nil
            tombstone.isArchived = true
            tombstone.updatedAt = now()
            recoveredRoutine = tombstone
        }
        if liveRoutine == nil, recoveredRoutine == nil {
            throw PracticeServiceError.missingRoutine
        }

        let routine = liveRoutine ?? recoveredRoutine
        guard let storedProjectID = routine?.projectId,
              let projectIndex = snapshot.projects.firstIndex(where: {
                  $0.id == storedProjectID && $0.deletedAt == nil
              }) else {
            throw PracticeValidationError.missingProject
        }
        let requestedDifferentProject = linkedProjectId != nil && linkedProjectId != storedProjectID
        let timestamp = now()
        let session = try PracticeSession(
            id: sessionId,
            routineId: routineId,
            linkedProjectId: storedProjectID,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: activeDurationSeconds,
            segments: segments,
            summary: summary,
            note: note,
            createdAt: timestamp,
            updatedAt: timestamp
        ).validated()

        let project = snapshot.projects[projectIndex]
        let durationMinutes = max(1, (activeDurationSeconds + 59) / 60)
        let sessionNote = note?.trimmedForJournal.nilIfEmpty ?? routine?.name ?? "Practice"
        let learningSession = try LearningSession(
            id: sessionId,
            projectId: storedProjectID,
            source: .timer,
            actionType: .practice,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMinutes: durationMinutes,
            note: sessionNote,
            nextStepBefore: project.currentNextStep,
            nextStepAfter: project.currentNextStep,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var updatedProject = project
        updatedProject.lastActionType = .practice
        updatedProject.defaultDurationMinutes = durationMinutes
        updatedProject.updatedAt = timestamp
        let trailEvent = TrailEvent(
            projectId: storedProjectID,
            type: .session,
            sourceId: learningSession.id,
            occurredAt: timestamp,
            title: "Practice session",
            detail: sessionNote
        )

        var upserts: [JournalEntity] = []
        if let recoveredRoutine {
            upserts.append(.practiceRoutine(try recoveredRoutine.validated()))
        }
        upserts += [
            .practiceSession(session),
            .session(learningSession),
            .project(updatedProject),
            .trailEvent(trailEvent)
        ]
        try repository.commit(JournalTransaction(upserts: upserts, origin: .user))
        return PracticeSessionSaveResult(
            session: session,
            learningSession: learningSession,
            didDropMissingProjectLink: requestedDifferentProject
        )
    }

    /// Applies post-save reflection to an existing PracticeSession. The
    /// session identity must already be present so abandoning reflection can
    /// never create a second session or silently recreate a deleted one.
    @discardableResult
    public func updateSessionReflection(
        sessionId: UUID,
        routineId: UUID,
        recoverDeletedRoutine: Bool = false,
        linkedProjectId: UUID?,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        segments: [PracticeSegment] = [],
        summary: PracticeSummary? = nil,
        note: String?
    ) throws -> PracticeSessionSaveResult {
        let snapshot = try repository.snapshot()
        guard let existingSession = snapshot.practiceSessions.first(where: {
            $0.id == sessionId && $0.deletedAt == nil
        }),
        let existingLearningSession = snapshot.sessions.first(where: {
            $0.id == sessionId && $0.deletedAt == nil
        }) else {
            throw PracticeServiceError.missingSession
        }

        // Reflection is an enrichment of the already-persisted base record.
        // Every completion field that establishes identity must match before
        // we touch the note/attention marker. In particular, never route this
        // through saveSession: that would recreate the LearningSession,
        // project, and TrailEvent side effects.
        guard existingSession.routineId == routineId,
              existingSession.startedAt == startedAt,
              existingSession.endedAt == endedAt,
              existingSession.activeDurationSeconds == activeDurationSeconds,
              existingSession.segments == segments,
              summaryIdentityMatches(existingSession.summary, summary),
              linkedProjectId == nil || linkedProjectId == existingSession.linkedProjectId else {
            throw PracticeServiceError.sessionIdentityMismatch
        }

        let normalizedNote = note?.trimmedForJournal
        var updatedSession = existingSession
        updatedSession.note = normalizedNote
        if let summary,
           let existingSummary = existingSession.summary {
            // The identity guard above already established that all observed
            // block fields are unchanged. Rebuild only the marker so no
            // completion payload can rewrite historical observations.
            updatedSession.summary = PracticeSummary(
                totalActiveDurationSeconds: existingSummary.totalActiveDurationSeconds,
                blockSummaries: existingSummary.blockSummaries,
                attentionMarker: summary.attentionMarker
            )
        } else {
            updatedSession.summary = existingSession.summary
        }

        // Retrying the same reflection is a no-op: this avoids a new outbox
        // mutation and keeps all timestamps stable for idempotent enrichment.
        guard updatedSession.note != existingSession.note ||
              updatedSession.summary != existingSession.summary else {
            return PracticeSessionSaveResult(
                session: existingSession,
                learningSession: existingLearningSession,
                didDropMissingProjectLink: false
            )
        }

        updatedSession.updatedAt = now()
        let sessionReference = JournalEntityReference(.practiceSession, sessionId)
        let pendingBaseMutation = try repository
            .pendingMutations(limit: Int.max)
            .first(where: { $0.entity == sessionReference })
        var revisionExpectations: [JournalEntityReference: RevisionGuardExpectation] = [:]
        if pendingBaseMutation == nil,
           let metadata = try repository.metadata(for: sessionReference) {
            // Once the base payload has reached CloudKit, reflection is a
            // guarded update of the existing target. If the base is still in
            // the outbox, it will reuse that transaction's dependency chain
            // instead and must not carry a stale standalone guard.
            revisionExpectations[sessionReference] = .existingTarget(
                revisionID: sessionId,
                recordChangeTag: metadata.recordChangeTag
            )
        }
        try repository.commit(
            JournalTransaction(
                upserts: [.practiceSession(updatedSession)],
                origin: .user,
                transactionID: pendingBaseMutation?.transactionID ?? UUID(),
                revisionExpectations: revisionExpectations
            )
        )
        _ = recoverDeletedRoutine
        return PracticeSessionSaveResult(
            session: updatedSession,
            learningSession: existingLearningSession,
            didDropMissingProjectLink: false
        )
    }

    public func deleteRoutineIfUnused(_ routineId: UUID) throws {
        let snapshot = try repository.snapshot()
        guard let routine = liveRoutine(id: routineId, in: snapshot) else {
            throw PracticeServiceError.missingRoutine
        }
        guard !routine.isStructuralLocked else {
            throw PracticeServiceError.lockedRoutineCannotBeModified
        }
        guard !snapshot.practiceSessions.contains(where: {
            $0.routineId == routineId && $0.deletedAt == nil
        }) else {
            throw PracticeServiceError.routineHasSessions
        }

        try repository.commit(
            JournalTransaction(
                deletions: [.init(.practiceRoutine, routineId)],
                origin: .user
            )
        )
    }

    private func liveRoutine(id: UUID, in snapshot: JournalSnapshot) -> PracticeRoutine? {
        snapshot.practiceRoutines.first { $0.id == id && $0.deletedAt == nil }
    }

    private func summaryIdentityMatches(
        _ existing: PracticeSummary?,
        _ incoming: PracticeSummary?
    ) -> Bool {
        switch (existing, incoming) {
        case (nil, nil):
            return true
        case let (.some(existing), .some(incoming)):
            return existing.totalActiveDurationSeconds == incoming.totalActiveDurationSeconds &&
                existing.blockSummaries == incoming.blockSummaries
        default:
            return false
        }
    }

    private func hasDuplicateActiveName(
        _ name: String,
        excluding excludedRoutineID: UUID? = nil,
        in snapshot: JournalSnapshot
    ) -> Bool {
        let normalizedName = normalizedRoutineName(name)
        return snapshot.operationalPracticeRoutines.contains { routine in
            routine.id != excludedRoutineID
                && !routine.isArchived
                && routine.deletedAt == nil
                && normalizedRoutineName(routine.name) == normalizedName
        }
    }

    private func hasOperationalRoutine(
        for projectID: UUID?,
        excluding routineID: UUID?,
        in snapshot: JournalSnapshot
    ) -> Bool {
        guard let projectID else { return false }
        return snapshot.operationalPracticeRoutines.contains {
            $0.projectId == projectID
                && $0.id != routineID
                && !$0.isArchived
        }
    }

    private func normalizedRoutineName(_ name: String) -> String {
        name.trimmedForJournal.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
