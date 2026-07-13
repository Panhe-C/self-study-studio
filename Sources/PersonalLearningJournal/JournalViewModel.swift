import Combine
import Foundation

@MainActor
public final class JournalViewModel: ObservableObject {
    @Published public private(set) var snapshot: JournalSnapshot
    @Published public private(set) var syncSummary: SyncSummary
    @Published public private(set) var syncConflicts: [SyncConflict]
    @Published public private(set) var syncAccountState: CloudAccountState
    @Published public private(set) var syncPendingMutationCount: Int
    @Published public private(set) var syncLastSuccess: Date?
    @Published public private(set) var bootstrapEntityCount: Int
    @Published public private(set) var draftCoursePlan: CoursePlan?
    @Published public private(set) var coursePlanGenerationState: CoursePlanGenerationState
    @Published public private(set) var coursePlanValidationErrors: [CoursePlanningValidationError]
    @Published private var rememberedCoursePlanningInputs: [UUID: CoursePlanningInput]

    private let journalService: JournalService
    private let reviewService: ReviewService
    private let exportService: ExportService
    private let attachmentStore: AttachmentStore
    private let practiceService: PracticeService
    public let practiceTimer: PracticeTimerRuntime
    private let coursePlanningService: CoursePlanningService?
    private let syncCoordinator: (any CloudSyncCoordinating)?
    private let syncRepository: (any JournalRepository)?
    private let accountCoordinator: CloudAccountCoordinator?

    public init(
        journalService: JournalService,
        reviewService: ReviewService,
        exportService: ExportService,
        attachmentStore: AttachmentStore = .defaultStore(),
        practiceService: PracticeService,
        practiceTimer: PracticeTimerRuntime,
        coursePlanningService: CoursePlanningService? = nil,
        syncCoordinator: (any CloudSyncCoordinating)? = nil,
        syncRepository: (any JournalRepository)? = nil,
        accountCoordinator: CloudAccountCoordinator? = nil
    ) {
        self.journalService = journalService
        self.reviewService = reviewService
        self.exportService = exportService
        self.attachmentStore = attachmentStore
        self.practiceService = practiceService
        self.practiceTimer = practiceTimer
        self.coursePlanningService = coursePlanningService
        self.syncCoordinator = syncCoordinator
        self.syncRepository = syncRepository
        self.accountCoordinator = accountCoordinator
        self.snapshot = journalService.snapshot()
        self.syncSummary = .localOnly
        self.syncConflicts = []
        self.syncAccountState = accountCoordinator?.state ?? CloudAccountState(mode: .localOnly)
        self.syncPendingMutationCount = 0
        self.syncLastSuccess = nil
        self.bootstrapEntityCount = 0
        self.draftCoursePlan = nil
        self.coursePlanGenerationState = .idle
        self.coursePlanValidationErrors = []
        self.rememberedCoursePlanningInputs = [:]
    }

    public func refreshSyncSummary() async {
        refreshSyncRepositoryDetails()
        if let accountCoordinator {
            syncAccountState = accountCoordinator.state
            bootstrapEntityCount = (try? accountCoordinator.prepareExistingLocalDataForCloud()) ?? 0
        }
        guard let syncCoordinator else {
            syncSummary = .localOnly
            return
        }
        let status = await syncCoordinator.status
        if case let .synced(lastSuccess) = status {
            syncLastSuccess = lastSuccess
        }
        syncSummary = SyncSummary(
            status: status,
            conflictCount: syncRepository == nil ? nil : syncConflicts.count
        )
    }

    public func syncNow() async throws {
        guard let syncCoordinator else {
            await refreshSyncSummary()
            return
        }

        do {
            try await syncCoordinator.syncNow()
        } catch {
            await refreshSyncSummary()
            throw error
        }
        refresh()
        await refreshSyncSummary()
    }

    public func confirmExistingLocalDataUpload() throws {
        try accountCoordinator?.confirmExistingLocalDataUpload()
        refreshSyncRepositoryDetails()
        bootstrapEntityCount = 0
    }

