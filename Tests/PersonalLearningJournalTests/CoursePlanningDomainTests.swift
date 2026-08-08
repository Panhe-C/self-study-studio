import XCTest
@testable import PersonalLearningJournal

final class CoursePlanningDomainTests: XCTestCase {
    func testCoursePlanRequiresPositiveWeeklyBudget() throws {
        XCTAssertThrowsError(
            try CoursePlan(
                projectId: UUID(),
                revision: 1,
                status: .draft,
                courseURL: nil,
                courseTitle: "CS336",
                courseOutline: "",
                goal: "Implement a language model",
                expectedOutcome: "Working notebook",
                startsOn: Date(),
                deadline: nil,
                weeklyBudgetMinutes: 0,
                summary: ""
            )
        ) { error in
            XCTAssertEqual(error as? CoursePlanningValidationError, .invalidWeeklyBudget)
        }
    }

    func testPlanPhaseRejectsReversedTargetRange() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(
            try PlanPhase(
                planId: UUID(),
                title: "Tokenizer",
                objective: "Understand tokenization",
                expectedProof: "Tokenizer notebook",
                ordinal: 0,
                targetStart: day,
                targetEnd: day.addingTimeInterval(-60)
            )
        ) { error in
            XCTAssertEqual(error as? CoursePlanningValidationError, .invalidDateRange)
        }
    }

    func testLegacySnapshotDecodesWithEmptyPlanningCollections() throws {
        let data = Data(#"{"projects":[],"sessions":[],"proofs":[],"reviews":[],"trailEvents":[]}"#.utf8)

        let snapshot = try JSONDecoder.journal.decode(JournalSnapshot.self, from: data)

        XCTAssertTrue(snapshot.coursePlans.isEmpty)
        XCTAssertTrue(snapshot.planPhases.isEmpty)
        XCTAssertTrue(snapshot.plannedSessions.isEmpty)
    }

    func testLegacyCoursePlanArchiveDecodesAsLearningPlanWithoutLoss() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000007b1")!
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-0000000007b2")!
        let payload = """
        {
          "id": "\(id.uuidString)",
          "projectId": "\(projectID.uuidString)",
          "revision": 3,
          "status": "active",
          "courseURL": "https://example.com/course",
          "courseTitle": "Legacy Course",
          "courseOutline": "Outline",
          "goal": "Ship a notebook",
          "expectedOutcome": "Notebook",
          "startsOn": "2023-11-14T22:13:20Z",
          "deadline": null,
          "weeklyBudgetMinutes": 180,
          "summary": "Keep the original plan",
          "createdAt": "2023-11-14T22:13:20Z",
          "updatedAt": "2023-11-15T22:13:20Z",
          "activatedAt": "2023-11-15T22:13:20Z",
          "deletedAt": null,
          "schemaVersion": 1
        }
        """

        let plan = try JSONDecoder.journal.decode(LearningPlan.self, from: Data(payload.utf8))

        XCTAssertEqual(plan.id, id)
        XCTAssertEqual(plan.courseTitle, "Legacy Course")
        XCTAssertEqual(plan.revision, 3)
        XCTAssertEqual(plan.planSeriesID, id)
        XCTAssertEqual(plan.revisionID, id)
        XCTAssertNil(plan.baseRevisionID)
        XCTAssertNil(plan.supersedesID)
    }

    func testPlanRevisionIsAnImmutableRevisionSnapshot() throws {
        let plan = try CoursePlan(
            projectId: UUID(),
            revision: 1,
            status: .draft,
            courseURL: nil,
            courseTitle: "Learning Plan",
            courseOutline: "Outline",
            goal: "Learn",
            expectedOutcome: "Proof",
            startsOn: Date(timeIntervalSince1970: 1_700_000_000),
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "Summary"
        )

        let revision = PlanRevision(plan: plan, phases: [], sessions: [])

        XCTAssertEqual(revision.plan.id, plan.id)
        XCTAssertEqual(revision.revisionID, plan.revisionID)
        XCTAssertEqual(revision.planSeriesID, plan.planSeriesID)
        XCTAssertFalse(revision.isActive)
    }
}
