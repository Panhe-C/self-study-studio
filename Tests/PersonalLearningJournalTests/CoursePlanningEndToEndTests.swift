import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CoursePlanningEndToEndTests: XCTestCase {
    func testActivatePlanStartPlannedSessionAndRecordProofCompletesTheLoop() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let planningService = CoursePlanningService(repository: repository, now: { self.timestamp })
        let journalService = JournalService(repository: repository, now: { self.timestamp })

        let draftPlan = try planningService.saveDraft(input: input, draft: draft)
        _ = try planningService.activate(draftPlanID: draftPlan.id)
        let planned = try XCTUnwrap(try repository.snapshot().plannedSessions.first)
        let session = try journalService.quickLog(
            projectId: project.id,
            actionType: planned.actionType,
            durationMinutes: planned.durationMinutes,
            note: "Completed the tokenizer exercise",
            nextStep: nil,
            plannedSessionId: planned.id
        )
        _ = try journalService.addProof(
            projectId: project.id,
            sessionId: session.id,
            type: .link,
            title: "Tokenizer notebook",
            statement: "The tokenizer passes the course examples"
        )

        let completed = try XCTUnwrap(try repository.snapshot().plannedSessions.first)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.completedSessionId, session.id)
    }

    func testWeeklyReviewIncludesActivePlanProgressAsSources() async throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let planningService = CoursePlanningService(repository: repository, now: { self.timestamp })
        let journalService = JournalService(repository: repository, now: { self.timestamp })
        let draftPlan = try planningService.saveDraft(input: input, draft: draft)
        _ = try planningService.activate(draftPlanID: draftPlan.id)
        let planned = try XCTUnwrap(try repository.snapshot().plannedSessions.first)
        _ = try journalService.quickLog(
            projectId: project.id,
            actionType: planned.actionType,
            durationMinutes: planned.durationMinutes,
            note: "Completed the tokenizer exercise",
            nextStep: nil,
            plannedSessionId: planned.id
        )

        let review = try await ReviewService(
            journalService: journalService,
            provider: RuleBasedReviewProvider(),
            now: { self.timestamp }
        ).createWeeklyReview(
            periodStart: timestamp.addingTimeInterval(-7 * 86_400),
            periodEnd: timestamp.addingTimeInterval(7 * 86_400)
        )

        XCTAssertTrue(review.aiSourceSummary.contains { $0.contains("plan") })
        XCTAssertTrue(review.aiSourceSummary.contains { $0.contains("completed 1 of 2") })
    }

    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let project = Project(
        name: "CS336",
        area: "AI",
        goal: "Build a tokenizer",
        currentNextStep: "Read lecture 1",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private var input: CoursePlanningInput {
        CoursePlanningInput(
            projectId: project.id,
            courseTitle: "CS336",
            courseOutline: "Lecture 1: tokenization",
            goal: project.goal,
            expectedOutcome: "Tokenizer notebook",
            startsOn: timestamp,
            deadline: timestamp.addingTimeInterval(7 * 86_400),
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )
    }

    private var draft: CoursePlanDraft {
        CoursePlanDraft(
            title: "CS336 plan",
            summary: "Tokenizer foundation",
            phases: [
                CoursePlanDraftPhase(
                    id: "foundations",
                    title: "Foundations",
                    objective: "Understand tokenization",
                    expectedProof: "Tokenizer notebook",
                    ordinal: 0,
                    targetStart: timestamp,
                    targetEnd: timestamp.addingTimeInterval(7 * 86_400)
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "tokenizer",
                    phaseID: "foundations",
                    title: "Implement tokenizer",
                    actionType: .course,
                    expectedProof: "Tokenizer notebook",
                    durationMinutes: 45,
                    deadline: timestamp
                ),
                CoursePlanDraftSession(
                    id: "review",
                    phaseID: "foundations",
                    title: "Review tokenizer examples",
                    actionType: .review,
                    expectedProof: "Tokenizer notebook",
                    durationMinutes: 45,
                    deadline: timestamp.addingTimeInterval(86_400)
                )
            ]
        )
    }
}