    public func resolveSyncConflict(id: UUID, using payload: Data) throws {
        guard let syncRepository else { return }
        guard let conflict = syncConflicts.first(where: { $0.id == id }) else { return }
        let entity = try decodedConflictEntity(payload, kind: conflict.entity.kind)
        guard entity.reference == conflict.entity else {
            throw SyncConflictResolutionError.mismatchedEntity
        }
        try syncRepository.resolveConflict(id: id, with: entity)
        refresh()
        refreshSyncRepositoryDetails()
    }

    public var hasCompletedOnboarding: Bool {
        snapshot.hasCompletedOnboarding
    }

    public var shouldShowMainTabs: Bool {
        hasCompletedOnboarding || !projects.isEmpty
    }

    public var pendingFirstRecordProject: Project? {
        guard let projectId = snapshot.pendingFirstRecordProjectId else { return nil }
        return snapshot.projects.first { $0.id == projectId }
    }

    public var projects: [Project] {
        snapshot.projects
    }

    public var sessions: [LearningSession] {
        snapshot.sessions
    }

    public var proofs: [Proof] {
        snapshot.proofs
    }

    public var reviews: [Review] {
        snapshot.reviews
    }

    public var coursePlans: [CoursePlan] {
        snapshot.coursePlans
    }

    public var planPhases: [PlanPhase] {
        snapshot.planPhases
    }

    public var plannedSessions: [PlannedSession] {
        snapshot.plannedSessions
    }

    public var practiceRoutines: [PracticeRoutine] {
        snapshot.practiceRoutines
    }

    public var practiceSessions: [PracticeSession] {
        snapshot.practiceSessions
    }

    public var continueCards: [Project] {
        journalService.todayContinueProjects()
    }

    @discardableResult
    public func onboardProject(
        name: String,
        area: String,
        goal: String,
        nextStep: String
    ) throws -> Project {
        let projects = try onboardProjects([
            ProjectOnboardingDraft(name: name, area: area, goal: goal, nextStep: nextStep)
        ])
        guard let project = projects.first else { throw JournalValidationError.emptyName }
        return project
    }

    @discardableResult
    public func onboardProjects(
        _ drafts: [ProjectOnboardingDraft]
    ) throws -> [Project] {
        let projects = try journalService.createOnboardingProjects(drafts)
        refresh()
        return projects
    }

    @discardableResult
    public func createProject(
        name: String,
        area: String,
        goal: String,
        nextStep: String
    ) throws -> Project {
        let project = try journalService.createProject(
            name: name,
            area: area,
            goal: goal,
            nextStep: nextStep
        )
        refresh()
        return project
    }

    @discardableResult
    public func quickLog(
        projectId: UUID,
        actionType: ActionType? = nil,
        durationMinutes: Int,
        note: String,
        nextStep: String? = nil,
        plannedSessionId: UUID? = nil
    ) throws -> LearningSession {
        let session = try journalService.quickLog(
            projectId: projectId,
            actionType: actionType,
            durationMinutes: durationMinutes,
            note: note,
            nextStep: nextStep,
            plannedSessionId: plannedSessionId
        )
        tryCompleteOnboarding(afterRecording: projectId)
        refresh()
        return session
    }

    @discardableResult
    public func updateProject(
        projectId: UUID,
        name: String,
        area: String,
        goal: String,
        nextStep: String
    ) throws -> Project {
        let project = try journalService.updateProject(
            projectId: projectId,
            name: name,
            area: area,
            goal: goal,
            nextStep: nextStep
        )
        refresh()
        return project
    }

    public func updateProjectStatus(
        projectId: UUID,
        status: ProjectStatus
    ) throws {
        try journalService.updateProjectStatus(projectId: projectId, status: status)
        refresh()
    }

    @discardableResult
    public func generateCoursePlan(_ input: CoursePlanningInput) async throws -> CoursePlan {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        rememberCoursePlanningInput(input)
        coursePlanGenerationState = .generating
        coursePlanValidationErrors = []
        do {
            let plan = try await coursePlanningService.generateDraft(
                input: input,
                context: coursePlanningContext(for: input.projectId)
            )
            refresh()
            draftCoursePlan = plan
            coursePlanGenerationState = .ready(plan.id)
            return plan
        } catch let error as CoursePlanningError {
            if case let .invalidDraft(errors) = error {
                coursePlanValidationErrors = errors
            }
            coursePlanGenerationState = .failed(error)
            throw error
        } catch let error as CoursePlanningValidationError {
            coursePlanValidationErrors = [error]
            coursePlanGenerationState = .failed(.invalidDraft([error]))
            throw error
        } catch {
            coursePlanGenerationState = .failed(.providerUnavailable)
            throw error
        }
    }

