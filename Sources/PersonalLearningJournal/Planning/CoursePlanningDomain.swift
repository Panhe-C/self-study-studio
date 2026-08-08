import Foundation

public struct CanonicalNextStepProposal: Equatable, Sendable {
    public var projectId: UUID
    public var plannedSessionId: UUID
    public var title: String
    public var reason: String

    public init(projectId: UUID, plannedSessionId: UUID, title: String, reason: String) {
        self.projectId = projectId
        self.plannedSessionId = plannedSessionId
        self.title = title
        self.reason = reason
    }
}

public enum CoursePlanStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case active
    case archived
    case completed
}

public enum PlannedSessionStatus: String, Codable, CaseIterable, Sendable {
    case unscheduled
    case scheduled
    case completed
    case skipped
    case cancelled
}

public enum CoursePlanningValidationError: Error, Equatable, Sendable {
    case emptyTitle
    case emptyGoal
    case invalidWeeklyBudget
    case invalidDateRange
    case unknownPhaseReference(String)
    case invalidDuration
    case duplicateDraftID(String)
    case phaseOutsidePlan(String)
    case invalidRevision
    case invalidOrdinal
    case invalidRevisionIdentity
}

public enum PlanRevisionIdentityError: Error, Equatable, Sendable {
    case baseRevisionCannotReferenceSelf
    case supersededRevisionCannotReferenceSelf
    case supersededRevisionRequiresBase
}

/// The four edges that make a Learning Plan revision immutable and
/// addressable. Keeping them together prevents individual fields from
/// drifting during local edits, Cloud merges, or migration.
public struct PlanRevisionIdentity: Codable, Equatable, Hashable, Sendable {
    public let revisionID: UUID
    public let planSeriesID: UUID
    public let baseRevisionID: UUID?
    public let supersedesID: UUID?

    public init(
        revisionID: UUID,
        planSeriesID: UUID,
        baseRevisionID: UUID? = nil,
        supersedesID: UUID? = nil
    ) {
        self.revisionID = revisionID
        self.planSeriesID = planSeriesID
        self.baseRevisionID = baseRevisionID
        self.supersedesID = supersedesID
    }

    public func validate() throws {
        if baseRevisionID == revisionID {
            throw PlanRevisionIdentityError.baseRevisionCannotReferenceSelf
        }
        if supersedesID == revisionID {
            throw PlanRevisionIdentityError.supersededRevisionCannotReferenceSelf
        }
        if supersedesID != nil, baseRevisionID == nil {
            throw PlanRevisionIdentityError.supersededRevisionRequiresBase
        }
    }
}

