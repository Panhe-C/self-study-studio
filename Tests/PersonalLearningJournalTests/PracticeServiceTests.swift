import XCTest
@testable import PersonalLearningJournal

final class PracticeServiceTests: XCTestCase {
    private let project = Project(name: "Practice Project", area: "Learning", goal: "Improve", status: .idea, currentNextStep: "")

    func testPersistentRoutineRequiresExistingProject() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = PracticeService(repository: repository)

        XCTAssertThrowsError(
            try service.createRoutine(
                projectId: nil,
                name: "Guitar",
                symbolName: "guitars",
                color: .coral,
                targetMinutes: 30,
                weekdays: [2]
            )
        ) { error in
            XCTAssertEqual(error as? PracticeValidationError, .missingProject)
        }
    }

    func testServiceValidatesAndCommitsRoutine() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
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
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
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
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
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
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
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
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
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

    func testRoutineProjectWinsOverMissingCompletionOverrideAndCreatesLearningSession() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
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

        XCTAssertEqual(result.session.linkedProjectId, project.id)
        XCTAssertTrue(result.didDropMissingProjectLink)
        XCTAssertEqual(try repository.snapshot().practiceSessions, [result.session])
        XCTAssertEqual(try repository.snapshot().sessions, [result.learningSession])
        XCTAssertEqual(result.learningSession.id, result.session.id)
        XCTAssertEqual(result.learningSession.projectId, project.id)
    }

    func testDeleteRoutineRejectsLiveSessionsAndSoftDeletesUnusedRoutine() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
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

    func testSaveSessionPersistsSegmentsAndSummaryInOneTransaction() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = PracticeService(repository: repository)
        let first = PracticeBlock(name: "Theory", targetMinutes: 5, ordinal: 0)
        let second = PracticeBlock(name: "Technique", targetMinutes: 10, ordinal: 1)
        let routine = try service.createRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 15,
            weekdays: [2],
            blocks: [first, second]
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 130)
        let segments = [
            PracticeSegment(
                blockID: first.id,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(10),
                activeDurationSeconds: 10
            ),
            PracticeSegment(
                blockID: second.id,
                startedAt: startedAt.addingTimeInterval(10),
                endedAt: endedAt,
                activeDurationSeconds: 20
            )
        ]
        let summary = PracticeSummary.from(blocks: routine.blocks, segments: segments, attentionMarker: "Needs tempo")

        let result = try service.saveSession(
            routineId: routine.id,
            linkedProjectId: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: 30,
            segments: segments,
            summary: summary,
            note: "Practice"
        )

        XCTAssertEqual(result.session.segments, segments)
        XCTAssertEqual(result.session.summary, summary)
        XCTAssertEqual(try repository.snapshot().practiceSessions, [result.session])
    }
}