    @discardableResult
    public func saveManualDraft(
        input: CoursePlanningInput,
        draft: CoursePlanDraft
    ) throws -> CoursePlan {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        rememberCoursePlanningInput(input)
        do {
            let plan = try coursePlanningService.saveDraft(input: input, draft: draft)
            refresh()
            draftCoursePlan = plan
            coursePlanGenerationState = .ready(plan.id)
            coursePlanValidationErrors = []
            return plan
        } catch let error as CoursePlanningValidationError {
            coursePlanValidationErrors = [error]
            coursePlanGenerationState = .failed(.invalidDraft([error]))
            throw error
        }
    }

    public func activateCoursePlan(draftPlanID: UUID) throws {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        _ = try coursePlanningService.activate(draftPlanID: draftPlanID)
        if draftCoursePlan?.id == draftPlanID {
            draftCoursePlan = nil
        }
        coursePlanGenerationState = .idle
        refresh()
    }

    @discardableResult
    public func reviseCoursePlan(
        planID: UUID,
        input: CoursePlanningInput,
        draft: CoursePlanDraft
    ) throws -> CoursePlan {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        rememberCoursePlanningInput(input)
        let plan = try coursePlanningService.revise(planID: planID, input: input, draft: draft)
        refresh()
        draftCoursePlan = plan
        coursePlanGenerationState = .ready(plan.id)
        coursePlanValidationErrors = []
        return plan
    }

    public func applyReviewRecommendation(
        reviewId: UUID,
        projectId: UUID
    ) throws {
        try journalService.applyReviewRecommendation(reviewId: reviewId, projectId: projectId)
        refresh()
    }

    public func applyReviewNextStep(
        reviewId: UUID,
        projectId: UUID
    ) throws {
        guard let review = snapshot.reviews.first(where: { $0.id == reviewId }) else {
            throw JournalValidationError.missingReview
        }
        guard let nextStep = review.nextSteps[projectId] else {
            throw JournalValidationError.missingReviewRecommendation
        }
        guard let project = snapshot.projects.first(where: { $0.id == projectId }) else {
            throw JournalValidationError.missingProject
        }

        _ = try journalService.updateProject(
            projectId: projectId,
            name: project.name,
            area: project.area,
            goal: project.goal,
            nextStep: nextStep
        )
        refresh()
    }

    @discardableResult
    public func saveTimerSession(
        projectId: UUID,
        actionType: ActionType,
        startedAt: Date,
        endedAt: Date,
        note: String,
        nextStep: String? = nil,
        plannedSessionId: UUID? = nil
    ) throws -> LearningSession {
        let session = try journalService.saveTimerSession(
            projectId: projectId,
            actionType: actionType,
            startedAt: startedAt,
            endedAt: endedAt,
            note: note,
            nextStep: nextStep,
            plannedSessionId: plannedSessionId
        )
        tryCompleteOnboarding(afterRecording: projectId)
        refresh()
        return session
    }

    @discardableResult
    public func addProof(
        id: UUID = UUID(),
        projectId: UUID,
        sessionId: UUID? = nil,
        type: ProofType,
        title: String,
        statement: String,
        localPath: String? = nil,
        url: URL? = nil,
        mimeType: String? = nil,
        fileSize: Int? = nil
    ) throws -> Proof {
        let proof = try journalService.addProof(
            id: id,
            projectId: projectId,
            sessionId: sessionId,
            type: type,
            title: title,
            statement: statement,
            localPath: localPath,
            url: url,
            mimeType: mimeType,
            fileSize: fileSize
        )
        tryCompleteOnboarding(afterRecording: projectId)
        refresh()
        return proof
    }

