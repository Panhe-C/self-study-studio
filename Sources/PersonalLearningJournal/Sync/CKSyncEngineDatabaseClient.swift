@preconcurrency import CloudKit
import Foundation

public final class CKSyncEngineDatabaseClient: NSObject, CloudDatabaseClient, CKSyncEngineDelegate, @unchecked Sendable {
    public static let defaultContainerIdentifier = "iCloud.com.local.selfstudystudio"

    private let database: CKDatabase
    private let mapper: CloudRecordMapper
    private let zoneID: CKRecordZone.ID
    private let stateLock = NSLock()
    private var engineStateSerialization: CKSyncEngine.State.Serialization?
    private var engine: CKSyncEngine!

    public init(
        containerIdentifier: String = CKSyncEngineDatabaseClient.defaultContainerIdentifier,
        zoneName: String = CloudSyncCoordinator.zoneName,
        stateSerializationData: Data? = nil,
        mapper: CloudRecordMapper = CloudRecordMapper()
    ) {
        self.database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        self.mapper = mapper
        self.zoneID = CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        self.engineStateSerialization = Self.checkpoint(from: stateSerializationData)?.engineState
        super.init()

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: engineStateSerialization,
            delegate: self
        )
        configuration.automaticallySync = false
        engine = CKSyncEngine(configuration)
    }

    public func ensureZone(named: String) async throws {
        let requestedZoneID = CKRecordZone.ID(
            zoneName: named,
            ownerName: CKCurrentUserDefaultName
        )
        let result = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: requestedZoneID)],
            deleting: []
        )
        if case let .failure(error)? = result.saveResults[requestedZoneID] {
            throw error
        }
    }

    public func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        guard !mutations.isEmpty else { return CloudSendResult() }

        var mutationByRecordID: [CKRecord.ID: CloudMutation] = [:]
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for mutation in mutations {
            switch mutation {
            case let .save(_, entity):
                let record = try await recordForSave(entity)
                mutationByRecordID[record.recordID] = mutation
                recordsToSave.append(record)
            case let .delete(_, reference):
                let recordID = CKRecord.ID(recordName: reference.id.uuidString, zoneID: zoneID)
                mutationByRecordID[recordID] = mutation
                recordIDsToDelete.append(recordID)
            }
        }

        do {
            let result = try await database.modifyRecords(
                saving: recordsToSave,
                deleting: recordIDsToDelete,
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            return try makeSendResult(result, mutationByRecordID: mutationByRecordID)
        } catch {
            return failures(for: mutations, error: error)
        }
    }

    public func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        let checkpoint = Self.checkpoint(from: tokenData)
        let serverToken = try checkpoint.flatMap { try Self.serverChangeToken(from: $0.serverChangeTokenData) }
        let result = try await database.recordZoneChanges(
            inZoneWith: zoneID,
            since: serverToken
        )

        var changes: [CloudRemoteChange] = []
        for (_, recordResult) in result.modificationResultsByID {
            switch recordResult {
            case let .success(modification):
                changes.append(.save(modification.record))
            case let .failure(error):
                throw error
            }
        }
        changes.append(contentsOf: result.deletions.map { .delete($0.recordID) })

        let nextCheckpoint = CloudSyncEngineCheckpoint(
            engineState: currentEngineStateSerialization(),
            serverChangeTokenData: try Self.archivedServerChangeToken(result.changeToken)
        )
        return CloudChangeBatch(
            changes: changes,
            tokenData: try JSONEncoder.journal.encode(nextCheckpoint),
            moreComing: result.moreComing
        )
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        if case let .stateUpdate(update) = event {
            stateLock.withLock {
                engineStateSerialization = update.stateSerialization
            }
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }

    public func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([zoneID]))
    }

    private func recordForSave(_ entity: JournalEntity) async throws -> CKRecord {
        let encoded = try mapper.record(for: entity, zoneID: zoneID)
        let results = try await database.records(for: [encoded.recordID])
        guard case let .success(existing)? = results[encoded.recordID] else {
            return encoded
        }

        let encodedKeys = Set(encoded.allKeys())
        for key in existing.allKeys() where !encodedKeys.contains(key) {
            existing[key] = nil
        }
        for key in encoded.allKeys() {
            existing[key] = encoded[key]
        }
        return existing
    }

    private func makeSendResult(
        _ result: (
            saveResults: [CKRecord.ID: Result<CKRecord, Error>],
            deleteResults: [CKRecord.ID: Result<Void, Error>]
        ),
        mutationByRecordID: [CKRecord.ID: CloudMutation]
    ) throws -> CloudSendResult {
        var acknowledged = Set<UUID>()
        var metadata: [SyncRecordMetadata] = []
        var retryable: [UUID: String] = [:]
        var terminal: [UUID: String] = [:]

        for (recordID, result) in result.saveResults {
            guard let mutation = mutationByRecordID[recordID],
                  case let .save(mutationID, entity) = mutation else { continue }
            switch result {
            case let .success(savedRecord):
                acknowledged.insert(mutationID)
                metadata.append(
                    SyncRecordMetadata(
                        entity: entity.reference,
                        zoneName: zoneID.zoneName,
                        recordName: savedRecord.recordID.recordName,
                        recordChangeTag: savedRecord.recordChangeTag,
                        lastSyncedPayload: try JSONEncoder.journal.encode(entity),
                        lastSyncedAt: Date(),
                        state: .synced
                    )
                )
            case let .failure(error):
                store(error: error, for: mutationID, retryable: &retryable, terminal: &terminal)
            }
        }

        for (recordID, result) in result.deleteResults {
            guard let mutation = mutationByRecordID[recordID],
                  case let .delete(mutationID, _) = mutation else { continue }
            switch result {
            case .success:
                acknowledged.insert(mutationID)
            case let .failure(error):
                store(error: error, for: mutationID, retryable: &retryable, terminal: &terminal)
            }
        }

        return CloudSendResult(
            acknowledgedMutationIDs: acknowledged,
            metadata: metadata,
            retryableErrors: retryable,
            terminalErrors: terminal
        )
    }

    private func failures(for mutations: [CloudMutation], error: Error) -> CloudSendResult {
        var retryable: [UUID: String] = [:]
        var terminal: [UUID: String] = [:]
        for mutation in mutations {
            let mutationID: UUID
            switch mutation {
            case let .save(id, _), let .delete(id, _): mutationID = id
            }
            store(error: error, for: mutationID, retryable: &retryable, terminal: &terminal)
        }
        return CloudSendResult(retryableErrors: retryable, terminalErrors: terminal)
    }

    private func store(
        error: Error,
        for mutationID: UUID,
        retryable: inout [UUID: String],
        terminal: inout [UUID: String]
    ) {
        let message = error.localizedDescription
        guard let cloudError = error as? CKError else {
            retryable[mutationID] = message
            return
        }
        switch cloudError.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverRecordChanged:
            retryable[mutationID] = message
        default:
            terminal[mutationID] = message
        }
    }

    private func currentEngineStateSerialization() -> CKSyncEngine.State.Serialization? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return engineStateSerialization
    }

    private static func checkpoint(from data: Data?) -> CloudSyncEngineCheckpoint? {
        guard let data else { return nil }
        return try? JSONDecoder.journal.decode(CloudSyncEngineCheckpoint.self, from: data)
    }

    private static func archivedServerChangeToken(_ token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func serverChangeToken(from data: Data?) throws -> CKServerChangeToken? {
        guard let data else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}

private struct CloudSyncEngineCheckpoint: Codable {
    var engineState: CKSyncEngine.State.Serialization?
    var serverChangeTokenData: Data?
}