/// The canonical learning-plan aggregate root.
///
/// `CoursePlan` remains a typealias below so persisted archives, JournalEntity
/// cases, and the CloudKit `CoursePlan` record type remain readable forever.
public struct LearningPlan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var revision: Int
    /// Stable identity shared by all revisions in one learning-plan series.
    public var planSeriesID: UUID
    /// Stable identity for this immutable revision.
    public var revisionID: UUID
    /// The revision this draft was based on, when one exists.
    public var baseRevisionID: UUID?
    /// The revision superseded when this revision is activated.
    public var supersedesID: UUID?
    public var status: CoursePlanStatus
    public var courseURL: URL?
    public var courseTitle: String
    public var courseOutline: String
    public var goal: String
    public var expectedOutcome: String
    public var startsOn: Date
    public var deadline: Date?
    public var weeklyBudgetMinutes: Int
    public var summary: String
    public var createdAt: Date
    public var updatedAt: Date
    public var activatedAt: Date?
    public var deletedAt: Date?
    public var schemaVersion: Int

    public var isPublished: Bool {
        switch status {
        case .active, .archived, .completed:
            return true
        case .draft:
            return false
        }
    }

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        revision: Int,
        planSeriesID: UUID? = nil,
        revisionID: UUID? = nil,
        baseRevisionID: UUID? = nil,
        supersedesID: UUID? = nil,
        status: CoursePlanStatus,
        courseURL: URL?,
        courseTitle: String,
        courseOutline: String,
        goal: String,
        expectedOutcome: String,
        startsOn: Date,
        deadline: Date?,
        weeklyBudgetMinutes: Int,
        summary: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        activatedAt: Date? = nil,
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
    ) throws {
        guard !courseTitle.trimmedForJournal.isEmpty else {
            throw CoursePlanningValidationError.emptyTitle
        }
        guard !goal.trimmedForJournal.isEmpty else {
            throw CoursePlanningValidationError.emptyGoal
        }
        guard revision > 0 else {
            throw CoursePlanningValidationError.invalidRevision
        }
        guard weeklyBudgetMinutes > 0 else {
            throw CoursePlanningValidationError.invalidWeeklyBudget
        }
        guard deadline.map({ $0 >= startsOn }) ?? true else {
            throw CoursePlanningValidationError.invalidDateRange
        }

        self.id = id
        self.projectId = projectId
        self.revision = revision
        self.planSeriesID = planSeriesID ?? id
        self.revisionID = revisionID ?? id
        self.baseRevisionID = baseRevisionID
        self.supersedesID = supersedesID
        self.status = status
        self.courseURL = courseURL
        self.courseTitle = courseTitle.trimmedForJournal
        self.courseOutline = courseOutline.trimmedForJournal
        self.goal = goal.trimmedForJournal
        self.expectedOutcome = expectedOutcome.trimmedForJournal
        self.startsOn = startsOn
        self.deadline = deadline
        self.weeklyBudgetMinutes = weeklyBudgetMinutes
        self.summary = summary.trimmedForJournal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activatedAt = activatedAt
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion

        do {
            try revisionIdentity.validate()
        } catch {
            throw CoursePlanningValidationError.invalidRevisionIdentity
        }
    }

    public var revisionIdentity: PlanRevisionIdentity {
        PlanRevisionIdentity(
            revisionID: revisionID,
            planSeriesID: planSeriesID,
            baseRevisionID: baseRevisionID,
            supersedesID: supersedesID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case revision
        case planSeriesID
        case revisionID
        case baseRevisionID
        case supersedesID
        case status
        case courseURL
        case courseTitle
        case courseOutline
        case goal
        case expectedOutcome
        case startsOn
        case deadline
        case weeklyBudgetMinutes
        case summary
        case createdAt
        case updatedAt
        case activatedAt
        case deletedAt
        case schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let projectId = try container.decode(UUID.self, forKey: .projectId)
        let revision = try container.decode(Int.self, forKey: .revision)
        let status = try container.decode(CoursePlanStatus.self, forKey: .status)
        let courseURL = try container.decodeIfPresent(URL.self, forKey: .courseURL)
        let courseTitle = try container.decode(String.self, forKey: .courseTitle)
        let courseOutline = try container.decodeIfPresent(String.self, forKey: .courseOutline) ?? ""
        let goal = try container.decode(String.self, forKey: .goal)
        let expectedOutcome = try container.decodeIfPresent(String.self, forKey: .expectedOutcome) ?? ""
        let startsOn = try container.decode(Date.self, forKey: .startsOn)
        let deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        let weeklyBudgetMinutes = try container.decode(Int.self, forKey: .weeklyBudgetMinutes)
        let summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let activatedAt = try container.decodeIfPresent(Date.self, forKey: .activatedAt)
        let deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? JournalSchema.currentVersion

        try self.init(
            id: id,
            projectId: projectId,
            revision: revision,
            planSeriesID: try container.decodeIfPresent(UUID.self, forKey: .planSeriesID) ?? id,
            revisionID: try container.decodeIfPresent(UUID.self, forKey: .revisionID) ?? id,
            baseRevisionID: try container.decodeIfPresent(UUID.self, forKey: .baseRevisionID),
            supersedesID: try container.decodeIfPresent(UUID.self, forKey: .supersedesID),
            status: status,
            courseURL: courseURL,
            courseTitle: courseTitle,
            courseOutline: courseOutline,
            goal: goal,
            expectedOutcome: expectedOutcome,
            startsOn: startsOn,
            deadline: deadline,
            weeklyBudgetMinutes: weeklyBudgetMinutes,
            summary: summary,
            createdAt: createdAt,
            updatedAt: updatedAt,
            activatedAt: activatedAt,
            deletedAt: deletedAt,
            schemaVersion: schemaVersion
        )
    }
}

