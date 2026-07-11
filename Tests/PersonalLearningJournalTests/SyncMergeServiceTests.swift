import XCTest
@testable import PersonalLearningJournal

final class SyncMergeServiceTests: XCTestCase {
    func testDisjointProjectEditsMergeWithoutConflict() throws {
        let base = Project(
            id: UUID(),
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        var local = base
        local.goal = "New goal"
        local.updatedAt = Date(timeIntervalSince1970: 2_000)
        var server = base
        server.currentNextStep = "New next"
        server.updatedAt = Date(timeIntervalSince1970: 3_000)

        let result = try SyncMergeService().merge(
            base: .project(base),
            local: .project(local),
            server: .project(server)
        )

        guard case let .merged(.project(project)) = result else {
            return XCTFail("Expected merged project")
        }
        XCTAssertEqual(project.goal, "New goal")
        XCTAssertEqual(project.currentNextStep, "New next")
        XCTAssertEqual(project.updatedAt, server.updatedAt)
    }

    func testSameFieldProjectEditsCreateConflictWithoutDroppingEitherValue() throws {
        let base = Project(
            id: UUID(),
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        var local = base
        local.goal = "Local goal"
        local.updatedAt = Date(timeIntervalSince1970: 2_000)
        var server = base
        server.goal = "Server goal"
        server.updatedAt = Date(timeIntervalSince1970: 3_000)

        let result = try SyncMergeService().merge(
            base: .project(base),
            local: .project(local),
            server: .project(server)
        )

        guard case let .conflict(conflict) = result else {
            return XCTFail("Expected conflict")
        }
        XCTAssertEqual(conflict.entity, .init(.project, base.id))
        XCTAssertEqual(conflict.conflictingFields, ["goal"])
        XCTAssertFalse(conflict.localPayload.isEmpty)
        XCTAssertFalse(conflict.serverPayload.isEmpty)
    }

    func testDifferentEntityKindsAreRejected() {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let event = TrailEvent(
            projectId: project.id,
            type: .session,
            sourceId: UUID(),
            occurredAt: Date(),
            title: "Session",
            detail: "Read"
        )

        XCTAssertThrowsError(
            try SyncMergeService().merge(
                base: .project(project),
                local: .project(project),
                server: .trailEvent(event)
            )
        )
    }

    func testOptionalProjectFieldMergesNilToValueWithoutRejectingPayload() throws {
        let base = Project(
            id: UUID(),
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        var local = base
        local.archivedAt = Date(timeIntervalSince1970: 2_000)
        local.updatedAt = Date(timeIntervalSince1970: 2_000)
        var server = base
        server.currentNextStep = "Lecture 2"
        server.updatedAt = Date(timeIntervalSince1970: 3_000)

        let result = try SyncMergeService().merge(
            base: .project(base),
            local: .project(local),
            server: .project(server)
        )

        guard case let .merged(.project(project)) = result else {
            return XCTFail("Expected merged project")
        }
        XCTAssertEqual(project.archivedAt, local.archivedAt)
        XCTAssertEqual(project.currentNextStep, server.currentNextStep)
    }

    func testSameFieldPlanPhaseEditsCreateConflict() throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let base = try PlanPhase(
            planId: UUID(),
            title: "Tokenizer",
            objective: "Understand tokenization",
            expectedProof: "Notebook",
            ordinal: 0,
            targetStart: timestamp,
            targetEnd: timestamp.addingTimeInterval(60),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var local = base
        local.objective = "Implement byte pair encoding"
        local.updatedAt = timestamp.addingTimeInterval(60)
        var server = base
        server.objective = "Compare tokenizers"
        server.updatedAt = timestamp.addingTimeInterval(120)

        let result = try SyncMergeService().merge(
            base: .planPhase(base),
            local: .planPhase(local),
            server: .planPhase(server)
        )

        guard case let .conflict(conflict) = result else {
            return XCTFail("Expected conflict")
        }
        XCTAssertEqual(conflict.entity, .init(.planPhase, base.id))
        XCTAssertEqual(conflict.conflictingFields, ["objective"])
    }
}
