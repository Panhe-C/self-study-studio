import Combine
import Foundation

@MainActor
public final class JournalViewModel: ObservableObject {
    @Published public private(set) var snapshot: JournalSnapshot
    @Published public private(set) var syncSummary: SyncSummary
    @Published public private(set) var syncConflicts: [SyncConflict]
    @Published public private(set) var syncTerminalMutations: [PendingMutation]
    @Published public private(set) var syncAccountState: CloudAccountState
    @Published public private(set) var syncPendingMutationCount: Int
    @Published public private(set) var syncLastSuccess: Date?
    @Published public private(set) var bootstrapEntityCount: Int
    @Published public private(set) var draftCoursePlan: LearningPlan?
    @Published public private(set) var coursePlanGenerationState: CoursePlanGenerationState
    @Published public private(set) var coursePlanValidationErrors: [CoursePlanningValidationError]
    @Published public private(set) var pendingCanonicalNextStepProposal: CanonicalNextStepProposal?
    @Published public private(set) var pendingAttachmentCleanupEntries: [AttachmentCleanupEntry]
    @Published public private(set) var attachmentCleanupQueueError: AttachmentCleanupQueueError?
    @Published public private(set) var attachmentCleanupQueueQuarantineURL: URL?
    public var pendingAttachmentCleanupPaths: [String] {
        pendingAttachmentCleanupEntries.flatMap(\.paths)
    }
    public var pendingAttachmentCleanupOrphanPaths: [String] {
        pendingAttachmentCleanupEntries
            .filter { $0.projectID == nil }
            .flatMap(\.paths)
    }
    @Published private var rememberedCoursePlanningInputs: [UUID: CoursePlanningInput]
    /// Day-scoped Today presentation choices. These are intentionally kept
    /// outside Journal persistence: the derived agenda is never a second
    /// source of truth for plans, routines, completions, or Trail history.
    @Published private var todayAgendaOverrides: [TodayAgendaOverride]

    private let journalService: JournalService
    private let reviewService: ReviewService
    private let exportService: ExportService
    private let attachmentStore: AttachmentStore
    private let archiveService: JournalArchiveService
    private let cleanupQueue: AttachmentCleanupQueue
    private let practiceService: PracticeService
    public let practiceTimer: PracticeTimerRuntime
    private let coursePlanningService: CoursePlanningService?
    private let syncCoordinator: (any CloudSyncCoordinating)?
    private let syncRepository: (any JournalRepository)?
    private let accountCoordinator: CloudAccountCoordinator?
    private var automaticSyncTask: Task<Void, Never>?