/// Compatibility alias for pre-B2 source and persisted API callers.
public typealias CoursePlan = LearningPlan

public extension LearningPlan {
    var reference: JournalEntityReference {
        JournalEntityReference(.coursePlan, id)
    }
}

/// Immutable snapshot of a learning-plan revision and its structural children.
public struct PlanRevision: Codable, Equatable, Identifiable, Sendable {
    public let revisionID: UUID
    public let planSeriesID: UUID
    public let baseRevisionID: UUID?
    public let supersedesID: UUID?
    public let plan: LearningPlan
    public let phases: [PlanPhase]
    public let sessions: [PlannedSession]
    /// Revision-scoped Practice Routine snapshots. Legacy routines remain
    /// project-owned when this collection is empty.
    public let practiceRoutines: [PracticeRoutine]

    public var id: UUID { revisionID }
    public var isActive: Bool { plan.status == .active }
    public var isSuperseded: Bool { supersedesID != nil && plan.status != .active }

    public init(
        plan: LearningPlan,
        phases: [PlanPhase],
        sessions: [PlannedSession],
        practiceRoutines: [PracticeRoutine] = []
    ) {
        self.revisionID = plan.revisionID
        self.planSeriesID = plan.planSeriesID
        self.baseRevisionID = plan.baseRevisionID
        self.supersedesID = plan.supersedesID
        self.plan = plan
        self.phases = phases
        self.sessions = sessions
        self.practiceRoutines = practiceRoutines
    }
}

/// Mutable structural-edit workspace. It is intentionally separate from the
/// immutable `PlanRevision` persisted by activation.
public struct PlanRevisionDraft: Codable, Equatable, Identifiable, Sendable {
    public var revisionID: UUID
    public var planSeriesID: UUID
    public var baseRevisionID: UUID?
    public var supersedesID: UUID?
    public var plan: LearningPlan
    public var phases: [PlanPhase]
    public var sessions: [PlannedSession]
    public var practiceRoutines: [PracticeRoutine]
    /// Captured when the adjustment UI opens. It is persisted with the draft
    /// so a restart cannot silently replace the caller's base/tag expectation.
    public var guardExpectation: RevisionGuardExpectation

    public var id: UUID { revisionID }

    public init(
        plan: LearningPlan,
        phases: [PlanPhase],
        sessions: [PlannedSession],
        practiceRoutines: [PracticeRoutine] = [],
        revisionID: UUID? = nil,
        planSeriesID: UUID? = nil,
        baseRevisionID: UUID? = nil,
        supersedesID: UUID? = nil,
        guardExpectation: RevisionGuardExpectation = .newRecord()
    ) {
        self.revisionID = revisionID ?? plan.revisionID
        self.planSeriesID = planSeriesID ?? plan.planSeriesID
        self.baseRevisionID = baseRevisionID ?? plan.baseRevisionID
        self.supersedesID = supersedesID ?? plan.supersedesID
        self.plan = plan
        self.phases = phases
        self.sessions = sessions
        self.practiceRoutines = practiceRoutines
        self.guardExpectation = guardExpectation
    }

    public func materializedRevision() -> PlanRevision {
        var value = plan
        value.revisionID = revisionID
        value.planSeriesID = planSeriesID
        value.baseRevisionID = baseRevisionID
        value.supersedesID = supersedesID
        return PlanRevision(
            plan: value,
            phases: phases,
            sessions: sessions,
            practiceRoutines: practiceRoutines
        )
    }

    private enum CodingKeys: String, CodingKey {
        case revisionID, planSeriesID, baseRevisionID, supersedesID
        case plan, phases, sessions, practiceRoutines, guardExpectation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let plan = try container.decode(LearningPlan.self, forKey: .plan)
        self.init(
            plan: plan,
            phases: try container.decode([PlanPhase].self, forKey: .phases),
            sessions: try container.decode([PlannedSession].self, forKey: .sessions),
            practiceRoutines: try container.decodeIfPresent([PracticeRoutine].self, forKey: .practiceRoutines) ?? [],
            revisionID: try container.decodeIfPresent(UUID.self, forKey: .revisionID) ?? plan.revisionID,
            planSeriesID: try container.decodeIfPresent(UUID.self, forKey: .planSeriesID) ?? plan.planSeriesID,
            baseRevisionID: try container.decodeIfPresent(UUID.self, forKey: .baseRevisionID) ?? plan.baseRevisionID,
            supersedesID: try container.decodeIfPresent(UUID.self, forKey: .supersedesID) ?? plan.supersedesID,
            guardExpectation: try container.decodeIfPresent(
                RevisionGuardExpectation.self,
                forKey: .guardExpectation
            ) ?? (plan.baseRevisionID.map {
                .existing(baseRevisionID: $0, recordChangeTag: nil)
            } ?? .newRecord())
        )
    }
}

