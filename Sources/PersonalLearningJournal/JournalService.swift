import Foundation

public final class JournalService {
    private let repository: any JournalRepository
    private let now: () -> Date
    private var state: JournalSnapshot

    public init(
        repository: any JournalRepository,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
        self.state = (try? repository.snapshot()) ?? JournalSnapshot()
    }

    public convenience init(
        store: any JournalStore,
        now: @escaping () -> Date = Date.init
    ) {
        let snapshot = (try? store.load()) ?? JournalSnapshot()
        self.init(repository: InMemoryJournalRepository(snapshot: snapshot), now: now)
    }

    public func snapshot() -> JournalSnapshot {
        state
    }

    public func refreshFromRepository() {
        state = (try? repository.snapshot()) ?? state
    }

    public func project(id: UUID) -> Project? {
        state.projects.first { $0.id == id }
    }

    public func session(id: UUID) -> LearningSession? {
        state.sessions.first { $0.id == id }
    }

    public func sessions(projectId: UUID) -> [LearningSession] {
        state.sessions.filter { $0.projectId == projectId }
    }

    public func proofs(projectId: UUID) -> [Proof] {
        state.proofs.filter { $0.projectId == projectId }
    }

    public func proofs(sessionId: UUID) -> [Proof] {
        state.proofs.filter { $0.sessionId == sessionId }
    }

    @discardableResult
    public func createOnboardingProjects(
        _ drafts: [ProjectOnboardingDraft]
    ) throws -> [Project] {
        let limitedDrafts = Array(drafts.prefix(3))
        guard !limitedDrafts.isEmpty else { throw JournalValidationError.emptyName }

        for draft in limitedDrafts {
            guard !draft.name.trimmedForJournal.isEmpty else { throw JournalValidationError.emptyName }
            guard !draft.goal.trimmedForJournal.isEmpty else { throw JournalValidationError.emptyGoal }
            guard !draft.nextStep.trimmedForJournal.isEmpty else { throw JournalValidationError.emptyNextStep }
        }

        let createdAt = now()
        let projects = limitedDrafts.map { draft in
            Project(
                name: draft.name.trimmedForJournal,
                area: draft.area.trimmedForJournal,
                goal: draft.goal.trimmedForJournal,
                currentNextStep: draft.nextStep.trimmedForJournal,
                createdAt: createdAt,
                updatedAt: createdAt
            )
        }

        var nextState = state
        nextState.projects.append(contentsOf: projects)
        nextState.hasCompletedOnboarding = false
        nextState.pendingFirstRecordProjectId = projects.first?.id
        try persist(
            upserts: projects.map(JournalEntity.project),
            stateMetadata: JournalStateMetadata(snapshot: nextState)
        )
        state = nextState
        return projects
    }

    public func completeOnboarding() throws {
        guard let projectId = state.pendingFirstRecordProjectId else {
            throw JournalValidationError.missingFirstRecord
        }
        let hasFirstRecord = state.sessions.contains { $0.projectId == projectId }
            || state.proofs.contains { $0.projectId == projectId }
        guard hasFirstRecord else { throw JournalValidationError.missingFirstRecord }

        var nextState = state
        nextState.hasCompletedOnboarding = true
        nextState.pendingFirstRecordProjectId = nil
        try persist(stateMetadata: JournalStateMetadata(snapshot: nextState))
        state = nextState
    }

