import XCTest
@testable import PersonalLearningJournal

final class SwiftDataJournalRepositoryTests: XCTestCase {
    func testSwiftDataRepositoryRoundTripsEntityAndOutboxAcrossInstances() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal-v2.store")
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )

        try autoreleasepool {
            let first = try SwiftDataJournalRepository(url: url)
            try first.commit(
                JournalTransaction(upserts: [.project(project)], origin: .user)
            )
        }

        let second = try SwiftDataJournalRepository(url: url)
        XCTAssertEqual(try second.snapshot().projects.map(\.id), [project.id])
        XCTAssertEqual(try second.pendingMutations(limit: 10).count, 1)
    }

    func testRemoteTransactionPersistsWithoutCreatingOutbox() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let project = Project(
            name: "Guitar",
            area: "Music",
            goal: "Play three songs",
            currentNextStep: "Practice verse one",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = try SwiftDataJournalRepository(
            url: root.appendingPathComponent("journal-v2.store")
        )

        try repository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .remote)
        )

        XCTAssertEqual(try repository.snapshot().projects, [project])
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
    }

    func testDeletionPersistsAsHiddenTombstoneAndOutboundMutation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal-v2.store")
        let project = Project(
            name: "DaVinci",
            area: "Color",
            goal: "Finish",
            currentNextStep: "Practice"
        )

        try autoreleasepool {
            let first = try SwiftDataJournalRepository(url: url)
            try first.commit(
                JournalTransaction(upserts: [.project(project)], origin: .remote)
            )
            try first.commit(
                JournalTransaction(
                    deletions: [.init(.project, project.id)],
                    origin: .user
                )
            )
        }

        let second = try SwiftDataJournalRepository(url: url)
        XCTAssertTrue(try second.snapshot().projects.isEmpty)
        XCTAssertEqual(
            try second.pendingMutations(limit: 10).map(\.operation),
            [.delete]
        )
    }

    func testRepositoryRoundTripsPlanningGraph() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Implement a language model",
            currentNextStep: "Read lecture 1",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let plan = try CoursePlan(
            projectId: project.id,
            revision: 1,
            status: .draft,
            courseURL: nil,
            courseTitle: "CS336",
            courseOutline: "Lecture 1",
            goal: project.goal,
            expectedOutcome: "Working notebook",
            startsOn: timestamp,
            deadline: nil,
            weeklyBudgetMinutes: 240,
            summary: "Build the first language model.",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let phase = try PlanPhase(
            planId: plan.id,
            title: "Foundations",
            objective: "Understand tokenization",
            expectedProof: "Tokenizer notebook",
            ordinal: 0,
            targetStart: timestamp,
            targetEnd: timestamp,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let plannedSession = try PlannedSession(
            planId: plan.id,
            phaseId: phase.id,
            projectId: project.id,
            title: "Implement tokenizer",
            actionType: .course,
            expectedProof: "Tokenizer notebook",
            durationMinutes: 45,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = try SwiftDataJournalRepository(
            url: root.appendingPathComponent("journal-v2.store")
        )

        try repository.commit(
            JournalTransaction(
                upserts: [.coursePlan(plan), .planPhase(phase), .plannedSession(plannedSession)],
                origin: .user
            )
        )

        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.coursePlans, [plan])
        XCTAssertEqual(snapshot.planPhases, [phase])
        XCTAssertEqual(snapshot.plannedSessions, [plannedSession])
        XCTAssertEqual(try repository.pendingMutations(limit: 10).count, 3)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
