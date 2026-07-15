import XCTest
@testable import PersonalLearningJournal

final class JournalServiceTests: XCTestCase {
    func testActivatingIdeaRequiresContractAndAttentionBudgetOverride() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let service = JournalService(store: InMemoryJournalStore(), now: { timestamp })
        let first = try service.createIdea(name: "One", area: "A")

        XCTAssertThrowsError(
            try service.activateProject(
                projectId: first.id,
                goal: "Goal",
                nextStep: "Next",
                contract: nil
            )
        ) { error in
            XCTAssertEqual(error as? JournalValidationError, .missingEvidenceContract)
        }

        for name in ["One", "Two", "Three"] {
            let idea = name == "One" ? first : try service.createIdea(name: name, area: "A")
            let contract = try EvidenceContract.weekly(
                projectId: idea.id,
                expectedArtifact: .text,
                acceptanceCriteria: "Explain it",
                startsAt: timestamp
            )
            _ = try service.activateProject(
                projectId: idea.id,
                goal: "Goal",
                nextStep: "Next",
                contract: contract
            )
        }

        let fourth = try service.createIdea(name: "Four", area: "A")
        let fourthContract = try EvidenceContract.weekly(
            projectId: fourth.id,
            expectedArtifact: .text,
            acceptanceCriteria: "Explain it",
            startsAt: timestamp
        )
        XCTAssertThrowsError(
            try service.activateProject(
                projectId: fourth.id,
                goal: "Goal",
                nextStep: "Next",
                contract: fourthContract
            )
        ) { error in
            XCTAssertEqual(error as? JournalValidationError, .attentionBudgetExceeded)
        }
        XCTAssertEqual(service.project(id: fourth.id)?.status, .idea)

