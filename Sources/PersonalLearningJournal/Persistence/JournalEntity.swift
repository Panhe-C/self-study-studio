import Foundation

public enum JournalEntityKind: String, Codable, CaseIterable, Sendable {
    case project
    case session
    case proof
    case review
    case evidenceContract
    case evidenceAcceptance
    case proofRevision
    case reviewDecision
    case trailEvent
    case coursePlan
    case planPhase
    case plannedSession
    case availabilityRule
    case schedulingPreferences
    case practiceRoutine
    case practiceSession
}

public struct JournalEntityReference: Codable, Equatable, Hashable, Sendable {
    public var kind: JournalEntityKind
    public var id: UUID

    public init(_ kind: JournalEntityKind, _ id: UUID) {
        self.kind = kind
        self.id = id
    }
}

public enum JournalEntity: Codable, Equatable, Sendable {
    case project(Project)
    case session(LearningSession)
    case proof(Proof)
    case review(Review)
    case evidenceContract(EvidenceContract)
    case evidenceAcceptance(EvidenceAcceptance)
    case proofRevision(ProofRevision)
    case reviewDecision(ReviewDecision)
    case trailEvent(TrailEvent)
    case coursePlan(CoursePlan)
    case planPhase(PlanPhase)
    case plannedSession(PlannedSession)
    case availabilityRule(AvailabilityRule)
    case schedulingPreferences(SchedulingPreferences)
    case practiceRoutine(PracticeRoutine)
    case practiceSession(PracticeSession)

    public var reference: JournalEntityReference {
        switch self {
        case let .project(value): .init(.project, value.id)
        case let .session(value): .init(.session, value.id)
        case let .proof(value): .init(.proof, value.id)
        case let .review(value): .init(.review, value.id)
        case let .evidenceContract(value): .init(.evidenceContract, value.id)
        case let .evidenceAcceptance(value): .init(.evidenceAcceptance, value.id)
        case let .proofRevision(value): .init(.proofRevision, value.id)
        case let .reviewDecision(value): .init(.reviewDecision, value.id)
        case let .trailEvent(value): .init(.trailEvent, value.id)
        case let .coursePlan(value): .init(.coursePlan, value.id)
        case let .planPhase(value): .init(.planPhase, value.id)
        case let .plannedSession(value): .init(.plannedSession, value.id)
        case let .availabilityRule(value): .init(.availabilityRule, value.id)
        case let .schedulingPreferences(value): .init(.schedulingPreferences, value.id)
        case let .practiceRoutine(value): .init(.practiceRoutine, value.id)
        case let .practiceSession(value): .init(.practiceSession, value.id)
        }
    }

    var isDeleted: Bool {
        switch self {
        case let .project(value): value.deletedAt != nil
        case let .session(value): value.deletedAt != nil
        case let .proof(value): value.deletedAt != nil
        case let .review(value): value.deletedAt != nil
        case let .evidenceContract(value): value.deletedAt != nil
        case let .evidenceAcceptance(value): value.deletedAt != nil
        case let .proofRevision(value): value.deletedAt != nil
        case let .reviewDecision(value): value.deletedAt != nil
        case let .trailEvent(value): value.deletedAt != nil
        case let .coursePlan(value): value.deletedAt != nil
        case let .planPhase(value): value.deletedAt != nil
        case let .plannedSession(value): value.deletedAt != nil
        case let .availabilityRule(value): value.deletedAt != nil
        case let .schedulingPreferences(value): value.deletedAt != nil
        case let .practiceRoutine(value): value.deletedAt != nil
        case let .practiceSession(value): value.deletedAt != nil
        }
    }

    func deleting(at date: Date) -> JournalEntity {
        switch self {
        case var .project(value):
            value.deletedAt = date
            value.updatedAt = date
            return .project(value)
        case var .session(value):
            value.deletedAt = date
            value.updatedAt = date
            return .session(value)
        case var .proof(value):
            value.deletedAt = date
            value.updatedAt = date
            return .proof(value)
        case var .review(value):
            value.deletedAt = date
            value.updatedAt = date
            return .review(value)
        case var .evidenceContract(value):
            value.deletedAt = date
            value.updatedAt = date
            return .evidenceContract(value)
        case var .evidenceAcceptance(value):
            value.deletedAt = date
            return .evidenceAcceptance(value)
        case var .proofRevision(value):
            value.deletedAt = date
            return .proofRevision(value)
        case var .reviewDecision(value):
            value.deletedAt = date
            return .reviewDecision(value)
        case var .trailEvent(value):
            value.deletedAt = date
            return .trailEvent(value)
        case var .coursePlan(value):
            value.deletedAt = date
            value.updatedAt = date
            return .coursePlan(value)
        case var .planPhase(value):
            value.deletedAt = date
            value.updatedAt = date
            return .planPhase(value)
        case var .plannedSession(value):
            value.deletedAt = date
            value.updatedAt = date
            return .plannedSession(value)
        case var .availabilityRule(value):
            value.deletedAt = date
            value.updatedAt = date
            return .availabilityRule(value)
        case var .schedulingPreferences(value):
            value.deletedAt = date
            value.updatedAt = date
            return .schedulingPreferences(value)
        case var .practiceRoutine(value):
            value.deletedAt = date
            value.updatedAt = date
            return .practiceRoutine(value)
        case var .practiceSession(value):
            value.deletedAt = date
            value.updatedAt = date
            return .practiceSession(value)
        }
    }
}

public enum MutationOrigin: Sendable {
    case user
    case migration
    case remote
}

public struct JournalStateMetadata: Codable, Equatable, Sendable {
    public var hasCompletedOnboarding: Bool
    public var pendingFirstRecordProjectId: UUID?

    public init(
        hasCompletedOnboarding: Bool,
        pendingFirstRecordProjectId: UUID?
    ) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.pendingFirstRecordProjectId = pendingFirstRecordProjectId
    }

    public init(snapshot: JournalSnapshot) {
        self.init(
            hasCompletedOnboarding: snapshot.hasCompletedOnboarding,
            pendingFirstRecordProjectId: snapshot.pendingFirstRecordProjectId
        )
    }
}

public struct JournalTransaction: Sendable {
    public var upserts: [JournalEntity]
    public var deletions: [JournalEntityReference]
    public var origin: MutationOrigin
    public var stateMetadata: JournalStateMetadata?
    public var completedMigrationIdentifier: String?

    public init(
        upserts: [JournalEntity] = [],
        deletions: [JournalEntityReference] = [],
        origin: MutationOrigin,
        stateMetadata: JournalStateMetadata? = nil,
        completedMigrationIdentifier: String? = nil
    ) {
        self.upserts = upserts
        self.deletions = deletions
        self.origin = origin
        self.stateMetadata = stateMetadata
        self.completedMigrationIdentifier = completedMigrationIdentifier
    }
}