    @discardableResult
    public func addProofFromAttachmentData(
        _ data: Data,
        projectId: UUID,
        sessionId: UUID? = nil,
        type: ProofType,
        title: String,
        statement: String,
        originalFileName: String,
        mimeType: String?
    ) throws -> Proof {
        let proofId = UUID()
        let attachment = try attachmentStore.saveData(
            data,
            projectId: projectId,
            sessionId: sessionId,
            proofId: proofId,
            originalFileName: originalFileName,
            mimeType: mimeType
        )
        return try addProof(
            id: proofId,
            projectId: projectId,
            sessionId: sessionId,
            type: type,
            title: title,
            statement: statement,
            localPath: attachment.fileURL.path,
            mimeType: attachment.mimeType,
            fileSize: attachment.fileSize
        )
    }

    @discardableResult
    public func addProofFromFile(
        fileURL: URL,
        projectId: UUID,
        sessionId: UUID? = nil,
        type: ProofType,
        title: String,
        statement: String,
        mimeType: String?
    ) throws -> Proof {
        let proofId = UUID()
        let attachment = try attachmentStore.copyFile(
            from: fileURL,
            projectId: projectId,
            sessionId: sessionId,
            proofId: proofId,
            mimeType: mimeType
        )
        return try addProof(
            id: proofId,
            projectId: projectId,
            sessionId: sessionId,
            type: type,
            title: title,
            statement: statement,
            localPath: attachment.fileURL.path,
            mimeType: attachment.mimeType,
            fileSize: attachment.fileSize
        )
    }

