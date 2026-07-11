import Foundation

public final class CoursePlanningService {
    private let repository: any JournalRepository
    private let validator: CoursePlanValidator
    private let now: () -> Date

    public init(
        repository: any JournalRepository,
        validator: CoursePlanValidator = CoursePlanValidator(),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.validator = validator
        self.now = now
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
    public func activate(draftPlanID: UUID) throws -> CoursePlan {
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
        if let nextSession {
            project.currentNextStep = nextSession.title
        }
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
        return activatedPlan
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

    public func complete(plannedSessionID: UUID, with sessionID: UUID) throws {
        let snapshot = try repository.snapshot()
        guard let index = snapshot.plannedSessions.firstIndex(where: { $0.id == plannedSessionID }) else {
            throw JournalValidationError.missingProject
        }
        var session = snapshot.plannedSessions[index]
        session.status = .completed
        session.completedSessionId = sessionID
        session.updatedAt = now()
        try repository.commit(JournalTransaction(upserts: [.plannedSession(session)], origin: .user))
    }
}
