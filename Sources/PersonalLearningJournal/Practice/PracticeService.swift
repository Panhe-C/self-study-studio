import Foundation

public enum PracticeServiceError: Error, Equatable, Sendable {
    case missingRoutine
    case duplicateActiveRoutineName
    case routineHasSessions
    case activeRoutineCannotBeModified
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
        reminderTime: PracticeReminderTime? = nil
    ) throws -> PracticeRoutine {
        let projects = try repository.snapshot().projects.filter { $0.deletedAt == nil && $0.status != .trash }
        guard projects.count == 1 else { throw PracticeValidationError.missingProject }
        return try createRoutine(
            projectId: projects[0].id,
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            reminderTime: reminderTime
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
        reminderTime: PracticeReminderTime? = nil
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
            reminderTime: reminderTime,
            createdAt: timestamp,
            updatedAt: timestamp
        ).validated()
        guard !hasDuplicateActiveName(routine.name, in: snapshot) else {
            throw PracticeServiceError.duplicateActiveRoutineName
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
        reminderTime: PracticeReminderTime? = nil
    ) throws -> PracticeRoutine {
        let snapshot = try repository.snapshot()
        guard let existing = liveRoutine(id: routineId, in: snapshot) else {
            throw PracticeServiceError.missingRoutine
        }

        let updated = try PracticeRoutine(
            id: existing.id,
            projectId: existing.projectId,
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
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

    public func deleteRoutineIfUnused(_ routineId: UUID) throws {
        let snapshot = try repository.snapshot()
        guard liveRoutine(id: routineId, in: snapshot) != nil else {
            throw PracticeServiceError.missingRoutine
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

    private func hasDuplicateActiveName(
        _ name: String,
        excluding excludedRoutineID: UUID? = nil,
        in snapshot: JournalSnapshot
    ) -> Bool {
        let normalizedName = normalizedRoutineName(name)
        return snapshot.practiceRoutines.contains { routine in
            routine.id != excludedRoutineID
                && !routine.isArchived
                && routine.deletedAt == nil
                && normalizedRoutineName(routine.name) == normalizedName
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
