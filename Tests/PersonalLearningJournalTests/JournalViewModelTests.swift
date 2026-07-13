import CloudKit
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class JournalViewModelTests: XCTestCase {
    @MainActor
    func testSyncSummaryShowsQueuedChangesAndConflictCount() async throws {
        let repository = InMemoryJournalRepository()
        let journalService = JournalService(repository: repository)
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(
                journalService: journalService,
                provider: RuleBasedReviewProvider()
            ),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository),
            practiceTimer: PracticeTimerRuntime(store: ViewModelPracticeTimerStateStore()),
            syncCoordinator: StaticSyncStatusProvider(
                status: .failed(pending: 2, conflicts: 1, message: "Offline")
            )
        )

        await viewModel.refreshSyncSummary()

        XCTAssertEqual(viewModel.syncSummary.title, "Needs Attention")
        XCTAssertEqual(viewModel.syncSummary.detail, "2 changes waiting, 1 conflict")
    }
    func testOnboardingCompletesAfterFirstQuickLogAndShowsTodayContinueCard() throws {
        let viewModel = makeViewModel()

        let project = try viewModel.onboardProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "整理 perplexity"
        )

        XCTAssertFalse(viewModel.hasCompletedOnboarding)
        XCTAssertEqual(viewModel.pendingFirstRecordProject?.id, project.id)

        _ = try viewModel.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "完成第一条学习记录"
        )

        XCTAssertTrue(viewModel.hasCompletedOnboarding)
        XCTAssertNil(viewModel.pendingFirstRecordProject)
        XCTAssertEqual(viewModel.continueCards.map(\.id), [project.id])
    }

    func testCreatingProjectAfterOnboardingKeepsOnboardingCompleted() throws {
        let viewModel = makeViewModel()
        let initialProject = try viewModel.onboardProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "写 notebook"
        )
        _ = try viewModel.quickLog(
            projectId: initialProject.id,
            durationMinutes: 20,
            note: "完成第一条记录"
        )

        let laterProject = try viewModel.createProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )

        XCTAssertTrue(viewModel.hasCompletedOnboarding)
        XCTAssertNil(viewModel.pendingFirstRecordProject)
        XCTAssertEqual(Set(viewModel.projects.map(\.id)), Set([initialProject.id, laterProject.id]))
    }

    func testOnboardingCanCreateUpToThreeCurrentProjects() throws {
        let viewModel = makeViewModel()

        let projects = try viewModel.onboardProjects([
            ProjectOnboardingDraft(
                name: "CS336",
                area: "AI",
                goal: "复现课程",
                nextStep: "整理 loss"
            ),
            ProjectOnboardingDraft(
                name: "吉他弹唱",
                area: "Music",
                goal: "完整弹唱 3 首歌",
                nextStep: "练 F 到 C"
            ),
            ProjectOnboardingDraft(
                name: "DaVinci 调色",
                area: "Color",
                goal: "掌握基础调色工作流",
                nextStep: "做一组 before/after"
            )
        ])

        XCTAssertEqual(projects.map(\.name), ["CS336", "吉他弹唱", "DaVinci 调色"])
        XCTAssertEqual(Set(viewModel.continueCards.map(\.id)), Set(projects.map(\.id)))
    }

    func testQuickLogRefreshesSessionsAndTrail() throws {
        let viewModel = makeViewModel()
        let project = try viewModel.onboardProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )

        let session = try viewModel.quickLog(
            projectId: project.id,
            durationMinutes: 18,
            note: "练了第一段",
            nextStep: "继续练 F 到 C"
        )

        XCTAssertEqual(viewModel.sessions.map(\.id), [session.id])
        XCTAssertTrue(viewModel.trail(for: project.id).contains { $0.type == .session })
    }

    func testCanEditProjectChangeStatusAndReadProjectCollections() throws {
        let viewModel = makeViewModel()
        let project = try viewModel.onboardProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "看 Lecture 1"
        )
        let session = try viewModel.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "补记一次学习",
            nextStep: "写 tokenizer notes"
        )
        let proof = try viewModel.addProof(
            projectId: project.id,
            sessionId: session.id,
            type: .link,
            title: "Notebook",
            statement: "证明完成了第一版 bigram baseline"
        )

        let updated = try viewModel.updateProject(
            projectId: project.id,
            name: "CS336 LM",
            area: "LLM",
            goal: "复现训练 loop",
            nextStep: "跑通 tokenizer"
        )
        try viewModel.updateProjectStatus(projectId: project.id, status: .lowFrequency)

        XCTAssertEqual(updated.name, "CS336 LM")
        XCTAssertEqual(viewModel.projects.first?.status, .lowFrequency)
        XCTAssertEqual(viewModel.sessionsForProject(project.id).map(\.id), [session.id])
        XCTAssertEqual(viewModel.proofsForProject(project.id).map(\.id), [proof.id])
        XCTAssertEqual(viewModel.proofsForSession(session.id).map(\.id), [proof.id])
    }

    func testTimerProofAndWeeklyReviewUpdateVisibleTabs() async throws {
        let viewModel = makeViewModel()
        let startedAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 100 + 30 * 60)
        let project = try viewModel.onboardProject(
            name: "DaVinci",
            area: "Color",
            goal: "掌握基础调色工作流",
            nextStep: "做一组 before/after"
        )

        let session = try viewModel.saveTimerSession(
            projectId: project.id,
            actionType: .practice,
            startedAt: startedAt,
            endedAt: endedAt,
            note: "做完一组白平衡",
            nextStep: "修正肤色偏红"
        )
        let proof = try viewModel.addProof(
            projectId: project.id,
            sessionId: session.id,
            type: .image,
            title: "before/after",
            statement: "证明能控制白平衡，但肤色偏红"
        )
        let review = try await viewModel.createWeeklyReview(
            periodStart: .distantPast,
            periodEnd: .distantFuture
        )

        XCTAssertEqual(viewModel.sessions.map(\.id), [session.id])
        XCTAssertEqual(viewModel.proofs.map(\.id), [proof.id])
        XCTAssertEqual(viewModel.reviews.map(\.id), [review.id])
        XCTAssertTrue(viewModel.trail(for: project.id).contains { $0.type == .review })
        XCTAssertEqual(viewModel.reviewsForProject(project.id).map(\.id), [review.id])
    }

    func testGeneratedPlanRemainsDraftUntilActivateIsCalled() async throws {
        let repository = InMemoryJournalRepository()
        let journalService = JournalService(repository: repository)
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository),
            practiceTimer: PracticeTimerRuntime(store: ViewModelPracticeTimerStateStore()),
            coursePlanningService: CoursePlanningService(
                repository: repository,
                provider: StubCoursePlanningProvider()
            )
        )
        let project = try viewModel.createProject(
            name: "CS336",
            area: "AI",
            goal: "Build a tokenizer",
            nextStep: "Read lecture 1"
        )
        let input = CoursePlanningInput(
            projectId: project.id,
            courseTitle: "CS336",
            courseOutline: "Lecture 1: tokenization",
            goal: project.goal,
            expectedOutcome: "Tokenizer notebook",
            startsOn: Date(timeIntervalSince1970: 1_700_000_000),
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )

        let draftPlan = try await viewModel.generateCoursePlan(input)

        XCTAssertEqual(viewModel.draftCoursePlan?.id, draftPlan.id)
        XCTAssertNil(viewModel.activeCoursePlan(for: project.id))

        try viewModel.activateCoursePlan(draftPlanID: draftPlan.id)

        XCTAssertEqual(viewModel.activeCoursePlan(for: project.id)?.id, draftPlan.id)
    }

    func testProjectsNeedingReviewAreVisibleToViews() throws {
        let referenceDate = Date(timeIntervalSince1970: 10_000_000)
        let viewModel = makeViewModel(now: { referenceDate.addingTimeInterval(-8 * 24 * 60 * 60) })
        let project = try viewModel.onboardProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )

        XCTAssertEqual(
            viewModel.projectsNeedingReview(referenceDate: referenceDate).map(\.id),
            [project.id]
        )
    }

    func testReviewActionsApplyRecommendationAndNextStepOnlyWhenRequested() throws {
        let repository = InMemoryJournalRepository()
        let journalService = JournalService(repository: repository)
        let project = try journalService.createProject(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            nextStep: "练第一段"
        )
        let review = Review(
            periodStart: .distantPast,
            periodEnd: .distantFuture,
            facts: ["Guitar: no sessions this week."],
            patterns: ["The project has gone quiet."],
            decisions: ["Lower Guitar for this week."],
            projectRecommendations: [project.id: .lowFrequency],
            nextSteps: [project.id: "录一段第一段练习"],
            aiSourceSummary: ["project: no session in period"]
        )
        try journalService.recordReview(review)
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository),
            practiceTimer: PracticeTimerRuntime(store: ViewModelPracticeTimerStateStore())
        )

        try viewModel.applyReviewRecommendation(reviewId: review.id, projectId: project.id)
        try viewModel.applyReviewNextStep(reviewId: review.id, projectId: project.id)

        XCTAssertEqual(viewModel.projects.first?.status, .lowFrequency)
        XCTAssertEqual(viewModel.projects.first?.currentNextStep, "录一段第一段练习")
    }

    func testAddProofFromAttachmentDataStoresFileBeforeCreatingProof() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = makeViewModel(attachmentRoot: root)
        let project = try viewModel.onboardProject(
            name: "DaVinci",
            area: "Color",
            goal: "掌握基础调色工作流",
            nextStep: "做一组 before/after"
        )

        let proof = try viewModel.addProofFromAttachmentData(
            Data("png".utf8),
            projectId: project.id,
            sessionId: nil,
            type: .image,
            title: "before/after",
            statement: "证明能控制白平衡",
            originalFileName: "before-after.png",
            mimeType: "image/png"
        )

        let storedPath = try XCTUnwrap(proof.localPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedPath))
        XCTAssertEqual(proof.fileSize, 3)
        XCTAssertEqual(proof.mimeType, "image/png")
    }

    func testResolvingCloudConflictQueuesChosenEntityForSync() async throws {
        let original = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish lecture notes",
            currentNextStep: "Read lecture 1"
        )
        var local = original
        local.currentNextStep = "Write local notes"
        var cloud = original
        cloud.currentNextStep = "Review cloud notes"

        let conflict = SyncConflict(
            entity: .init(.project, original.id),
            basePayload: try JSONEncoder.journal.encode(JournalEntity.project(original)),
            localPayload: try JSONEncoder.journal.encode(JournalEntity.project(local)),
            serverPayload: try JSONEncoder.journal.encode(JournalEntity.project(cloud)),
            proposedPayload: try JSONEncoder.journal.encode(local),
            conflictingFields: ["currentNextStep"]
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [local]))
        try repository.applyRemote(
            JournalTransaction(origin: .remote),
            conflicts: [conflict]
        )
        let journalService = JournalService(repository: repository)
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository),
            practiceTimer: PracticeTimerRuntime(store: ViewModelPracticeTimerStateStore()),
            syncRepository: repository
        )

        await viewModel.refreshSyncSummary()
        try viewModel.resolveSyncConflict(id: conflict.id, using: conflict.serverPayload)

        XCTAssertTrue(viewModel.syncConflicts.isEmpty)
        XCTAssertEqual(viewModel.projects.first?.currentNextStep, "Review cloud notes")
        XCTAssertEqual(
            try repository.pendingMutations(limit: 10).map(\.entity),
            [.init(.project, original.id)]
        )
    }

    func testSavingPracticeCompletionRefreshesSnapshotAndReportsDroppedLink() throws {
        let repository = InMemoryJournalRepository()
        let journalService = JournalService(repository: repository)
        let practiceService = PracticeService(repository: repository)
        let runtime = PracticeTimerRuntime(store: ViewModelPracticeTimerStateStore())
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: practiceService,
            practiceTimer: runtime
        )
        let routine = try viewModel.createPracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let completion = PracticeTimerCompletion(
            routineId: routine.id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_800),
            activeDurationSeconds: 1_800
        )

        let result = try viewModel.savePracticeCompletion(
            completion,
            linkedProjectId: UUID(),
            note: "Scales"
        )

        XCTAssertEqual(viewModel.practiceSessions.map(\.id), [result.session.id])
        XCTAssertTrue(result.didDropMissingProjectLink)
        XCTAssertNil(result.session.linkedProjectId)
    }

    func testPracticeFacadeUsesInjectedRuntimeAndRefreshesRoutineMutations() throws {
        let repository = InMemoryJournalRepository()
        let journalService = JournalService(repository: repository)
        let runtime = PracticeTimerRuntime(store: ViewModelPracticeTimerStateStore())
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository),
            practiceTimer: runtime
        )
        let routine = try viewModel.createPracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )

        try viewModel.startPractice(routine)
        XCTAssertThrowsError(
            try viewModel.updatePracticeRoutine(
                routineId: routine.id,
                name: "Acoustic Guitar",
                symbolName: "music.note",
                color: .blue,
                targetMinutes: 45,
                weekdays: [2, 4]
            )
        )

        XCTAssertTrue(viewModel.practiceTimer === runtime)
        XCTAssertEqual(viewModel.practiceTimer.snapshot.activeRoutineId, routine.id)
        XCTAssertEqual(viewModel.practiceRoutines.first?.name, routine.name)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 10))
        )
        XCTAssertTrue(
            viewModel.practiceCards(now: monday, calendar: calendar).first?.isActiveTimer == true
        )

        viewModel.discardPractice()
        let updated = try viewModel.updatePracticeRoutine(
            routineId: routine.id,
            name: "Acoustic Guitar",
            symbolName: "music.note",
            color: .blue,
            targetMinutes: 45,
            weekdays: [2, 4]
        )
        XCTAssertEqual(viewModel.practiceRoutines.first?.name, updated.name)
        _ = try viewModel.archivePracticeRoutine(routine.id)
        XCTAssertTrue(viewModel.practiceRoutines[0].isArchived)
        try viewModel.deletePracticeRoutineIfUnused(routine.id)
        XCTAssertTrue(viewModel.practiceRoutines.isEmpty)
    }

    func testApplicationSessionKeepsPracticeRuntimeAcrossAccountRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = JournalApplicationSession(
            documentsDirectory: root,
            accountProvider: LocalOnlyAccountProvider()
        )
        let runtime = session.viewModel.practiceTimer

        await session.refreshAccount()

        XCTAssertTrue(session.viewModel.practiceTimer === runtime)
    }

    private func makeViewModel(
        attachmentRoot: URL? = nil,
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> JournalViewModel {
        let repository = InMemoryJournalRepository(now: now)
        let journalService = JournalService(repository: repository, now: now)
        let attachmentStore = attachmentRoot.map { AttachmentStore(rootDirectory: $0) }
        return JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            attachmentStore: attachmentStore ?? .defaultStore(),
            practiceService: PracticeService(repository: repository, now: now),
            practiceTimer: PracticeTimerRuntime(store: ViewModelPracticeTimerStateStore(), now: now)
        )
    }
}

