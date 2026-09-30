import XCTest
@testable import PersonalLearningJournal

/// Deterministic end-to-end coverage for the vNext acceptance scenarios A–F
/// (spec section 17). Every test composes the REAL services —
/// `CoursePlanningService`, `CoursePlanDraftEditingService`,
/// `PendingStudyCaptureStore`, rule-based/adaptive providers,
/// `LearningRecordService`, `LearningAdjustmentService`,
/// `TodayAgendaService`, `VNextTodayProjector` — over
/// `InMemoryJournalRepository` and a temp-dir capture store. No network, no
/// simulator, no CloudKit: these tests are deterministic service-level
/// evidence, not device or sync acceptance.
@MainActor
final class VNextEndToEndTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Scenario A: new course

    /// A. 用户输入 CS336 → 合法草稿 → 编辑一个活动并重生成一个 Phase →
    /// 草稿未启用时 Today 不出现活动 → 启用后 Today 出现唯一 Up Next。
    func testScenarioANewCourseDraftHiddenFromTodayUntilActivatedThenExactlyOneUpNext() async throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let input = makePlanningInput(projectID: project.id)
        let provider = StubCoursePlanningProvider(
            draft: makeProviderDraft(),
            regeneration: makePhaseOneRegeneration()
        )
        let planning = CoursePlanningService(repository: repository, provider: provider, now: { self.t0 })

        // 2. The (fake) provider returns a legal draft; the service persists
        // it as a draft revision.
        let generated = try await planning.generateDraft(input: input, context: CoursePlanningContext())
        XCTAssertEqual(generated.status, .draft)

        // 4. A non-activated draft contributes nothing to Today.
        var agenda = TodayAgendaService().agenda(
            snapshot: try repository.snapshot(), day: t0, now: t0
        )
        XCTAssertFalse(agenda.items.contains { $0.source == .plannedSession })

        // 3a. The learner edits one activity on the editable draft value.
        var edited = CoursePlanDraftEditingService.editSession(
            provider.draft, sessionID: "s1"
        ) { $0.title = "Implement a byte-pair tokenizer (edited)" }
        XCTAssertEqual(edited.sessions.first { $0.id == "s1" }?.title,
                       "Implement a byte-pair tokenizer (edited)")

        // 3b. Regenerating phase 1 through the provider replaces only that
        // phase and its sessions; phase 2 and its sessions keep identity,
        // text, and order.
        let phaseOne = try XCTUnwrap(edited.phases.first { $0.id == "phase-1" })
        let regeneration = try await planning.regeneratePhase(
            input: input, context: CoursePlanningContext(), phase: phaseOne
        )
        edited = CoursePlanDraftEditingService.replacingPhase(
            edited, phaseID: "phase-1", with: regeneration,
            sessionIDGenerator: { "s1-regenerated" }
        )
        XCTAssertEqual(edited.phases.map(\.id), ["phase-1", "phase-2"])
        XCTAssertEqual(edited.phases[1], provider.draft.phases[1])
        XCTAssertEqual(
            edited.sessions.filter { $0.phaseID == "phase-2" },
            provider.draft.sessions.filter { $0.phaseID == "phase-2" }
        )
        XCTAssertEqual(edited.phases[0].title, "Foundations (regenerated)")
        XCTAssertEqual(edited.sessions.filter { $0.phaseID == "phase-1" }.map(\.id),
                       ["s1-regenerated"])

        // The edited draft is saved explicitly and stays a draft.
        let revisedDraft = try planning.saveDraft(input: input, draft: edited)
        XCTAssertEqual(revisedDraft.status, .draft)
        agenda = TodayAgendaService().agenda(
            snapshot: try repository.snapshot(), day: t0, now: t0
        )
        XCTAssertFalse(agenda.items.contains { $0.source == .plannedSession })

        // 5. Activation makes Today show exactly one Up Next, sourced from
        // the activated plan's planned sessions.
        _ = try planning.activate(draftPlanID: revisedDraft.id)

        let snapshot = try repository.snapshot()
        agenda = TodayAgendaService().agenda(snapshot: snapshot, day: t0, now: t0)
        let upNextItems = agenda.items.filter { $0.position == .upNext }
        XCTAssertEqual(upNextItems.count, 1)
        let upNext = try XCTUnwrap(upNextItems.first)
        XCTAssertEqual(upNext.source, .plannedSession)
        XCTAssertTrue(snapshot.plannedSessions.contains {
            $0.id == upNext.sourceID && $0.planId == revisedDraft.id
        })

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: snapshot
        )
        XCTAssertEqual(projection.upNext?.item.id, upNext.id)
        XCTAssertEqual(projection.upNext?.courseName, "CS336")
        XCTAssertEqual(projection.upNext?.primaryAction, .start)
    }

    // MARK: - Scenario B: complete a study

    /// B. 结束计时后 Journal 仍无新 Session → 检查没有预选答案 → 回答后得到
    /// record draft → 确认后 Session、assessment、planned completion 和
    /// Trail 一次性写入。
    func testScenarioBConfirmPublishesSessionAssessmentPlannedCompletionAndTrailInOneCommit() async throws {
        let project = makeProject()
        let planned = try makePlannedSession(
            projectID: project.id,
            title: "Watch Lecture 1: Tokenization",
            completionCriteria: ["Can define a token", "Ran the tokenizer demo"]
        )
        var commitCount = 0
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned]),
            commitHook: { _ in commitCount += 1 }
        )
        let root = try makeTempRoot()
        let captureStore = makeCaptureStore(root: root)
        let recordService = makeRecordService(
            repository: repository, captureStore: captureStore, root: root
        )

        // 1. Begin from Up Next and end the timer.
        let capture = try captureStore.begin(
            projectID: project.id, plannedSessionID: planned.id, source: .timer
        )
        try captureStore.noteElapsed(id: capture.id, activeDurationSeconds: 45 * 60)
        _ = try captureStore.end(id: capture.id)

        // 2. Ending the timer is not a journal fact.
        var snapshot = try repository.snapshot()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .scheduled)

        // 3. The rule-based completion check carries no preselected answers.
        let checkDraft = try await RuleBasedCompletionCheckProvider().makeCheckDraft(
            input: CompletionCheckInput(
                activityTitle: planned.title,
                completionCriteria: planned.completionCriteria,
                expectedProof: planned.expectedProof,
                phaseObjective: nil,
                prerequisitesSummary: nil
            )
        )
        XCTAssertEqual(checkDraft.source, .ruleBased)
        let checking = try captureStore.attachCheckDraft(id: capture.id, draft: checkDraft)
        XCTAssertNil(checking.answers.progress)
        XCTAssertTrue(checking.answers.completedCriterionIDs.isEmpty)
        XCTAssertNil(checking.answers.understanding)
        XCTAssertNil(checking.answers.blocker)

        // 4. Answering yields an editable record draft (still device-local).
        let criterionID = try XCTUnwrap(checkDraft.criteria.first?.id)
        _ = try captureStore.recordAnswers(
            id: capture.id,
            answers: CompletionCheckAnswers(
                progress: .mostlyCompleted,
                completedCriterionIDs: [criterionID],
                understanding: .mostlyUnderstood,
                blocker: "BPE merges unclear"
            )
        )
        let recordDraft = try await LearningRecordDraftGenerator(
            provider: RuleBasedLearningRecordDraftProvider()
        ).makeDraft(
            input: LearningRecordDraftInput(
                capture: try XCTUnwrap(captureStore.allCaptures().first),
                activityTitle: planned.title,
                currentNextStep: project.currentNextStep
            )
        )
        let ready = try captureStore.attachRecordDraft(id: capture.id, draft: recordDraft)
        XCTAssertEqual(ready.recordDraft?.source, .ruleBased)
        XCTAssertEqual(ready.stage, .awaitingRecordConfirmation)
        XCTAssertTrue(try repository.snapshot().sessions.isEmpty)

        // 5. Confirmation publishes everything in ONE commit and removes the
        // capture.
        let session = try recordService.confirm(capture: ready)

        XCTAssertEqual(commitCount, 1)
        snapshot = try repository.snapshot()
        let stored = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(stored.id, session.id)
        let assessment = try XCTUnwrap(stored.assessment)
        XCTAssertEqual(assessment.progress, .mostlyCompleted)
        XCTAssertEqual(assessment.completedCriterionIDs, [criterionID])
        XCTAssertEqual(assessment.understanding, .mostlyUnderstood)
        XCTAssertEqual(assessment.blocker, "BPE merges unclear")
        XCTAssertEqual(assessment.revision, 1)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .completed)
        XCTAssertEqual(snapshot.plannedSessions.first?.completedSessionId, session.id)
        XCTAssertEqual(snapshot.trailEvents.map(\.type), [.session])
        XCTAssertTrue(try captureStore.allCaptures().isEmpty)
    }

    // MARK: - Scenario C: save for later and recovery

    /// C. 稍后填写 → （模拟重启：同一目录上的全新 store 实例）→ Today 首卡
    /// 恢复该检查 → 确认前不影响计划进度。
    func testScenarioCSaveForLaterSurvivesStoreRecreationAndStaysOutOfJournalUntilConfirm() async throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id, title: "Read Lecture 2 notes")
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned])
        )
        let root = try makeTempRoot()
        let captureDirectory = root.appendingPathComponent("captures", isDirectory: true)
        let firstStore = PendingStudyCaptureStore(directory: captureDirectory, now: { self.t0 })

        // 1. End the study and choose "save for later".
        let capture = try firstStore.begin(
            projectID: project.id, plannedSessionID: planned.id, source: .timer
        )
        try firstStore.noteElapsed(id: capture.id, activeDurationSeconds: 20 * 60)
        _ = try firstStore.end(id: capture.id)
        _ = try firstStore.saveForLater(id: capture.id)

        // 2–3. A fresh store instance on the same directory (an app restart)
        // recovers the pending confirmation, and Today's first card surfaces
        // it above Up Next.
        let restartedStore = PendingStudyCaptureStore(directory: captureDirectory, now: { self.t0 })
        let recovered = try XCTUnwrap(restartedStore.pendingConfirmations().first)
        XCTAssertEqual(recovered.id, capture.id)
        XCTAssertEqual(recovered.stage, .savedForLater)

        let snapshot = try repository.snapshot()
        let projection = VNextTodayProjector.project(
            agenda: TodayAgendaService().agenda(snapshot: snapshot, day: t0, now: t0),
            pendingCaptures: try restartedStore.pendingConfirmations(),
            activeCapture: try restartedStore.activeCapture(),
            snapshot: snapshot
        )
        XCTAssertEqual(projection.recoveryCard?.capture.id, capture.id)
        XCTAssertEqual(projection.recoveryCard?.title, planned.title)

        // 4. Before confirmation nothing touched the journal.
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .scheduled)

        // Finishing after the restart confirms normally.
        let recordService = makeRecordService(
            repository: repository, captureStore: restartedStore, root: root
        )
        _ = try restartedStore.reopen(id: capture.id)
        _ = try restartedStore.recordAnswers(
            id: capture.id,
            answers: CompletionCheckAnswers(progress: .completed)
        )
        let recordDraft = try await LearningRecordDraftGenerator(
            provider: RuleBasedLearningRecordDraftProvider()
        ).makeDraft(
            input: LearningRecordDraftInput(
                capture: try XCTUnwrap(restartedStore.allCaptures().first),
                activityTitle: planned.title,
                currentNextStep: project.currentNextStep
            )
        )
        let ready = try restartedStore.attachRecordDraft(id: capture.id, draft: recordDraft)
        _ = try recordService.confirm(capture: ready)

        let after = try repository.snapshot()
        XCTAssertEqual(after.sessions.count, 1)
        XCTAssertEqual(after.plannedSessions.first?.status, .completed)
        XCTAssertTrue(try restartedStore.allCaptures().isEmpty)
    }

    // MARK: - Scenario D: later correction

    /// D. 修正 progress 和 summary → 最新记录 revision 2 → revision 1 可查看
    /// → 修正不静默重写旧 Plan Revision。
    func testScenarioDAmendBumpsRevisionKeepsSnapshotAndLeavesPlanUntouched() throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id, title: "Train the tokenizer")
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned])
        )
        let root = try makeTempRoot()
        let captureStore = makeCaptureStore(root: root)
        let recordService = makeRecordService(
            repository: repository, captureStore: captureStore, root: root
        )

        let capture = try captureStore.begin(
            projectID: project.id, plannedSessionID: planned.id, source: .timer
        )
        try captureStore.noteElapsed(id: capture.id, activeDurationSeconds: 30 * 60)
        _ = try captureStore.end(id: capture.id)
        _ = try captureStore.recordAnswers(
            id: capture.id,
            answers: CompletionCheckAnswers(progress: .partial, blocker: "Loss not decreasing")
        )
        let ready = try captureStore.attachRecordDraft(
            id: capture.id,
            draft: LearningRecordDraft(
                summary: "Trained the tokenizer for 30 minutes.",
                result: "",
                blockers: "Loss not decreasing",
                suggestedNextStep: nil,
                adjustmentSignal: .ordinary,
                source: .ruleBased
            )
        )
        let session = try recordService.confirm(capture: ready)
        let originalNote = session.note
        let plansBefore = try repository.snapshot().coursePlans
        let plannedBefore = try repository.snapshot().plannedSessions

        // Correct the summary and progress later.
        let amended = try recordService.amend(
            sessionID: session.id,
            note: "Trained the tokenizer; loss stalled at step 400.",
            progress: .mostlyCompleted,
            completedCriterionIDs: [],
            understanding: .needsReview,
            blocker: "Loss stalled at step 400"
        )

        // The latest record shows revision 2; revision 1 remains viewable as
        // an immutable snapshot.
        XCTAssertEqual(amended.assessment?.revision, 2)
        XCTAssertEqual(amended.assessment?.progress, .mostlyCompleted)
        let snapshot = try repository.snapshot()
        let revision = try XCTUnwrap(snapshot.learningRecordRevisions.first)
        XCTAssertEqual(snapshot.learningRecordRevisions.count, 1)
        XCTAssertEqual(revision.sessionID, session.id)
        XCTAssertEqual(revision.revision, 1)
        XCTAssertEqual(revision.previousNote, originalNote)
        XCTAssertEqual(revision.previousAssessment?.progress, .partial)

        // The correction never silently rewrites plan revisions or trail.
        XCTAssertEqual(snapshot.coursePlans, plansBefore)
        XCTAssertEqual(snapshot.plannedSessions, plannedBefore)
    }

    // MARK: - Scenario E: dynamic adjustments

    /// E. 重复 partial → pending nextStep 建议 → adopt 在同一 commit 改
    /// Next Step；结构建议 → v2 draft 期间 v1 保持 active → 启用 v2 后 v1
    /// archived 且仍可读取。
    func testScenarioEDetectAdoptNextStepAndStructuralRevisionLifecycle() throws {
        let project = makeProject()
        let plan = try LearningPlan(
            projectId: project.id, revision: 1, status: .active,
            courseURL: nil, courseTitle: "CS336 Plan", courseOutline: "",
            goal: project.goal, expectedOutcome: "Tokenizer notebook",
            startsOn: t0.addingTimeInterval(-7 * 86_400), deadline: nil,
            weeklyBudgetMinutes: 360, summary: "Summary",
            createdAt: t0, updatedAt: t0
        )
        let comfortablePhase = try PlanPhase(
            planId: plan.id, title: "Foundations", objective: "Objective",
            expectedProof: "Proof", ordinal: 0,
            targetStart: t0.addingTimeInterval(-7 * 86_400),
            targetEnd: t0.addingTimeInterval(30 * 86_400),
            createdAt: t0, updatedAt: t0
        )
        let closingPhase = try PlanPhase(
            planId: plan.id, title: "Applied", objective: "Objective",
            expectedProof: "Proof", progress: .active, ordinal: 1,
            targetStart: t0.addingTimeInterval(-7 * 86_400),
            targetEnd: t0.addingTimeInterval(86_400),
            createdAt: t0, updatedAt: t0
        )
        // Two consecutive confirmed records end `.partial` on the same
        // planned activity.
        var sessions: [LearningSession] = []
        var plannedSessions: [PlannedSession] = []
        for index in 0..<2 {
            let record = try LearningSession(
                projectId: project.id, source: .timer, actionType: .course,
                startedAt: t0, endedAt: t0.addingTimeInterval(1_800), durationMinutes: 30,
                note: "Attempt \(index)", nextStepBefore: "", nextStepAfter: "",
                createdAt: t0, updatedAt: t0,
                assessment: LearningRecordAssessment(
                    progress: .partial,
                    completedCriterionIDs: [],
                    understanding: nil,
                    blocker: nil,
                    aiDraftedSummary: false,
                    userEditedSummary: false,
                    confirmedAt: t0.addingTimeInterval(TimeInterval(index)),
                    revision: 1
                )
            )
            sessions.append(record)
            plannedSessions.append(try PlannedSession(
                planId: plan.id, phaseId: comfortablePhase.id, projectId: project.id,
                title: "Read Chapter 3", actionType: .reading, durationMinutes: 30,
                status: .completed, completedSessionId: record.id,
                createdAt: t0, updatedAt: t0
            ))
        }
        // The closing phase misses more than half of its sessions.
        plannedSessions.append(try PlannedSession(
            planId: plan.id, phaseId: closingPhase.id, projectId: project.id,
            title: "Done early", actionType: .reading, durationMinutes: 30,
            status: .completed, createdAt: t0, updatedAt: t0
        ))
        for index in 0..<3 {
            plannedSessions.append(try PlannedSession(
                planId: plan.id, phaseId: closingPhase.id, projectId: project.id,
                title: "Pending \(index)", actionType: .reading, durationMinutes: 30,
                status: .unscheduled, createdAt: t0, updatedAt: t0
            ))
        }
        var commitCount = 0
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project],
                sessions: sessions,
                coursePlans: [plan],
                planPhases: [comfortablePhase, closingPhase],
                plannedSessions: plannedSessions
            ),
            commitHook: { _ in commitCount += 1 }
        )
        let planning = CoursePlanningService(repository: repository, now: { self.t0 })
        let adjustments = LearningAdjustmentService(
            repository: repository, planningService: planning, now: { self.t0 }
        )

        // Detection sees only confirmed records and produces both signals.
        let detected = try adjustments.detectSuggestions(projectID: project.id)
        let nextStepSuggestion = try XCTUnwrap(detected.first { $0.kind == .nextStep })
        let structuralSuggestion = try XCTUnwrap(detected.first { $0.kind == .structuralRevision })
        XCTAssertEqual(nextStepSuggestion.decision, .pending)
        XCTAssertEqual(structuralSuggestion.decision, .pending)

        // Adopting the ordinary suggestion changes the Next Step and decides
        // the suggestion in ONE commit.
        let commitsBeforeAdopt = commitCount
        try adjustments.adopt(
            suggestionID: nextStepSuggestion.id,
            command: .nextStep(value: nextStepSuggestion.proposedValue)
        )
        XCTAssertEqual(commitCount - commitsBeforeAdopt, 1)
        var snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.projects.first?.currentNextStep,
                       nextStepSuggestion.proposedValue)
        XCTAssertEqual(
            snapshot.learningAdjustmentSuggestions.first { $0.id == nextStepSuggestion.id }?.decision,
            .adopted
        )

        // The structural suggestion prepares a v2 draft; v1 stays active and
        // the suggestion stays pending until activation.
        let revisionDraft = try adjustments.prepareStructuralDraft(suggestionID: structuralSuggestion.id)
        XCTAssertEqual(revisionDraft.plan.status, .draft)
        XCTAssertEqual(revisionDraft.plan.revision, 2)
        snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.coursePlans.first { $0.id == plan.id }?.status, .active)
        let storedStructural = try XCTUnwrap(
            snapshot.learningAdjustmentSuggestions.first { $0.id == structuralSuggestion.id }
        )
        XCTAssertEqual(storedStructural.decision, .pending)
        XCTAssertEqual(storedStructural.planRevisionDraftID, revisionDraft.plan.id)

        // Activating v2 through the normal activation path archives v1, which
        // remains readable in the snapshot.
        _ = try planning.activate(
            draftPlanID: revisionDraft.plan.id,
            expectation: revisionDraft.guardExpectation
        )
        try adjustments.markAdoptedAfterActivation(suggestionID: structuralSuggestion.id)

        snapshot = try repository.snapshot()
        let archivedV1 = try XCTUnwrap(snapshot.coursePlans.first { $0.id == plan.id })
        XCTAssertEqual(archivedV1.status, .archived)
        XCTAssertEqual(archivedV1.courseTitle, "CS336 Plan")
        XCTAssertEqual(snapshot.coursePlans.first { $0.id == revisionDraft.plan.id }?.status, .active)
        XCTAssertFalse(snapshot.planPhases.filter { $0.planId == plan.id }.isEmpty)
        XCTAssertEqual(
            snapshot.learningAdjustmentSuggestions.first { $0.id == structuralSuggestion.id }?.decision,
            .adopted
        )
    }

    // MARK: - Scenario F: degradation

    /// F. 无 AI 配置时：rule-based fallback 仍走完整闭环（check + record
    /// draft + confirm）；手动创建计划可启用并出现在 Today。
    func testScenarioFUnconfiguredAIStillCompletesLoopAndManualPlanAppearsInToday() async throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id, title: "Skim Lecture 3")
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], plannedSessions: [planned])
        )
        let root = try makeTempRoot()
        let captureStore = makeCaptureStore(root: root)
        let recordService = makeRecordService(
            repository: repository, captureStore: captureStore, root: root
        )

        // Adaptive providers without any AI configuration fall back to the
        // deterministic rule-based drafts and never throw.
        let unconfiguredSettings = AIReviewSettingsStore(
            userDefaults: UserDefaults(suiteName: "VNextEndToEndTests.\(UUID().uuidString)")!,
            keyStore: VNextTestAPIKeyStore()
        )
        let capture = try captureStore.begin(
            projectID: project.id, plannedSessionID: planned.id, source: .timer
        )
        try captureStore.noteElapsed(id: capture.id, activeDurationSeconds: 15 * 60)
        _ = try captureStore.end(id: capture.id)

        let checkDraft = try await AdaptiveCompletionCheckProvider(
            settingsStore: unconfiguredSettings
        ).makeCheckDraft(
            input: CompletionCheckInput(
                activityTitle: planned.title,
                completionCriteria: planned.completionCriteria,
                expectedProof: planned.expectedProof,
                phaseObjective: nil,
                prerequisitesSummary: nil
            )
        )
        XCTAssertEqual(checkDraft.source, .ruleBased)
        _ = try captureStore.attachCheckDraft(id: capture.id, draft: checkDraft)
        _ = try captureStore.recordAnswers(
            id: capture.id,
            answers: CompletionCheckAnswers(progress: .completed)
        )
        let recordDraft = try await LearningRecordDraftGenerator(
            provider: AdaptiveLearningRecordDraftProvider(settingsStore: unconfiguredSettings)
        ).makeDraft(
            input: LearningRecordDraftInput(
                capture: try XCTUnwrap(captureStore.allCaptures().first),
                activityTitle: planned.title,
                currentNextStep: project.currentNextStep
            )
        )
        let ready = try captureStore.attachRecordDraft(id: capture.id, draft: recordDraft)
        XCTAssertEqual(ready.recordDraft?.source, .ruleBased)

        // The full loop still confirms offline and without AI.
        let session = try recordService.confirm(capture: ready)
        let confirmed = try XCTUnwrap(try repository.snapshot().sessions.first)
        XCTAssertEqual(confirmed.id, session.id)
        XCTAssertNotNil(confirmed.assessment)
        XCTAssertEqual(try repository.snapshot().plannedSessions.first?.status, .completed)

        // A fully manual plan draft — built with the editing service from
        // scratch, no provider involved — activates and appears in Today.
        let manualProject = Project(
            name: "Linear Algebra", area: "Math",
            goal: "Refresh eigen-decomposition", currentNextStep: "Open notes",
            activeEvidenceContractId: UUID()
        )
        let manualRepository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [manualProject])
        )
        let manualPlanning = CoursePlanningService(
            repository: manualRepository, now: { self.t0 }
        )
        let manualInput = CoursePlanningInput(
            projectId: manualProject.id,
            courseTitle: "Linear Algebra",
            courseOutline: "",
            goal: manualProject.goal,
            expectedOutcome: "Notes",
            startsOn: t0,
            deadline: t0.addingTimeInterval(14 * 86_400),
            weeklyBudgetMinutes: 120,
            preferredSessionMinutes: 30
        )
        var manualDraft = CoursePlanDraft(
            title: "Linear Algebra refresher", summary: "", phases: [], sessions: []
        )
        manualDraft = CoursePlanDraftEditingService.addPhase(
            manualDraft,
            phase: CoursePlanDraftPhase(
                id: "manual-phase", title: "Review", objective: "Revisit eigen basics",
                expectedProof: "Summary notes", ordinal: 0,
                targetStart: t0, targetEnd: t0.addingTimeInterval(14 * 86_400)
            )
        )
        manualDraft = CoursePlanDraftEditingService.addSession(
            manualDraft,
            session: CoursePlanDraftSession(
                id: "manual-session", phaseID: "manual-phase",
                title: "Rework eigen exercises", actionType: .practice,
                durationMinutes: 30
            )
        )
        let savedManual = try manualPlanning.saveDraft(input: manualInput, draft: manualDraft)
        _ = try manualPlanning.activate(draftPlanID: savedManual.id)

        let manualAgenda = TodayAgendaService().agenda(
            snapshot: try manualRepository.snapshot(), day: t0, now: t0
        )
        let upNext = manualAgenda.items.filter { $0.position == .upNext }
        XCTAssertEqual(upNext.count, 1)
        XCTAssertEqual(upNext.first?.source, .plannedSession)
        XCTAssertEqual(upNext.first?.title, "Rework eigen exercises")
    }

    // MARK: - Legacy lossless read

    /// 旧 Journal fixture：无 assessment 的 Session 和无 vNext 字段的
    /// Plan/Phase/PlannedSession 无损读取，且不伪造 assessment。
    func testLegacySnapshotDecodesLosslesslyWithoutFabricatedAssessments() throws {
        let projectID = UUID()
        let planID = UUID()
        let phaseID = UUID()
        let sessionDate = Date(timeIntervalSince1970: 1_600_000_000)
        let legacySnapshot = JournalSnapshot(
            projects: [Project(
                id: projectID,
                name: "CS336", area: "AI", goal: "Finish", currentNextStep: "Lecture 1",
                createdAt: sessionDate, updatedAt: sessionDate
            )],
            sessions: [try LearningSession(
                projectId: projectID,
                source: .quickLog, actionType: .course,
                startedAt: sessionDate, endedAt: sessionDate.addingTimeInterval(1_800),
                durationMinutes: 30, note: "Read chapter one",
                nextStepBefore: "Start", nextStepAfter: "Continue",
                createdAt: sessionDate, updatedAt: sessionDate
            )],
            coursePlans: [try LearningPlan(
                id: planID, projectId: projectID,
                revision: 1, status: .active, courseURL: nil,
                courseTitle: "Legacy Plan", courseOutline: "", goal: "Finish",
                expectedOutcome: "", startsOn: sessionDate, deadline: nil,
                weeklyBudgetMinutes: 120, summary: "",
                createdAt: sessionDate, updatedAt: sessionDate
            )],
            planPhases: [try PlanPhase(
                id: phaseID, planId: planID, title: "Legacy Phase",
                objective: "Objective", expectedProof: "Proof", ordinal: 0,
                targetStart: sessionDate,
                targetEnd: sessionDate.addingTimeInterval(7 * 86_400),
                createdAt: sessionDate, updatedAt: sessionDate
            )],
            plannedSessions: [try PlannedSession(
                planId: planID, phaseId: phaseID, projectId: projectID,
                title: "Legacy activity", actionType: .reading, durationMinutes: 30,
                status: .unscheduled, createdAt: sessionDate, updatedAt: sessionDate
            )],
            hasCompletedOnboarding: true
        )

        // Shape the payload like a pre-vNext file: strip every key that did
        // not exist before, including the whole vNext collections.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder.journal.encode(legacySnapshot)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "learningRecordRevisions")
        object.removeValue(forKey: "learningAdjustmentSuggestions")
        var sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        for index in sessions.indices {
            sessions[index].removeValue(forKey: "assessment")
        }
        object["sessions"] = sessions
        var plans = try XCTUnwrap(object["coursePlans"] as? [[String: Any]])
        for index in plans.indices {
            for key in ["planSeriesID", "revisionID", "baseRevisionID", "supersedesID",
                        "activatedAt", "schemaVersion"] {
                plans[index].removeValue(forKey: key)
            }
        }
        object["coursePlans"] = plans
        var phases = try XCTUnwrap(object["planPhases"] as? [[String: Any]])
        for index in phases.indices {
            for key in ["planRevisionID", "planSeriesID", "isStructuralLocked",
                        "progress", "schemaVersion"] {
                phases[index].removeValue(forKey: key)
            }
        }
        object["planPhases"] = phases
        var planned = try XCTUnwrap(object["plannedSessions"] as? [[String: Any]])
        for index in planned.indices {
            for key in ["planRevisionID", "planSeriesID", "isStructuralLocked",
                        "planningWindow", "completionCriteria", "recommendationReason",
                        "schemaVersion"] {
                planned[index].removeValue(forKey: key)
            }
        }
        object["plannedSessions"] = planned
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.journal.decode(JournalSnapshot.self, from: legacyData)

        // Values survive; nothing is fabricated.
        let decodedSession = try XCTUnwrap(decoded.sessions.first)
        XCTAssertEqual(decodedSession.note, "Read chapter one")
        XCTAssertEqual(decodedSession.durationMinutes, 30)
        XCTAssertNil(decodedSession.assessment)
        XCTAssertTrue(decoded.learningRecordRevisions.isEmpty)
        XCTAssertTrue(decoded.learningAdjustmentSuggestions.isEmpty)
        let decodedPlan = try XCTUnwrap(decoded.coursePlans.first)
        XCTAssertEqual(decodedPlan.courseTitle, "Legacy Plan")
        XCTAssertEqual(decodedPlan.revision, 1)
        XCTAssertEqual(decodedPlan.planSeriesID, planID)
        XCTAssertEqual(decodedPlan.revisionID, planID)
        XCTAssertEqual(decoded.planPhases.first?.title, "Legacy Phase")
        let decodedPlanned = try XCTUnwrap(decoded.plannedSessions.first)
        XCTAssertEqual(decodedPlanned.title, "Legacy activity")
        XCTAssertTrue(decodedPlanned.completionCriteria.isEmpty)
        XCTAssertNil(decodedPlanned.recommendationReason)

        // Re-encoding and re-decoding is stable (no data loss through the
        // current schema), and the legacy session still has no assessment.
        let roundTripped = try JSONDecoder.journal.decode(
            JournalSnapshot.self,
            from: JSONEncoder.journal.encode(decoded)
        )
        XCTAssertNil(roundTripped.sessions.first?.assessment)
        XCTAssertEqual(roundTripped.sessions.first?.note, "Read chapter one")
        XCTAssertEqual(roundTripped.coursePlans.first?.courseTitle, "Legacy Plan")
    }

    // MARK: - Fixtures

    private func makeProject() -> Project {
        Project(
            name: "CS336",
            area: "AI",
            goal: "Build a GPT tokenizer from scratch",
            currentNextStep: "Watch Lecture 1",
            createdAt: t0,
            updatedAt: t0,
            activeEvidenceContractId: UUID()
        )
    }

    private func makePlanningInput(projectID: UUID) -> CoursePlanningInput {
        CoursePlanningInput(
            projectId: projectID,
            courseTitle: "CS336",
            courseOutline: "Lecture 1: tokenization. Lecture 2: language modeling.",
            goal: "Build a GPT tokenizer from scratch",
            expectedOutcome: "Tokenizer notebook",
            startsOn: t0,
            deadline: t0.addingTimeInterval(8 * 7 * 86_400),
            weeklyBudgetMinutes: 360,
            preferredSessionMinutes: 60,
            prerequisites: "Python basics"
        )
    }

    /// The deterministic draft a (fake) provider returns for CS336: two
    /// phases, two activities each.
    private func makeProviderDraft() -> CoursePlanDraft {
        CoursePlanDraft(
            title: "CS336 Plan",
            summary: "Tokenizer first, then language modeling",
            phases: [
                CoursePlanDraftPhase(
                    id: "phase-1", title: "Foundations",
                    objective: "Understand tokenization",
                    expectedProof: "Tokenizer notebook", ordinal: 0,
                    targetStart: t0,
                    targetEnd: t0.addingTimeInterval(4 * 7 * 86_400)
                ),
                CoursePlanDraftPhase(
                    id: "phase-2", title: "Language Modeling",
                    objective: "Train a small LM",
                    expectedProof: "Training log", ordinal: 1,
                    targetStart: t0.addingTimeInterval(4 * 7 * 86_400),
                    targetEnd: t0.addingTimeInterval(8 * 7 * 86_400)
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "s1", phaseID: "phase-1",
                    title: "Implement a byte-pair tokenizer", actionType: .practice,
                    durationMinutes: 60,
                    completionCriteria: ["Can define a token", "Runs on sample text"]
                ),
                CoursePlanDraftSession(
                    id: "s2", phaseID: "phase-1",
                    title: "Watch Lecture 1", actionType: .course,
                    durationMinutes: 60
                ),
                CoursePlanDraftSession(
                    id: "s3", phaseID: "phase-2",
                    title: "Watch Lecture 2", actionType: .course,
                    durationMinutes: 60
                ),
                CoursePlanDraftSession(
                    id: "s4", phaseID: "phase-2",
                    title: "Train a bigram baseline", actionType: .practice,
                    durationMinutes: 60
                )
            ]
        )
    }

    private func makePhaseOneRegeneration() -> CoursePlanPhaseRegeneration {
        CoursePlanPhaseRegeneration(
            phase: CoursePlanDraftPhase(
                id: "phase-1", title: "Foundations (regenerated)",
                objective: "Understand tokenization deeply",
                expectedProof: "Tokenizer notebook", ordinal: 0,
                targetStart: t0,
                targetEnd: t0.addingTimeInterval(4 * 7 * 86_400)
            ),
            sessions: [
                CoursePlanDraftSession(
                    id: "ignored-by-splice", phaseID: "phase-1",
                    title: "Implement a byte-pair tokenizer v2", actionType: .practice,
                    durationMinutes: 60,
                    completionCriteria: ["Runs on sample text"]
                )
            ]
        )
    }

    private func makePlannedSession(
        projectID: UUID,
        title: String,
        completionCriteria: [String] = []
    ) throws -> PlannedSession {
        try PlannedSession(
            planId: UUID(),
            phaseId: UUID(),
            projectId: projectID,
            title: title,
            actionType: .course,
            durationMinutes: 45,
            completionCriteria: completionCriteria,
            status: .scheduled,
            createdAt: t0,
            updatedAt: t0
        )
    }

    private func makeCaptureStore(root: URL) -> PendingStudyCaptureStore {
        PendingStudyCaptureStore(
            directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true),
            now: { self.t0 }
        )
    }

    private func makeRecordService(
        repository: InMemoryJournalRepository,
        captureStore: PendingStudyCaptureStore,
        root: URL
    ) -> LearningRecordService {
        LearningRecordService(
            repository: repository,
            captureStore: captureStore,
            attachmentStore: AttachmentStore(rootDirectory: root),
            now: { self.t0 }
        )
    }
}

/// Deterministic provider double: returns a fixed draft and a fixed
/// single-phase regeneration. No network, no configuration.
private struct StubCoursePlanningProvider: CoursePlanningProvider {
    var draft: CoursePlanDraft
    var regeneration: CoursePlanPhaseRegeneration

    func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft {
        draft
    }

    func regeneratePhase(
        input: CoursePlanningInput,
        context: CoursePlanningContext,
        phase: CoursePlanDraftPhase
    ) async throws -> CoursePlanPhaseRegeneration {
        regeneration
    }
}

private final class VNextTestAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? {
        values[key]
    }

    func setValue(_ value: String?, for key: String) throws {
        values[key] = value
    }
}
