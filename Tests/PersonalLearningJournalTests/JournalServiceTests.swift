import XCTest
@testable import PersonalLearningJournal

final class JournalServiceTests: XCTestCase {
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
        let sessionProject = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "写 notebook"
        )
        let proofProject = try service.createProject(
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

    func testCreatesOnboardingProjectAndShowsItOnTodayWhenNextStepExists() throws {
        let service = JournalService(store: InMemoryJournalStore())

        let project = try service.createProject(
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
        let active = try service.createProject(
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