    @discardableResult
    public func createProject(
        name: String,
        area: String,
        goal: String,
        nextStep: String,
        defaultDurationMinutes: Int = 30
    ) throws -> Project {
        let createdAt = now()
        guard !name.trimmedForJournal.isEmpty else { throw JournalValidationError.emptyName }
        guard !goal.trimmedForJournal.isEmpty else { throw JournalValidationError.emptyGoal }

        let project = Project(
            name: name.trimmedForJournal,
            area: area.trimmedForJournal,
            goal: goal.trimmedForJournal,
            currentNextStep: nextStep.trimmedForJournal,
            defaultDurationMinutes: defaultDurationMinutes,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        state.projects.append(project)
        try persist(upserts: [.project(project)])
        return project
    }

    @discardableResult
    public func updateProject(
        projectId: UUID,
        name: String,
        area: String,
        goal: String,
        nextStep: String
    ) throws -> Project {
        guard let index = state.projects.firstIndex(where: { $0.id == projectId }) else {
            throw JournalValidationError.missingProject
        }
        guard !name.trimmedForJournal.isEmpty else { throw JournalValidationError.emptyName }
        guard !goal.trimmedForJournal.isEmpty else { throw JournalValidationError.emptyGoal }

        let updatedAt = now()
        let trailStartIndex = state.trailEvents.count
        let previousNextStep = state.projects[index].currentNextStep
        state.projects[index].name = name.trimmedForJournal
        state.projects[index].area = area.trimmedForJournal
        state.projects[index].goal = goal.trimmedForJournal
        state.projects[index].currentNextStep = nextStep.trimmedForJournal
        state.projects[index].updatedAt = updatedAt

        appendNextStepChangeIfNeeded(
            projectId: projectId,
            sourceId: projectId,
            previous: previousNextStep,
            next: nextStep.trimmedForJournal,
            occurredAt: updatedAt
        )

        try persist(
            upserts: [.project(state.projects[index])]
                + state.trailEvents[trailStartIndex...].map(JournalEntity.trailEvent)
        )
        return state.projects[index]
    }

    public func todayContinueProjects(limit: Int = 3) -> [Project] {
        let sessionsByProject = Dictionary(grouping: state.sessions, by: \.projectId)
        let proofsByProject = Dictionary(grouping: state.proofs, by: \.projectId)

        return state.projects
            .filter(\.canContinue)
            .sorted { left, right in
                let leftDate = latestActivityDate(
                    project: left,
                    sessions: sessionsByProject[left.id, default: []],
                    proofs: proofsByProject[left.id, default: []]
                )
                let rightDate = latestActivityDate(
                    project: right,
                    sessions: sessionsByProject[right.id, default: []],
                    proofs: proofsByProject[right.id, default: []]
                )

                if leftDate == rightDate {
                    return left.createdAt < right.createdAt
                }

                return leftDate > rightDate
            }
            .prefix(limit)
            .map { $0 }
    }

    public func projectsNeedingReview(
        referenceDate: Date = Date(),
        idleDays: Int = 7
    ) -> [Project] {
        let idleInterval = TimeInterval(idleDays * 24 * 60 * 60)

        return state.projects
            .filter { $0.status == .active }
            .filter { project in
                let lastSessionDate = state.sessions
                    .filter { $0.projectId == project.id }
                    .map(\.endedAt)
                    .max()
                let lastProofDate = state.proofs
                    .filter { $0.projectId == project.id }
                    .map(\.createdAt)
                    .max()
                let lastActivityDate = [
                    project.updatedAt,
                    lastSessionDate,
                    lastProofDate
                ].compactMap { $0 }.max() ?? project.createdAt

                return referenceDate.timeIntervalSince(lastActivityDate) >= idleInterval
            }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    public func shouldShowReviewPrompt(
        referenceDate: Date = Date(),
        evidenceThreshold: Int = 3
    ) -> Bool {
        if !projectsNeedingReview(referenceDate: referenceDate).isEmpty {
            return true
        }

        let periodStart = Calendar.current.date(
            byAdding: .day,
            value: -7,
            to: referenceDate
        ) ?? referenceDate.addingTimeInterval(-7 * 24 * 60 * 60)
        let latestReviewDate = state.reviews.map(\.createdAt).max()

        let recentSessions = state.sessions.filter {
            $0.endedAt >= periodStart
                && $0.endedAt <= referenceDate
                && (latestReviewDate == nil || $0.endedAt > latestReviewDate!)
        }
        let recentProofs = state.proofs.filter {
            $0.createdAt >= periodStart
                && $0.createdAt <= referenceDate
                && (latestReviewDate == nil || $0.createdAt > latestReviewDate!)
        }

        return recentSessions.count + recentProofs.count >= evidenceThreshold
    }

    @discardableResult
    public func quickLog(
        projectId: UUID,
        actionType: ActionType? = nil,
        durationMinutes: Int,
        note: String,
        nextStep: String? = nil,
        plannedSessionId: UUID? = nil,
        endedAt: Date? = nil
    ) throws -> LearningSession {
        let finishedAt = endedAt ?? now()
        return try recordSession(
            projectId: projectId,
            source: .quickLog,
            actionType: actionType,
            durationMinutes: durationMinutes,
            note: note,
            nextStep: nextStep,
            plannedSessionId: plannedSessionId,
            startedAt: finishedAt.addingTimeInterval(TimeInterval(-durationMinutes * 60)),
            endedAt: finishedAt
        )
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
        let durationMinutes = Int(endedAt.timeIntervalSince(startedAt) / 60)
        guard durationMinutes > 0 else { throw JournalValidationError.invalidDuration }
        return try recordSession(
            projectId: projectId,
            source: .timer,
            actionType: actionType,
            durationMinutes: durationMinutes,
            note: note,
            nextStep: nextStep,
            plannedSessionId: plannedSessionId,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    @discardableResult
    private func recordSession(
        projectId: UUID,
        source: SessionSource,
        actionType: ActionType?,
        durationMinutes: Int,
        note: String,
        nextStep: String?,
        plannedSessionId: UUID?,
        startedAt: Date,
        endedAt: Date
    ) throws -> LearningSession {
        refreshFromRepository()
        guard let projectIndex = state.projects.firstIndex(where: { $0.id == projectId }) else {
            throw JournalValidationError.missingProject
        }
        let plannedSessionIndex = try plannedSessionId.map { id -> Int in
            guard let index = state.plannedSessions.firstIndex(where: { $0.id == id }),
                  state.plannedSessions[index].projectId == projectId else {
                throw JournalValidationError.missingPlannedSession
            }
            return index
        }

        let project = state.projects[projectIndex]
        let trailStartIndex = state.trailEvents.count
        let resolvedActionType = actionType ?? project.lastActionType
        let resolvedNextStep = nextStep?.trimmedForJournal.isEmpty == false
            ? nextStep!.trimmedForJournal
            : project.currentNextStep

        let session = try LearningSession(
            projectId: projectId,
            source: source,
            actionType: resolvedActionType,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMinutes: durationMinutes,
            note: note,
            nextStepBefore: project.currentNextStep,
            nextStepAfter: resolvedNextStep,
            createdAt: endedAt,
            updatedAt: endedAt
        )

        state.sessions.append(session)
        state.projects[projectIndex].lastActionType = resolvedActionType
        state.projects[projectIndex].defaultDurationMinutes = durationMinutes
        state.projects[projectIndex].currentNextStep = resolvedNextStep
        state.projects[projectIndex].updatedAt = endedAt

        appendTrailEvent(
            type: .session,
            projectId: projectId,
            sourceId: session.id,
            occurredAt: endedAt,
            title: "\(durationMinutes) min · \(resolvedActionType.rawValue)",
            detail: session.note
        )
        appendNextStepChangeIfNeeded(
            projectId: projectId,
            sourceId: session.id,
            previous: project.currentNextStep,
            next: resolvedNextStep,
            occurredAt: endedAt
        )

        var plannedSession: PlannedSession?
        if let plannedSessionIndex {
            var value = state.plannedSessions[plannedSessionIndex]
            value.status = .completed
            value.completedSessionId = session.id
            value.updatedAt = endedAt
            state.plannedSessions[plannedSessionIndex] = value
            plannedSession = value
        }

        var upserts: [JournalEntity] = [
            .project(state.projects[projectIndex]),
            .session(session)
        ]
        upserts.append(contentsOf: state.trailEvents[trailStartIndex...].map(JournalEntity.trailEvent))
        if let plannedSession {
            upserts.append(.plannedSession(plannedSession))
        }
        try persist(upserts: upserts)
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
        guard state.projects.contains(where: { $0.id == projectId }) else {
            throw JournalValidationError.missingProject
        }

        let createdAt = now()
        let trailStartIndex = state.trailEvents.count
        let proof = try Proof(
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
            createdAt: createdAt,
            updatedAt: createdAt
        )
        state.proofs.append(proof)
        appendTrailEvent(
            type: .proof,
            projectId: projectId,
            sourceId: proof.id,
            occurredAt: createdAt,
            title: proof.title,
            detail: proof.statement
        )
        try persist(
            upserts: [.proof(proof)]
                + state.trailEvents[trailStartIndex...].map(JournalEntity.trailEvent)
        )
        return proof
    }

    public func updateProjectStatus(projectId: UUID, status: ProjectStatus) throws {
        guard let index = state.projects.firstIndex(where: { $0.id == projectId }) else {
            throw JournalValidationError.missingProject
        }

        let changedAt = now()
        let trailStartIndex = state.trailEvents.count
        state.projects[index].status = status
        state.projects[index].updatedAt = changedAt
        state.projects[index].archivedAt = status == .archived ? changedAt : nil

        appendTrailEvent(
            type: .statusChange,
            projectId: projectId,
            sourceId: projectId,
            occurredAt: changedAt,
            title: "Status changed",
            detail: "Project status changed to \(status.rawValue)"
        )
        try persist(
            upserts: [.project(state.projects[index])]
                + state.trailEvents[trailStartIndex...].map(JournalEntity.trailEvent)
        )
    }

    public func applyReviewRecommendation(reviewId: UUID, projectId: UUID) throws {
        guard let review = state.reviews.first(where: { $0.id == reviewId }) else {
            throw JournalValidationError.missingReview
        }
        guard let status = review.projectRecommendations[projectId] else {
            throw JournalValidationError.missingReviewRecommendation
        }
        try updateProjectStatus(projectId: projectId, status: status)
    }

    public func trailEvents(projectId: UUID) -> [TrailEvent] {
        state.trailEvents.filter { $0.projectId == projectId }
    }

    public func recordReview(_ review: Review) throws {
        let trailStartIndex = state.trailEvents.count
        state.reviews.append(review)

        let referencedProjectIds = Set(
            Array(review.nextSteps.keys) + Array(review.projectRecommendations.keys)
        )
        for projectId in referencedProjectIds {
            appendTrailEvent(
                type: .review,
                projectId: projectId,
                sourceId: review.id,
                occurredAt: review.createdAt,
                title: "Weekly Review",
                detail: review.decisions.prefix(3).joined(separator: " ")
            )
        }

        try persist(
            upserts: [.review(review)]
                + state.trailEvents[trailStartIndex...].map(JournalEntity.trailEvent)
        )
    }

    @discardableResult
    public func updateReview(
        reviewId: UUID,
        facts: [String],
        patterns: [String],
        decisions: [String],
        nextSteps: [UUID: String]
    ) throws -> Review {
        guard let index = state.reviews.firstIndex(where: { $0.id == reviewId }) else {
            throw JournalValidationError.missingReview
        }

        state.reviews[index].facts = facts.cleanedReviewItems
        state.reviews[index].patterns = patterns.cleanedReviewItems
        state.reviews[index].decisions = decisions.cleanedReviewItems
        state.reviews[index].nextSteps = nextSteps.mapValues { $0.trimmedForJournal }
            .filter { !$0.value.isEmpty }
        state.reviews[index].updatedAt = now()

        try persist(upserts: [.review(state.reviews[index])])
        return state.reviews[index]
    }

    private func appendNextStepChangeIfNeeded(
        projectId: UUID,
        sourceId: UUID,
        previous: String,
        next: String,
        occurredAt: Date
    ) {
        guard previous != next else { return }
        appendTrailEvent(
            type: .nextStepChange,
            projectId: projectId,
            sourceId: sourceId,
            occurredAt: occurredAt,
            title: "Next Step updated",
            detail: "Next Step changed from \(previous) to \(next)"
        )
    }

    private func latestActivityDate(
        project: Project,
        sessions: [LearningSession],
        proofs: [Proof]
    ) -> Date {
        [
            project.updatedAt,
            sessions.map(\.endedAt).max(),
            proofs.map(\.createdAt).max()
        ].compactMap { $0 }.max() ?? project.createdAt
    }

    private func appendTrailEvent(
        type: TrailEventType,
        projectId: UUID,
        sourceId: UUID,
        occurredAt: Date,
        title: String,
        detail: String
    ) {
        state.trailEvents.append(
            TrailEvent(
                projectId: projectId,
                type: type,
                sourceId: sourceId,
                occurredAt: occurredAt,
                title: title,
                detail: detail
            )
        )
    }

    private func persist(
        upserts: [JournalEntity] = [],
        deletions: [JournalEntityReference] = [],
        stateMetadata: JournalStateMetadata? = nil
    ) throws {
        do {
            try repository.commit(
                JournalTransaction(
                    upserts: upserts,
                    deletions: deletions,
                    origin: .user,
                    stateMetadata: stateMetadata
                )
            )
        } catch {
            state = (try? repository.snapshot()) ?? state
            throw error
        }
    }
}

private extension Array where Element == String {
    var cleanedReviewItems: [String] {
        map(\.trimmedForJournal).filter { !$0.isEmpty }
    }
}
