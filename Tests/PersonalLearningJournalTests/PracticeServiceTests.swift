import XCTest
@testable import PersonalLearningJournal

final class PracticeServiceTests: XCTestCase {
    func testServiceValidatesAndCommitsRoutine() throws {
        let repository = InMemoryJournalRepository()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let service = PracticeService(repository: repository, now: { timestamp })

        let routine = try service.createRoutine(
            name: " Guitar ",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2, 4, 6]
        )

        XCTAssertEqual(routine.name, "Guitar")
        XCTAssertEqual(routine.createdAt, timestamp)
        XCTAssertEqual(try repository.snapshot().practiceRoutines, [routine])
    }

    func testServiceRejectsDuplicateActiveNameCaseInsensitively() throws {
        let repository = InMemoryJournalRepository()
        let service = PracticeService(repository: repository)
        _ = try service.createRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )

        XCTAssertThrowsError(
            try service.createRoutine(
                name: " guitar ",
                symbolName: "music.note",
                color: .blue,
                targetMinutes: 20,
                weekdays: [3]
            )
        )
    }

    func testArchivedRoutineDoesNotBlockDuplicateName() throws {
        let repository = InMemoryJournalRepository()
        let service = PracticeService(repository: repository)
        let archived = try service.createRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        _ = try service.archiveRoutine(archived.id)

        let replacement = try service.createRoutine(
            name: " guitar ",
            symbolName: "music.note",
            color: .blue,
            targetMinutes: 20,
            weekdays: [3]
        )

        XCTAssertEqual(replacement.name, "guitar")
    }

    func testUpdateAndArchiveRoutineRefreshUpdatedAt() throws {
        let repository = InMemoryJournalRepository()
        var timestamp = Date(timeIntervalSince1970: 1_000)
        let service = PracticeService(repository: repository, now: { timestamp })
        let routine = try service.createRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        timestamp = Date(timeIntervalSince1970: 2_000)

        let updated = try service.updateRoutine(
            routineId: routine.id,
            name: "Acoustic guitar",
            symbolName: "music.note",
            color: .blue,
            targetMinutes: 45,
            weekdays: [1, 3, 5]
        )
        timestamp = Date(timeIntervalSince1970: 3_000)
        let archived = try service.archiveRoutine(routine.id)

        XCTAssertEqual(updated.name, "Acoustic guitar")
        XCTAssertEqual(updated.updatedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.updatedAt, timestamp)
    }

    func testSaveSessionRequiresExistingNonDeletedRoutine() throws {
        let repository = InMemoryJournalRepository()
        let service = PracticeService(repository: repository)

        XCTAssertThrowsError(
            try service.saveSession(
                routineId: UUID(),
                linkedProjectId: nil,
                startedAt: .now,
                endedAt: .now.addingTimeInterval(60),
                activeDurationSeconds: 60,
                note: nil
            )
        )
    }

    func testMissingLinkedProjectFallsBackToNil() throws {
        let repository = InMemoryJournalRepository()
        let service = PracticeService(repository: repository)
        let routine = try service.createRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )

        let result = try service.saveSession(
            routineId: routine.id,
            linkedProjectId: UUID(),
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            activeDurationSeconds: 60,
            note: nil
        )

        XCTAssertNil(result.session.linkedProjectId)
        XCTAssertTrue(result.didDropMissingProjectLink)
        XCTAssertEqual(try repository.snapshot().practiceSessions, [result.session])
    }

    func testDeleteRoutineRejectsLiveSessionsAndSoftDeletesUnusedRoutine() throws {
        let repository = InMemoryJournalRepository()
        let service = PracticeService(repository: repository)
        let routine = try service.createRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        _ = try service.saveSession(
            routineId: routine.id,
            linkedProjectId: nil,
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            activeDurationSeconds: 60,
            note: nil
        )

        XCTAssertThrowsError(try service.deleteRoutineIfUnused(routine.id))

        let session = try XCTUnwrap(repository.snapshot().practiceSessions.first)
        try repository.commit(
            JournalTransaction(
                deletions: [.init(.practiceSession, session.id)],
                origin: .user
            )
        )
        try service.deleteRoutineIfUnused(routine.id)

        XCTAssertTrue(try repository.snapshot().practiceRoutines.isEmpty)
    }
}
