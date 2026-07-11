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
}
