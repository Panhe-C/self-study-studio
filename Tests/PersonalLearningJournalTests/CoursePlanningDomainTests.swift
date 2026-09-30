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

    func testLegacyCoursePlanningInputDecodesWithVNextDefaults() throws {
        let payload = """
        {
          "projectId": "00000000-0000-0000-0000-0000000007b2",
          "courseTitle": "CS336",
          "courseOutline": "Lecture 1: tokenization",
          "goal": "Build a tokenizer",
          "expectedOutcome": "Tokenizer notebook",
          "startsOn": "2023-11-14T22:13:20Z",
          "weeklyBudgetMinutes": 180,
          "preferredSessionMinutes": 45,
          "availableMinutesByWeekday": {"2": 90}
        }
        """

        let input = try JSONDecoder.journal.decode(CoursePlanningInput.self, from: Data(payload.utf8))

        XCTAssertNil(input.studyPeriodWeeks)
        XCTAssertEqual(input.prerequisites, "")
        XCTAssertEqual(input.constraints, "")
        XCTAssertEqual(input.courseTitle, "CS336")
    }

    func testCoursePlanningInputRoundTripsVNextFields() throws {
        let input = CoursePlanningInput(
            projectId: UUID(),
            courseTitle: "CS336",
            courseOutline: "Lecture 1: tokenization",
            goal: "Build a tokenizer",
            expectedOutcome: "Tokenizer notebook",
            startsOn: Date(timeIntervalSince1970: 1_700_000_000),
            studyPeriodWeeks: 8,
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45,
            availableMinutesByWeekday: [2: 90],
            prerequisites: "Basic Python",
            constraints: "No GPU; evenings only"
        )

        let decoded = try JSONDecoder.journal.decode(
            CoursePlanningInput.self,
            from: JSONEncoder.journal.encode(input)
        )

        XCTAssertEqual(decoded, input)
    }

    func testEffectiveDeadlinePrefersExplicitDeadlineOverStudyPeriod() {
        let startsOn = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = startsOn.addingTimeInterval(30 * 86_400)
        let input = CoursePlanningInput(
            projectId: UUID(),
            courseTitle: "CS336",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Proof",
            startsOn: startsOn,
            deadline: deadline,
            studyPeriodWeeks: 8,
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )

        XCTAssertEqual(input.effectiveDeadline, deadline)
    }

    func testEffectiveDeadlineDerivesFromStudyPeriodWeeksWhenDeadlineMissing() {
        let startsOn = Date(timeIntervalSince1970: 1_700_000_000)
        let input = CoursePlanningInput(
            projectId: UUID(),
            courseTitle: "CS336",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Proof",
            startsOn: startsOn,
            studyPeriodWeeks: 6,
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )

        XCTAssertEqual(input.effectiveDeadline, startsOn.addingTimeInterval(6 * 7 * 86_400))
        XCTAssertNil(input.deadline)
    }

    func testEffectiveDeadlineIsNilWithoutDeadlineOrStudyPeriod() {
        let input = CoursePlanningInput(
            projectId: UUID(),
            courseTitle: "CS336",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Proof",
            startsOn: Date(timeIntervalSince1970: 1_700_000_000),
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )

        XCTAssertNil(input.effectiveDeadline)
    }

    func testLegacyPlannedSessionDecodesWithEmptyCompletionCriteria() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000012",
          "planId": "00000000-0000-0000-0000-000000000010",
          "phaseId": "00000000-0000-0000-0000-000000000011",
          "projectId": "00000000-0000-0000-0000-000000000001",
          "title": "Implement BPE merge loop",
          "actionType": "course",
          "durationMinutes": 60,
          "status": "scheduled",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z",
          "schemaVersion": 3
        }
        """

        let session = try JSONDecoder.journal.decode(PlannedSession.self, from: Data(payload.utf8))

        XCTAssertEqual(session.completionCriteria, [])
        XCTAssertNil(session.recommendationReason)
    }

    func testPlannedSessionRoundTripsCompletionCriteriaAndRecommendationReason() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try PlannedSession(
            planId: UUID(),
            phaseId: UUID(),
            projectId: UUID(),
            title: "Implement tokenizer",
            actionType: .course,
            durationMinutes: 45,
            completionCriteria: ["Running tokenizer notebook", "Merge loop unit test passes"],
            recommendationReason: "First activity in the Foundations phase",
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let decoded = try JSONDecoder.journal.decode(
            PlannedSession.self,
            from: JSONEncoder.journal.encode(session)
        )

        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.completionCriteria, ["Running tokenizer notebook", "Merge loop unit test passes"])
        XCTAssertEqual(decoded.recommendationReason, "First activity in the Foundations phase")
    }

    func testLegacyDraftSessionDecodesWithEmptyCompletionCriteria() throws {
        let payload = """
        {
          "id": "tokenizer",
          "phaseID": "foundations",
          "title": "Implement tokenizer",
          "actionType": "course",
          "durationMinutes": 45
        }
        """

        let session = try JSONDecoder.journal.decode(CoursePlanDraftSession.self, from: Data(payload.utf8))

        XCTAssertEqual(session.completionCriteria, [])
        XCTAssertNil(session.recommendationReason)
        XCTAssertEqual(session.title, "Implement tokenizer")
    }

    func testSaveDraftPersistsCompletionCriteriaAndRecommendationReason() throws {
        let projectID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            id: projectID,
            name: "CS336",
            area: "AI",
            goal: "Build a model",
            currentNextStep: "Read lecture 1",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let input = CoursePlanningInput(
            projectId: projectID,
            courseTitle: "CS336",
            courseOutline: "Language models",
            goal: project.goal,
            expectedOutcome: "Notebook",
            startsOn: timestamp,
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )
        let draft = CoursePlanDraft(
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
                    durationMinutes: 45,
                    completionCriteria: ["Running tokenizer notebook"],
                    recommendationReason: "Starts the Foundations phase"
                )
            ]
        )

        _ = try service.saveDraft(input: input, draft: draft)

        let persisted = try XCTUnwrap(try repository.snapshot().plannedSessions.first)
        XCTAssertEqual(persisted.completionCriteria, ["Running tokenizer notebook"])
        XCTAssertEqual(persisted.recommendationReason, "Starts the Foundations phase")

        let decoded = try JSONDecoder.journal.decode(
            PlannedSession.self,
            from: JSONEncoder.journal.encode(persisted)
        )
        XCTAssertEqual(decoded, persisted)
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
