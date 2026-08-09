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
        try saveDraft(input: input, draft: draft, basedOn: nil)
    }

    private func saveDraft(
        input: CoursePlanningInput,
        draft: CoursePlanDraft,
        basedOn basePlan: LearningPlan?
    ) throws -> LearningPlan {
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
            planSeriesID: basePlan?.planSeriesID,
            baseRevisionID: basePlan?.revisionID,
            supersedesID: basePlan?.revisionID,
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
                planRevisionID: plan.revisionID,
                planSeriesID: plan.planSeriesID,
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
                planRevisionID: plan.revisionID,
                planSeriesID: plan.planSeriesID,
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

        let revisionRoutines: [PracticeRoutine] = basePlan.map { base in
            snapshot.practiceRoutines
                .filter { $0.planRevisionID == base.revisionID }
                .map { routine in
                    var value = routine
                    value.id = UUID()
                    value.planRevisionID = plan.revisionID
                    value.planSeriesID = plan.planSeriesID
                    value.isStructuralLocked = false
                    value.createdAt = createdAt
                    value.updatedAt = createdAt
                    value.deletedAt = nil
                    return value
                }
        } ?? []

        let newRecordExpectations = Dictionary(uniqueKeysWithValues: (
            [plan.reference]
                + phases.map { JournalEntity.planPhase($0).reference }
                + plannedSessions.map { JournalEntity.plannedSession($0).reference }
                + revisionRoutines.map { JournalEntity.practiceRoutine($0).reference }
        ).map { ($0, RevisionGuardExpectation.newRecord()) })
        try repository.commit(
            JournalTransaction(
                upserts: [.coursePlan(plan)]
                    + phases.map(JournalEntity.planPhase)
                    + plannedSessions.map(JournalEntity.plannedSession)
                    + revisionRoutines.map(JournalEntity.practiceRoutine),
                origin: .user,
                transactionID: plan.planSeriesID,
                revisionExpectations: newRecordExpectations
            )
        )
        return plan
    }

    @discardableResult
    public func activate(
        draftPlanID: UUID,
        expectation: RevisionGuardExpectation
    ) throws -> CanonicalNextStepProposal? {
        let snapshot = try repository.snapshot()
        guard let planIndex = snapshot.coursePlans.firstIndex(where: { $0.id == draftPlanID }) else {
            throw JournalValidationError.missingProject
        }
        guard let projectIndex = snapshot.projects.firstIndex(where: { $0.id == snapshot.coursePlans[planIndex].projectId }) else {
            throw JournalValidationError.missingProject
        }
        let activatedAt = now()
        let existingPlan = snapshot.coursePlans[planIndex]

        try validateActivationExpectation(
            expectation,
            draftPlan: existingPlan,
            snapshot: snapshot
        )

        // Activation is idempotent. In particular, do not create another
        // outbox mutation or trail event when a retry observes the already
        // active revision.
        if existingPlan.status == .active {
            return nextStepProposal(
                projectID: existingPlan.projectId,
                planID: existingPlan.id,
                sessions: snapshot.plannedSessions,
                phases: snapshot.planPhases,
                reason: "First session in the activated learning plan"
            )
        }

        var activatedPlan = existingPlan
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

        let activatedPhases = phases.map { phase -> PlanPhase in
            var value = phase
            value.planRevisionID = activatedPlan.revisionID
            value.planSeriesID = activatedPlan.planSeriesID
            value.isStructuralLocked = true
            return value
        }
        let activatedSessions = snapshot.plannedSessions.filter { $0.planId == activatedPlan.id }.map { session -> PlannedSession in
            var value = session
            value.planRevisionID = activatedPlan.revisionID
            value.planSeriesID = activatedPlan.planSeriesID
            value.isStructuralLocked = true
            return value
        }
        let activatedRoutines = snapshot.practiceRoutines
            .filter { $0.planRevisionID == activatedPlan.revisionID }
            .map { routine -> PracticeRoutine in
                var value = routine
                value.planRevisionID = activatedPlan.revisionID
                value.planSeriesID = activatedPlan.planSeriesID
                value.isStructuralLocked = true
                return value
            }
        // The Project pointer, plan children, and Learning Trail event form
        // one causal transaction. The repository still preserves append-only
        // semantics for nonplanning entities across later user transactions.
        var upserts: [JournalEntity] = [.coursePlan(activatedPlan), .project(project)]
            + activatedPhases.map(JournalEntity.planPhase)
            + activatedSessions.map(JournalEntity.plannedSession)
            + activatedRoutines.map(JournalEntity.practiceRoutine)
        let activePlans = snapshot.coursePlans.filter {
            $0.projectId == project.id && $0.status == .active && $0.id != activatedPlan.id
        }
        if activePlans.count > 1 {
            throw CoursePlanningError.multipleActivePlans(project.id)
        }
        // A project may only have one active revision.  A draft that is not
        // linked to the current series is still archived as history when it
        // becomes canonical, but it is never marked as a superseding
        // revision; the supersedes/base relationship remains restricted to
        // matching series/base identities.
        for currentActive in activePlans {
            var archived = currentActive
            archived.status = .archived
            archived.updatedAt = activatedAt
            upserts.append(.coursePlan(archived))
            for phase in snapshot.planPhases where phase.planId == archived.id {
                var value = phase
                value.isStructuralLocked = true
                upserts.append(.planPhase(value))
            }
            for session in snapshot.plannedSessions where session.planId == archived.id {
                var value = session
                value.isStructuralLocked = true
                upserts.append(.plannedSession(value))
            }
            for routine in snapshot.practiceRoutines where routine.planRevisionID == archived.revisionID {
                var value = routine
                value.isStructuralLocked = true
                upserts.append(.practiceRoutine(value))
            }
        }
        let trailEvent = TrailEvent(
            projectId: project.id,
            type: .planActivated,
            sourceId: activatedPlan.id,
            occurredAt: activatedAt,
            title: "Learning plan activated",
            detail: activatedPlan.courseTitle
        )
        upserts.append(.trailEvent(trailEvent))
        // Keep the caller's captured target/base expectation intact. In
        // particular, a draft that was synced before activation carries an
        // existing-target guard; replacing it with a freshly inferred base
        // guard would allow activation to overwrite a newer draft payload.
        var expectations: [JournalEntityReference: RevisionGuardExpectation] = [
            activatedPlan.reference: expectation
        ]
        for currentActive in activePlans {
            let currentMetadata = try repository.metadata(for: currentActive.reference)
            expectations[currentActive.reference] = if currentMetadata != nil {
                .existingTarget(
                    revisionID: currentActive.revisionID,
                    recordChangeTag: currentMetadata?.recordChangeTag
                )
            } else {
                // No metadata means the old active revision has not reached
                // CloudKit yet; it remains a new target in this offline
                // dependency chain. A server-side record, if any, will fail
                // the new-record guard instead of being overwritten.
                .existing(
                    baseRevisionID: currentActive.revisionID,
                    recordChangeTag: nil
                )
            }
        }
        try repository.commit(
            JournalTransaction(
                upserts: upserts,
                origin: .user,
                transactionID: activatedPlan.planSeriesID,
                revisionExpectations: expectations
            )
        )
        return nextSession.map {
            CanonicalNextStepProposal(
                projectId: project.id,
                plannedSessionId: $0.id,
                title: $0.title,
                reason: "First session in the activated learning plan"
            )
        }
    }

    /// Compatibility overload for existing callers. It still captures a
    /// concrete expectation from the repository before entering activation.
    @discardableResult
    public func activate(draftPlanID: UUID) throws -> CanonicalNextStepProposal? {
        try activate(
            draftPlanID: draftPlanID,
            expectation: try revisionGuardExpectation(for: draftPlanID)
        )
    }

    /// Captures the adjustment/new-record guard at the moment the UI opens.
    public func revisionGuardExpectation(for planID: UUID) throws -> RevisionGuardExpectation {
        let snapshot = try repository.snapshot()
        guard let plan = snapshot.coursePlans.first(where: { $0.id == planID }) else {
            throw JournalValidationError.missingProject
        }
        let targetMetadata = try repository.metadata(for: plan.reference)
        if let targetMetadata {
            return .existingTarget(
                revisionID: plan.revisionID,
                recordChangeTag: targetMetadata.recordChangeTag
            )
        }
        if let baseRevisionID = plan.baseRevisionID {
            let baseReference = JournalEntityReference(.coursePlan, baseRevisionID)
            return .existing(
                baseRevisionID: baseRevisionID,
                recordChangeTag: try repository.metadata(for: baseReference)?.recordChangeTag
            )
        }
        return .newRecord()
    }

    private func validateActivationExpectation(
        _ expectation: RevisionGuardExpectation,
        draftPlan: LearningPlan,
        snapshot: JournalSnapshot
    ) throws {
        switch expectation.recordState {
        case .newRecord:
            let targetMetadata = try repository.metadata(for: draftPlan.reference)
            try RevisionGuard.validate(
                expectation: expectation,
                currentRevisionID: draftPlan.revisionID,
                currentRecordChangeTag: targetMetadata?.recordChangeTag,
                currentRecordExists: targetMetadata != nil
            )
        case .existingRecord:
            guard let baseRevisionID = expectation.baseRevisionID else {
                throw RevisionGuardError.stale(
                    baseRevisionID: draftPlan.revisionID,
                    expectedRecordChangeTag: expectation.recordChangeTag,
                    actualRecordChangeTag: nil
                )
            }
            let baseReference = JournalEntityReference(.coursePlan, baseRevisionID)
            let metadata = try repository.metadata(for: baseReference)
            try RevisionGuard.validate(
                expectation: expectation,
                currentRevisionID: baseRevisionID,
                currentRecordChangeTag: metadata?.recordChangeTag,
                currentRecordExists: snapshot.coursePlans.contains { $0.id == baseRevisionID }
            )
        }
    }

    @discardableResult
    public func revise(
        planID: UUID,
        input: CoursePlanningInput,
        draft: CoursePlanDraft
    ) throws -> CoursePlan {
        let snapshot = try repository.snapshot()
        guard let basePlan = snapshot.coursePlans.first(where: { $0.id == planID }) else {
            throw JournalValidationError.missingProject
        }
        guard input.projectId == basePlan.projectId else {
            throw CoursePlanningError.projectMismatch
        }
        return try saveDraft(input: input, draft: draft, basedOn: basePlan)
    }

    /// Persists a structural edit as an explicit immutable-revision draft.
    @discardableResult
    public func saveRevisionDraft(
        planID: UUID,
        input: CoursePlanningInput,
        draft: CoursePlanDraft
    ) throws -> PlanRevisionDraft {
        let plan = try revise(planID: planID, input: input, draft: draft)
        let snapshot = try repository.snapshot()
        let expectation = try revisionGuardExpectation(for: plan.id)
        return PlanRevisionDraft(
            plan: plan,
            phases: snapshot.planPhases.filter { $0.planId == plan.id },
            sessions: snapshot.plannedSessions.filter { $0.planId == plan.id },
            practiceRoutines: snapshot.practiceRoutines.filter {
                $0.planRevisionID == plan.revisionID
            },
            guardExpectation: expectation
        )
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

    /// Reschedules one execution record without creating a new plan revision.
    /// The phase window and every sibling session remain untouched; the prior
    /// window is retained in a schedule-change Trail event for carryover audit.
    @discardableResult
    public func reschedule(
        plannedSessionID: UUID,
        newDeadline: Date
    ) throws -> PlannedSession {
        let snapshot = try repository.snapshot()
        guard let index = snapshot.plannedSessions.firstIndex(where: { $0.id == plannedSessionID }) else {
            throw JournalValidationError.missingPlannedSession
        }
        var session = snapshot.plannedSessions[index]
        guard session.status != .completed else { return session }

        let phase = snapshot.planPhases.first(where: { $0.id == session.phaseId })
        let originalWindowStart = phase?.targetStart ?? session.createdAt
        let originalWindowEnd = session.deadline ?? phase?.targetEnd ?? session.createdAt
        let timestamp = now()
        session.deadline = newDeadline
        session.status = .scheduled
        session.updatedAt = timestamp

        let event = TrailEvent(
            projectId: session.projectId,
            type: .scheduleChanged,
            sourceId: session.id,
            occurredAt: timestamp,
            title: "Planned session rescheduled",
            detail: [
                "Original window: \(originalWindowStart.ISO8601Format()) – \(originalWindowEnd.ISO8601Format())",
                "New deadline: \(newDeadline.ISO8601Format())"
            ].joined(separator: " · ")
        )
        let sessionReference = JournalEntityReference(.plannedSession, session.id)
        var expectations: [JournalEntityReference: RevisionGuardExpectation] = [:]
        if let metadata = try repository.metadata(for: sessionReference) {
            expectations[sessionReference] = .existingTarget(
                revisionID: session.id,
                recordChangeTag: metadata.recordChangeTag
            )
        }
        try repository.commit(
            JournalTransaction(
                upserts: [.plannedSession(session), .trailEvent(event)],
                origin: .user,
                revisionExpectations: expectations
            )
        )
        return session
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