@MainActor
private final class ViewModelPracticeTimerStateStore: PracticeTimerStateStore {
    private var data: Data?

    func load() -> Data? { data }

    func save(_ data: Data?) throws {
        self.data = data
    }
}

private actor LocalOnlyAccountProvider: CloudAccountProviding {
    func accountStatus() async throws -> CKAccountStatus { .noAccount }

    func currentUserRecordName() async throws -> String? { nil }
}

private actor StaticSyncStatusProvider: CloudSyncCoordinating {
    let fixedStatus: SyncStatus

    init(status: SyncStatus) {
        self.fixedStatus = status
    }

    var status: SyncStatus { fixedStatus }

    func start() async {}

    func syncNow() async throws {}
}

private struct StubCoursePlanningProvider: CoursePlanningProvider {
    func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft {
        CoursePlanDraft(
            title: "CS336 plan",
            summary: "Start with tokenization.",
            phases: [
                CoursePlanDraftPhase(
                    id: "foundations",
                    title: "Foundations",
                    objective: "Understand tokenization",
                    expectedProof: "Tokenizer notebook",
                    ordinal: 0,
                    targetStart: input.startsOn,
                    targetEnd: input.startsOn.addingTimeInterval(86_400)
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "tokenizer",
                    phaseID: "foundations",
                    title: "Implement a tokenizer",
                    actionType: .course,
                    expectedProof: "Tokenizer notebook",
                    durationMinutes: input.preferredSessionMinutes
                )
            ]
        )
    }
}
