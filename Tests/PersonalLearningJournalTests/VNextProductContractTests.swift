import Foundation
import XCTest
@testable import PersonalLearningJournal

/// Non-regressible vNext product contract. These tests pin the navigation
/// shape and the Today first-screen count limits before RootView migrates;
/// they are guard rails, not feature specs.
final class VNextProductContractTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func testVNextPrimaryTabsExposeExecutionProjectsTrailAndCoach() {
        XCTAssertEqual(StudioExperienceContract.vNextPrimaryTabs, [.today, .courses, .trail, .coach])
    }

    func testProjectDetailHasProductionAdjustmentRequestEntryPoint() throws {
        let source = try sourceFile("Sources/PersonalLearningJournal/Views/ProjectsView.swift")

        XCTAssertTrue(source.contains("Task { await requestAdjustmentSuggestions() }"))
        XCTAssertTrue(source.contains("viewModel.requestAdjustmentSuggestions("))
        XCTAssertTrue(source.contains("userRequest: String(localized: \"adjustment.request.default\")"))
        XCTAssertTrue(source.contains("isRequestingAdjustments"))
    }

    func testVNextTodayHasSimpleProjectTimerPracticeEntryPoint() throws {
        let source = try sourceFile("Sources/PersonalLearningJournal/Views/VNextTodayView.swift")
        let root = try sourceFile("Sources/PersonalLearningJournal/Views/RootView.swift")

        XCTAssertTrue(root.contains("VNextTodayView(viewModel: viewModel)"))
        XCTAssertFalse(source.contains("showingPracticeSetup"))
        XCTAssertFalse(source.contains("SimplePracticeSetupView("))
        XCTAssertTrue(source.contains("inlinePracticeLauncher"))
        XCTAssertTrue(source.contains("projectStrip"))
        XCTAssertTrue(source.contains("startInlinePractice"))
        XCTAssertTrue(source.contains("PracticeTimerMode.allCases"))
        XCTAssertTrue(source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertTrue(source.contains(".scrollTargetBehavior(.viewAligned)"))
        XCTAssertTrue(source.contains("in: 1...180"))
        XCTAssertTrue(source.contains("step: 1"))
        XCTAssertTrue(source.contains("viewModel.startSimplePractice("))
        XCTAssertFalse(source.contains("countdownPresets"))
        XCTAssertFalse(source.contains("PracticeRoutineEditorView(viewModel: viewModel, routine: nil)"))
        XCTAssertTrue(source.contains("startPracticeFromAgenda"))
        XCTAssertTrue(source.contains("onStartPractice"))
        XCTAssertTrue(source.contains("recoveryArea"))
        XCTAssertTrue(source.contains("compactPracticeRecoveryRow"))
        XCTAssertTrue(source.contains("openPracticeRoutine(card.routineID, zoomSourceID:"))
        XCTAssertTrue(source.contains("skillPracticeShelf"))
        XCTAssertTrue(source.contains("quickFinishPractice"))
        XCTAssertTrue(source.contains("scheduledOnly: false"))
        XCTAssertTrue(source.contains("practiceProjectName(for: card.routine)"))
        XCTAssertTrue(source.contains("projectName: projectName"))
    }

    func testFirstScreenShowsExactlyOneUpNext() {
        let upNext = makeItem(title: "Attention lecture", position: .upNext)
        let screen = StudioExperienceContract.firstScreen(agenda: [
            upNext,
            makeItem(title: "Reading", position: .laterToday),
            makeItem(title: "Guitar", position: .optional),
        ])

        XCTAssertEqual(screen.upNext, upNext)
        XCTAssertFalse(screen.alternatives.contains(upNext))
    }

    func testFirstScreenShowsAtMostTwoAlternatives() {
        let screen = StudioExperienceContract.firstScreen(agenda: [
            makeItem(title: "Up Next", position: .upNext),
            makeItem(title: "One", position: .laterToday),
            makeItem(title: "Two", position: .laterToday),
            makeItem(title: "Three", position: .optional),
            makeItem(title: "Four", position: .optional),
        ])

        XCTAssertEqual(screen.alternatives.count, 2)
        XCTAssertEqual(screen.alternatives.map(\.title), ["One", "Two"])
    }

    func testFirstScreenNeverShowsSkippedItems() {
        let skipped = makeItem(title: "Skipped", position: .skipToday)
        let screen = StudioExperienceContract.firstScreen(agenda: [
            makeItem(title: "Up Next", position: .upNext),
            skipped,
            makeItem(title: "Alternative", position: .optional),
        ])

        XCTAssertNotEqual(screen.upNext, skipped)
        XCTAssertFalse(screen.alternatives.contains(skipped))
    }

    func testDraftPlanSessionsDoNotEnterToday() throws {
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10))
        )
        let agenda = makeAgenda(planStatus: .draft, day: day)

        XCTAssertFalse(agenda.items.contains { $0.source == .plannedSession })
        XCTAssertFalse(agenda.items.contains { $0.title == "Unreachable draft session" })
    }

    func testActivePlanSessionsDoEnterToday() throws {
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10))
        )
        let agenda = makeAgenda(planStatus: .active, day: day)

        XCTAssertEqual(
            agenda.items.filter { $0.source == .plannedSession }.map(\.title),
            ["Active plan session"]
        )
    }

    func testEndingStudyNeverImplicitlyConfirmsARecord() {
        // Guard rail: "end study" only stops capture; a LearningSession is
        // confirmed exclusively through an explicit quick log or a reviewed
        // timer record. Any future capture source that would auto-confirm on
        // stop must break this contract.
        XCTAssertEqual(SessionSource.allCases, [.quickLog, .timer])
    }

    // MARK: - VNextTodayProjector (Task 11)

    func testProjectionShowsExactlyOneUpNextAndAtMostTwoAlternatives() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot
        )

        XCTAssertEqual(projection.upNext?.item.sourceID, fixture.session.id)
        XCTAssertEqual(projection.alternatives.count, 2)
        XCTAssertFalse(projection.alternatives.contains { $0.position == .skipToday })
        XCTAssertFalse(projection.alternatives.contains { $0.id == projection.upNext?.item.id })
    }

    func testProjectionKeepsFullAgendaForViewAll() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let skipped = fixture.snapshot.projects[1]
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day,
            overrides: [
                TodayAgendaOverride(
                    day: day,
                    source: .nextStep,
                    sourceID: skipped.id,
                    position: .skipToday
                ),
            ]
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot
        )

        // The first screen projects only the top three; the full agenda —
        // including the skipped item — stays available for "view all /
        // adjust today" so the choice can be restored.
        XCTAssertEqual(projection.fullAgenda, agenda.items)
        XCTAssertTrue(projection.fullAgenda.contains { $0.position == .skipToday })
        XCTAssertEqual(
            projection.fullAgenda.count,
            (projection.upNext == nil ? 0 : 1) + projection.alternatives.count + 1
        )
    }

    func testProjectionPendingCaptureTakesPriorityOverNewActivity() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )
        let capture = makeCapture(
            projectID: fixture.project.id,
            plannedSessionID: fixture.session.id,
            stage: .recovered,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: capture,
            snapshot: fixture.snapshot
        )

        XCTAssertEqual(projection.recoveryCard?.capture, capture)
        XCTAssertEqual(projection.recoveryCard?.title, fixture.session.title)
        // A capture holding the timer slot must not allow a second active
        // capture: the Up Next primary action surfaces Continue instead.
        XCTAssertEqual(projection.upNext?.primaryAction, .resumeCapture(capture.id))
    }

    func testProjectionPendingConfirmationShowsRecoveryCardButStartStaysAvailable() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )
        let capture = makeCapture(
            projectID: fixture.project.id,
            plannedSessionID: fixture.session.id,
            stage: .savedForLater,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [capture],
            activeCapture: nil,
            snapshot: fixture.snapshot
        )

        XCTAssertEqual(projection.recoveryCard?.capture, capture)
        // Saved-for-later confirmations do not occupy the timer slot, so a
        // new activity may still start.
        XCTAssertEqual(projection.upNext?.primaryAction, .start)
    }

    func testProjectionWithoutPendingCaptureStartsNewActivity() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot
        )

        XCTAssertNil(projection.recoveryCard)
        XCTAssertEqual(projection.upNext?.primaryAction, .start)
    }

    func testPracticeAlternativeCanStartDirectlyWithoutMakingItUpNext() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )
        let practiceItem = try XCTUnwrap(agenda.items.first { $0.source == .practiceRoutine })
        let routine = try XCTUnwrap(fixture.snapshot.practiceRoutines.first { $0.id == practiceItem.sourceID })

        XCTAssertEqual(
            VNextTodayProjector.practicePrimaryAction(
                routineID: routine.id,
                activeRoutineID: nil,
                pendingCompletionRoutineID: nil
            ),
            .startPractice(routine.id)
        )
        XCTAssertNotEqual(practiceItem.position, .upNext)
    }

    func testActivePracticeTimerProjectsRecoveryAndResumeWithoutSecondStart() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let routine = try XCTUnwrap(fixture.snapshot.practiceRoutines.first)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day,
            overrides: [
                TodayAgendaOverride(
                    day: day,
                    source: .practiceRoutine,
                    sourceID: routine.id,
                    position: .upNext
                ),
            ]
        )

        let timerSnapshot = PracticeTimerSnapshot(
            activeRoutineId: routine.id,
            startedAt: day.addingTimeInterval(-120),
            activeElapsedSeconds: 120,
            isRunning: true,
            targetSeconds: routine.targetMinutes * 60
        )
        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot,
            practiceSnapshot: timerSnapshot
        )

        XCTAssertEqual(projection.practiceRecoveryCard?.routineID, routine.id)
        XCTAssertEqual(projection.practiceRecoveryCard?.kind, .activeTimer)
        XCTAssertEqual(projection.upNext?.primaryAction, .resumePractice(routine.id))
    }

    func testGuidedCaptureDoesNotTurnPracticeUpNextIntoAStudyFlowAction() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let routine = try XCTUnwrap(fixture.snapshot.practiceRoutines.first)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day,
            overrides: [
                TodayAgendaOverride(
                    day: day,
                    source: .practiceRoutine,
                    sourceID: routine.id,
                    position: .upNext
                ),
            ]
        )
        let capture = makeCapture(
            projectID: fixture.project.id,
            plannedSessionID: fixture.session.id,
            stage: .recovered,
            now: day
        )
        let timerSnapshot = PracticeTimerSnapshot(
            activeRoutineId: routine.id,
            startedAt: day.addingTimeInterval(-120),
            activeElapsedSeconds: 120,
            isRunning: true,
            targetSeconds: routine.targetMinutes * 60
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: capture,
            snapshot: fixture.snapshot,
            practiceSnapshot: timerSnapshot
        )

        XCTAssertEqual(projection.recoveryCard?.capture, capture)
        XCTAssertEqual(projection.practiceRecoveryCard?.routineID, routine.id)
        XCTAssertEqual(projection.practiceRecoveryCard?.kind, .activeTimer)
        XCTAssertEqual(projection.upNext?.primaryAction, .resumePractice(routine.id))
    }

    func testGuidedCaptureAndPendingPracticeCompletionBothRemainRecoverable() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let routine = try XCTUnwrap(fixture.snapshot.practiceRoutines.first)
        let capture = makeCapture(
            projectID: fixture.project.id,
            plannedSessionID: fixture.session.id,
            stage: .recovered,
            now: day
        )
        let completion = PracticeTimerCompletion(
            routineId: routine.id,
            startedAt: day.addingTimeInterval(-300),
            endedAt: day,
            activeDurationSeconds: 300,
            blocks: routine.orderedBlocks
        )
        let pending = PracticePendingCompletionDraft(
            completion: completion,
            routinePresentation: PracticeRoutinePresentationSnapshot(routine: routine)
        )
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: capture,
            snapshot: fixture.snapshot,
            practiceSnapshot: .inactive,
            pendingPracticeCompletion: pending
        )

        XCTAssertEqual(projection.recoveryCard?.capture, capture)
        XCTAssertEqual(projection.practiceRecoveryCard?.routineID, routine.id)
        XCTAssertEqual(projection.practiceRecoveryCard?.kind, .pendingCompletion)
    }

    func testPendingPracticeCompletionProjectsRecoveryAndDisappearsAfterClear() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let routine = try XCTUnwrap(fixture.snapshot.practiceRoutines.first)
        let completion = PracticeTimerCompletion(
            routineId: routine.id,
            startedAt: day.addingTimeInterval(-300),
            endedAt: day,
            activeDurationSeconds: 300,
            blocks: routine.orderedBlocks
        )
        let pending = PracticePendingCompletionDraft(
            completion: completion,
            routinePresentation: PracticeRoutinePresentationSnapshot(routine: routine)
        )
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day,
            overrides: [
                TodayAgendaOverride(
                    day: day,
                    source: .practiceRoutine,
                    sourceID: routine.id,
                    position: .upNext
                ),
            ]
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot,
            practiceSnapshot: .inactive,
            pendingPracticeCompletion: pending
        )
        XCTAssertEqual(projection.practiceRecoveryCard?.routineID, routine.id)
        XCTAssertEqual(projection.practiceRecoveryCard?.kind, .pendingCompletion)
        XCTAssertEqual(projection.upNext?.primaryAction, .resumePracticeCompletion(routine.id))

        let cleared = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot,
            practiceSnapshot: .inactive,
            pendingPracticeCompletion: nil
        )
        XCTAssertNil(cleared.practiceRecoveryCard)
    }

    func testNoActiveOrPendingPracticeTimerAddsNoRecoveryNoise() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot,
            practiceSnapshot: .inactive,
            pendingPracticeCompletion: nil
        )

        XCTAssertNil(projection.practiceRecoveryCard)
    }

    func testProjectionUpNextCardResolvesCoursePhaseReasonAndCriteria() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot
        )

        let card = try XCTUnwrap(projection.upNext)
        XCTAssertEqual(card.courseName, fixture.project.name)
        XCTAssertEqual(card.phaseName, fixture.phase.title)
        XCTAssertEqual(card.recommendationReason, "Shortest path to the phase proof")
        XCTAssertEqual(card.criteriaSummary, "Summarize the lecture · Note one open question")
        XCTAssertEqual(card.plannedSession, fixture.session)
    }

    func testProjectionUpNextCardFallsBackToAgendaDetail() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(
            day: day,
            recommendationReason: nil,
            completionCriteria: []
        )
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot
        )

        let card = try XCTUnwrap(projection.upNext)
        XCTAssertNil(card.recommendationReason)
        XCTAssertNil(card.criteriaSummary)
        XCTAssertFalse(card.item.detail.isEmpty)
        XCTAssertEqual(card.courseName, fixture.project.name)
    }

    func testProjectionMapsCarryoverReviewSyncAndCapacityToBanners() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(
            day: day,
            sessionDeadline: day.addingTimeInterval(-86_400)
        )
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )
        XCTAssertEqual(agenda.items.filter { $0.carryover != nil }.count, 1)

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot,
            pendingReviewCount: 2,
            hasSyncIssue: true,
            capacityExceededCount: 1
        )

        XCTAssertEqual(
            projection.banners,
            [
                VNextTodayBanner(kind: .carryover, count: 1),
                VNextTodayBanner(kind: .review, count: 2),
                VNextTodayBanner(kind: .sync, count: 0),
                VNextTodayBanner(kind: .capacity, count: 1),
            ]
        )
        XCTAssertEqual(Set(projection.banners.map(\.id)).count, projection.banners.count)
    }

    func testProjectionEmitsNoBannersWhenNothingNeedsAttention() throws {
        let day = try projectionDay()
        let fixture = try makeProjectionFixture(day: day)
        let agenda = TodayAgendaService(calendar: calendar).agenda(
            snapshot: fixture.snapshot,
            day: day,
            now: day
        )

        let projection = VNextTodayProjector.project(
            agenda: agenda,
            pendingCaptures: [],
            activeCapture: nil,
            snapshot: fixture.snapshot
        )

        XCTAssertTrue(projection.banners.isEmpty)
    }

    // MARK: - Root navigation structure (Task 12)

    func testRootViewRendersExactlyTheVNextPrimaryTabs() {
        // RootView's TabView is built by switching over
        // `StudioExperienceContract.vNextPrimaryTabs`; pinning the contract
        // pins the real tab structure.
        // Calendar/Library/Reviews/Sync/AI Settings/Export/App Lock live in
        // the top-right menu, never as peer tabs.
        XCTAssertEqual(StudioExperienceContract.vNextPrimaryTabs, [.today, .courses, .trail, .coach])
    }

    // MARK: - CourseSummaryProjector (Task 12)

    func testCourseSummariesExcludeTrashedAndDeletedProjects() throws {
        let day = try projectionDay()
        let active = makeCourseProject(name: "Active", updatedAt: day)
        var trashed = makeCourseProject(name: "Trashed", updatedAt: day)
        trashed.status = .trash
        trashed.previousStatusBeforeTrash = .active
        trashed.deletedAt = day
        var deleted = makeCourseProject(name: "Deleted", updatedAt: day)
        deleted.deletedAt = day

        let summaries = CourseSummaryProjector.project(
            snapshot: JournalSnapshot(projects: [active, trashed, deleted])
        )

        XCTAssertEqual(summaries.map(\.project.name), ["Active"])
    }

    func testCourseSummariesOrderActiveFirstByUpdatedAtDesc() throws {
        let day = try projectionDay()
        let completed = makeCourseProject(name: "Completed", status: .completed, updatedAt: day)
        let oldActive = makeCourseProject(name: "Old Active", updatedAt: day.addingTimeInterval(-3_600))
        let paused = makeCourseProject(name: "Paused", status: .paused, updatedAt: day)
        let newActive = makeCourseProject(name: "New Active", updatedAt: day)

        let summaries = CourseSummaryProjector.project(
            snapshot: JournalSnapshot(projects: [completed, oldActive, paused, newActive])
        )

        // Status groups rank active → paused → completed; within a group the
        // most recently touched project comes first.
        XCTAssertEqual(
            summaries.map(\.project.name),
            ["New Active", "Old Active", "Paused", "Completed"]
        )
    }

    func testCourseSummaryResolvesCurrentPhaseMilestoneAndPendingSuggestions() throws {
        let day = try projectionDay()
        let fixture = try makeCourseFixture(day: day)
        let pending = LearningAdjustmentSuggestion(
            projectID: fixture.project.id,
            kind: .nextStep,
            title: "Tighten the next step",
            rationale: "Two records stalled",
            proposedValue: "Read one section",
            createdAt: day
        )
        var adopted = pending
        adopted.id = UUID()
        adopted.decision = .adopted
        var deletedPending = pending
        deletedPending.id = UUID()
        deletedPending.deletedAt = day
        let snapshot = fixture.snapshot(with: [pending, adopted, deletedPending])

        let summary = try XCTUnwrap(
            CourseSummaryProjector.project(snapshot: snapshot).first
        )

        // Phase 1 is completed, so the current phase is the first
        // non-completed one by ordinal; the milestone is its objective.
        XCTAssertEqual(summary.activePlan, fixture.plan)
        XCTAssertEqual(summary.currentPhase, fixture.currentPhase)
        XCTAssertEqual(summary.milestone, fixture.currentPhase.objective)
        XCTAssertEqual(summary.pendingSuggestionCount, 1)
        XCTAssertFalse(summary.isManualProject)
    }

    func testCourseSummaryNextStepPrefersProjectNextStep() throws {
        let day = try projectionDay()
        let fixture = try makeCourseFixture(day: day)

        let summary = try XCTUnwrap(
            CourseSummaryProjector.project(snapshot: fixture.snapshot()).first
        )

        XCTAssertEqual(summary.nextStep, fixture.project.currentNextStep)
    }

    func testCourseSummaryNextStepFallsBackToFirstIncompletePlannedSession() throws {
        let day = try projectionDay()
        let fixture = try makeCourseFixture(day: day, projectNextStep: "  ")

        let summary = try XCTUnwrap(
            CourseSummaryProjector.project(snapshot: fixture.snapshot()).first
        )

        XCTAssertEqual(summary.nextStep, fixture.pendingSession.title)
    }

    func testCourseSummaryLastConfirmedRecordIsLatestAssessedSession() throws {
        let day = try projectionDay()
        let project = makeCourseProject(name: "Manual", updatedAt: day)
        let confirmed = try makeAssessedSession(
            projectID: project.id,
            note: "Confirmed record",
            endedAt: day.addingTimeInterval(-3_600)
        )
        // A later session WITHOUT an assessment is not a confirmed record.
        let legacyLater = try LearningSession(
            projectId: project.id,
            source: .quickLog,
            actionType: .course,
            startedAt: day.addingTimeInterval(-1_800),
            endedAt: day,
            durationMinutes: 30,
            note: "Legacy quick log",
            nextStepBefore: "a",
            nextStepAfter: "b"
        )

        let summary = try XCTUnwrap(
            CourseSummaryProjector.project(
                snapshot: JournalSnapshot(projects: [project], sessions: [confirmed, legacyLater])
            ).first
        )

        XCTAssertEqual(summary.lastConfirmedRecord, confirmed)
        XCTAssertTrue(summary.isManualProject)
        XCTAssertNil(summary.currentPhase)
        XCTAssertNil(summary.milestone)
        XCTAssertEqual(summary.nextStep, project.currentNextStep)
        XCTAssertEqual(summary.pendingSuggestionCount, 0)
    }

    @MainActor
    func testDailyOverrideStaysLocalOnlyAndNeverWritesTrailOrActivePlan() throws {
        let day = try projectionDay()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemoryJournalRepository()
        let journalService = JournalService(repository: repository)
        let captureStore = PendingStudyCaptureStore(directory: root, now: { day })
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            attachmentStore: .defaultStore(),
            pendingCaptureStore: captureStore,
            practiceService: PracticeService(repository: repository),
            practiceTimer: PracticeTimerRuntime(store: EphemeralPracticeTimerStateStore())
        )
        let project = try viewModel.onboardProject(
            name: "Planned",
            area: "Test",
            goal: "Learn",
            nextStep: "Take one small step"
        )
        let trailBefore = viewModel.snapshot.trailEvents
        let planBefore = viewModel.snapshot.coursePlans
        let projectBefore = viewModel.snapshot.projects

        viewModel.applyTodayAgendaOverride(
            TodayAgendaOverride(
                day: day,
                source: .nextStep,
                sourceID: project.id,
                position: .upNext
            ),
            calendar: calendar
        )

        XCTAssertEqual(viewModel.snapshot.trailEvents, trailBefore)
        XCTAssertEqual(viewModel.snapshot.coursePlans, planBefore)
        XCTAssertEqual(viewModel.snapshot.projects, projectBefore)
        // The view-model projection is pure assembly: it reflects the same
        // agenda the service computes and writes nothing back.
        let projection = viewModel.vNextTodayProjection(now: day, calendar: calendar)
        XCTAssertEqual(projection.fullAgenda, viewModel.todayAgenda(now: day, calendar: calendar).items)
        XCTAssertEqual(viewModel.snapshot.trailEvents, trailBefore)
    }

    private func makeItem(title: String, position: TodayAgendaPosition) -> TodayAgendaItem {
        TodayAgendaItem(
            source: .plannedSession,
            sourceID: UUID(),
            projectID: UUID(),
            title: title,
            detail: "Detail",
            durationMinutes: 30,
            position: position
        )
    }

    private func makeAgenda(planStatus: CoursePlanStatus, day: Date) -> TodayAgenda {
        do {
            var project = Project(
                name: "Planned",
                area: "Test",
                goal: "Learn",
                currentNextStep: "Take one small step",
                createdAt: day.addingTimeInterval(-300),
                updatedAt: day.addingTimeInterval(-300),
                activeEvidenceContractId: UUID()
            )
            let plan = try LearningPlan(
                projectId: project.id,
                revision: 1,
                status: planStatus,
                courseURL: nil,
                courseTitle: "Plan",
                courseOutline: "",
                goal: "Learn",
                expectedOutcome: "Outcome",
                startsOn: day.addingTimeInterval(-86_400),
                deadline: nil,
                weeklyBudgetMinutes: 60,
                summary: "",
                createdAt: day.addingTimeInterval(-86_400),
                updatedAt: day.addingTimeInterval(-86_400)
            )
            project.activeCoursePlanId = plan.id
            let phase = try PlanPhase(
                planId: plan.id,
                planRevisionID: plan.revisionID,
                planSeriesID: plan.planSeriesID,
                title: "Phase",
                objective: "Objective",
                expectedProof: "Proof",
                ordinal: 0,
                targetStart: day.addingTimeInterval(-86_400),
                targetEnd: day.addingTimeInterval(86_400),
                createdAt: day.addingTimeInterval(-86_400),
                updatedAt: day.addingTimeInterval(-86_400)
            )
            let session = try PlannedSession(
                planId: plan.id,
                planRevisionID: plan.revisionID,
                planSeriesID: plan.planSeriesID,
                phaseId: phase.id,
                projectId: project.id,
                title: planStatus == .draft ? "Unreachable draft session" : "Active plan session",
                actionType: .course,
                durationMinutes: 30,
                deadline: day.addingTimeInterval(3_600),
                status: .scheduled,
                createdAt: day.addingTimeInterval(-60),
                updatedAt: day.addingTimeInterval(-60)
            )
            let snapshot = JournalSnapshot(
                projects: [project],
                coursePlans: [plan],
                planPhases: [phase],
                plannedSessions: [session]
            )
            return TodayAgendaService(calendar: calendar).agenda(snapshot: snapshot, day: day, now: day)
        } catch {
            XCTFail("fixture construction failed: \(error)")
            return TodayAgenda(day: day, items: [])
        }
    }

    // MARK: - Projection fixtures (Task 11)

    private struct ProjectionFixture {
        let project: Project
        let phase: PlanPhase
        let session: PlannedSession
        let snapshot: JournalSnapshot
    }

    private func projectionDay() throws -> Date {
        try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 10))
        )
    }

    /// One active plan session (default Up Next), one practice occurrence,
    /// and two Next Steps: four agenda items, so the first screen must
    /// project the top three and retain the rest for "view all".
    private func makeProjectionFixture(
        day: Date,
        recommendationReason: String? = "Shortest path to the phase proof",
        completionCriteria: [String] = ["Summarize the lecture", "Note one open question"],
        sessionDeadline: Date? = nil
    ) throws -> ProjectionFixture {
        var project = Project(
            name: "Planned",
            area: "Test",
            goal: "Learn",
            currentNextStep: "Take one small step",
            createdAt: day.addingTimeInterval(-300),
            updatedAt: day.addingTimeInterval(-300),
            activeEvidenceContractId: UUID()
        )
        let other = Project(
            name: "Other",
            area: "Test",
            goal: "Learn",
            currentNextStep: "Read one page",
            createdAt: day.addingTimeInterval(-100),
            updatedAt: day.addingTimeInterval(-100),
            activeEvidenceContractId: UUID()
        )
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Plan",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Outcome",
            startsOn: day.addingTimeInterval(-86_400),
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "",
            createdAt: day.addingTimeInterval(-86_400),
            updatedAt: day.addingTimeInterval(-86_400)
        )
        project.activeCoursePlanId = plan.id
        let phase = try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Foundations",
            objective: "Objective",
            expectedProof: "Proof",
            ordinal: 0,
            targetStart: day.addingTimeInterval(-86_400),
            targetEnd: day.addingTimeInterval(86_400),
            createdAt: day.addingTimeInterval(-86_400),
            updatedAt: day.addingTimeInterval(-86_400)
        )
        let session = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: phase.id,
            projectId: project.id,
            title: "Work the problem set",
            actionType: .course,
            durationMinutes: 45,
            completionCriteria: completionCriteria,
            recommendationReason: recommendationReason,
            deadline: sessionDeadline ?? day.addingTimeInterval(3_600),
            status: .scheduled,
            createdAt: day.addingTimeInterval(-60),
            updatedAt: day.addingTimeInterval(-60)
        )
        let routine = PracticeRoutine(
            projectId: project.id,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 20,
            weekdays: [2],
            createdAt: day.addingTimeInterval(-86_400),
            updatedAt: day.addingTimeInterval(-86_400)
        )
        let snapshot = JournalSnapshot(
            projects: [project, other],
            coursePlans: [plan],
            planPhases: [phase],
            plannedSessions: [session],
            practiceRoutines: [routine]
        )
        return ProjectionFixture(project: project, phase: phase, session: session, snapshot: snapshot)
    }

    private func makeCapture(
        projectID: UUID,
        plannedSessionID: UUID?,
        stage: PendingStudyCaptureStage,
        now: Date
    ) -> PendingStudyCapture {
        PendingStudyCapture(
            id: UUID(),
            projectID: projectID,
            plannedSessionID: plannedSessionID,
            source: .timer,
            stage: stage,
            startedAt: now.addingTimeInterval(-1_800),
            updatedAt: now
        )
    }

    // MARK: - Course summary fixtures (Task 12)

    private struct CourseFixture {
        let project: Project
        let plan: LearningPlan
        let completedPhase: PlanPhase
        let currentPhase: PlanPhase
        let pendingSession: PlannedSession

        func snapshot(
            with suggestions: [LearningAdjustmentSuggestion] = []
        ) -> JournalSnapshot {
            JournalSnapshot(
                projects: [project],
                coursePlans: [plan],
                planPhases: [completedPhase, currentPhase],
                plannedSessions: [pendingSession],
                learningAdjustmentSuggestions: suggestions
            )
        }
    }

    private func makeCourseProject(
        name: String,
        status: ProjectStatus = .active,
        updatedAt: Date
    ) -> Project {
        Project(
            name: name,
            area: "Test",
            goal: "Learn",
            status: status,
            currentNextStep: "Take one small step",
            createdAt: updatedAt,
            updatedAt: updatedAt,
            activeEvidenceContractId: UUID()
        )
    }

    /// One active plan with a completed first phase, an in-progress second
    /// phase, and one incomplete planned session inside the current phase.
    private func makeCourseFixture(
        day: Date,
        projectNextStep: String = "Take one small step"
    ) throws -> CourseFixture {
        var project = makeCourseProject(name: "Course", updatedAt: day)
        project.currentNextStep = projectNextStep
        let plan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Plan",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Outcome",
            startsOn: day.addingTimeInterval(-86_400),
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "",
            createdAt: day.addingTimeInterval(-86_400),
            updatedAt: day.addingTimeInterval(-86_400)
        )
        project.activeCoursePlanId = plan.id
        let completedPhase = try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Foundations",
            objective: "Foundations objective",
            expectedProof: "Proof",
            progress: .completed,
            ordinal: 0,
            targetStart: day.addingTimeInterval(-86_400),
            targetEnd: day,
            createdAt: day.addingTimeInterval(-86_400),
            updatedAt: day
        )
        let currentPhase = try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Deep Work",
            objective: "Deep work objective",
            expectedProof: "Proof",
            progress: .active,
            ordinal: 1,
            targetStart: day,
            targetEnd: day.addingTimeInterval(86_400),
            createdAt: day.addingTimeInterval(-86_400),
            updatedAt: day
        )
        let pendingSession = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: currentPhase.id,
            projectId: project.id,
            title: "Work the problem set",
            actionType: .course,
            durationMinutes: 45,
            deadline: day.addingTimeInterval(3_600),
            status: .scheduled,
            createdAt: day.addingTimeInterval(-60),
            updatedAt: day.addingTimeInterval(-60)
        )
        return CourseFixture(
            project: project,
            plan: plan,
            completedPhase: completedPhase,
            currentPhase: currentPhase,
            pendingSession: pendingSession
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func makeAssessedSession(
        projectID: UUID,
        note: String,
        endedAt: Date
    ) throws -> LearningSession {
        try LearningSession(
            projectId: projectID,
            source: .timer,
            actionType: .course,
            startedAt: endedAt.addingTimeInterval(-1_800),
            endedAt: endedAt,
            durationMinutes: 30,
            note: note,
            nextStepBefore: "a",
            nextStepAfter: "b",
            assessment: LearningRecordAssessment(
                progress: .completed,
                completedCriterionIDs: [],
                aiDraftedSummary: false,
                userEditedSummary: false,
                confirmedAt: endedAt,
                revision: 1
            )
        )
    }
}

@MainActor
private final class EphemeralPracticeTimerStateStore: PracticeTimerStateStore {
    private var data: Data?

    func load() -> Data? { data }

    func save(_ data: Data?) throws { self.data = data }
}