        _ = try service.activateProject(
            projectId: fourth.id,
            goal: "Goal",
            nextStep: "Next",
            contract: fourthContract,
            allowAttentionBudgetOverride: true
        )
        XCTAssertEqual(service.snapshot().evidenceContracts.count, 4)
    }

    func testAcceptProofCreatesAcceptanceAndImmutableRevisionSnapshot() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Explain attention",
            currentNextStep: "Write notes"
        )
        let contract = try EvidenceContract.weekly(
            projectId: project.id,
            expectedArtifact: .text,
            acceptanceCriteria: "Explains attention",
            startsAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], evidenceContracts: [contract])
        )
        let service = JournalService(repository: repository, now: { timestamp })
        let proof = try service.addProof(
            projectId: project.id,
            type: .text,
            title: "Attention",
            statement: "I can explain it",
            artifactBody: "# Attention\nQKV"
        )

        let acceptance = try service.acceptProof(
            proofId: proof.id,
            contractId: contract.id,
            acceptedCriteria: ["Explains attention"]
        )

        XCTAssertEqual(acceptance.proofId, proof.id)
        XCTAssertEqual(service.snapshot().proofRevisions.first?.statement, proof.statement)
        XCTAssertEqual(service.snapshot().proofRevisions.first?.revision, proof.revision)
    }

    func testReviewRequiresExplicitDecisionAndCompletionRequiresQualifyingCapstone() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Ship",
            currentNextStep: "Demo"
        )
        let review = Review(
            periodStart: timestamp,
            periodEnd: timestamp,
            facts: [], patterns: [], decisions: [], projectRecommendations: [:],
            nextSteps: [:], aiSourceSummary: [], createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], reviews: [review])
        )
        let service = JournalService(repository: repository, now: { timestamp })

        XCTAssertThrowsError(try service.completeReview(reviewId: review.id, decision: nil)) {
            XCTAssertEqual($0 as? JournalValidationError, .missingReviewDecision)
        }

        let invalidDecision = ReviewDecision(
            reviewId: review.id,
            projectId: project.id,
            kind: .complete,
            capstoneProofId: UUID(),
            decidedAt: timestamp
        )
        XCTAssertThrowsError(try service.completeProject(projectId: project.id, decision: invalidDecision)) {
            XCTAssertEqual($0 as? JournalValidationError, .missingCapstoneProof)
        }
    }

    func testCompleteReviewPersistsDecisionAndCompletesProjectWithCapstone() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Ship", area: "Product", goal: "Launch", currentNextStep: "Demo")
        let proof = try Proof.text(
            projectId: project.id,
            title: "Capstone",
            artifactBody: "# Demo\nIt works",
            statement: "This demonstrates the completed project",
            createdAt: timestamp
        )
        let revision = ProofRevision(
            proof: proof,
            revision: proof.revision,
            artifactChecksum: "sha256:capstone",
            createdAt: timestamp
        )
        let review = Review(
            periodStart: timestamp,
            periodEnd: timestamp,
            facts: [], patterns: [], decisions: [], projectRecommendations: [:],
            nextSteps: [:], aiSourceSummary: [], createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(
            projects: [project], proofs: [proof], reviews: [review], proofRevisions: [revision]
        ))
        let service = JournalService(repository: repository, now: { timestamp })
        let decision = ReviewDecision(
            reviewId: review.id,
            projectId: project.id,
            kind: .complete,
            capstoneProofId: proof.id,
            decidedAt: timestamp
        )

        let completed = try service.completeProject(projectId: project.id, decision: decision)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.completedAt, timestamp)
        XCTAssertEqual(service.snapshot().reviewDecisions, [decision])
        XCTAssertEqual(service.snapshot().reviews.first?.confirmedDecisionIds, [decision.id])
        XCTAssertEqual(service.snapshot().reviews.first?.referencedProofRevisionIds, [revision.id])
    }

    func testTwoUnresolvedContractPeriodsRequireDecision() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Guitar", area: "Music", goal: "Play", currentNextStep: "Practice")
        let contract = try EvidenceContract.weekly(
            projectId: project.id,
            expectedArtifact: .audio,
            acceptanceCriteria: "Clean verse",
            startsAt: start
        )
        let service = JournalService(
            store: InMemoryJournalStore(snapshot: JournalSnapshot(
                projects: [project], evidenceContracts: [contract]
            ))
        )

        XCTAssertEqual(
            service.contractState(
                projectId: project.id,
                referenceDate: start.addingTimeInterval(14 * 24 * 60 * 60)
            ),
            .decisionRequired(unresolvedPeriods: 2)
        )
    }

    func testQuickLogCommitsOnlyChangedEntities() throws {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let repository = TransactionSpyRepository(
            snapshot: JournalSnapshot(projects: [project])
        )
        let service = JournalService(repository: repository)

        _ = try service.quickLog(
            projectId: project.id,
            durationMinutes: 30,
            note: "Finished lecture one",
            nextStep: "Lecture 2"
        )

        let transaction = try XCTUnwrap(repository.transactions.last)
        XCTAssertEqual(
            transaction.upserts.map(\.reference.kind),
            [.project, .session, .trailEvent, .trailEvent]
        )
        XCTAssertTrue(transaction.deletions.isEmpty)
    }
    func testOnboardingIsNotCompleteUntilFirstSessionIsRecorded() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try XCTUnwrap(
            service.createOnboardingProjects([
                ProjectOnboardingDraft(
                    name: "CS336",
                    area: "AI",
                    goal: "复现课程",
                    nextStep: "整理 loss"
                )
            ]).first
        )

        XCTAssertFalse(service.snapshot().hasCompletedOnboarding)
        XCTAssertEqual(service.snapshot().pendingFirstRecordProjectId, project.id)

        _ = try service.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "复现了第一段"
        )
        try service.completeOnboarding()

        XCTAssertTrue(service.snapshot().hasCompletedOnboarding)
        XCTAssertNil(service.snapshot().pendingFirstRecordProjectId)
    }

    func testOnboardingProjectCreationIsAtomicWhenAnyDraftIsInvalid() throws {
        let service = JournalService(store: InMemoryJournalStore())

        XCTAssertThrowsError(
            try service.createOnboardingProjects([
                ProjectOnboardingDraft(
                    name: "CS336",
                    area: "AI",
                    goal: "复现课程",
                    nextStep: "整理 loss"
                ),
                ProjectOnboardingDraft(
                    name: "",
                    area: "Music",
                    goal: "完整弹唱 3 首歌",
                    nextStep: "练 F 到 C"
                )
            ])
        )

        XCTAssertTrue(service.snapshot().projects.isEmpty)
        XCTAssertNil(service.snapshot().pendingFirstRecordProjectId)
    }

    func testTodayContinueOrderingUsesMostRecentProofWhenItIsNewerThanSessions() throws {
        let base = Date(timeIntervalSince1970: 10_000_000)
        var currentDate = base
        let service = JournalService(store: InMemoryJournalStore(), now: { currentDate })
        let sessionProject = try createActivatedProject(
            service: service,
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "写 notebook"
        )
        let proofProject = try createActivatedProject(
            service: service,
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )
        _ = try service.quickLog(
            projectId: sessionProject.id,
            durationMinutes: 20,
            note: "复现第一段",
            endedAt: base.addingTimeInterval(60)
        )
        currentDate = base.addingTimeInterval(120)
        _ = try service.addProof(
            projectId: proofProject.id,
            type: .audio,
            title: "练习录音",
            statement: "能完整弹完第一段"
        )

        XCTAssertEqual(
            service.todayContinueProjects().map(\.id),
            [proofProject.id, sessionProject.id]
        )
    }

    func testActivatedProjectShowsOnTodayWhenCommitmentIsComplete() throws {
        let service = JournalService(store: InMemoryJournalStore())

        let project = try createActivatedProject(
            service: service,
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "整理 perplexity 和 loss 的关系"
        )

        XCTAssertEqual(project.status, .active)
        XCTAssertEqual(service.todayContinueProjects().map(\.id), [project.id])
    }

    func testTodayContinueHidesProjectsWithoutNextStepAndArchivedProjects() throws {
        let service = JournalService(store: InMemoryJournalStore())
        _ = try service.createProject(
            name: "No next step",
            area: "General",
            goal: "Keep learning",
            nextStep: ""
        )
        let active = try createActivatedProject(
            service: service,
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练 F 到 C"
        )

        try service.updateProjectStatus(projectId: active.id, status: .archived)

        XCTAssertTrue(service.todayContinueProjects().isEmpty)
    }

    func testUpdatesProjectDetailsAndArchivesIt() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "看 Lecture 1"
        )

        let updated = try service.updateProject(
            projectId: project.id,
            name: "CS336 Language Modeling",
            area: "LLM",
            goal: "复现一个小训练 loop",
            nextStep: "写 tokenizer notes"
        )
        try service.updateProjectStatus(projectId: project.id, status: .archived)

        let archived = try XCTUnwrap(service.project(id: project.id))
        XCTAssertEqual(updated.name, "CS336 Language Modeling")
        XCTAssertEqual(updated.area, "LLM")
        XCTAssertEqual(updated.goal, "复现一个小训练 loop")
        XCTAssertEqual(archived.status, .archived)
        XCTAssertNotNil(archived.archivedAt)
    }

    func testQuickLogUsesProjectDefaultsAndUpdatesNextStep() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "DaVinci",
            area: "Color",
            goal: "掌握基础调色工作流",
            nextStep: "做一组 before/after"
        )

        let session = try service.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "完成第一组白平衡练习",
            nextStep: "修正肤色偏红"
        )

        let updatedProject = try XCTUnwrap(service.project(id: project.id))
        XCTAssertEqual(session.source, .quickLog)
        XCTAssertEqual(session.actionType, .course)
        XCTAssertEqual(session.nextStepBefore, "做一组 before/after")
        XCTAssertEqual(session.nextStepAfter, "修正肤色偏红")
        XCTAssertEqual(updatedProject.currentNextStep, "修正肤色偏红")
    }

    func testQuickLogCompletesLinkedPlannedSessionInSameJournal() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Build a model",
            currentNextStep: "Read lecture 1",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let plan = try CoursePlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "CS336",
            courseOutline: "Language models",
            goal: project.goal,
            expectedOutcome: "Notebook",
            startsOn: timestamp,
            deadline: nil,
            weeklyBudgetMinutes: 180,
            summary: "Build a model",
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
        let planned = try PlannedSession(
            planId: plan.id,
            phaseId: phase.id,
            projectId: project.id,
            title: "Implement tokenizer",
            actionType: .course,
            durationMinutes: 30,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project],
                coursePlans: [plan],
                planPhases: [phase],
                plannedSessions: [planned]
            )
        )
        let service = JournalService(repository: repository, now: { timestamp })

        let session = try service.quickLog(
            projectId: project.id,
            durationMinutes: planned.durationMinutes,
            note: "Completed tokenizer exercise",
            plannedSessionId: planned.id,
            endedAt: timestamp.addingTimeInterval(30 * 60)
        )

        let updated = try XCTUnwrap(repository.snapshot().plannedSessions.first)
        XCTAssertEqual(updated.status, .completed)
        XCTAssertEqual(updated.completedSessionId, session.id)
    }

    func testListsSessionsAndProofsByProjectAndSession() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )
        let first = try service.quickLog(
            projectId: project.id,
            durationMinutes: 18,
            note: "练了第一段",
            nextStep: "继续练第一段"
        )
        let second = try service.quickLog(
            projectId: project.id,
            durationMinutes: 22,
            note: "练 F 到 C",
            nextStep: "录一版完整片段"
        )
        let proof = try service.addProof(
            projectId: project.id,
            sessionId: second.id,
            type: .audio,
            title: "完整片段",
            statement: "证明第一段能弹完，但换和弦慢"
        )

        XCTAssertEqual(service.sessions(projectId: project.id).map(\.id), [first.id, second.id])
        XCTAssertEqual(service.session(id: second.id)?.note, "练 F 到 C")
        XCTAssertEqual(service.proofs(projectId: project.id).map(\.id), [proof.id])
        XCTAssertEqual(service.proofs(sessionId: second.id).map(\.id), [proof.id])
    }

    func testTimerSessionComputesDurationAndStoresLastActionType() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let startedAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 100 + 47 * 60)
        let project = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "看 Lecture 1"
        )

        let session = try service.saveTimerSession(
            projectId: project.id,
            actionType: .output,
            startedAt: startedAt,
            endedAt: endedAt,
            note: "写了 bigram baseline",
            nextStep: "跑通训练 loop"
        )

        let updatedProject = try XCTUnwrap(service.project(id: project.id))
        XCTAssertEqual(session.source, .timer)
        XCTAssertEqual(session.durationMinutes, 47)
        XCTAssertEqual(updatedProject.lastActionType, .output)
        XCTAssertEqual(updatedProject.defaultDurationMinutes, 47)
    }

    func testAddProofRequiresStatementAndAttachesToSession() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )
        let session = try service.quickLog(
            projectId: project.id,
            durationMinutes: 18,
            note: "练了第一段",
            nextStep: "继续练 F 到 C"
        )

        XCTAssertThrowsError(
            try service.addProof(
                projectId: project.id,
                sessionId: session.id,
                type: .audio,
                title: "练习录音",
                statement: " "
            )
        )

        let proof = try service.addProof(
            projectId: project.id,
            sessionId: session.id,
            type: .audio,
            title: "练习录音",
            statement: "能完整弹完第一段，但 F -> C 仍然卡"
        )

        XCTAssertEqual(proof.sessionId, session.id)
        XCTAssertEqual(service.snapshot().proofs.map(\.id), [proof.id])
    }

    func testReviseProofPreservesPriorRevisionAndUpdatesTextArtifact() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createIdea(name: "Algorithms", area: "CS")
        let original = try service.addProof(
            projectId: project.id,
            type: .text,
            title: "Invariant",
            statement: "First explanation",
            artifactBody: "Original derivation"
        )

        let revised = try service.reviseProof(
            proofId: original.id,
            title: "Loop invariant",
            statement: "Clearer explanation",
            artifactBody: "Revised derivation"
        )

        XCTAssertEqual(revised.revision, 2)
        XCTAssertEqual(revised.artifactBody, "Revised derivation")
        XCTAssertEqual(service.snapshot().proofRevisions.map(\.revision), [1])
        XCTAssertEqual(service.snapshot().proofRevisions.first?.statement, "First explanation")
    }

    func testProjectsNeedingReviewIncludeActiveProjectsIdleForSevenDays() throws {
        let referenceDate = Date(timeIntervalSince1970: 10_000_000)
        let createdAt = referenceDate.addingTimeInterval(-8 * 24 * 60 * 60)
        let service = JournalService(store: InMemoryJournalStore(), now: { createdAt })
        let idleProject = try service.createProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )

        XCTAssertEqual(
            service.projectsNeedingReview(referenceDate: referenceDate).map(\.id),
            [idleProject.id]
        )
    }

    func testProjectsNeedingReviewExcludeRecentlyActiveProjects() throws {
        let referenceDate = Date(timeIntervalSince1970: 10_000_000)
        let service = JournalService(store: InMemoryJournalStore(), now: { referenceDate })
        let project = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "整理 loss"
        )
        _ = try service.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "补记一次学习",
            endedAt: referenceDate.addingTimeInterval(-2 * 24 * 60 * 60)
        )

        XCTAssertTrue(service.projectsNeedingReview(referenceDate: referenceDate).isEmpty)
    }

    func testShouldShowReviewPromptWhenRecentEvidenceIsEnough() throws {
        let referenceDate = Date(timeIntervalSince1970: 10_000_000)
        let service = JournalService(store: InMemoryJournalStore(), now: { referenceDate })
        let project = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "整理 loss"
        )
        _ = try service.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "补记一次学习",
            endedAt: referenceDate.addingTimeInterval(-3 * 24 * 60 * 60)
        )
        _ = try service.quickLog(
            projectId: project.id,
            durationMinutes: 25,
            note: "看完 lecture",
            endedAt: referenceDate.addingTimeInterval(-2 * 24 * 60 * 60)
        )
        _ = try service.addProof(
            projectId: project.id,
            type: .link,
            title: "Notebook",
            statement: "证明完成了第一版 bigram baseline"
        )

        XCTAssertTrue(service.shouldShowReviewPrompt(referenceDate: referenceDate))
    }

    func testTrailEventsCombineSessionsProofsNextStepAndStatusChangesNewestLast() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "看 Lecture 1"
        )
        let session = try service.quickLog(
            projectId: project.id,
            durationMinutes: 45,
            note: "看完 Lecture 1",
            nextStep: "整理 perplexity"
        )
        _ = try service.addProof(
            projectId: project.id,
            sessionId: session.id,
            type: .link,
            title: "Bigram notebook",
            statement: "复现了 bigram baseline"
        )
        try service.updateProjectStatus(projectId: project.id, status: .lowFrequency)

        let events = service.trailEvents(projectId: project.id)

        XCTAssertEqual(events.map(\.type), [.session, .nextStepChange, .proof, .statusChange])
        XCTAssertTrue(events[0].detail.contains("看完 Lecture 1"))
        XCTAssertTrue(events[1].detail.contains("整理 perplexity"))
        XCTAssertTrue(events[2].detail.contains("复现了 bigram baseline"))
        XCTAssertTrue(events[3].detail.contains("low-frequency"))
    }

    private func createActivatedProject(
        service: JournalService,
        name: String,
        area: String,
        goal: String,
        nextStep: String
    ) throws -> Project {
        let idea = try service.createIdea(name: name, area: area)
        let contract = try EvidenceContract.weekly(
            projectId: idea.id,
            expectedArtifact: .text,
            acceptanceCriteria: "Explain the result",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return try service.activateProject(
            projectId: idea.id,
            goal: goal,
            nextStep: nextStep,
            contract: contract
        )
    }
}