/// A read model for all revisions belonging to one stable plan series.
public struct LearningPlanAggregate: Codable, Equatable, Identifiable, Sendable {
    public let projectId: UUID
    public let planSeriesID: UUID
    public let revisions: [PlanRevision]

    public var id: UUID { planSeriesID }
    /// Exactly one active revision is considered canonical. A malformed
    /// aggregate with zero or multiple active revisions returns nil.
    public var activeRevision: PlanRevision? {
        let active = revisions.filter(\.isActive)
        return active.count == 1 ? active[0] : nil
    }
    public var supersededRevisions: [PlanRevision] {
        revisions.filter { !$0.isActive }
    }

    public init(projectId: UUID, planSeriesID: UUID, revisions: [PlanRevision]) {
        self.projectId = projectId
        self.planSeriesID = planSeriesID
        self.revisions = revisions.sorted { lhs, rhs in
            if lhs.plan.revision != rhs.plan.revision {
                return lhs.plan.revision < rhs.plan.revision
            }
            return lhs.revisionID.uuidString < rhs.revisionID.uuidString
        }
    }
}

public extension JournalSnapshot {
    /// Groups legacy CoursePlan records and canonical LearningPlan revisions
    /// without dropping superseded history.
    func learningPlanAggregates(for projectID: UUID? = nil) -> [LearningPlanAggregate] {
        let plans = coursePlans.filter { projectID == nil || $0.projectId == projectID }
        struct AggregateKey: Hashable {
            let projectID: UUID
            let seriesID: UUID
        }
        let grouped = Dictionary(grouping: plans) {
            AggregateKey(projectID: $0.projectId, seriesID: $0.planSeriesID)
        }
        return grouped.map { key, plans in
            LearningPlanAggregate(
                projectId: key.projectID,
                planSeriesID: key.seriesID,
                revisions: plans.map { plan in
                    PlanRevision(
                        plan: plan,
                        phases: planPhases.filter { $0.planId == plan.id },
                        sessions: plannedSessions.filter { $0.planId == plan.id },
                        practiceRoutines: practiceRoutines.filter {
                            $0.planRevisionID == plan.revisionID
                        }
                    )
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.projectId != rhs.projectId {
                return lhs.projectId.uuidString < rhs.projectId.uuidString
            }
            return lhs.planSeriesID.uuidString < rhs.planSeriesID.uuidString
        }
    }

    /// Routines that can participate in current-day practice operations.
    ///
    /// Legacy routines have no revision scope and remain visible. A
    /// revision-scoped routine is operational only when its owning Project's
    /// active Learning Plan points at that exact revision. Superseded
    /// revisions stay available through `practiceRoutineHistory` instead of
    /// leaking into Today, the timer, or routine management.
    var operationalPracticeRoutines: [PracticeRoutine] {
        var activeRevisionByProject: [UUID: UUID] = [:]
        for project in projects {
            let explicitlyLinkedPlan = project.activeCoursePlanId.flatMap { activePlanID in
                coursePlans.first {
                    $0.id == activePlanID
                        && $0.projectId == project.id
                        && $0.status == .active
                }
            }
            let activePlans = coursePlans.filter {
                $0.projectId == project.id && $0.status == .active
            }
            let activePlan = explicitlyLinkedPlan
                ?? (activePlans.count == 1 ? activePlans[0] : nil)
            if let activePlan {
                activeRevisionByProject[project.id] = activePlan.revisionID
            }
        }

        return practiceRoutines.filter { routine in
            guard routine.deletedAt == nil else { return false }
            guard let revisionID = routine.planRevisionID else {
                return true
            }
            guard let projectID = routine.projectId,
                  let activeRevisionID = activeRevisionByProject[projectID]
            else {
                return false
            }
            return revisionID == activeRevisionID
        }
    }

    /// Full routine history, including superseded revision snapshots.
    var practiceRoutineHistory: [PracticeRoutine] {
        practiceRoutines
    }
}

public enum RevisionGuardRecordState: String, Codable, Sendable {
    case newRecord
    case existingRecord
}

public struct RevisionGuardExpectation: Equatable, Codable, Sendable {
    public let baseRevisionID: UUID?
    public let recordChangeTag: String?
    public let recordState: RevisionGuardRecordState
    /// The record being written may be new even when the base record is
    /// existing (the normal adjustment flow).
    public let targetRecordState: RevisionGuardRecordState

    public init(baseRevisionID: UUID, recordChangeTag: String) {
        self.init(
            baseRevisionID: baseRevisionID,
            recordChangeTag: recordChangeTag,
            recordState: .existingRecord,
            targetRecordState: .newRecord
        )
    }

    public init(
        baseRevisionID: UUID?,
        recordChangeTag: String?,
        recordState: RevisionGuardRecordState,
        targetRecordState: RevisionGuardRecordState = .newRecord
    ) {
        self.baseRevisionID = baseRevisionID
        self.recordChangeTag = recordChangeTag
        self.recordState = recordState
        self.targetRecordState = targetRecordState
    }

    public static func existing(
        baseRevisionID: UUID,
        recordChangeTag: String?
    ) -> RevisionGuardExpectation {
        RevisionGuardExpectation(
            baseRevisionID: baseRevisionID,
            recordChangeTag: recordChangeTag,
            recordState: .existingRecord,
            targetRecordState: .newRecord
        )
    }

    public static func existingTarget(
        revisionID: UUID,
        recordChangeTag: String?
    ) -> RevisionGuardExpectation {
        RevisionGuardExpectation(
            baseRevisionID: revisionID,
            recordChangeTag: recordChangeTag,
            recordState: .existingRecord,
            targetRecordState: .existingRecord
        )
    }

    public static func newRecord() -> RevisionGuardExpectation {
        RevisionGuardExpectation(
            baseRevisionID: nil,
            recordChangeTag: nil,
            recordState: .newRecord,
            targetRecordState: .newRecord
        )
    }
}

public enum RevisionGuardError: Error, Equatable, Sendable {
    case stale(
        baseRevisionID: UUID,
        expectedRecordChangeTag: String?,
        actualRecordChangeTag: String?
    )
    case missingBaseRevision(UUID)
    case missingRecordChangeTag(UUID)
}

public enum RevisionGuard {
    public static func validate(
        expectation: RevisionGuardExpectation,
        currentRevisionID: UUID,
        currentRecordChangeTag: String?,
        currentRecordExists: Bool = true
    ) throws {
        if expectation.recordState == .newRecord {
            guard !currentRecordExists, currentRecordChangeTag == nil else {
                throw RevisionGuardError.stale(
                    baseRevisionID: currentRevisionID,
                    expectedRecordChangeTag: nil,
                    actualRecordChangeTag: currentRecordChangeTag
                )
            }
            return
        }

        guard let baseRevisionID = expectation.baseRevisionID,
              baseRevisionID == currentRevisionID,
              currentRecordExists else {
            throw RevisionGuardError.stale(
                baseRevisionID: expectation.baseRevisionID ?? currentRevisionID,
                expectedRecordChangeTag: expectation.recordChangeTag,
                actualRecordChangeTag: currentRecordChangeTag
            )
        }

        if expectation.recordChangeTag != currentRecordChangeTag {
            if expectation.recordChangeTag != nil, currentRecordChangeTag == nil {
                throw RevisionGuardError.missingRecordChangeTag(baseRevisionID)
            }
            throw RevisionGuardError.stale(
                baseRevisionID: baseRevisionID,
                expectedRecordChangeTag: expectation.recordChangeTag,
                actualRecordChangeTag: currentRecordChangeTag
            )
        }
    }
}

public struct PlanPhase: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var planId: UUID
    /// Revision/series identity is copied from the owning plan. Legacy phase
    /// archives omit these keys and safely fall back to `planId`.
    public var planRevisionID: UUID
    public var planSeriesID: UUID
    /// Published revisions lock structural phase fields in sync merges.
    public var isStructuralLocked: Bool
    public var title: String
    public var objective: String
    public var expectedProof: String
    public var ordinal: Int
    public var targetStart: Date
    public var targetEnd: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        planId: UUID,
        planRevisionID: UUID? = nil,
        planSeriesID: UUID? = nil,
        isStructuralLocked: Bool = false,
        title: String,
        objective: String,
        expectedProof: String,
        ordinal: Int,
        targetStart: Date,
        targetEnd: Date,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
    ) throws {
        guard !title.trimmedForJournal.isEmpty else {
            throw CoursePlanningValidationError.emptyTitle
        }
        guard !objective.trimmedForJournal.isEmpty else {
            throw CoursePlanningValidationError.emptyGoal
        }
        guard ordinal >= 0 else {
            throw CoursePlanningValidationError.invalidOrdinal
        }
        guard targetEnd >= targetStart else {
            throw CoursePlanningValidationError.invalidDateRange
        }

        self.id = id
        self.planId = planId
        self.planRevisionID = planRevisionID ?? planId
        self.planSeriesID = planSeriesID ?? planId
        self.isStructuralLocked = isStructuralLocked
        self.title = title.trimmedForJournal
        self.objective = objective.trimmedForJournal
        self.expectedProof = expectedProof.trimmedForJournal
        self.ordinal = ordinal
        self.targetStart = targetStart
        self.targetEnd = targetEnd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, planId, planRevisionID, planSeriesID, isStructuralLocked
        case title, objective, expectedProof, ordinal, targetStart, targetEnd
        case createdAt, updatedAt, deletedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            planId: container.decode(UUID.self, forKey: .planId),
            planRevisionID: container.decodeIfPresent(UUID.self, forKey: .planRevisionID),
            planSeriesID: container.decodeIfPresent(UUID.self, forKey: .planSeriesID),
            isStructuralLocked: container.decodeIfPresent(Bool.self, forKey: .isStructuralLocked) ?? false,
            title: container.decode(String.self, forKey: .title),
            objective: container.decode(String.self, forKey: .objective),
            expectedProof: container.decode(String.self, forKey: .expectedProof),
            ordinal: container.decode(Int.self, forKey: .ordinal),
            targetStart: container.decode(Date.self, forKey: .targetStart),
            targetEnd: container.decode(Date.self, forKey: .targetEnd),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? JournalSchema.currentVersion
        )
    }
}

