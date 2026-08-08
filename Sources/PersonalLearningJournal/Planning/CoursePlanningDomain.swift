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

/// Immutable snapshot of a learning-plan revision and its structural children.
public struct PlanRevision: Codable, Equatable, Identifiable, Sendable {
    public let revisionID: UUID
    public let planSeriesID: UUID
    public let baseRevisionID: UUID?
    public let supersedesID: UUID?
    public let plan: LearningPlan
    public let phases: [PlanPhase]
    public let sessions: [PlannedSession]

    public var id: UUID { revisionID }
    public var isActive: Bool { plan.status == .active }
    public var isSuperseded: Bool { supersedesID != nil && plan.status != .active }

    public init(
        plan: LearningPlan,
        phases: [PlanPhase],
        sessions: [PlannedSession]
    ) {
        self.revisionID = plan.revisionID
        self.planSeriesID = plan.planSeriesID
        self.baseRevisionID = plan.baseRevisionID
        self.supersedesID = plan.supersedesID
        self.plan = plan
        self.phases = phases
        self.sessions = sessions
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

    public var id: UUID { revisionID }

    public init(
        plan: LearningPlan,
        phases: [PlanPhase],
        sessions: [PlannedSession],
        revisionID: UUID? = nil,
        planSeriesID: UUID? = nil,
        baseRevisionID: UUID? = nil,
        supersedesID: UUID? = nil
    ) {
        self.revisionID = revisionID ?? plan.revisionID
        self.planSeriesID = planSeriesID ?? plan.planSeriesID
        self.baseRevisionID = baseRevisionID ?? plan.baseRevisionID
        self.supersedesID = supersedesID ?? plan.supersedesID
        self.plan = plan
        self.phases = phases
        self.sessions = sessions
    }

    public func materializedRevision() -> PlanRevision {
        PlanRevision(plan: plan, phases: phases, sessions: sessions)
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
                        sessions: plannedSessions.filter { $0.planId == plan.id }
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
}

public struct RevisionGuardExpectation: Equatable, Codable, Sendable {
    public let baseRevisionID: UUID
    public let recordChangeTag: String

    public init(baseRevisionID: UUID, recordChangeTag: String) {
        self.baseRevisionID = baseRevisionID
        self.recordChangeTag = recordChangeTag
    }
}

public enum RevisionGuardError: Error, Equatable, Sendable {
    case stale(
        baseRevisionID: UUID,
        expectedRecordChangeTag: String,
        actualRecordChangeTag: String?
    )
    case missingBaseRevision(UUID)
    case missingRecordChangeTag(UUID)
}

public enum RevisionGuard {
    public static func validate(
        expectation: RevisionGuardExpectation,
        currentRevisionID: UUID,
        currentRecordChangeTag: String?
    ) throws {
        guard expectation.baseRevisionID == currentRevisionID else {
            throw RevisionGuardError.stale(
                baseRevisionID: expectation.baseRevisionID,
                expectedRecordChangeTag: expectation.recordChangeTag,
                actualRecordChangeTag: currentRecordChangeTag
            )
        }
        guard let currentRecordChangeTag else {
            throw RevisionGuardError.missingRecordChangeTag(expectation.baseRevisionID)
        }
        guard currentRecordChangeTag == expectation.recordChangeTag else {
            throw RevisionGuardError.stale(
                baseRevisionID: expectation.baseRevisionID,
                expectedRecordChangeTag: expectation.recordChangeTag,
                actualRecordChangeTag: currentRecordChangeTag
            )
        }
    }
}

public struct PlanPhase: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var planId: UUID
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
}

public struct PlannedSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var planId: UUID
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
