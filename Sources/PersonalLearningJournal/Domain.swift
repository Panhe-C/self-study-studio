import Foundation

public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case active
    case lowFrequency = "low-frequency"
    case paused
    case archived
}

public enum ActionType: String, Codable, CaseIterable, Sendable {
    case course
    case practice
    case output
    case reading
    case experiment
    case review
}

public enum SessionSource: String, Codable, CaseIterable, Sendable {
    case quickLog
    case timer
}

public enum ProofType: String, Codable, CaseIterable, Sendable {
    case image
    case audio
    case file
    case link
}

public enum TrailEventType: String, Codable, CaseIterable, Sendable {
    case session
    case proof
    case review
    case statusChange
    case nextStepChange
}

public enum JournalValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyGoal
    case emptyNextStep
    case emptySessionNote
    case emptyProofStatement
    case invalidDuration
    case missingProject
    case missingReview
    case missingFirstRecord
    case missingReviewRecommendation
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var area: String
    public var goal: String
    public var status: ProjectStatus
    public var currentNextStep: String
    public var lastActionType: ActionType
    public var defaultDurationMinutes: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        area: String,
        goal: String,
        status: ProjectStatus = .active,
        currentNextStep: String,
        lastActionType: ActionType = .course,
        defaultDurationMinutes: Int = 30,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.area = area
        self.goal = goal
        self.status = status
        self.currentNextStep = currentNextStep
        self.lastActionType = lastActionType
        self.defaultDurationMinutes = defaultDurationMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    public var canContinue: Bool {
        status == .active && !currentNextStep.trimmedForJournal.isEmpty
    }
}

public struct ProjectOnboardingDraft: Equatable, Sendable {
    public var name: String
    public var area: String
    public var goal: String
    public var nextStep: String

    public init(
        name: String,
        area: String,
        goal: String,
        nextStep: String
    ) {
        self.name = name
        self.area = area
        self.goal = goal
        self.nextStep = nextStep
    }
}

public struct LearningSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var source: SessionSource
    public var actionType: ActionType
    public var startedAt: Date
    public var endedAt: Date
    public var durationMinutes: Int
    public var note: String
    public var nextStepBefore: String
    public var nextStepAfter: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        source: SessionSource,
        actionType: ActionType,
        startedAt: Date,
        endedAt: Date,
        durationMinutes: Int,
        note: String,
        nextStepBefore: String,
        nextStepAfter: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard durationMinutes > 0 else { throw JournalValidationError.invalidDuration }
        guard !note.trimmedForJournal.isEmpty else { throw JournalValidationError.emptySessionNote }

        self.id = id
        self.projectId = projectId
        self.source = source
        self.actionType = actionType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMinutes = durationMinutes
        self.note = note.trimmedForJournal
        self.nextStepBefore = nextStepBefore.trimmedForJournal
        self.nextStepAfter = nextStepAfter.trimmedForJournal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Proof: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var sessionId: UUID?
    public var type: ProofType
    public var title: String
    public var statement: String
    public var localPath: String?
    public var url: URL?
    public var mimeType: String?
    public var fileSize: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
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
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard !statement.trimmedForJournal.isEmpty else {
            throw JournalValidationError.emptyProofStatement
        }

        self.id = id
        self.projectId = projectId
        self.sessionId = sessionId
        self.type = type
        self.title = title.trimmedForJournal.isEmpty ? type.rawValue.capitalized : title.trimmedForJournal
        self.statement = statement.trimmedForJournal
        self.localPath = localPath
        self.url = url
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Review: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var periodStart: Date
    public var periodEnd: Date
    public var facts: [String]
    public var patterns: [String]
    public var decisions: [String]
    public var projectRecommendations: [UUID: ProjectStatus]
    public var nextSteps: [UUID: String]
    public var aiSourceSummary: [String]
    public var sourceReferences: [String: [String]]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        periodStart: Date,
        periodEnd: Date,
        facts: [String],
        patterns: [String],
        decisions: [String],
        projectRecommendations: [UUID: ProjectStatus],
        nextSteps: [UUID: String],
        aiSourceSummary: [String],
        sourceReferences: [String: [String]] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.facts = facts
        self.patterns = patterns
        self.decisions = decisions
        self.projectRecommendations = projectRecommendations
        self.nextSteps = nextSteps
        self.aiSourceSummary = aiSourceSummary
        self.sourceReferences = sourceReferences
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TrailEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var type: TrailEventType
    public var sourceId: UUID
    public var occurredAt: Date
    public var title: String
    public var detail: String

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        type: TrailEventType,
        sourceId: UUID,
        occurredAt: Date,
        title: String,
        detail: String
    ) {
        self.id = id
        self.projectId = projectId
        self.type = type
        self.sourceId = sourceId
        self.occurredAt = occurredAt
        self.title = title
        self.detail = detail
    }
}

extension String {
    var trimmedForJournal: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