public struct PlannedSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var planId: UUID
    public var planRevisionID: UUID
    public var planSeriesID: UUID
    /// Published revision sessions allow execution-only changes but lock
    /// structural fields such as title, phase, and duration.
    public var isStructuralLocked: Bool
    public var phaseId: UUID
    public var projectId: UUID
    public var title: String
    public var actionType: ActionType
    public var expectedProof: String?
    public var durationMinutes: Int
    public var deadline: Date?
    public var status: PlannedSessionStatus
    public var completedSessionId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        planId: UUID,
        planRevisionID: UUID? = nil,
        planSeriesID: UUID? = nil,
        isStructuralLocked: Bool = false,
        phaseId: UUID,
        projectId: UUID,
        title: String,
        actionType: ActionType,
        expectedProof: String? = nil,
        durationMinutes: Int,
        deadline: Date? = nil,
        status: PlannedSessionStatus = .unscheduled,
        completedSessionId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
    ) throws {
        guard !title.trimmedForJournal.isEmpty else {
            throw CoursePlanningValidationError.emptyTitle
        }
        guard durationMinutes > 0 else {
            throw CoursePlanningValidationError.invalidDuration
        }

        self.id = id
        self.planId = planId
        self.planRevisionID = planRevisionID ?? planId
        self.planSeriesID = planSeriesID ?? planId
        self.isStructuralLocked = isStructuralLocked
        self.phaseId = phaseId
        self.projectId = projectId
        self.title = title.trimmedForJournal
        self.actionType = actionType
        self.expectedProof = expectedProof?.trimmedForJournal
        self.durationMinutes = durationMinutes
        self.deadline = deadline
        self.status = status
        self.completedSessionId = completedSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, planId, planRevisionID, planSeriesID, isStructuralLocked
        case phaseId, projectId, title, actionType, expectedProof, durationMinutes
        case deadline, status, completedSessionId, createdAt, updatedAt, deletedAt
        case schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            planId: container.decode(UUID.self, forKey: .planId),
            planRevisionID: container.decodeIfPresent(UUID.self, forKey: .planRevisionID),
            planSeriesID: container.decodeIfPresent(UUID.self, forKey: .planSeriesID),
            isStructuralLocked: container.decodeIfPresent(Bool.self, forKey: .isStructuralLocked) ?? false,
            phaseId: container.decode(UUID.self, forKey: .phaseId),
            projectId: container.decode(UUID.self, forKey: .projectId),
            title: container.decode(String.self, forKey: .title),
            actionType: container.decode(ActionType.self, forKey: .actionType),
            expectedProof: container.decodeIfPresent(String.self, forKey: .expectedProof),
            durationMinutes: container.decode(Int.self, forKey: .durationMinutes),
            deadline: container.decodeIfPresent(Date.self, forKey: .deadline),
            status: container.decode(PlannedSessionStatus.self, forKey: .status),
            completedSessionId: container.decodeIfPresent(UUID.self, forKey: .completedSessionId),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? JournalSchema.currentVersion
        )
    }
}