    public init(
        journalService: JournalService,
        reviewService: ReviewService,
        exportService: ExportService,
        attachmentStore: AttachmentStore = .defaultStore(),
        archiveService: JournalArchiveService = JournalArchiveService(),
        cleanupQueue: AttachmentCleanupQueue? = nil,
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
        self.archiveService = archiveService
        self.cleanupQueue = cleanupQueue ?? AttachmentCleanupQueue(rootDirectory: attachmentStore.rootDirectory)
        self.practiceService = practiceService
        self.practiceTimer = practiceTimer
        self.coursePlanningService = coursePlanningService
        self.syncCoordinator = syncCoordinator
        self.syncRepository = syncRepository
        self.accountCoordinator = accountCoordinator
        self.snapshot = journalService.snapshot()
        self.syncSummary = .localOnly
        self.syncConflicts = []
        self.syncTerminalMutations = []
        self.syncAccountState = accountCoordinator?.state ?? CloudAccountState(mode: .localOnly)
        self.syncPendingMutationCount = 0
        self.syncLastSuccess = nil
        self.bootstrapEntityCount = 0
        self.draftCoursePlan = nil
        self.coursePlanGenerationState = .idle
        self.coursePlanValidationErrors = []
        self.pendingCanonicalNextStepProposal = nil
        self.pendingAttachmentCleanupEntries = []
        self.attachmentCleanupQueueError = nil
        self.attachmentCleanupQueueQuarantineURL = nil
        self.rememberedCoursePlanningInputs = [:]
        self.todayAgendaOverrides = []
        loadAttachmentCleanupQueue()
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

    public func applicationDidBecomeActive() async {
        guard syncCoordinator != nil else {
            refresh()
            await refreshSyncSummary()
            return
        }
        try? await syncNow()
    }

    public func confirmExistingLocalDataUpload() throws {
        try accountCoordinator?.confirmExistingLocalDataUpload()
        refreshSyncRepositoryDetails()
        bootstrapEntityCount = 0
        scheduleAutomaticSyncIfNeeded()
    }

    public func completeAccountSpaceTransfer(choice: AccountSpaceTransferChoice) throws {
        try accountCoordinator?.completeTransfer(choice: choice)
        refreshSyncRepositoryDetails()
        bootstrapEntityCount = 0
        refresh()
        scheduleAutomaticSyncIfNeeded()
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

    /// Requeues a terminal mutation using the current persisted server tag.
    /// The replacement is atomic, so a failed validation leaves the terminal
    /// item untouched for another recovery decision.
    public func retryTerminalMutation(id: UUID) throws {
        guard let syncRepository else { return }
        try SyncConflictRecoveryService(repository: syncRepository)
            .retryTerminalMutation(id: id)
        refresh()
    }

    /// Discards a terminal outbox item while preserving the current local
    /// entity. This is an explicit user decision, not an automatic retry.
    public func discardTerminalMutation(id: UUID) throws {
        guard let syncRepository else { return }
        try SyncConflictRecoveryService(repository: syncRepository)
            .discardTerminalMutation(id: id)
        refresh()
    }

    public func retryTerminalMutationAndSync(id: UUID) async throws {
        try retryTerminalMutation(id: id)
        try await syncNow()
    }

    public func discardTerminalMutationAndSync(id: UUID) async throws {
        try discardTerminalMutation(id: id)
        try await syncNow()
    }

    public var hasCompletedOnboarding: Bool {
        snapshot.hasCompletedOnboarding
    }

    public var shouldShowMainTabs: Bool {
        projects.contains { !$0.isTrashed && $0.deletedAt == nil }
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

    public var proofRevisions: [ProofRevision] {
        snapshot.proofRevisions
    }

    public var reviews: [Review] {
        snapshot.reviews
    }

    /// Canonical Learning Plan collection. `coursePlans` remains the source
    /// compatibility spelling below for older integrations.
    public var learningPlans: [LearningPlan] {
        snapshot.coursePlans
    }

    public var coursePlans: [CoursePlan] { learningPlans }

    public var planPhases: [PlanPhase] {
        snapshot.planPhases
    }

    public var plannedSessions: [PlannedSession] {
        snapshot.plannedSessions
    }

    public var practiceRoutines: [PracticeRoutine] {
        snapshot.operationalPracticeRoutines
    }

    /// Full routine history for plan-revision detail and audit-oriented
    /// presentation. Operational surfaces should use `practiceRoutines`.
    public var practiceRoutineHistory: [PracticeRoutine] {
        snapshot.practiceRoutineHistory
    }

    public var practiceSessions: [PracticeSession] {
        snapshot.practiceSessions
    }

    public var continueCards: [Project] {
        journalService.todayContinueProjects()
    }

    public func todayRecommendations(
        now: Date = Date(),
        pinnedProjectIDs: Set<UUID> = []
    ) -> [TodayRecommendation] {
        TodayRecommendationService(pinnedProjectIDs: pinnedProjectIDs)
            .recommendations(snapshot: snapshot, now: now)
    }

    /// Returns the deterministic Today projection for the current Journal
    /// snapshot. The service never writes the computed agenda back to Journal.
    public func todayAgenda(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodayAgenda {
        TodayAgendaService(calendar: calendar).agenda(
            snapshot: snapshot,
            day: now,
            now: now,
            overrides: todayAgendaOverrides
        )
    }

    /// Applies a local, day-scoped ordering choice. Source records and Trail
    /// remain unchanged; explicit source actions still go through Journal APIs.
    public func applyTodayAgendaOverride(
        _ override: TodayAgendaOverride,
        calendar: Calendar = .current
    ) {
        if override.position == .upNext {
            // Up Next is exclusive within a day. Removing an older explicit
            // choice lets the service demote that item to its declared default
            // position when a new item is selected.
            todayAgendaOverrides.removeAll {
                calendar.isDate($0.day, inSameDayAs: override.day) &&
                    $0.position == .upNext
            }
        }
        todayAgendaOverrides.removeAll {
            calendar.isDate($0.day, inSameDayAs: override.day) &&
                $0.source == override.source &&
                $0.sourceID == override.sourceID
        }
        todayAgendaOverrides.append(override)
    }

    public func clearTodayAgendaOverride(
        day: Date,
        source: TodayAgendaSource,
        sourceID: UUID,
        calendar: Calendar = .current
    ) {
        todayAgendaOverrides.removeAll {
            calendar.isDate($0.day, inSameDayAs: day) &&
                $0.source == source &&
                $0.sourceID == sourceID
        }
    }

    public func productHealth(now: Date = Date()) -> ProductHealthReport {
        ProductHealthService().report(snapshot: snapshot, now: now)
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
    public func createIdea(name: String, area: String) throws -> Project {
        let project = try journalService.createIdea(name: name, area: area)
        refresh()
        return project
    }

    @discardableResult
    public func activateProject(
        projectId: UUID,
        goal: String,
        nextStep: String,
        contract: EvidenceContract,
        allowAttentionBudgetOverride: Bool = false
    ) throws -> Project {
        let project = try journalService.activateProject(
            projectId: projectId,
            goal: goal,
            nextStep: nextStep,
            contract: contract,
            allowAttentionBudgetOverride: allowAttentionBudgetOverride
        )
        refresh()
        return project
    }

    @discardableResult
    public func reviseContract(projectId: UUID, contract: EvidenceContract) throws -> EvidenceContract {
        let value = try journalService.reviseContract(projectId: projectId, contract: contract)
        refresh()
        return value
    }

    @discardableResult
    public func acceptProof(
        proofId: UUID,
        contractId: UUID,
        acceptedCriteria: [String]
    ) throws -> EvidenceAcceptance {
        let value = try journalService.acceptProof(
            proofId: proofId,
            contractId: contractId,
            acceptedCriteria: acceptedCriteria
        )
        refresh()
        return value
    }

    @discardableResult
    public func completeReview(reviewId: UUID, decision: ReviewDecision) throws -> ReviewDecision {
        let value = try journalService.completeReview(reviewId: reviewId, decision: decision)
        refresh()
        return value
    }

    @discardableResult
    public func completeProject(projectId: UUID, decision: ReviewDecision) throws -> Project {
        let value = try journalService.completeProject(projectId: projectId, decision: decision)
        refresh()
        return value
    }

    public func moveToTrash(projectId: UUID) throws {
        try journalService.moveToTrash(projectId: projectId)
        refresh()
    }

    public func restoreFromTrash(projectId: UUID) throws {
        try journalService.restoreFromTrash(projectId: projectId)
        refresh()
    }

    @discardableResult
    public func permanentlyDelete(projectId: UUID) throws -> TrashPurgeImpact {
        guard let repository = syncRepository else {
            throw JournalArchiveError.invalidArchive
        }
        defer { refresh() }
        try reloadAttachmentCleanupQueue()
        let impact = archiveService.purgeImpact(projectID: projectId, snapshot: snapshot)
        try cleanupQueue.enqueue(projectID: projectId, paths: impact.attachmentPaths)
        let result = try archiveService.purge(
            projectID: projectId,
            snapshot: snapshot,
            from: repository
        )
        try cleanupQueue.remove(projectID: projectId, paths: result.attachmentPaths)
        return result
    }

    public func retryAttachmentCleanup(projectID: UUID, paths: [String]) throws {
        guard let repository = syncRepository else {
            throw JournalArchiveError.invalidArchive
        }
        defer { refresh() }
        try reloadAttachmentCleanupQueue()
        do {
            try archiveService.retryAttachmentCleanup(
                projectID: projectID,
                paths: paths,
                repository: repository
            )
            try cleanupQueue.remove(projectID: projectID, paths: paths)
        } catch let error as JournalArchiveError {
            if case let .attachmentDeletionFailed(failedPaths) = error {
                let successfulPaths = Set(paths).subtracting(failedPaths)
                try cleanupQueue.remove(projectID: projectID, paths: Array(successfulPaths))
            }
            throw error
        }
    }

    public func retryAttachmentCleanup(paths: [String]) throws {
        try reloadAttachmentCleanupQueue()
        guard let entry = pendingAttachmentCleanupEntries.first(where: {
            !Set(paths).isDisjoint(with: $0.paths)
        }) else { return }
        guard let projectID = entry.projectID else {
            throw AttachmentCleanupQueueError.orphanCleanupRequiresConfirmation(
                paths.filter { entry.paths.contains($0) }
            )
        }
        try retryAttachmentCleanup(projectID: projectID, paths: paths)
    }

    public func retryPendingAttachmentCleanup() throws {
        try reloadAttachmentCleanupQueue()
        let orphanPaths = pendingAttachmentCleanupOrphanPaths
        var firstError: Error?
        for entry in pendingAttachmentCleanupEntries {
            guard let projectID = entry.projectID else { continue }
            do {
                try retryAttachmentCleanup(projectID: projectID, paths: entry.paths)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        if !orphanPaths.isEmpty {
            throw AttachmentCleanupQueueError.orphanCleanupRequiresConfirmation(orphanPaths)
        }
    }

    public func recoverAttachmentCleanupQueue(confirmed: Bool = true) throws {
        guard confirmed else { return }
        do {
            try reloadAttachmentCleanupQueue()
        } catch let error as AttachmentCleanupQueueError {
            switch error {
            case .invalidQueue, .legacyQueueNeedsReview:
                _ = try quarantineCorruptQueue()
            default:
                throw error
            }
        }
    }

    public func recoverLegacyOrphan(paths: [String], confirmed: Bool) throws {
        try reloadAttachmentCleanupQueue()
        let orphanPaths = Set(pendingAttachmentCleanupOrphanPaths)
        let selectedPaths = paths.filter { orphanPaths.contains($0) }
        guard confirmed else {
            throw AttachmentCleanupQueueError.orphanCleanupRequiresConfirmation(
                selectedPaths.isEmpty ? paths : selectedPaths
            )
        }
        guard !selectedPaths.isEmpty else {
            throw AttachmentCleanupQueueError.orphanCleanupRequiresConfirmation(paths)
        }

        var failedPaths: [String] = []
        var removedPaths: [String] = []
        for path in selectedPaths {
            do {
                try attachmentStore.removeAttachment(at: URL(fileURLWithPath: path))
                removedPaths.append(path)
            } catch {
                failedPaths.append(path)
            }
        }
        try cleanupQueue.removeOrphan(paths: removedPaths)
        refresh()
        if !failedPaths.isEmpty {
            throw AttachmentCleanupQueueError.orphanCleanupFailed(failedPaths)
        }
    }

    @discardableResult
    public func quarantineCorruptQueue() throws -> URL {
        do {
            let quarantineURL = try cleanupQueue.quarantineCorruptQueue()
            attachmentCleanupQueueQuarantineURL = quarantineURL
            try reloadAttachmentCleanupQueue()
            return quarantineURL
        } catch let error as AttachmentCleanupQueueError {
            attachmentCleanupQueueError = error
            throw error
        } catch {
            attachmentCleanupQueueError = .quarantineFailed
            throw AttachmentCleanupQueueError.quarantineFailed
        }
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
        captureNextStepProposal(after: plannedSessionId)
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
    public func generateCoursePlan(_ input: CoursePlanningInput) async throws -> LearningPlan {
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
    ) throws -> LearningPlan {
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

    /// Runs the deterministic weekly Capacity Check for an editable draft.
    /// The projection is read-only: it never creates completion, Trail, or
    /// calendar records. Callers may pass the calendar-configured rules when
    /// the wizard is open; otherwise persisted rules are used.
    public func capacityCheck(
        draft: CoursePlanDraft,
        input: CoursePlanningInput,
        availabilityRules: [AvailabilityRule]? = nil,
        calendar: Calendar = .current
    ) -> CapacityCheckResult {
        CapacityCheckService(calendar: calendar).check(
            draft: draft,
            input: input,
            practiceRoutines: snapshot.operationalPracticeRoutines,
            availabilityRules: availabilityRules
                ?? snapshot.availabilityRules.filter { $0.deletedAt == nil }
        )
    }

    /// Runs the same projection for a persisted Learning Plan revision.
    public func capacityCheck(
        for planID: UUID,
        availabilityRules: [AvailabilityRule]? = nil,
        calendar: Calendar = .current
    ) -> CapacityCheckResult {
        CapacityCheckService(calendar: calendar).check(
            snapshot: snapshot,
            planID: planID,
            availabilityRules: availabilityRules
        )
    }

    @discardableResult
    public func activateCoursePlan(
        draftPlanID: UUID,
        expectation: RevisionGuardExpectation,
        capacityAcknowledged: Bool = false
    ) throws -> CanonicalNextStepProposal? {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        let proposal = try coursePlanningService.activate(
            draftPlanID: draftPlanID,
            expectation: expectation,
            capacityAcknowledged: capacityAcknowledged
        )
        pendingCanonicalNextStepProposal = proposal
        if draftCoursePlan?.id == draftPlanID {
            draftCoursePlan = nil
        }
        coursePlanGenerationState = .idle
        refresh()
        return proposal
    }

    /// Compatibility entry point for legacy callers. The real adjustment UI
    /// captures and passes the expectation explicitly; this overload captures
    /// it immediately before activation for older integrations.
    @discardableResult
    public func activateCoursePlan(
        draftPlanID: UUID,
        capacityAcknowledged: Bool = false
    ) throws -> CanonicalNextStepProposal? {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        let expectation = try coursePlanningService.revisionGuardExpectation(for: draftPlanID)
        return try activateCoursePlan(
            draftPlanID: draftPlanID,
            expectation: expectation,
            capacityAcknowledged: capacityAcknowledged
        )
    }

    public func revisionGuardExpectation(for planID: UUID) throws -> RevisionGuardExpectation {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        return try coursePlanningService.revisionGuardExpectation(for: planID)
    }

    @discardableResult
    public func confirmCanonicalNextStep(
        _ proposal: CanonicalNextStepProposal,
        title: String? = nil
    ) throws -> Project {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        let project = try coursePlanningService.confirmNextStep(proposal, title: title)
        if pendingCanonicalNextStepProposal == proposal {
            pendingCanonicalNextStepProposal = nil
        }
        refresh()
        return project
    }

    @discardableResult
    public func reviseCoursePlan(
        planID: UUID,
        input: CoursePlanningInput,
        draft: CoursePlanDraft
    ) throws -> LearningPlan {
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
        captureNextStepProposal(after: plannedSessionId)
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
        fileSize: Int? = nil,
        artifactBody: String? = nil
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
            fileSize: fileSize,
            artifactBody: artifactBody
        )
        tryCompleteOnboarding(afterRecording: projectId)
        refresh()
        return proof
    }

    @discardableResult
    public func reviseProof(
        proofId: UUID,
        title: String,
        statement: String,
        artifactBody: String? = nil
    ) throws -> Proof {
        let proof = try journalService.reviseProof(
            proofId: proofId,
            title: title,
            statement: statement,
            artifactBody: artifactBody
        )
        refresh()
        return proof
    }

    public func proofRevisions(for proofId: UUID) -> [ProofRevision] {
        snapshot.proofRevisions
            .filter { $0.proofId == proofId && $0.deletedAt == nil }
            .sorted { $0.revision > $1.revision }
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
            projectId: syncedRoutine?.projectId,
            planRevisionID: syncedRoutine?.planRevisionID,
            planSeriesID: syncedRoutine?.planSeriesID,
            isStructuralLocked: syncedRoutine?.isStructuralLocked ?? false,
            name: presentation?.name ?? syncedRoutine?.name ?? "Practice",
            symbolName: presentation?.symbolName ?? syncedRoutine?.symbolName ?? "timer",
            color: presentation?.color ?? syncedRoutine?.color ?? .teal,
            targetMinutes: max(1, (timerSnapshot.targetSeconds + 59) / 60),
            weekdays: Set(1...7),
            blocks: syncedRoutine?.orderedBlocks ?? timerSnapshot.blocks.map { block in
                PracticeBlock(
                    id: block.id,
                    name: block.name,
                    targetMinutes: max(1, block.targetMinutes),
                    ordinal: block.ordinal,
                    focus: block.focus,
                    nextFocusCandidates: block.nextFocusCandidates
                )
            },
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
        reminderTime: PracticeReminderTime? = nil,
        blocks: [PracticeBlock] = []
    ) throws -> PracticeRoutine {
        let projects = snapshot.projects.filter { $0.deletedAt == nil && !$0.isTrashed }
        guard projects.count == 1 else { throw PracticeValidationError.missingProject }
        return try createPracticeRoutine(
            projectId: projects[0].id,
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            reminderTime: reminderTime,
            blocks: blocks
        )
    }

    @discardableResult
    public func createPracticeRoutine(
        projectId: UUID,
        name: String,
        symbolName: String,
        color: PracticeSemanticColor,
        targetMinutes: Int,
        weekdays: Set<Int>,
        reminderTime: PracticeReminderTime? = nil,
        blocks: [PracticeBlock] = []
    ) throws -> PracticeRoutine {
        let routine = try practiceService.createRoutine(
            projectId: projectId,
            name: name,
            symbolName: symbolName,
            color: color,
            targetMinutes: targetMinutes,
            weekdays: weekdays,
            reminderTime: reminderTime,
            blocks: blocks
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
        reminderTime: PracticeReminderTime? = nil,
        blocks: [PracticeBlock]? = nil
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
            reminderTime: reminderTime,
            blocks: blocks
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
        if routine.orderedBlocks.isEmpty {
            try practiceTimer.start(
                routineId: routine.id,
                targetSeconds: routine.targetMinutes * 60,
                routinePresentation: PracticeRoutinePresentationSnapshot(routine: routine)
            )
        } else {
            try practiceTimer.start(
                routine: routine,
                routinePresentation: PracticeRoutinePresentationSnapshot(routine: routine)
            )
        }
    }

    @discardableResult
    public func persistPracticeCompletionBase(
        _ completion: PracticeTimerCompletion,
        linkedProjectId: UUID?
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
            segments: completion.segments,
            summary: completion.summary,
            note: nil
        )
        refresh()
        return result
    }

    @discardableResult
    public func savePracticeCompletion(
        _ completion: PracticeTimerCompletion,
        linkedProjectId: UUID?,
        note: String?,
        attentionMarker: String? = nil
    ) throws -> PracticeSessionSaveResult {
        let pending = practiceTimer.pendingCompletion
        let pendingMatchesCompletion = pending?.completion == completion
        let summary = if let attentionMarker, !completion.blocks.isEmpty {
            PracticeSummary.from(
                blocks: completion.blocks,
                segments: completion.segments,
                attentionMarker: attentionMarker
            )
        } else {
            completion.summary
        }
        let persistedPending = pendingMatchesCompletion && practiceSessions.contains {
            $0.id == pending!.id && $0.deletedAt == nil
        }
        let result: PracticeSessionSaveResult
        if persistedPending {
            result = try practiceService.updateSessionReflection(
                sessionId: pending!.id,
                routineId: completion.routineId,
                recoverDeletedRoutine: pending?.routinePresentation?.routineId == completion.routineId,
                linkedProjectId: linkedProjectId,
                startedAt: completion.startedAt,
                endedAt: completion.endedAt,
                activeDurationSeconds: completion.activeDurationSeconds,
                segments: completion.segments,
                summary: summary,
                note: note
            )
        } else {
            result = try practiceService.saveSession(
                sessionId: pendingMatchesCompletion ? pending!.id : UUID(),
                routineId: completion.routineId,
                recoverDeletedRoutine: pendingMatchesCompletion
                    && pending?.routinePresentation?.routineId == completion.routineId,
                linkedProjectId: linkedProjectId,
                startedAt: completion.startedAt,
                endedAt: completion.endedAt,
                activeDurationSeconds: completion.activeDurationSeconds,
                segments: completion.segments,
                summary: summary,
                note: note
            )
        }
        refresh()
        if pendingMatchesCompletion, !practiceTimer.clearPendingCompletion() {
            throw PracticeTimerRuntimeError.pendingCompletionCouldNotClear
        }
        return result
    }

    /// Finishes a guided session by persisting its base outcome first. Optional
    /// reflection is then applied as a guarded update to that same session.
    @discardableResult
    public func finishAndSavePractice(
        linkedProjectId: UUID? = nil,
        note: String? = nil,
        attentionMarker: String? = nil
    ) throws -> PracticeSessionSaveResult? {
        guard let completion = practiceTimer.finish() else { return nil }
        let base = try persistPracticeCompletionBase(
            completion,
            linkedProjectId: linkedProjectId
        )
        if note != nil || attentionMarker != nil {
            return try savePracticeCompletion(
                completion,
                linkedProjectId: linkedProjectId,
                note: note,
                attentionMarker: attentionMarker
            )
        }
        guard practiceTimer.clearPendingCompletion() else {
            throw PracticeTimerRuntimeError.pendingCompletionCouldNotClear
        }
        return base
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

    public func learningPlans(for projectId: UUID) -> [LearningPlan] {
        snapshot.coursePlans
            .filter { $0.projectId == projectId }
            .sorted { $0.revision > $1.revision }
    }

    public func coursePlans(for projectId: UUID) -> [CoursePlan] {
        learningPlans(for: projectId)
    }

    public func learningPlanAggregates(for projectId: UUID) -> [LearningPlanAggregate] {
        snapshot.learningPlanAggregates(for: projectId)
    }

    public func activeLearningPlan(for projectId: UUID) -> LearningPlan? {
        if let aggregatePlan = snapshot.learningPlanAggregates(for: projectId)
            .compactMap(\.activeRevision)
            .first?.plan {
            return aggregatePlan
        }
        guard let activeID = snapshot.projects.first(where: { $0.id == projectId })?.activeCoursePlanId else {
            return nil
        }
        return snapshot.coursePlans.first { $0.id == activeID }
    }

    public func activeCoursePlan(for projectId: UUID) -> CoursePlan? {
        activeLearningPlan(for: projectId)
    }

    public func supersededLearningPlans(for projectId: UUID) -> [LearningPlan] {
        snapshot.learningPlanAggregates(for: projectId)
            .flatMap(\.supersededRevisions)
            .map(\.plan)
            .sorted { $0.revision > $1.revision }
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

    @discardableResult
    public func reschedulePlannedSession(
        _ id: UUID,
        newDeadline: Date,
        capacityAcknowledged: Bool = false,
        calendar: Calendar = .current
    ) throws -> PlannedSession {
        guard let coursePlanningService else {
            throw CoursePlanningError.providerUnavailable
        }
        if let session = snapshot.plannedSessions.first(where: { $0.id == id }),
           let plan = snapshot.coursePlans.first(where: { $0.id == session.planId }) {
            var candidate = session
            candidate.deadline = newDeadline
            var candidateSessions = snapshot.plannedSessions.filter { $0.planId == plan.id }
            if let index = candidateSessions.firstIndex(where: { $0.id == id }) {
                candidateSessions[index] = candidate
            }
            let result = CapacityCheckService(calendar: calendar).check(
                plan: plan,
                phases: snapshot.planPhases.filter { $0.planId == plan.id },
                sessions: candidateSessions,
                practiceRoutines: snapshot.operationalPracticeRoutines,
                availabilityRules: snapshot.availabilityRules.filter { $0.deletedAt == nil }
            )
            guard capacityAcknowledged || !result.requiresAcknowledgement else {
                throw CoursePlanningError.capacityAcknowledgementRequired
            }
        }
        let session = try coursePlanningService.reschedule(
            plannedSessionID: id,
            newDeadline: newDeadline,
            capacityAcknowledged: capacityAcknowledged
        )
        refresh()
        return session
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
        loadAttachmentCleanupQueue()
        refreshSyncRepositoryDetails()
        scheduleAutomaticSyncIfNeeded()
    }

    private func reloadAttachmentCleanupQueue() throws {
        do {
            pendingAttachmentCleanupEntries = try cleanupQueue.load()
            attachmentCleanupQueueError = nil
        } catch let error as AttachmentCleanupQueueError {
            pendingAttachmentCleanupEntries = []
            attachmentCleanupQueueError = error
            throw error
        } catch {
            pendingAttachmentCleanupEntries = []
            attachmentCleanupQueueError = .invalidQueue
            throw AttachmentCleanupQueueError.invalidQueue
        }
    }

    private func loadAttachmentCleanupQueue() {
        do {
            try reloadAttachmentCleanupQueue()
        } catch {
            // The published error is the recovery surface; never hide a queue
            // that may still contain paths requiring an explicit repair.
        }
    }

    private func refreshSyncRepositoryDetails() {
        guard let syncRepository else {
            syncConflicts = []
            syncTerminalMutations = []
            syncPendingMutationCount = 0
            return
        }
        syncConflicts = (try? syncRepository.conflicts()) ?? []
        syncTerminalMutations = (try? syncRepository.terminalMutations(limit: 1_000)) ?? []
        syncPendingMutationCount = (try? syncRepository.pendingMutations(limit: 1_000).count) ?? 0
    }

    private func scheduleAutomaticSyncIfNeeded() {
        guard automaticSyncTask == nil,
              syncPendingMutationCount > 0,
              let syncCoordinator else { return }

        automaticSyncTask = Task { @MainActor [weak self, syncCoordinator] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            await syncCoordinator.start()
            self.journalService.refreshFromRepository()
            self.snapshot = self.journalService.snapshot()
            self.refreshSyncRepositoryDetails()
            let status = await syncCoordinator.status
            await self.refreshSyncSummary()
            self.automaticSyncTask = nil

            if case .synced = status {
                self.scheduleAutomaticSyncIfNeeded()
            }
        }
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
        case .evidenceContract:
            return .evidenceContract(try JSONDecoder.journal.decode(EvidenceContract.self, from: payload))
        case .evidenceAcceptance:
            return .evidenceAcceptance(try JSONDecoder.journal.decode(EvidenceAcceptance.self, from: payload))
        case .proofRevision:
            return .proofRevision(try JSONDecoder.journal.decode(ProofRevision.self, from: payload))
        case .reviewDecision:
            return .reviewDecision(try JSONDecoder.journal.decode(ReviewDecision.self, from: payload))
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

    private func captureNextStepProposal(after plannedSessionId: UUID?) {
        guard let plannedSessionId, let coursePlanningService else { return }
        pendingCanonicalNextStepProposal = try? coursePlanningService.nextStepProposal(
            after: plannedSessionId
        )
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
