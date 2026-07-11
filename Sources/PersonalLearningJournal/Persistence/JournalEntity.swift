import Foundation

public enum JournalEntityKind: String, Codable, CaseIterable, Sendable {
    case project
    case session
    case proof
    case review
    case trailEvent
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
    case trailEvent(TrailEvent)

    public var reference: JournalEntityReference {
        switch self {
        case let .project(value): .init(.project, value.id)
        case let .session(value): .init(.session, value.id)
        case let .proof(value): .init(.proof, value.id)
        case let .review(value): .init(.review, value.id)
        case let .trailEvent(value): .init(.trailEvent, value.id)
        }
    }

    var isDeleted: Bool {
        switch self {
        case let .project(value): value.deletedAt != nil
        case let .session(value): value.deletedAt != nil
        case let .proof(value): value.deletedAt != nil
        case let .review(value): value.deletedAt != nil
        case let .trailEvent(value): value.deletedAt != nil
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
        case var .trailEvent(value):
            value.deletedAt = date
            return .trailEvent(value)
        }
    }
}

public enum MutationOrigin: Sendable {
    case user
    case migration
    case remote
}

public struct JournalTransaction: Sendable {
    public var upserts: [JournalEntity]
    public var deletions: [JournalEntityReference]
    public var origin: MutationOrigin

    public init(
        upserts: [JournalEntity] = [],
        deletions: [JournalEntityReference] = [],
        origin: MutationOrigin
    ) {
        self.upserts = upserts
        self.deletions = deletions
        self.origin = origin
    }
}
