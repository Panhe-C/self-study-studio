import Foundation

public enum JournalSchema {
    public static let currentVersion = 2
}

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
    case planActivated
    case planRevised
    case scheduleChanged
    case calendarSynced
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
    case missingPlannedSession
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
    public var deletedAt: Date?
    public var schemaVersion: Int
    public var activeCoursePlanId: UUID?

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
        archivedAt: Date? = nil,
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion,
        activeCoursePlanId: UUID? = nil
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
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
        self.activeCoursePlanId = activeCoursePlanId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, area, goal, status, currentNextStep, lastActionType
        case defaultDurationMinutes, createdAt, updatedAt, archivedAt
        case deletedAt, schemaVersion, activeCoursePlanId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        area = try container.decode(String.self, forKey: .area)
        goal = try container.decode(String.self, forKey: .goal)
        status = try container.decode(ProjectStatus.self, forKey: .status)
        currentNextStep = try container.decode(String.self, forKey: .currentNextStep)
        lastActionType = try container.decode(ActionType.self, forKey: .lastActionType)
        defaultDurationMinutes = try container.decode(Int.self, forKey: .defaultDurationMinutes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? JournalSchema.currentVersion
        activeCoursePlanId = try container.decodeIfPresent(UUID.self, forKey: .activeCoursePlanId)
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
    public var deletedAt: Date?
    public var schemaVersion: Int

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
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
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
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, source, actionType, startedAt, endedAt
        case durationMinutes, note, nextStepBefore, nextStepAfter
        case createdAt, updatedAt, deletedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            projectId: container.decode(UUID.self, forKey: .projectId),
            source: container.decode(SessionSource.self, forKey: .source),
            actionType: container.decode(ActionType.self, forKey: .actionType),
            startedAt: container.decode(Date.self, forKey: .startedAt),
            endedAt: container.decode(Date.self, forKey: .endedAt),
            durationMinutes: container.decode(Int.self, forKey: .durationMinutes),
            note: container.decode(String.self, forKey: .note),
            nextStepBefore: container.decode(String.self, forKey: .nextStepBefore),
            nextStepAfter: container.decode(String.self, forKey: .nextStepAfter),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? JournalSchema.currentVersion
        )
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
    public var deletedAt: Date?
    public var schemaVersion: Int

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
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
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
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, sessionId, type, title, statement, localPath, url
        case mimeType, fileSize, createdAt, updatedAt, deletedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            projectId: container.decode(UUID.self, forKey: .projectId),
            sessionId: container.decodeIfPresent(UUID.self, forKey: .sessionId),
            type: container.decode(ProofType.self, forKey: .type),
            title: container.decode(String.self, forKey: .title),
            statement: container.decode(String.self, forKey: .statement),
            localPath: container.decodeIfPresent(String.self, forKey: .localPath),
            url: container.decodeIfPresent(URL.self, forKey: .url),
            mimeType: container.decodeIfPresent(String.self, forKey: .mimeType),
            fileSize: container.decodeIfPresent(Int.self, forKey: .fileSize),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? JournalSchema.currentVersion
        )
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
    public var deletedAt: Date?
    public var schemaVersion: Int

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
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
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
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, periodStart, periodEnd, facts, patterns, decisions
        case projectRecommendations, nextSteps, aiSourceSummary, sourceReferences
        case createdAt, updatedAt, deletedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            periodStart: try container.decode(Date.self, forKey: .periodStart),
            periodEnd: try container.decode(Date.self, forKey: .periodEnd),
            facts: try container.decode([String].self, forKey: .facts),
            patterns: try container.decode([String].self, forKey: .patterns),
            decisions: try container.decode([String].self, forKey: .decisions),
            projectRecommendations: try container.decode([UUID: ProjectStatus].self, forKey: .projectRecommendations),
            nextSteps: try container.decode([UUID: String].self, forKey: .nextSteps),
            aiSourceSummary: try container.decode([String].self, forKey: .aiSourceSummary),
            sourceReferences: try container.decodeIfPresent([String: [String]].self, forKey: .sourceReferences) ?? [:],
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? JournalSchema.currentVersion
        )
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
    public var deletedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        type: TrailEventType,
        sourceId: UUID,
        occurredAt: Date,
        title: String,
        detail: String,
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
    ) {
        self.id = id
        self.projectId = projectId
        self.type = type
        self.sourceId = sourceId
        self.occurredAt = occurredAt
        self.title = title
        self.detail = detail
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, type, sourceId, occurredAt, title, detail
        case deletedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            projectId: try container.decode(UUID.self, forKey: .projectId),
            type: try container.decode(TrailEventType.self, forKey: .type),
            sourceId: try container.decode(UUID.self, forKey: .sourceId),
            occurredAt: try container.decode(Date.self, forKey: .occurredAt),
            title: try container.decode(String.self, forKey: .title),
            detail: try container.decode(String.self, forKey: .detail),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? JournalSchema.currentVersion
        )
    }
}

extension String {
    var trimmedForJournal: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
