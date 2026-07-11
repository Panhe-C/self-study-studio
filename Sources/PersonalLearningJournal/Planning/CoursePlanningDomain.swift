import Foundation

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

public struct CoursePlan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var revision: Int
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
