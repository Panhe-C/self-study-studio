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

    private let journalService: JournalService
    private let reviewService: ReviewService
    private let exportService: ExportService
    private let attachmentStore: AttachmentStore
    private let syncCoordinator: (any CloudSyncCoordinating)?
    private let syncRepository: (any JournalRepository)?
    private let accountCoordinator: CloudAccountCoordinator?

    public init(
        journalService: JournalService,
        reviewService: ReviewService,
        exportService: ExportService,
        attachmentStore: AttachmentStore = .defaultStore(),
        syncCoordinator: (any CloudSyncCoordinating)? = nil,
        syncRepository: (any JournalRepository)? = nil,
        accountCoordinator: CloudAccountCoordinator? = nil
    ) {
        self.journalService = journalService
        self.reviewService = reviewService
        self.exportService = exportService
        self.attachmentStore = attachmentStore
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
        nextStep: String? = nil
    ) throws -> LearningSession {
        let session = try journalService.quickLog(
            projectId: projectId,
            actionType: actionType,
            durationMinutes: durationMinutes,
            note: note,
            nextStep: nextStep
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
        nextStep: String? = nil
    ) throws -> LearningSession {
        let session = try journalService.saveTimerSession(
            projectId: projectId,
            actionType: actionType,
            startedAt: startedAt,
            endedAt: endedAt,
            note: note,
            nextStep: nextStep
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

    public func reviewsForProject(_ projectId: UUID) -> [Review] {
        snapshot.reviews.filter { review in
            review.nextSteps.keys.contains(projectId)
                || review.projectRecommendations.keys.contains(projectId)
        }
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
        }
    }

    private func tryCompleteOnboarding(afterRecording projectId: UUID) {
        guard snapshot.pendingFirstRecordProjectId == projectId else { return }
        try? journalService.completeOnboarding()
    }
}

public enum SyncConflictResolutionError: Error, Equatable, Sendable {
    case mismatchedEntity
}
