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
        try await send(mutations, revisionExpectations: [:])
    }

    public func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: CloudRevisionExpectation]
    ) async throws -> CloudSendResult {
        guard !mutations.isEmpty else { return CloudSendResult() }

        var mutationByRecordID: [CKRecord.ID: CloudMutation] = [:]
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        do {
            // CloudKit does not make records created in this modifyRecords
            // request visible to a separate preflight fetch. Stage every
            // encoded record first so a revision guard can resolve a base
            // revision that is also being created by this atomic batch.
            var batchPreflight = CKSyncEngineBatchPreflightState()
            var encodedRecords: [CKRecord.ID: CKRecord] = [:]
            for mutation in mutations {
                if case let .save(_, entity) = mutation {
                    let encoded = try mapper.record(for: entity, zoneID: zoneID)
                    encodedRecords[encoded.recordID] = encoded
                    batchPreflight.stage(encoded)
                }
            }
            var materializedRecords: [CKRecord.ID: CKRecord] = [:]

            // Guarded preflight belongs to the same error-store boundary as
            // modifyRecords: a stale/missing tag becomes a terminal result
            // for this atomic transaction instead of an untracked throw.
            for mutation in mutations {
                switch mutation {
                case let .save(_, entity):
                    let record = try await recordForSave(
                        entity,
                        expectation: revisionExpectations[entity.reference],
                        encoded: try encodedRecord(
                            for: entity,
                            from: encodedRecords
                        ),
                        batchPreflight: batchPreflight,
                        materializedRecords: &materializedRecords
                    )
                    mutationByRecordID[record.recordID] = mutation
                    recordsToSave.append(record)
                case let .delete(_, reference):
                    let recordID = CKRecord.ID(recordName: reference.id.uuidString, zoneID: zoneID)
                    mutationByRecordID[recordID] = mutation
                    recordIDsToDelete.append(recordID)
                }
            }
            let result = try await database.modifyRecords(
                saving: recordsToSave,
                deleting: recordIDsToDelete,
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
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

    private func recordForSave(
        _ entity: JournalEntity,
        expectation: CloudRevisionExpectation?,
        encoded: CKRecord,
        batchPreflight: CKSyncEngineBatchPreflightState,
        materializedRecords: inout [CKRecord.ID: CKRecord]
    ) async throws -> CKRecord {
        let targetResult: Result<CKRecord, Error>?
        if let materialized = materializedRecords[encoded.recordID] {
            targetResult = .success(materialized)
        } else {
            targetResult = try await database.records(for: [encoded.recordID])[encoded.recordID]
        }
        if let expectation {
            if let baseRevisionID = expectation.baseRevisionID,
               baseRevisionID.uuidString != encoded.recordID.recordName {
                let baseID = CKRecord.ID(recordName: baseRevisionID.uuidString, zoneID: zoneID)
                let baseResult: Result<CKRecord, Error>?
                if let materialized = materializedRecords[baseID] {
                    baseResult = .success(materialized)
                } else if expectation.baseRecordChangeTag == nil,
                          batchPreflight.stagedRecord(for: baseID) != nil {
                    // A nil tag is the intentional representation of a new
                    // base record. It is safe to validate against the
                    // pre-staged in-batch record without asking CloudKit for
                    // a record that cannot exist server-side yet.
                    try batchPreflight.validateBaseRevision(
                        baseRecordID: baseID,
                        expectation: expectation,
                        entity: entity
                    )
                    baseResult = .success(try batchPreflight.stagedRecord(for: baseID).unwrap())
                } else {
                    baseResult = try await database.records(for: [baseID])[baseID]
                }
                guard case let .success(baseRecord)? = baseResult,
                      baseRecord.recordChangeTag == expectation.baseRecordChangeTag else {
                    throw CloudRevisionGuardError.stale(
                        entity: entity.reference,
                        expectedRecordChangeTag: expectation.baseRecordChangeTag,
                        actualRecordChangeTag: (try? actualTag(from: baseResult)) ?? nil
                    )
                }
                let targetExists = if case .success? = targetResult { true } else { false }
                try validateTarget(
                    expectation: expectation,
                    entity: entity,
                    currentExists: targetExists,
                    currentTag: (try? actualTag(from: targetResult)) ?? nil
                )
            } else {
                let currentExists = if case .success? = targetResult { true } else { false }
                let currentTag = try? actualTag(from: targetResult)
                try validateTarget(
                    expectation: expectation,
                    entity: entity,
                    currentExists: currentExists,
                    currentTag: currentTag ?? nil
                )
            }
        }

        guard case let .success(existing)? = targetResult else {
            return encoded
        }

        let encodedKeys = Set(encoded.allKeys())
        for key in existing.allKeys() where !encodedKeys.contains(key) {
            existing[key] = nil
        }
        for key in encoded.allKeys() {
            existing[key] = encoded[key]
        }
        materializedRecords[encoded.recordID] = existing
        return existing
    }

    private func encodedRecord(
        for entity: JournalEntity,
        from records: [CKRecord.ID: CKRecord]
    ) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: entity.reference.id.uuidString, zoneID: zoneID)
        guard let record = records[recordID] else {
            throw CloudRecordMapperError.mismatchedRecordIdentifier
        }
        return record
    }

    private func validateTarget(
        expectation: CloudRevisionExpectation,
        entity: JournalEntity,
        currentExists: Bool,
        currentTag: String?
    ) throws {
        switch expectation.targetRecordState {
        case .newRecord where currentExists:
            throw CloudRevisionGuardError.stale(
                entity: entity.reference,
                expectedRecordChangeTag: expectation.targetRecordChangeTag,
                actualRecordChangeTag: currentTag
            )
        case .existingRecord:
            guard currentExists, currentTag == expectation.targetRecordChangeTag else {
                throw CloudRevisionGuardError.stale(
                    entity: entity.reference,
                    expectedRecordChangeTag: expectation.targetRecordChangeTag,
                    actualRecordChangeTag: currentTag
                )
            }
        default:
            break
        }
    }

    private func actualTag(
        from result: Result<CKRecord, Error>?
    ) throws -> String? {
        guard case let .success(record)? = result else { return nil }
        return record.recordChangeTag
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
        if let guardError = error as? CloudRevisionGuardError {
            terminal[mutationID] = String(describing: guardError)
            return
        }
        guard let cloudError = error as? CKError else {
            retryable[mutationID] = message
            return
        }
        switch cloudError.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
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

/// In-memory view of records staged by one atomic CloudKit write. CloudKit
/// preflight reads cannot observe these records until the request commits, so
/// revision guards use this state for new base revisions created in the same
/// request.
struct CKSyncEngineBatchPreflightState {
    private var stagedRecords: [CKRecord.ID: CKRecord] = [:]

    mutating func stage(_ record: CKRecord) {
        stagedRecords[record.recordID] = record
    }

    func stagedRecord(for recordID: CKRecord.ID) -> CKRecord? {
        stagedRecords[recordID]
    }

    func validateBaseRevision(
        baseRecordID: CKRecord.ID,
        expectation: CloudRevisionExpectation,
        entity: JournalEntity
    ) throws {
        guard let baseRecord = stagedRecords[baseRecordID],
              baseRecord.recordChangeTag == expectation.baseRecordChangeTag else {
            throw CloudRevisionGuardError.stale(
                entity: entity.reference,
                expectedRecordChangeTag: expectation.baseRecordChangeTag,
                actualRecordChangeTag: stagedRecords[baseRecordID]?.recordChangeTag
            )
        }
    }
}

private extension Optional {
    func unwrap(or error: Error = CKRecordUnwrapError.missing) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}

private enum CKRecordUnwrapError: Error {
    case missing
}

private struct CloudSyncEngineCheckpoint: Codable {
    var engineState: CKSyncEngine.State.Serialization?
    var serverChangeTokenData: Data?
}