    @discardableResult
    public func createWeeklyReview(
        periodStart: Date,
        periodEnd: Date
    ) async throws -> Review {
        let review = try await reviewService.createWeeklyReview(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        refresh()
        return review
    }

    @discardableResult
    public func updateReview(
        reviewId: UUID,
        facts: [String],
        patterns: [String],
        decisions: [String],
        nextSteps: [UUID: String]
    ) throws -> Review {
        let review = try journalService.updateReview(
            reviewId: reviewId,
            facts: facts,
            patterns: patterns,
            decisions: decisions,
            nextSteps: nextSteps
        )
        refresh()
        return review
    }

    public func trail(for projectId: UUID) -> [TrailEvent] {
        journalService.trailEvents(projectId: projectId)
    }

    public func sessionsForProject(_ projectId: UUID) -> [LearningSession] {
        journalService.sessions(projectId: projectId)
    }

    public func proofsForProject(_ projectId: UUID) -> [Proof] {
        journalService.proofs(projectId: projectId)
    }

    public func proofsForSession(_ sessionId: UUID) -> [Proof] {
        journalService.proofs(sessionId: sessionId)
    }

    public func practiceSessionsForProject(_ projectId: UUID) -> [PracticeSession] {
        snapshot.practiceSessions.filter {
            $0.deletedAt == nil && $0.linkedProjectId == projectId
        }
    }

    public func practiceCards(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [StudioPracticeCard] {
        let timerSnapshot = practiceTimer.snapshot
        var presentedRoutines = practiceRoutines
        var presentedSessions = practiceSessions

        if let activeRoutine = activePracticePresentationRoutine(
            timerSnapshot: timerSnapshot,
            now: now
        ) {
            presentedRoutines.removeAll { $0.id == activeRoutine.id }
            presentedRoutines.append(activeRoutine)
            if let startedAt = timerSnapshot.startedAt {
                presentedSessions.append(
                    PracticeSession(
                        routineId: activeRoutine.id,
                        startedAt: startedAt,
                        endedAt: now,
                        activeDurationSeconds: timerSnapshot.activeElapsedSeconds
                    )
                )
            }
        }

        return StudioPresentation.practiceCards(
            routines: presentedRoutines,
            sessions: presentedSessions,
            activeRoutineId: timerSnapshot.activeRoutineId,
            now: now,
            calendar: calendar
        ).map { card in
            guard card.isActiveTimer else { return card }
            return StudioPracticeCard(
                routine: card.routine,
                statistics: card.statistics,
                isActiveTimer: true,
                targetSeconds: timerSnapshot.targetSeconds
            )
        }
    }

    private func activePracticePresentationRoutine(
        timerSnapshot: PracticeTimerSnapshot,
        now: Date
    ) -> PracticeRoutine? {
        guard let routineId = timerSnapshot.activeRoutineId else { return nil }
        let syncedRoutine = practiceRoutines.first { $0.id == routineId }
        let presentation = practiceTimer.activeRoutinePresentation

        return PracticeRoutine(
            id: routineId,
            name: presentation?.name ?? syncedRoutine?.name ?? "Practice",
            symbolName: presentation?.symbolName ?? syncedRoutine?.symbolName ?? "timer",
            color: presentation?.color ?? syncedRoutine?.color ?? .teal,
            targetMinutes: max(1, (timerSnapshot.targetSeconds + 59) / 60),
            weekdays: Set(1...7),
            reminderTime: syncedRoutine?.reminderTime,
            isArchived: false,
            createdAt: syncedRoutine?.createdAt ?? timerSnapshot.startedAt ?? now,
            updatedAt: syncedRoutine?.updatedAt ?? now,
            deletedAt: nil,
            schemaVersion: syncedRoutine?.schemaVersion ?? 1
        )
    }

    @discardableResult
    public func createPracticeRoutine(
        name: String,
        symbolName: String,
        color: PracticeSemanticColor,
        targetMinutes: Int,
        weekdays: Set<Int>,
        reminderTime: PracticeReminderTime? = nil
    ) throws -> PracticeRoutine {
        let routine = try practiceService.createRoutine(
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            reminderTime: reminderTime
        )
        refresh()
        return routine
    }

    @discardableResult
    public func updatePracticeRoutine(
        routineId: UUID,
        name: String,
        symbolName: String,
        color: PracticeSemanticColor,
        targetMinutes: Int,
        weekdays: Set<Int>,
        reminderTime: PracticeReminderTime? = nil
    ) throws -> PracticeRoutine {
        guard practiceTimer.snapshot.activeRoutineId != routineId else {
            throw PracticeServiceError.activeRoutineCannotBeModified
        }
        let routine = try practiceService.updateRoutine(
            routineId: routineId,
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            reminderTime: reminderTime
        )
        refresh()
        return routine
    }

    @discardableResult
    public func archivePracticeRoutine(_ routineId: UUID) throws -> PracticeRoutine {
        guard practiceTimer.snapshot.activeRoutineId != routineId else {
            throw PracticeServiceError.activeRoutineCannotBeModified
        }
        let routine = try practiceService.archiveRoutine(routineId)
        refresh()
        return routine
    }

    public func deletePracticeRoutineIfUnused(_ routineId: UUID) throws {
        guard practiceTimer.snapshot.activeRoutineId != routineId else {
            throw PracticeServiceError.activeRoutineCannotBeModified
        }
        try practiceService.deleteRoutineIfUnused(routineId)
        refresh()
    }

    public func startPractice(_ routine: PracticeRoutine) throws {
        try practiceTimer.start(
            routineId: routine.id,
            targetSeconds: routine.targetMinutes * 60,
            routinePresentation: PracticeRoutinePresentationSnapshot(routine: routine)
        )
    }

    @discardableResult
    public func savePracticeCompletion(
        _ completion: PracticeTimerCompletion,
        linkedProjectId: UUID?,
        note: String?
    ) throws -> PracticeSessionSaveResult {
        let pending = practiceTimer.pendingCompletion
        let pendingMatchesCompletion = pending?.completion == completion
        let result = try practiceService.saveSession(
            sessionId: pendingMatchesCompletion ? pending!.id : UUID(),
            routineId: completion.routineId,
            recoverDeletedRoutine: pendingMatchesCompletion
                && pending?.routinePresentation?.routineId == completion.routineId,
            linkedProjectId: linkedProjectId,
            startedAt: completion.startedAt,
            endedAt: completion.endedAt,
            activeDurationSeconds: completion.activeDurationSeconds,
            note: note
        )
        refresh()
        if pendingMatchesCompletion, !practiceTimer.clearPendingCompletion() {
            throw PracticeTimerRuntimeError.pendingCompletionCouldNotClear
        }
        return result
    }

    public func discardPractice() {
        practiceTimer.discard()
    }

    public func reviewsForProject(_ projectId: UUID) -> [Review] {
        snapshot.reviews.filter { review in
            review.nextSteps.keys.contains(projectId)
                || review.projectRecommendations.keys.contains(projectId)
        }
    }

    public func coursePlans(for projectId: UUID) -> [CoursePlan] {
        snapshot.coursePlans
            .filter { $0.projectId == projectId }
            .sorted { $0.revision > $1.revision }
    }

    public func activeCoursePlan(for projectId: UUID) -> CoursePlan? {
        guard let activeID = snapshot.projects.first(where: { $0.id == projectId })?.activeCoursePlanId else {
            return nil
        }
        return snapshot.coursePlans.first { $0.id == activeID }
    }

    public func phases(for planId: UUID) -> [PlanPhase] {
        snapshot.planPhases
            .filter { $0.planId == planId }
            .sorted { $0.ordinal < $1.ordinal }
    }

    public func plannedSessions(for planId: UUID) -> [PlannedSession] {
        let phaseOrdinals = Dictionary(uniqueKeysWithValues: phases(for: planId).map { ($0.id, $0.ordinal) })
        return snapshot.plannedSessions
            .filter { $0.planId == planId }
            .sorted {
                (phaseOrdinals[$0.phaseId] ?? .max, $0.createdAt) < (phaseOrdinals[$1.phaseId] ?? .max, $1.createdAt)
            }
    }

    public func todayPlannedSessions(referenceDate: Date = Date()) -> [PlannedSessionContext] {
        let interval = Calendar.current.dateInterval(of: .day, for: referenceDate)
        return activePlannedSessionContexts.filter { context in
            guard let deadline = context.session.deadline,
                  context.session.status == .unscheduled || context.session.status == .scheduled
            else { return false }
            return interval?.contains(deadline) == true
        }
        .sorted { ($0.session.deadline ?? .distantFuture) < ($1.session.deadline ?? .distantFuture) }
    }

    public func overduePlannedSessions(referenceDate: Date = Date()) -> [PlannedSessionContext] {
        let startOfDay = Calendar.current.startOfDay(for: referenceDate)
        return activePlannedSessionContexts.filter { context in
            guard let deadline = context.session.deadline,
                  context.session.status == .unscheduled || context.session.status == .scheduled
            else { return false }
            return deadline < startOfDay
        }
        .sorted { ($0.session.deadline ?? .distantPast) < ($1.session.deadline ?? .distantPast) }
    }

    public func unscheduledPlannedSessionCount(for planID: UUID) -> Int {
        snapshot.plannedSessions.count { $0.planId == planID && $0.status == .unscheduled }
    }

    public func unschedulePlannedSession(_ id: UUID) throws {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        try coursePlanningService.unschedule(plannedSessionID: id)
        refresh()
    }

    public func skipPlannedSession(_ id: UUID) throws {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        try coursePlanningService.skip(plannedSessionID: id)
        refresh()
    }

    public func rememberedCoursePlanningInput(for projectId: UUID) -> CoursePlanningInput? {
        rememberedCoursePlanningInputs[projectId]
    }

    public func rememberCoursePlanningInput(_ input: CoursePlanningInput) {
        rememberedCoursePlanningInputs[input.projectId] = input
    }

    public func projectsNeedingReview(referenceDate: Date = Date()) -> [Project] {
        journalService.projectsNeedingReview(referenceDate: referenceDate)
    }

    public func shouldShowReviewPrompt(referenceDate: Date = Date()) -> Bool {
        journalService.shouldShowReviewPrompt(referenceDate: referenceDate)
    }

    public func exportJSON() throws -> Data {
        try exportService.exportJSON(snapshot: snapshot)
    }

    public func exportAttachments(to exportDirectory: URL) throws -> [URL] {
        try exportService.exportAttachments(snapshot: snapshot, to: exportDirectory)
    }

    public func exportBundle(to exportDirectory: URL) throws -> JournalExportBundle {
        try exportService.exportBundle(snapshot: snapshot, to: exportDirectory)
    }

    public func refresh() {
        journalService.refreshFromRepository()
        snapshot = journalService.snapshot()
    }

    private func refreshSyncRepositoryDetails() {
        syncConflicts = (try? syncRepository?.conflicts()) ?? []
        syncPendingMutationCount = (try? syncRepository?.pendingMutations(limit: 1_000).count) ?? 0
    }

    private func decodedConflictEntity(
        _ payload: Data,
        kind: JournalEntityKind
    ) throws -> JournalEntity {
        if let wrapped = try? JSONDecoder.journal.decode(JournalEntity.self, from: payload) {
            return wrapped
        }
        switch kind {
        case .project:
            return .project(try JSONDecoder.journal.decode(Project.self, from: payload))
        case .session:
            return .session(try JSONDecoder.journal.decode(LearningSession.self, from: payload))
        case .proof:
            return .proof(try JSONDecoder.journal.decode(Proof.self, from: payload))
        case .review:
            return .review(try JSONDecoder.journal.decode(Review.self, from: payload))
        case .trailEvent:
            return .trailEvent(try JSONDecoder.journal.decode(TrailEvent.self, from: payload))
        case .coursePlan:
            return .coursePlan(try JSONDecoder.journal.decode(CoursePlan.self, from: payload))
        case .planPhase:
            return .planPhase(try JSONDecoder.journal.decode(PlanPhase.self, from: payload))
        case .plannedSession:
            return .plannedSession(try JSONDecoder.journal.decode(PlannedSession.self, from: payload))
        case .availabilityRule:
            return .availabilityRule(try JSONDecoder.journal.decode(AvailabilityRule.self, from: payload))
        case .schedulingPreferences:
            return .schedulingPreferences(try JSONDecoder.journal.decode(SchedulingPreferences.self, from: payload))
        case .practiceRoutine:
            return .practiceRoutine(try JSONDecoder.journal.decode(PracticeRoutine.self, from: payload))
        case .practiceSession:
            return .practiceSession(try JSONDecoder.journal.decode(PracticeSession.self, from: payload))
        }
    }

    private func tryCompleteOnboarding(afterRecording projectId: UUID) {
        guard snapshot.pendingFirstRecordProjectId == projectId else { return }
        try? journalService.completeOnboarding()
    }

    private func coursePlanningContext(for projectId: UUID) -> CoursePlanningContext {
        let sessions = sessionsForProject(projectId)
            .sorted { $0.endedAt > $1.endedAt }
            .prefix(5)
            .map { "\($0.durationMinutes) min \($0.actionType.rawValue): \($0.note)" }
        let proofs = proofsForProject(projectId)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(5)
            .map { "\($0.title): \($0.statement)" }
        return CoursePlanningContext(
            currentNextStep: snapshot.projects.first(where: { $0.id == projectId })?.currentNextStep ?? "",
            recentSessionSummaries: sessions,
            recentProofSummaries: proofs
        )
    }

    private var activePlannedSessionContexts: [PlannedSessionContext] {
        let activePlanIDs = Set(snapshot.projects.compactMap(\.activeCoursePlanId))
        let phaseByID = Dictionary(uniqueKeysWithValues: snapshot.planPhases.map { ($0.id, $0) })
        let projectByID = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        return snapshot.plannedSessions.compactMap { session in
            guard activePlanIDs.contains(session.planId),
                  let project = projectByID[session.projectId]
            else { return nil }
            return PlannedSessionContext(session: session, project: project, phase: phaseByID[session.phaseId])
        }
    }
}

public enum SyncConflictResolutionError: Error, Equatable, Sendable {
    case mismatchedEntity
}

public enum CoursePlanGenerationState: Equatable, Sendable {
    case idle
    case generating
    case ready(UUID)
    case failed(CoursePlanningError)
}

public struct PlannedSessionContext: Identifiable, Equatable, Sendable {
    public var id: UUID { session.id }
    public var session: PlannedSession
    public var project: Project
    public var phase: PlanPhase?

    public init(session: PlannedSession, project: Project, phase: PlanPhase?) {
        self.session = session
        self.project = project
        self.phase = phase
    }
}
