import Foundation

public final class CoursePlanningService {
    private let repository: any JournalRepository
    private let validator: CoursePlanValidator
    private let provider: any CoursePlanningProvider
    private let now: () -> Date

    public init(
        repository: any JournalRepository,
        validator: CoursePlanValidator = CoursePlanValidator(),
        provider: any CoursePlanningProvider = AdaptiveCoursePlanningProvider(),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.validator = validator
        self.provider = provider
        self.now = now
    }

    @discardableResult
    @MainActor
    public func generateDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlan {
        let draft = try await provider.makeDraft(input: input, context: context)
        return try saveDraft(input: input, draft: draft)
    }

    @discardableResult
    public func saveDraft(
        input: CoursePlanningInput,
        draft: CoursePlanDraft
    ) throws -> CoursePlan {
        let validation = validator.validate(draft, input: input)
        guard validation.isValid else {
            throw validation.errors.first ?? CoursePlanningValidationError.emptyTitle
        }

        let snapshot = try repository.snapshot()
        guard snapshot.projects.contains(where: { $0.id == input.projectId }) else {
            throw JournalValidationError.missingProject
        }
        let createdAt = now()
        let revision = (snapshot.coursePlans
            .filter { $0.projectId == input.projectId }
            .map(\.revision)
            .max() ?? 0) + 1
        let plan = try CoursePlan(
            projectId: input.projectId,
            revision: revision,
            status: .draft,
            courseURL: input.courseURL,
            courseTitle: draft.title,
            courseOutline: input.courseOutline,
            goal: input.goal,
            expectedOutcome: input.expectedOutcome,
            startsOn: input.startsOn,
            deadline: input.deadline,
            weeklyBudgetMinutes: input.weeklyBudgetMinutes,
            summary: draft.summary,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        var phaseIDs: [String: UUID] = [:]
        var phases: [PlanPhase] = []
        for draftPhase in draft.phases.sorted(by: { $0.ordinal < $1.ordinal }) {
            let phase = try PlanPhase(
                planId: plan.id,
                title: draftPhase.title,
                objective: draftPhase.objective,
                expectedProof: draftPhase.expectedProof,
                ordinal: draftPhase.ordinal,
                targetStart: draftPhase.targetStart,
                targetEnd: draftPhase.targetEnd,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            phaseIDs[draftPhase.id] = phase.id
            phases.append(phase)
        }
        let plannedSessions = try draft.sessions.map { draftSession -> PlannedSession in
            guard let phaseID = phaseIDs[draftSession.phaseID] else {
                throw CoursePlanningValidationError.unknownPhaseReference(draftSession.phaseID)
            }
            return try PlannedSession(
                planId: plan.id,
                phaseId: phaseID,
                projectId: input.projectId,
                title: draftSession.title,
                actionType: draftSession.actionType,
                expectedProof: draftSession.expectedProof,
                durationMinutes: draftSession.durationMinutes,
                deadline: draftSession.deadline,
                createdAt: createdAt,
                updatedAt: createdAt
            )
        }

        try repository.commit(
            JournalTransaction(
                upserts: [.coursePlan(plan)]
                    + phases.map(JournalEntity.planPhase)
                    + plannedSessions.map(JournalEntity.plannedSession),
                origin: .user
            )
        )
        return plan
    }

    @discardableResult
    public func activate(draftPlanID: UUID) throws -> CanonicalNextStepProposal? {
        let snapshot = try repository.snapshot()
        guard let planIndex = snapshot.coursePlans.firstIndex(where: { $0.id == draftPlanID }) else {
            throw JournalValidationError.missingProject
        }
        guard let projectIndex = snapshot.projects.firstIndex(where: { $0.id == snapshot.coursePlans[planIndex].projectId }) else {
            throw JournalValidationError.missingProject
        }
        let activatedAt = now()
        var activatedPlan = snapshot.coursePlans[planIndex]
        activatedPlan.status = .active
        activatedPlan.activatedAt = activatedAt
        activatedPlan.updatedAt = activatedAt

        var project = snapshot.projects[projectIndex]
        let phases = snapshot.planPhases.filter { $0.planId == activatedPlan.id }
        let phaseOrder = Dictionary(uniqueKeysWithValues: phases.map { ($0.id, $0.ordinal) })
        let nextSession = snapshot.plannedSessions
            .filter { $0.planId == activatedPlan.id && $0.status == .unscheduled }
            .sorted {
                (phaseOrder[$0.phaseId] ?? .max, $0.createdAt) < (phaseOrder[$1.phaseId] ?? .max, $1.createdAt)
            }
            .first
        project.activeCoursePlanId = activatedPlan.id
        project.updatedAt = activatedAt

        var upserts: [JournalEntity] = [.coursePlan(activatedPlan), .project(project)]
        if let currentActive = snapshot.coursePlans.first(where: {
            $0.projectId == project.id && $0.status == .active && $0.id != activatedPlan.id
        }) {
            var archived = currentActive
            archived.status = .archived
            archived.updatedAt = activatedAt
            upserts.append(.coursePlan(archived))
        }
        let trailEvent = TrailEvent(
            projectId: project.id,
            type: .planActivated,
            sourceId: activatedPlan.id,
            occurredAt: activatedAt,
            title: "Course plan activated",
            detail: activatedPlan.courseTitle
        )
        upserts.append(.trailEvent(trailEvent))
        try repository.commit(JournalTransaction(upserts: upserts, origin: .user))
        return nextSession.map {
            CanonicalNextStepProposal(
                projectId: project.id,
                plannedSessionId: $0.id,
                title: $0.title,
                reason: "First session in the activated course plan"
            )
        }
    }

    @discardableResult
    public func revise(
        planID: UUID,
        input: CoursePlanningInput,
        draft: CoursePlanDraft
    ) throws -> CoursePlan {
        guard try repository.snapshot().coursePlans.contains(where: { $0.id == planID }) else {
            throw JournalValidationError.missingProject
        }
        return try saveDraft(input: input, draft: draft)
    }

    public func unschedule(plannedSessionID: UUID) throws {
        let snapshot = try repository.snapshot()
        guard let index = snapshot.plannedSessions.firstIndex(where: { $0.id == plannedSessionID }) else {
            throw JournalValidationError.missingProject
        }
        var session = snapshot.plannedSessions[index]
        guard session.status != .completed else { return }
        session.status = .unscheduled
        session.updatedAt = now()
        try repository.commit(JournalTransaction(upserts: [.plannedSession(session)], origin: .user))
    }

    public func skip(plannedSessionID: UUID) throws {
        let snapshot = try repository.snapshot()
        guard let index = snapshot.plannedSessions.firstIndex(where: { $0.id == plannedSessionID }) else {
            throw JournalValidationError.missingPlannedSession
        }
        var session = snapshot.plannedSessions[index]
        guard session.status != .completed else { return }
        session.status = .skipped
        session.updatedAt = now()
        let trailEvent = TrailEvent(
            projectId: session.projectId,
            type: .scheduleChanged,
            sourceId: session.id,
            occurredAt: session.updatedAt,
            title: "Planned session skipped",
            detail: session.title
        )
        try repository.commit(
            JournalTransaction(
                upserts: [.plannedSession(session), .trailEvent(trailEvent)],
                origin: .user
            )
        )
    }

    @discardableResult
    public func complete(
        plannedSessionID: UUID,
        with sessionID: UUID
    ) throws -> CanonicalNextStepProposal? {
        let snapshot = try repository.snapshot()
        guard let index = snapshot.plannedSessions.firstIndex(where: { $0.id == plannedSessionID }) else {
            throw JournalValidationError.missingProject
        }
        var session = snapshot.plannedSessions[index]
        session.status = .completed
        session.completedSessionId = sessionID
        session.updatedAt = now()
        try repository.commit(JournalTransaction(upserts: [.plannedSession(session)], origin: .user))
        var sessions = snapshot.plannedSessions
        sessions[index] = session
        return nextStepProposal(
            projectID: session.projectId,
            planID: session.planId,
            sessions: sessions,
            phases: snapshot.planPhases,
            reason: "Next incomplete session after completing \(session.title)"
        )
    }

    public func nextStepProposal(after plannedSessionID: UUID) throws -> CanonicalNextStepProposal? {
        let snapshot = try repository.snapshot()
        guard let completed = snapshot.plannedSessions.first(where: { $0.id == plannedSessionID }) else {
            throw JournalValidationError.missingPlannedSession
        }
        return nextStepProposal(
            projectID: completed.projectId,
            planID: completed.planId,
            sessions: snapshot.plannedSessions,
            phases: snapshot.planPhases,
            reason: "Next incomplete session after completing \(completed.title)"
        )
    }

    @discardableResult
    public func confirmNextStep(
        _ proposal: CanonicalNextStepProposal,
        title: String? = nil
    ) throws -> Project {
        let snapshot = try repository.snapshot()
        guard let projectIndex = snapshot.projects.firstIndex(where: { $0.id == proposal.projectId }),
              snapshot.plannedSessions.contains(where: {
                  $0.id == proposal.plannedSessionId && $0.projectId == proposal.projectId
              }) else {
            throw JournalValidationError.missingPlannedSession
        }
        let confirmedTitle = (title ?? proposal.title).trimmedForJournal
        guard !confirmedTitle.isEmpty else { throw JournalValidationError.emptyNextStep }
        var project = snapshot.projects[projectIndex]
        project.currentNextStep = confirmedTitle
        project.updatedAt = now()
        let event = TrailEvent(
            projectId: project.id,
            type: .nextStepChange,
            sourceId: proposal.plannedSessionId,
            occurredAt: project.updatedAt,
            title: "Next Step confirmed",
            detail: confirmedTitle
        )
        try repository.commit(
            JournalTransaction(upserts: [.project(project), .trailEvent(event)], origin: .user)
        )
        return project
    }

    private func nextStepProposal(
        projectID: UUID,
        planID: UUID,
        sessions: [PlannedSession],
        phases: [PlanPhase],
        reason: String
    ) -> CanonicalNextStepProposal? {
        let phaseOrder = Dictionary(uniqueKeysWithValues: phases.map { ($0.id, $0.ordinal) })
        let next = sessions
            .filter {
                $0.planId == planID
                    && $0.projectId == projectID
                    && ($0.status == .unscheduled || $0.status == .scheduled)
            }
            .sorted {
                let lhs = (phaseOrder[$0.phaseId] ?? .max, $0.deadline ?? .distantFuture, $0.createdAt, $0.title, $0.id.uuidString)
                let rhs = (phaseOrder[$1.phaseId] ?? .max, $1.deadline ?? .distantFuture, $1.createdAt, $1.title, $1.id.uuidString)
                return lhs < rhs
            }
            .first
        return next.map {
            CanonicalNextStepProposal(
                projectId: projectID,
                plannedSessionId: $0.id,
                title: $0.title,
                reason: reason
            )
        }
    }
}