private final class TransactionSpyRepository: JournalRepository {
    private var storedSnapshot: JournalSnapshot
    var transactions: [JournalTransaction] = []

    init(snapshot: JournalSnapshot) {
        self.storedSnapshot = snapshot
    }

    func snapshot() throws -> JournalSnapshot { storedSnapshot }

    func commit(_ transaction: JournalTransaction) throws {
        transactions.append(transaction)
    }

    func pendingMutations(limit: Int) throws -> [PendingMutation] { [] }

    func acknowledge(
        _ mutationIDs: Set<UUID>,
        metadata: [SyncRecordMetadata]
    ) throws {}

    func conflicts() throws -> [SyncConflict] { [] }

    func resolveConflict(id: UUID, with entity: JournalEntity) throws {}

    func hasCompletedMigration(identifier: String) throws -> Bool { false }

    func entity(for reference: JournalEntityReference) throws -> JournalEntity? { nil }

    func metadata(for reference: JournalEntityReference) throws -> SyncRecordMetadata? { nil }

    func reference(recordName: String) throws -> JournalEntityReference? { nil }

    func recordSyncFailures(
        retryable: [UUID: String],
        terminal: [UUID: String]
    ) throws {}

    func syncChangeToken() throws -> Data? { nil }

    func storeSyncChangeToken(_ token: Data?) throws {}

    func applyRemote(
        _ transaction: JournalTransaction,
        conflicts: [SyncConflict]
    ) throws {}
}
