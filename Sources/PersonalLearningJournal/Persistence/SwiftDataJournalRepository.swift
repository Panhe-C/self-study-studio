import Foundation
import SwiftData

public enum SwiftDataJournalRepositoryError: Error, Equatable, Sendable {
    case invalidStoredValue
}

public final class SwiftDataJournalRepository: JournalRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(container: ModelContainer, now: @escaping () -> Date = Date.init) {
        self.context = ModelContext(container)
        self.now = now
    }

    public convenience init(url: URL, now: @escaping () -> Date = Date.init) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(url: url)
        try self.init(container: Self.makeContainer(configuration), now: now)
    }

    public static func inMemory(
        now: @escaping () -> Date = Date.init
    ) throws -> SwiftDataJournalRepository {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try SwiftDataJournalRepository(
            container: makeContainer(configuration),
            now: now
        )
    }

    public func snapshot() throws -> JournalSnapshot {
        JournalSnapshot(
            projects: try decodedRecords(StoredProjectV2.self, as: Project.self),
            sessions: try decodedRecords(StoredSessionV2.self, as: LearningSession.self),
            proofs: try decodedRecords(StoredProofV2.self, as: Proof.self),
            reviews: try decodedRecords(StoredReviewV2.self, as: Review.self),
            trailEvents: try decodedRecords(StoredTrailEventV2.self, as: TrailEvent.self)
        )
    }

    public func commit(_ transaction: JournalTransaction) throws {
        do {
            for entity in transaction.upserts {
                try upsert(entity)
                if case .user = transaction.origin {
                    insertMutation(for: entity.reference, operation: .save)
                }
            }
            for reference in transaction.deletions {
                try markDeleted(reference)
                if case .user = transaction.origin {
                    insertMutation(for: reference, operation: .delete)
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func pendingMutations(limit: Int) throws -> [PendingMutation] {
        let records = try context.fetch(FetchDescriptor<StoredPendingMutationV2>())
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
        return try records.prefix(max(0, limit)).map { try $0.domain() }
    }

    public func acknowledge(
        _ mutationIDs: Set<UUID>,
        metadata: [SyncRecordMetadata]
    ) throws {
        do {
            let mutations = try context.fetch(FetchDescriptor<StoredPendingMutationV2>())
            for mutation in mutations where mutationIDs.contains(mutation.id) {
                context.delete(mutation)
            }

            let storedMetadata = try context.fetch(FetchDescriptor<StoredSyncMetadataV2>())
            for value in metadata {
                let key = Self.key(for: value.entity)
                let payload = try JSONEncoder.journal.encode(value)
                if let existing = storedMetadata.first(where: { $0.key == key }) {
                    existing.payload = payload
                } else {
                    context.insert(StoredSyncMetadataV2(key: key, payload: payload))
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func conflicts() throws -> [SyncConflict] {
        try context.fetch(FetchDescriptor<StoredSyncConflictV2>())
            .filter { $0.resolvedAt == nil }
            .map { try JSONDecoder.journal.decode(SyncConflict.self, from: $0.payload) }
    }

    public func resolveConflict(id: UUID, with entity: JournalEntity) throws {
        do {
            let conflicts = try context.fetch(FetchDescriptor<StoredSyncConflictV2>())
            guard let conflict = conflicts.first(where: { $0.id == id }) else { return }
            conflict.resolvedAt = now()
            var value = try JSONDecoder.journal.decode(SyncConflict.self, from: conflict.payload)
            value.resolvedAt = conflict.resolvedAt
            conflict.payload = try JSONEncoder.journal.encode(value)
            try upsert(entity)
            insertMutation(for: entity.reference, operation: .save)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func upsert(_ entity: JournalEntity) throws {
        switch entity {
        case let .project(value):
            try upsert(value, in: StoredProjectV2.self)
        case let .session(value):
            try upsert(value, in: StoredSessionV2.self)
        case let .proof(value):
            try upsert(value, in: StoredProofV2.self)
        case let .review(value):
            try upsert(value, in: StoredReviewV2.self)
        case let .trailEvent(value):
            try upsert(value, in: StoredTrailEventV2.self)
        }
    }

    private func markDeleted(_ reference: JournalEntityReference) throws {
        switch reference.kind {
        case .project:
            try markDeleted(reference.id, in: StoredProjectV2.self, as: Project.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .session:
            try markDeleted(reference.id, in: StoredSessionV2.self, as: LearningSession.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .proof:
            try markDeleted(reference.id, in: StoredProofV2.self, as: Proof.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .review:
            try markDeleted(reference.id, in: StoredReviewV2.self, as: Review.self) {
                var value = $0
                value.deletedAt = now()
                value.updatedAt = value.deletedAt!
                return value
            }
        case .trailEvent:
            try markDeleted(reference.id, in: StoredTrailEventV2.self, as: TrailEvent.self) {
                var value = $0
                value.deletedAt = now()
                return value
            }
        }
    }

    private func upsert<Value: Codable & Identifiable, Record: StoredEntityV2>(
        _ value: Value,
        in recordType: Record.Type
    ) throws where Value.ID == UUID {
        let records = try context.fetch(FetchDescriptor<Record>())
        let payload = try JSONEncoder.journal.encode(value)
        let deletedAt = (value as? any DeletionDated)?.journalDeletedAt
        if let existing = records.first(where: { $0.id == value.id }) {
            existing.payload = payload
            existing.deletedAt = deletedAt
        } else {
            let ordinal = (records.map(\.ordinal).max() ?? -1) + 1
            context.insert(Record(id: value.id, ordinal: ordinal, payload: payload, deletedAt: deletedAt))
        }
    }

    private func markDeleted<Value: Codable, Record: StoredEntityV2>(
        _ id: UUID,
        in recordType: Record.Type,
        as valueType: Value.Type,
        transform: (Value) -> Value
    ) throws {
        let records = try context.fetch(FetchDescriptor<Record>())
        guard let record = records.first(where: { $0.id == id }) else { return }
        let value = try JSONDecoder.journal.decode(Value.self, from: record.payload)
        let deleted = transform(value)
        record.payload = try JSONEncoder.journal.encode(deleted)
        record.deletedAt = now()
    }

    private func decodedRecords<Record: StoredEntityV2, Value: Codable>(
        _ recordType: Record.Type,
        as valueType: Value.Type
    ) throws -> [Value] {
        try context.fetch(FetchDescriptor<Record>())
            .filter { $0.deletedAt == nil }
            .sorted { $0.ordinal < $1.ordinal }
            .map { try JSONDecoder.journal.decode(Value.self, from: $0.payload) }
    }

    private func insertMutation(
        for entity: JournalEntityReference,
        operation: SyncOperation
    ) {
        context.insert(
            StoredPendingMutationV2(
                id: UUID(),
                entityKindRaw: entity.kind.rawValue,
                entityID: entity.id,
                operationRaw: operation.rawValue,
                enqueuedAt: now(),
                retryCount: 0
            )
        )
    }

    private static func key(for reference: JournalEntityReference) -> String {
        "\(reference.kind.rawValue):\(reference.id.uuidString)"
    }

    private static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: StoredProjectV2.self,
            StoredSessionV2.self,
            StoredProofV2.self,
            StoredReviewV2.self,
            StoredTrailEventV2.self,
            StoredPendingMutationV2.self,
            StoredSyncMetadataV2.self,
            StoredSyncConflictV2.self,
            StoredRepositoryMetadataV2.self,
            configurations: configuration
        )
    }
}

public enum RepositoryFactory {
    public static func makeDefault(storeURL: URL) throws -> SwiftDataJournalRepository {
        try SwiftDataJournalRepository(url: storeURL)
    }
}

private protocol DeletionDated {
    var journalDeletedAt: Date? { get }
}

extension Project: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension LearningSession: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension Proof: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension Review: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }
extension TrailEvent: DeletionDated { fileprivate var journalDeletedAt: Date? { deletedAt } }

private protocol StoredEntityV2: PersistentModel {
    var id: UUID { get set }
    var ordinal: Int { get set }
    var payload: Data { get set }
    var deletedAt: Date? { get set }
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?)
}

@Model private final class StoredProjectV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredSessionV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredProofV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredReviewV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredTrailEventV2: StoredEntityV2 {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, ordinal: Int, payload: Data, deletedAt: Date?) {
        self.id = id
        self.ordinal = ordinal
        self.payload = payload
        self.deletedAt = deletedAt
    }
}

@Model private final class StoredPendingMutationV2 {
    @Attribute(.unique) var id: UUID
    var entityKindRaw: String
    var entityID: UUID
    var operationRaw: String
    var enqueuedAt: Date
    var retryCount: Int
    var lastError: String?

    init(
        id: UUID,
        entityKindRaw: String,
        entityID: UUID,
        operationRaw: String,
        enqueuedAt: Date,
        retryCount: Int,
        lastError: String? = nil
    ) {
        self.id = id
        self.entityKindRaw = entityKindRaw
        self.entityID = entityID
        self.operationRaw = operationRaw
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
        self.lastError = lastError
    }

    func domain() throws -> PendingMutation {
        guard let kind = JournalEntityKind(rawValue: entityKindRaw),
              let operation = SyncOperation(rawValue: operationRaw) else {
            throw SwiftDataJournalRepositoryError.invalidStoredValue
        }
        return PendingMutation(
            id: id,
            entity: .init(kind, entityID),
            operation: operation,
            enqueuedAt: enqueuedAt,
            retryCount: retryCount,
            lastError: lastError
        )
    }
}

@Model private final class StoredSyncMetadataV2 {
    @Attribute(.unique) var key: String
    var payload: Data
    init(key: String, payload: Data) {
        self.key = key
        self.payload = payload
    }
}

@Model private final class StoredSyncConflictV2 {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var resolvedAt: Date?
    init(id: UUID, payload: Data, resolvedAt: Date?) {
        self.id = id
        self.payload = payload
        self.resolvedAt = resolvedAt
    }
}

@Model private final class StoredRepositoryMetadataV2 {
    @Attribute(.unique) var key: String
    var value: String
    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
