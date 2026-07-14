import Foundation

public enum SyncOperation: String, Codable, Sendable {
    case save
    case delete
}

public enum SyncDatabaseScope: String, Codable, Sendable {
    case privateDatabase
}

public enum SyncState: String, Codable, Sendable {
    case pending
    case syncing
    case synced
    case failed
    case conflict
}

public struct PendingMutation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entity: JournalEntityReference
    public var operation: SyncOperation
    public var enqueuedAt: Date
    public var retryCount: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        entity: JournalEntityReference,
        operation: SyncOperation,
        enqueuedAt: Date = Date(),
        retryCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.entity = entity
        self.operation = operation
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

public struct SyncRecordMetadata: Codable, Equatable, Sendable {
    public var entity: JournalEntityReference
    public var zoneName: String
    public var recordName: String
    public var recordChangeTag: String?
    public var lastSyncedPayload: Data?
    public var lastSyncedAt: Date?
    public var state: SyncState
    public var lastError: String?

    public init(
        entity: JournalEntityReference,
        zoneName: String,
        recordName: String,
        recordChangeTag: String? = nil,
        lastSyncedPayload: Data? = nil,
        lastSyncedAt: Date? = nil,
        state: SyncState,
        lastError: String? = nil
    ) {
        self.entity = entity
        self.zoneName = zoneName
        self.recordName = recordName
        self.recordChangeTag = recordChangeTag
        self.lastSyncedPayload = lastSyncedPayload
        self.lastSyncedAt = lastSyncedAt
        self.state = state
        self.lastError = lastError
    }
}

public struct SyncConflict: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entity: JournalEntityReference
    public var basePayload: Data
    public var localPayload: Data
    public var serverPayload: Data
    public var proposedPayload: Data
    public var conflictingFields: [String]
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        entity: JournalEntityReference,
        basePayload: Data,
        localPayload: Data,
        serverPayload: Data,
        proposedPayload: Data,
        conflictingFields: [String],
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.entity = entity
        self.basePayload = basePayload
        self.localPayload = localPayload
        self.serverPayload = serverPayload
        self.proposedPayload = proposedPayload
        self.conflictingFields = conflictingFields
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}
