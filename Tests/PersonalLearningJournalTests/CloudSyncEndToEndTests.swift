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

    func testPracticeEntitiesUploadDownloadAndRemoteDeletion() async throws {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let projectID = UUID()
        let routine = PracticeRoutine(
            projectId: projectID,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let session = PracticeSession(
            routineId: routine.id,
            linkedProjectId: projectID,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(120),
            activeDurationSeconds: 120,
            note: "Chord changes",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let cloud = SharedFakeCloudDatabaseClient()
        let firstRepository = InMemoryJournalRepository()
        try firstRepository.commit(
            JournalTransaction(
                upserts: [.practiceRoutine(routine), .practiceSession(session)],
                origin: .user
            )
        )
        let firstCoordinator = CloudSyncCoordinator(repository: firstRepository, client: cloud)

        try await firstCoordinator.syncNow()

        let secondRepository = InMemoryJournalRepository()
        let secondCoordinator = CloudSyncCoordinator(repository: secondRepository, client: cloud)
        try await secondCoordinator.syncNow()
        XCTAssertEqual(try secondRepository.snapshot().practiceRoutines, [routine])
        XCTAssertEqual(try secondRepository.snapshot().practiceSessions, [session])

        await cloud.queueRemoteDeletion(recordName: routine.id.uuidString)
        try await firstCoordinator.syncNow()

        XCTAssertTrue(try firstRepository.snapshot().practiceRoutines.isEmpty)
        XCTAssertEqual(try firstRepository.snapshot().practiceSessions, [session])
        XCTAssertTrue(try firstRepository.pendingMutations(limit: 10).isEmpty)
    }

    func testPracticeBaseAndReflectionShareOneCloudTransaction() async throws {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let project = Project(
            name: "Practice Project",
            area: "Learning",
            goal: "Improve",
            currentNextStep: "Keep going",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let routine = PracticeRoutine(
            projectId: project.id,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository()
        try repository.commit(
            JournalTransaction(
                upserts: [.project(project), .practiceRoutine(routine)],
                origin: .remote
            )
        )
        let service = PracticeService(
            repository: repository,
            now: { timestamp.addingTimeInterval(1) }
        )
        let sessionID = UUID()
        let sessionReference = JournalEntityReference(.practiceSession, sessionID)
        let startedAt = timestamp
        let endedAt = timestamp.addingTimeInterval(120)
        _ = try service.saveSession(
            sessionId: sessionID,
            routineId: routine.id,
            linkedProjectId: routine.projectId,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: 120,
            note: nil
        )
        let basePending = try repository.pendingMutations(limit: 100)
        let baseTransactionID = try XCTUnwrap(
            basePending.first(where: { $0.entity == sessionReference })?.transactionID
        )

        _ = try service.updateSessionReflection(
            sessionId: sessionID,
            routineId: routine.id,
            linkedProjectId: routine.projectId,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: 120,
            note: "Enriched reflection"
        )

        let pending = try repository.pendingMutations(limit: 100)
        XCTAssertEqual(
            pending.filter { $0.entity == sessionReference }.count,
            1,
            "Reflection should replace the base PracticeSession mutation, not create a second transaction payload"
        )
        XCTAssertEqual(Set(pending.map(\.transactionID)), Set([baseTransactionID]))
        XCTAssertEqual(
            Set(pending.map(\.entity.kind)),
            Set([.project, .practiceSession, .session, .trailEvent])
        )

        let cloud = SharedFakeCloudDatabaseClient()
        let coordinator = CloudSyncCoordinator(repository: repository, client: cloud)
        try await coordinator.syncNow()

        let sentReferences = await cloud.sentReferences()
        XCTAssertEqual(sentReferences.count, 4)
        XCTAssertEqual(sentReferences.filter { $0 == sessionReference }.count, 1)
        XCTAssertEqual(sentReferences.filter { $0.kind == .project }.count, 1)
        XCTAssertEqual(sentReferences.filter { $0.kind == .session }.count, 1)
        XCTAssertEqual(sentReferences.filter { $0.kind == .trailEvent }.count, 1)

        let remoteRepository = InMemoryJournalRepository()
        let remoteCoordinator = CloudSyncCoordinator(repository: remoteRepository, client: cloud)
        try await remoteCoordinator.syncNow()
        let remoteSnapshot = try remoteRepository.snapshot()
        XCTAssertEqual(remoteSnapshot.practiceSessions.count, 1)
        XCTAssertEqual(remoteSnapshot.practiceSessions.first?.id, sessionID)
        XCTAssertEqual(remoteSnapshot.practiceSessions.first?.note, "Enriched reflection")
        XCTAssertEqual(remoteSnapshot.sessions.count, 1)
        XCTAssertEqual(remoteSnapshot.projects.count, 1)
        XCTAssertEqual(remoteSnapshot.trailEvents.count, 1)
    }
}

private actor SharedFakeCloudDatabaseClient: CloudDatabaseClient {
    private let mapper = CloudRecordMapper()
    private let zoneID = CKRecordZone.ID(
        zoneName: CloudSyncCoordinator.zoneName,
        ownerName: CKCurrentUserDefaultName
    )
    private var records: [CKRecord] = []
    private var remoteChanges: [CloudRemoteChange] = []
    private var sentReferenceLog: [JournalEntityReference] = []

    func ensureZone(named: String) async throws {}

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        var acknowledged = Set<UUID>()
        var metadata: [SyncRecordMetadata] = []
        sentReferenceLog.append(contentsOf: mutations.map { mutation in
            switch mutation {
            case let .save(_, entity): return entity.reference
            case let .delete(_, reference): return reference
            }
        })

        for mutation in mutations {
            switch mutation {
            case let .save(mutationID, entity):
                let record = try mapper.record(for: entity, zoneID: zoneID)
                records.removeAll {
                    $0.recordID == record.recordID && $0.recordType == record.recordType
                }
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
        if tokenData == nil {
            return CloudChangeBatch(
                changes: records.map(CloudRemoteChange.save),
                tokenData: Data("shared-fake-cloud-v1".utf8)
            )
        }
        let changes = remoteChanges
        remoteChanges = []
        return CloudChangeBatch(changes: changes)
    }

    func queueRemoteDeletion(recordName: String) {
        records.removeAll { $0.recordID.recordName == recordName }
        remoteChanges.append(
            .delete(CKRecord.ID(recordName: recordName, zoneID: zoneID))
        )
    }

    func sentReferences() -> [JournalEntityReference] {
        sentReferenceLog
    }
}
