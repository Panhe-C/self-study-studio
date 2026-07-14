import XCTest
@testable import PersonalLearningJournal

final class CoursePlanValidatorTests: XCTestCase {
    func testDraftRejectsUnknownPhaseReference() {
        let result = CoursePlanValidator().validate(
            CoursePlanDraft(
                title: "CS336 Plan",
                summary: "Build a model",
                phases: [
                    CoursePlanDraftPhase(
                        id: "foundations",
                        title: "Foundations",
                        objective: "Understand tokenization",
                        expectedProof: "Tokenizer notebook",
                        ordinal: 0,
                        targetStart: Date(timeIntervalSince1970: 1_700_000_000),
                        targetEnd: Date(timeIntervalSince1970: 1_700_086_400)
                    )
                ],
                sessions: [
                    CoursePlanDraftSession(
                        id: "tokenizer",
                        phaseID: "missing-phase",
                        title: "Implement tokenizer",
                        actionType: .course,
                        durationMinutes: 45
                    )
                ]
            ),
            input: validInput
        )

        XCTAssertEqual(result.errors, [.unknownPhaseReference("missing-phase")])
    }

    func testValidatorWarnsWhenWeeklyBudgetExceedsAvailability() {
        var input = validInput
        input.weeklyBudgetMinutes = 300
        input.availableMinutesByWeekday = [2: 60]

        let result = CoursePlanValidator().validate(validDraft, input: input)

        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
    }

    private var validInput: CoursePlanningInput {
        CoursePlanningInput(
            projectId: UUID(),
            courseTitle: "CS336",
            courseOutline: "Language models",
            goal: "Build a model",
            expectedOutcome: "Notebook",
            startsOn: Date(timeIntervalSince1970: 1_700_000_000),
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )
    }

    private var validDraft: CoursePlanDraft {
        CoursePlanDraft(
            title: "CS336 Plan",
            summary: "Build a model",
            phases: [
                CoursePlanDraftPhase(
                    id: "foundations",
                    title: "Foundations",
                    objective: "Understand tokenization",
                    expectedProof: "Tokenizer notebook",
                    ordinal: 0,
                    targetStart: Date(timeIntervalSince1970: 1_700_000_000),
                    targetEnd: Date(timeIntervalSince1970: 1_700_086_400)
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "tokenizer",
                    phaseID: "foundations",
                    title: "Implement tokenizer",
                    actionType: .course,
                    durationMinutes: 45
                )
            ]
        )
    }
}
