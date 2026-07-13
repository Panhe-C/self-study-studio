import Foundation

public enum PracticeServiceError: Error, Equatable, Sendable {
    case missingRoutine
    case duplicateActiveRoutineName
    case routineHasSessions
}

public struct PracticeSessionSaveResult: Equatable, Sendable {
    public let session: PracticeSession
    public let didDropMissingProjectLink: Bool

    public init(session: PracticeSession, didDropMissingProjectLink: Bool) {
        self.session = session
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
        let timestamp = now()
        let routine = try PracticeRoutine(
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            reminderTime: reminderTime,
            createdAt: timestamp,
            updatedAt: timestamp
        ).validated()
        let snapshot = try repository.snapshot()
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
        routineId: UUID,
        linkedProjectId: UUID?,
        startedAt: Date,
        endedAt: Date,
        activeDurationSeconds: Int,
        note: String?
    ) throws -> PracticeSessionSaveResult {
        let snapshot = try repository.snapshot()
        guard liveRoutine(id: routineId, in: snapshot) != nil else {
            throw PracticeServiceError.missingRoutine
        }

        let hasLiveProject = linkedProjectId.map { id in
            snapshot.projects.contains { $0.id == id && $0.deletedAt == nil }
        } ?? true
        let storedProjectID = hasLiveProject ? linkedProjectId : nil
        let timestamp = now()
        let session = try PracticeSession(
            routineId: routineId,
            linkedProjectId: storedProjectID,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: activeDurationSeconds,
            note: note,
            createdAt: timestamp,
            updatedAt: timestamp
        ).validated()

        try repository.commit(
            JournalTransaction(upserts: [.practiceSession(session)], origin: .user)
        )
        return PracticeSessionSaveResult(
            session: session,
            didDropMissingProjectLink: linkedProjectId != nil && !hasLiveProject
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
