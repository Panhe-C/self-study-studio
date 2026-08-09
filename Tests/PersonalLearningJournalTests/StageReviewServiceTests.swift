import XCTest
@testable import PersonalLearningJournal

final class StageReviewServiceTests: XCTestCase {
    func testReadinessIsDeterministicAndExplainsWhy() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(
            name: "Shaders",
            area: "Graphics",
            goal: "Explain one shader",
            currentNextStep: "Write the fragment stage"
        )
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Shaders",
            courseOutline: "",
            goal: project.goal,
            expectedOutcome: "A working fragment shader",
            startsOn: now.addingTimeInterval(-86_400),
            deadline: nil,
            weeklyBudgetMinutes: 120,
            summary: "",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-86_400),
            activatedAt: now.addingTimeInterval(-86_400)
        )
        let phase = try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Fragment stage",
            objective: "Explain the pipeline",
            expectedProof: "A runnable demo",
            ordinal: 0,
            targetStart: now.addingTimeInterval(-7 * 86_400),
            targetEnd: now.addingTimeInterval(-86_400)
        )
        let session = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: phase.id,
            projectId: project.id,
            title: "Build the demo",
            actionType: .experiment,
            durationMinutes: 30,
            status: .completed,
            completedSessionId: UUID()
        )
        let snapshot = JournalSnapshot(
            projects: [project],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [session]
        )

        let first = StageReviewReadinessService().evaluate(
            projectID: project.id,
            phaseID: phase.id,
            snapshot: snapshot,
            at: now
        )
        let second = StageReviewReadinessService().evaluate(
            projectID: project.id,
            phaseID: phase.id,
            snapshot: snapshot,
            at: now
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.isReady)
        XCTAssertTrue(first.reasons.contains(.phaseEnded))
        XCTAssertTrue(first.reasons.contains(.sessionsResolved))
        XCTAssertFalse(first.facts.isEmpty)
        XCTAssertTrue(first.explanation.contains("phase"))
    }

    func testReadinessExplainsUnresolvedSessionsAndMissingProof() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(name: "Guitar", area: "Music", goal: "Play a song", currentNextStep: "Practice")
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Guitar",
            courseOutline: "",
            goal: project.goal,
            expectedOutcome: "Play the song",
            startsOn: now,
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "",
            createdAt: now,
            updatedAt: now,
            activatedAt: now
        )
        let phase = try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Verse",
            objective: "Play the verse",
            expectedProof: "Recording",
            ordinal: 0,
            targetStart: now,
            targetEnd: now.addingTimeInterval(7 * 86_400)
        )
        let session = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: phase.id,
            projectId: project.id,
            title: "Practice verse",
            actionType: .practice,
            durationMinutes: 20,
            status: .scheduled
        )
        let snapshot = JournalSnapshot(
            projects: [project],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [session]
        )

        let readiness = StageReviewReadinessService().evaluate(
            projectID: project.id,
            phaseID: phase.id,
            snapshot: snapshot,
            at: now
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(readiness.reasons.contains(.unresolvedSessions))
        XCTAssertTrue(readiness.reasons.contains(.missingExpectedProof))
        XCTAssertTrue(readiness.explanation.contains("session"))
    }

    func testStageReviewCannotAdvancePhaseWithoutExplicitQualifyingProof() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(name: "Ship", area: "Product", goal: "Ship a demo", currentNextStep: "Demo")
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Demo",
            courseOutline: "",
            goal: project.goal,
            expectedOutcome: "A working demo",
            startsOn: now.addingTimeInterval(-86_400),
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-86_400),
            activatedAt: now.addingTimeInterval(-86_400)
        )
        let phase = try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Demo",
            objective: "Build the demo",
            expectedProof: "A runnable demo",
            ordinal: 0,
            targetStart: now.addingTimeInterval(-7 * 86_400),
            targetEnd: now.addingTimeInterval(-86_400)
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], coursePlans: [plan], planPhases: [phase])
        )
        let service = StageReviewService(repository: repository, now: { now })
        let review = try service.openStageReview(projectID: project.id, phaseID: phase.id)
        let decision = ReviewDecision(
            reviewId: review.id,
            projectId: project.id,
            kind: .advancePhase,
            phaseId: phase.id,
            decidedAt: now
        )

        XCTAssertThrowsError(
            try service.publishStageReview(
                reviewID: review.id,
                decision: decision,
                qualifyingProofID: nil,
                acceptedCriteria: [],
                expectation: try service.revisionGuardExpectation(for: review.id)
            )
        ) { error in
            XCTAssertEqual(error as? StageReviewError, .missingQualifyingProof)
        }
        XCTAssertEqual(try repository.snapshot().reviews.first?.status, .draft)
        XCTAssertTrue(try repository.snapshot().reviewDecisions.isEmpty)
    }

    func testStageReviewPublishesProofAndPhaseTransitionAtomicallyAndIdempotently() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(name: "Ship", area: "Product", goal: "Ship a demo", currentNextStep: "Demo")
        let contract = try EvidenceContract.weekly(
            projectId: project.id,
            expectedArtifact: .text,
            acceptanceCriteria: "A runnable demo",
            startsAt: now.addingTimeInterval(-7 * 86_400)
        )
        var readyProject = project
        readyProject.activeEvidenceContractId = contract.id
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Demo",
            courseOutline: "",
            goal: project.goal,
            expectedOutcome: "A working demo",
            startsOn: now.addingTimeInterval(-7 * 86_400),
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "",
            createdAt: now.addingTimeInterval(-7 * 86_400),
            updatedAt: now.addingTimeInterval(-7 * 86_400),
            activatedAt: now.addingTimeInterval(-7 * 86_400)
        )
        let phase = try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Demo",
            objective: "Build the demo",
            expectedProof: "A runnable demo",
            ordinal: 0,
            targetStart: now.addingTimeInterval(-7 * 86_400),
            targetEnd: now.addingTimeInterval(-86_400)
        )
        let proof = try Proof.text(
            projectId: project.id,
            title: "Runnable demo",
            artifactBody: "# Demo\nIt runs.",
            statement: "This proves the demo runs.",
            createdAt: now
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(
            projects: [readyProject],
            proofs: [proof],
            evidenceContracts: [contract],
            coursePlans: [plan],
            planPhases: [phase]
        ))
        let service = StageReviewService(repository: repository, now: { now })
        let review = try service.openStageReview(projectID: project.id, phaseID: phase.id)
        let decision = ReviewDecision(
            reviewId: review.id,
            projectId: project.id,
            kind: .advancePhase,
            phaseId: phase.id,
            decidedAt: now
        )

        let published = try service.publishStageReview(
            reviewID: review.id,
            decision: decision,
            qualifyingProofID: proof.id,
            acceptedCriteria: ["A runnable demo"],
            expectation: try service.revisionGuardExpectation(for: review.id)
        )
        let after = try repository.snapshot()
        XCTAssertEqual(published.status, .published)
        XCTAssertEqual(after.reviews.first?.status, .published)
        XCTAssertEqual(after.planPhases.first?.progress, .completed)
        XCTAssertEqual(after.projects.first?.status, .completed)
        XCTAssertEqual(after.evidenceAcceptances.count, 1)
        XCTAssertTrue(after.evidenceAcceptances.first?.isQualifyingProof == true)
        XCTAssertEqual(after.reviewDecisions.count, 1)
        XCTAssertEqual(after.trailEvents.filter { $0.type == .review }.count, 1)

        XCTAssertThrowsError(
            try service.publishStageReview(
                reviewID: review.id,
                decision: decision,
                qualifyingProofID: proof.id,
                acceptedCriteria: ["A runnable demo"],
                expectation: try service.revisionGuardExpectation(for: review.id)
            )
        ) { error in
            XCTAssertEqual(error as? StageReviewError, .alreadyPublished)
        }
        let idempotent = try repository.snapshot()
        XCTAssertEqual(idempotent.reviewDecisions.count, 1)
        XCTAssertEqual(idempotent.evidenceAcceptances.count, 1)
    }

    func testStageReviewPublicationRejectsStaleCapturedRevision() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(name: "Ship", area: "Product", goal: "Ship", currentNextStep: "Demo")
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Demo",
            courseOutline: "",
            goal: project.goal,
            expectedOutcome: "Demo",
            startsOn: now.addingTimeInterval(-86_400),
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-86_400),
            activatedAt: now.addingTimeInterval(-86_400)
        )
        let phase = try PlanPhase(
            planId: plan.id,
            title: "Demo",
            objective: "Build",
            expectedProof: "Demo",
            ordinal: 0,
            targetStart: now.addingTimeInterval(-86_400),
            targetEnd: now
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(
            projects: [project], coursePlans: [plan], planPhases: [phase]
        ))
        let service = StageReviewService(repository: repository, now: { now })
        let review = try service.openStageReview(projectID: project.id, phaseID: phase.id)
        let reviewReference = JournalEntity.review(review).reference
        let firstMutation = try XCTUnwrap(try repository.pendingMutations(limit: 10).first)
        try repository.acknowledge(
            [firstMutation.id],
            metadata: [SyncRecordMetadata(
                entity: reviewReference,
                zoneName: "LearningJournalZone",
                recordName: review.id.uuidString,
                recordChangeTag: "tag-1",
                state: .synced
            )]
        )
        let captured = try service.revisionGuardExpectation(for: review.id)

        var changed = review
        changed.facts.append("Changed after capture")
        try repository.commit(
            JournalTransaction(
                upserts: [.review(changed)],
                origin: .user,
                revisionExpectations: [reviewReference: captured]
            )
        )
        let secondMutation = try XCTUnwrap(try repository.pendingMutations(limit: 10).first)
        try repository.acknowledge(
            [secondMutation.id],
            metadata: [SyncRecordMetadata(
                entity: reviewReference,
                zoneName: "LearningJournalZone",
                recordName: review.id.uuidString,
                recordChangeTag: "tag-2",
                state: .synced
            )]
        )
        let decision = ReviewDecision(
            reviewId: review.id,
            projectId: project.id,
            kind: .continueUnchanged,
            phaseId: phase.id,
            decidedAt: now
        )

        XCTAssertThrowsError(
            try service.publishStageReview(
                reviewID: review.id,
                decision: decision,
                qualifyingProofID: nil,
                acceptedCriteria: [],
                expectation: captured
            )
        ) { error in
            XCTAssertEqual(error as? StageReviewError, .staleRevision)
        }
        XCTAssertEqual(try repository.snapshot().reviews.first?.status, .draft)
        XCTAssertTrue(try repository.snapshot().reviewDecisions.isEmpty)
    }

    func testReviseDecisionCreatesGuardedPlanRevisionDraftInsteadOfMutatingPublishedPlan() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(name: "Plan", area: "Study", goal: "Learn", currentNextStep: "Start")
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Plan",
            courseOutline: "",
            goal: project.goal,
            expectedOutcome: "Explain",
            startsOn: now.addingTimeInterval(-86_400),
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "",
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-86_400),
            activatedAt: now.addingTimeInterval(-86_400)
        )
        let phase = try PlanPhase(
            planId: plan.id,
            title: "Phase",
            objective: "Objective",
            expectedProof: "Proof",
            ordinal: 0,
            targetStart: now.addingTimeInterval(-86_400),
            targetEnd: now
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(
            projects: [project], coursePlans: [plan], planPhases: [phase]
        ))
        let service = StageReviewService(repository: repository, now: { now })
        let review = try service.openStageReview(projectID: project.id, phaseID: phase.id)
        let decision = ReviewDecision(
            reviewId: review.id,
            projectId: project.id,
            kind: .revisePhase,
            phaseId: phase.id,
            decidedAt: now
        )

        let published = try service.publishStageReview(
            reviewID: review.id,
            decision: decision,
            qualifyingProofID: nil,
            acceptedCriteria: [],
            expectation: try service.revisionGuardExpectation(for: review.id)
        )
        let after = try repository.snapshot()
        let draft = try XCTUnwrap(after.coursePlans.first { $0.status == .draft })
        XCTAssertEqual(published.status, .published)
        XCTAssertEqual(draft.baseRevisionID, plan.revisionID)
        XCTAssertEqual(draft.supersedesID, plan.revisionID)
        XCTAssertEqual(after.coursePlans.first { $0.id == plan.id }?.status, .active)
        XCTAssertEqual(after.planPhases.filter { $0.planId == draft.id }.count, 1)
        XCTAssertEqual(after.reviewDecisions.first?.planRevisionDraftId, draft.id)
    }
}