public struct CoursePlanningInput: Codable, Equatable, Sendable {
    public var projectId: UUID
    public var courseURL: URL?
    public var courseTitle: String
    public var courseOutline: String
    public var goal: String
    public var expectedOutcome: String
    public var startsOn: Date
    public var deadline: Date?
    public var weeklyBudgetMinutes: Int
    public var preferredSessionMinutes: Int
    public var availableMinutesByWeekday: [Int: Int]

    public init(
        projectId: UUID,
        courseURL: URL? = nil,
        courseTitle: String,
        courseOutline: String,
        goal: String,
        expectedOutcome: String,
        startsOn: Date,
        deadline: Date? = nil,
        weeklyBudgetMinutes: Int,
        preferredSessionMinutes: Int,
        availableMinutesByWeekday: [Int: Int] = [:]
    ) {
        self.projectId = projectId
        self.courseURL = courseURL
        self.courseTitle = courseTitle
        self.courseOutline = courseOutline
        self.goal = goal
        self.expectedOutcome = expectedOutcome
        self.startsOn = startsOn
        self.deadline = deadline
        self.weeklyBudgetMinutes = weeklyBudgetMinutes
        self.preferredSessionMinutes = preferredSessionMinutes
        self.availableMinutesByWeekday = availableMinutesByWeekday
    }
}

