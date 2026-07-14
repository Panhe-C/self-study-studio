import XCTest
@testable import PersonalLearningJournal

final class JournalRepositoryTests: XCTestCase {
    func testPracticeEntitiesRoundTripAndEnqueueMutations() throws {
        let repository = InMemoryJournalRepository()
        let routine = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let session = PracticeSession(
            routineId: routine.id,
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            activeDurationSeconds: 60
        )

        try repository.commit(
            JournalTransaction(
                upserts: [.practiceRoutine(routine), .practiceSession(session)],
                origin: .user
            )
        )

        XCTAssertEqual(try repository.snapshot().practiceRoutines, [routine])
        XCTAssertEqual(try repository.snapshot().practiceSessions, [session])
        XCTAssertEqual(try repository.pendingMutations(limit: 10).count, 2)
    }

    func testUserTransactionPersistsEntityAndOutboxAtomically() throws {
        let repository = InMemoryJournalRepository()
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )

        try repository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .user)
        )

        XCTAssertEqual(try repository.snapshot().projects, [project])
        XCTAssertEqual(
            try repository.pendingMutations(limit: 10).map(\.entity),
            [.init(.project, project.id)]
        )
    }

    func testRemoteAndMigrationApplyDoNotCreateOutboundMutations() throws {
        let repository = InMemoryJournalRepository()
        let remoteProject = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let migratedProject = Project(
            name: "Guitar",
            area: "Music",
            goal: "Play three songs",
            currentNextStep: "Practice verse one"
        )

        try repository.commit(
            JournalTransaction(upserts: [.project(remoteProject)], origin: .remote)
        )
        try repository.commit(
            JournalTransaction(upserts: [.project(migratedProject)], origin: .migration)
        )

        XCTAssertEqual(try repository.snapshot().projects.count, 2)
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
    }

    func testUpsertReplacesMatchingEntityAndDeletionRemovesItFromSnapshot() throws {
        let repository = InMemoryJournalRepository()
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        var revised = project
        revised.currentNextStep = "Lecture 2"

        try repository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .user)
        )
        try repository.commit(
            JournalTransaction(upserts: [.project(revised)], origin: .user)
        )

        XCTAssertEqual(try repository.snapshot().projects, [revised])

        try repository.commit(
            JournalTransaction(
                deletions: [.init(.project, project.id)],
                origin: .user
            )
        )

        XCTAssertTrue(try repository.snapshot().projects.isEmpty)
        XCTAssertEqual(
            try repository.pendingMutations(limit: 10).map(\.operation),
            [.save, .save, .delete]
        )
    }

    func testAcknowledgeRemovesOnlySpecifiedMutations() throws {
        let repository = InMemoryJournalRepository()
        let first = Project(
            name: "First",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Start"
        )
        let second = Project(
            name: "Second",
            area: "Music",
            goal: "Finish",
            currentNextStep: "Start"
        )
        try repository.commit(
            JournalTransaction(
                upserts: [.project(first), .project(second)],
                origin: .user
            )
        )
        let mutations = try repository.pendingMutations(limit: 10)

        try repository.acknowledge([mutations[0].id], metadata: [])

        XCTAssertEqual(
            try repository.pendingMutations(limit: 10).map(\.id),
            [mutations[1].id]
        )
    }
}
