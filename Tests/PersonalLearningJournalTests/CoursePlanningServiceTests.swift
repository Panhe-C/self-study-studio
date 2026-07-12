import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CoursePlanningServiceTests: XCTestCase {
    func testSavingDraftPersistsItWithoutActivatingProject() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })

        let draftPlan = try service.saveDraft(input: input, draft: draft)

        XCTAssertEqual(draftPlan.status, .draft)
        XCTAssertNil(try repository.snapshot().projects.first?.activeCoursePlanId)
        XCTAssertEqual(try repository.snapshot().coursePlans.map(\.id), [draftPlan.id])
        XCTAssertEqual(try repository.snapshot().plannedSessions.count, 1)
    }

    func testActivationUpdatesProjectAndArchivesPreviousPlan() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let firstDraft = try service.saveDraft(input: input, draft: draft)
        _ = try service.activate(draftPlanID: firstDraft.id)
        let secondDraft = try service.saveDraft(input: input, draft: draft)

        let activated = try service.activate(draftPlanID: secondDraft.id)
        let snapshot = try repository.snapshot()

        XCTAssertEqual(activated.status, .active)
        XCTAssertEqual(snapshot.projects.first?.activeCoursePlanId, secondDraft.id)
        XCTAssertEqual(snapshot.coursePlans.first { $0.id == firstDraft.id }?.status, .archived)
        XCTAssertEqual(snapshot.trailEvents.filter { $0.type == .planActivated }.count, 2)
    }

    func testGenerationFailureLeavesJournalUnchanged() async throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(
            repository: repository,
            provider: UnavailableCoursePlanningProvider(),
            now: { self.timestamp }
        )

        do {
            _ = try await service.generateDraft(input: input, context: .init())
            XCTFail("Expected AI configuration error")
        } catch let error as CoursePlanningError {
            XCTAssertEqual(error, .configurationRequired)
        }
        XCTAssertTrue(try repository.snapshot().coursePlans.isEmpty)
    }

    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let projectID = UUID()

    private var project: Project {
        Project(
            id: projectID,
            name: "CS336",
            area: "AI",
            goal: "Build a model",
            currentNextStep: "Read lecture 1",
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private var input: CoursePlanningInput {
        CoursePlanningInput(
            projectId: projectID,
            courseTitle: "CS336",
            courseOutline: "Language models",
            goal: project.goal,
            expectedOutcome: "Notebook",
            startsOn: timestamp,
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )
    }

    private var draft: CoursePlanDraft {
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
                    targetStart: timestamp,
                    targetEnd: timestamp.addingTimeInterval(86_400)
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

private struct UnavailableCoursePlanningProvider: CoursePlanningProvider {
    func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft {
        throw CoursePlanningError.configurationRequired
    }
}
