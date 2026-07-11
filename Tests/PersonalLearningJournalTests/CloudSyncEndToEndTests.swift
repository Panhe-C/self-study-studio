import CloudKit
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CloudSyncEndToEndTests: XCTestCase {
    func testOfflineEditSurvivesRestartUploadsAndAppearsOnSecondRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstStoreURL = root.appendingPathComponent("first.store")
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Implement a language model",
            currentNextStep: "Read lecture 1",
            createdAt: recordedAt,
            updatedAt: recordedAt
        )
        let offlineRepository = try SwiftDataJournalRepository(url: firstStoreURL)
        try offlineRepository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .user)
        )

        let cloud = SharedFakeCloudDatabaseClient()
        let restartedRepository = try SwiftDataJournalRepository(url: firstStoreURL)
        let firstCoordinator = CloudSyncCoordinator(
            repository: restartedRepository,
            client: cloud
        )
        try await firstCoordinator.syncNow()

        let secondRepository = InMemoryJournalRepository()
        let secondCoordinator = CloudSyncCoordinator(
            repository: secondRepository,
            client: cloud
        )
        try await secondCoordinator.syncNow()

        XCTAssertEqual(try secondRepository.snapshot().projects, [project])
        XCTAssertTrue(try restartedRepository.pendingMutations(limit: 10).isEmpty)
    }
}

private actor SharedFakeCloudDatabaseClient: CloudDatabaseClient {
    private let mapper = CloudRecordMapper()
    private let zoneID = CKRecordZone.ID(
        zoneName: CloudSyncCoordinator.zoneName,
        ownerName: CKCurrentUserDefaultName
    )
    private var records: [CKRecord] = []

    func ensureZone(named: String) async throws {}

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        var acknowledged = Set<UUID>()
        var metadata: [SyncRecordMetadata] = []

        for mutation in mutations {
            switch mutation {
            case let .save(mutationID, entity):
                let record = try mapper.record(for: entity, zoneID: zoneID)
                records.removeAll { $0.recordID == record.recordID }
                records.append(record)
                acknowledged.insert(mutationID)
                metadata.append(
                    SyncRecordMetadata(
                        entity: entity.reference,
                        zoneName: CloudSyncCoordinator.zoneName,
                        recordName: record.recordID.recordName,
                        lastSyncedPayload: try JSONEncoder.journal.encode(entity),
                        lastSyncedAt: Date(),
                        state: .synced
                    )
                )
            case let .delete(mutationID, reference):
                records.removeAll { $0.recordID.recordName == reference.id.uuidString }
                acknowledged.insert(mutationID)
            }
        }

        return CloudSendResult(
            acknowledgedMutationIDs: acknowledged,
            metadata: metadata
        )
    }

    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        guard tokenData == nil else { return CloudChangeBatch() }
        return CloudChangeBatch(
            changes: records.map(CloudRemoteChange.save),
            tokenData: Data("shared-fake-cloud-v1".utf8)
        )
    }
}