public struct CoursePlanDraft: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var phases: [CoursePlanDraftPhase]
    public var sessions: [CoursePlanDraftSession]
    public var assumptions: [String]
    public var warnings: [String]

    public init(
        title: String,
        summary: String,
        phases: [CoursePlanDraftPhase],
        sessions: [CoursePlanDraftSession],
        assumptions: [String] = [],
        warnings: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.phases = phases
        self.sessions = sessions
        self.assumptions = assumptions
        self.warnings = warnings
    }
}

public struct CoursePlanDraftPhase: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var objective: String
    public var expectedProof: String
    public var ordinal: Int
    public var targetStart: Date
    public var targetEnd: Date

    public init(
        id: String,
        title: String,
        objective: String,
        expectedProof: String,
        ordinal: Int,
        targetStart: Date,
        targetEnd: Date
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.expectedProof = expectedProof
        self.ordinal = ordinal
        self.targetStart = targetStart
        self.targetEnd = targetEnd
    }
}

public struct CoursePlanDraftSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var phaseID: String
    public var title: String
    public var actionType: ActionType
    public var expectedProof: String?
    public var durationMinutes: Int
    public var deadline: Date?

    public init(
        id: String,
        phaseID: String,
        title: String,
        actionType: ActionType,
        expectedProof: String? = nil,
        durationMinutes: Int,
        deadline: Date? = nil
    ) {
        self.id = id
        self.phaseID = phaseID
        self.title = title
        self.actionType = actionType
        self.expectedProof = expectedProof
        self.durationMinutes = durationMinutes
        self.deadline = deadline
    }
}
