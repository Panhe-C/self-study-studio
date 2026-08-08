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

    func testServiceRejectsDifferentNameWhenProjectAlreadyHasOperationalRoutine() throws {
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
                name: "Technique",
                symbolName: "music.note",
                color: .blue,
                targetMinutes: 20,
                weekdays: [3]
            )
        )
    }

    func testServiceTreatsActiveRevisionRoutineAsOperational() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let activePlan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Current",
            courseOutline: "",
            goal: "Improve",
            expectedOutcome: "Practice",
            startsOn: timestamp,
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "Current",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var linkedProject = project
        linkedProject.activeCoursePlanId = activePlan.id
        let revisionRoutine = PracticeRoutine(
            projectId: project.id,
            planRevisionID: activePlan.revisionID,
            planSeriesID: activePlan.planSeriesID,
            isStructuralLocked: true,
            name: "Published routine",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [linkedProject],
                coursePlans: [activePlan],
                practiceRoutines: [revisionRoutine]
            )
        )
        let service = PracticeService(repository: repository)

        XCTAssertThrowsError(
            try service.createRoutine(
                projectId: project.id,
                name: "New routine",
                symbolName: "music.note",
                color: .teal,
                targetMinutes: 20,
                weekdays: [3]
            )
        )
    }

    func testServiceAllowsRoutineWhenOnlySupersededRevisionIsOperationallyHidden() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let activePlan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Current",
            courseOutline: "",
            goal: "Improve",
            expectedOutcome: "Practice",
            startsOn: timestamp,
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "Current",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var linkedProject = project
        linkedProject.activeCoursePlanId = activePlan.id
        let supersededRoutine = PracticeRoutine(
            projectId: project.id,
            planRevisionID: UUID(),
            planSeriesID: activePlan.planSeriesID,
            isStructuralLocked: true,
            name: "Old routine",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [linkedProject],
                coursePlans: [activePlan],
                practiceRoutines: [supersededRoutine]
            )
        )
        let service = PracticeService(repository: repository)

        let created = try service.createRoutine(
            projectId: project.id,
            name: "New routine",
            symbolName: "music.note",
            color: .teal,
            targetMinutes: 20,
            weekdays: [3]
        )

        XCTAssertEqual(created.projectId, project.id)
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

    func testReflectionUpdateRequiresAnExistingBaseSession() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = PracticeService(repository: repository)
        let routine = try service.createRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let before = try repository.snapshot()

        XCTAssertThrowsError(
            try service.updateSessionReflection(
                sessionId: UUID(),
                routineId: routine.id,
                linkedProjectId: nil,
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 160),
                activeDurationSeconds: 60,
                note: "Should not create a session"
            )
        ) { error in
            XCTAssertEqual(error as? PracticeServiceError, .missingSession)
        }
        XCTAssertEqual(try repository.snapshot(), before)
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
