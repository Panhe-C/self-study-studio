import CloudKit
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CloudSyncCoordinatorTests: XCTestCase {
    func testSuccessfulPushAcknowledgesOnlySavedMutations() async throws {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let repository = InMemoryJournalRepository()
        try repository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .user)
        )
        let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        let client = FakeCloudDatabaseClient(
            result: CloudSendResult(acknowledgedMutationIDs: [mutation.id])
        )
        let coordinator = CloudSyncCoordinator(repository: repository, client: client)

        try await coordinator.syncNow()

        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
        let sentCount = await client.sentMutationCount()
        XCTAssertEqual(sentCount, 1)
    }

    func testRetryableFailureKeepsMutationAndIncrementsRetryCount() async throws {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let repository = InMemoryJournalRepository()
        try repository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .user)
        )
        let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        let client = FakeCloudDatabaseClient(
            result: CloudSendResult(retryableErrors: [mutation.id: "network unavailable"])
        )
        let coordinator = CloudSyncCoordinator(repository: repository, client: client)

        try await coordinator.syncNow()

        let pending = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        XCTAssertEqual(pending.id, mutation.id)
        XCTAssertEqual(pending.retryCount, 1)
        XCTAssertEqual(pending.lastError, "network unavailable")
    }

    func testDeleteMutationIsSentAsCloudDelete() async throws {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let repository = InMemoryJournalRepository()
        try repository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .remote)
        )
        try repository.commit(
            JournalTransaction(deletions: [.init(.project, project.id)], origin: .user)
        )
        let client = FakeCloudDatabaseClient(result: CloudSendResult())
        let coordinator = CloudSyncCoordinator(repository: repository, client: client)

        try await coordinator.syncNow()

        let sentMutation = await client.firstSentMutation()
        guard case let .delete(_, reference) = try XCTUnwrap(sentMutation) else {
            return XCTFail("Expected delete mutation")
        }
        XCTAssertEqual(reference, .init(.project, project.id))
    }

    func testRemoteRecordAppliesWithoutCreatingOutboundMutation() async throws {
        let project = Project(
            name: "Remote project",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let mapper = CloudRecordMapper()
        let zoneID = CKRecordZone.ID(
            zoneName: "LearningJournalZone",
            ownerName: CKCurrentUserDefaultName
        )
        let record = try mapper.record(for: .project(project), zoneID: zoneID)
        let repository = InMemoryJournalRepository()
        let client = FakeCloudDatabaseClient(
            result: CloudSendResult(),
            batches: [CloudChangeBatch(changes: [.save(record)], tokenData: Data("token".utf8))]
        )
        let coordinator = CloudSyncCoordinator(repository: repository, client: client)

        try await coordinator.syncNow()

        XCTAssertEqual(try repository.snapshot().projects, [project])
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
    }

    func testRemoteDeleteUsesStoredRecordMetadata() async throws {
        let project = Project(
            name: "Remote project",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let repository = InMemoryJournalRepository()
        try repository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .remote)
        )
        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: .init(.project, project.id),
                zoneName: "LearningJournalZone",
                recordName: project.id.uuidString,
                state: .synced
            )
        ])
        let recordID = CKRecord.ID(
            recordName: project.id.uuidString,
            zoneID: CKRecordZone.ID(zoneName: "LearningJournalZone", ownerName: CKCurrentUserDefaultName)
        )
        let client = FakeCloudDatabaseClient(
            result: CloudSendResult(),
            batches: [CloudChangeBatch(changes: [.delete(recordID)])]
        )
        let coordinator = CloudSyncCoordinator(repository: repository, client: client)

        try await coordinator.syncNow()

        XCTAssertTrue(try repository.snapshot().projects.isEmpty)
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
    }

    func testConcurrentSyncRequestsShareOneInFlightOperation() async throws {
        let repository = InMemoryJournalRepository()
        let client = FakeCloudDatabaseClient(result: CloudSendResult())
        let coordinator = CloudSyncCoordinator(repository: repository, client: client)

        async let first: Void = coordinator.syncNow()
        async let second: Void = coordinator.syncNow()
        _ = try await (first, second)

        let ensureZoneCallCount = await client.ensureZoneCallCount()
        XCTAssertEqual(ensureZoneCallCount, 1)
    }

    func testConcurrentSyncRequestWaitsForInFlightOperation() async throws {
        let repository = InMemoryJournalRepository()
        let client = PausingCloudDatabaseClient()
        let coordinator = CloudSyncCoordinator(repository: repository, client: client)
        let secondStarted = AsyncFlag()
        let secondFinished = AsyncFlag()

        let first = Task { try await coordinator.syncNow() }
        while await client.ensureZoneCallCount() == 0 {
            await Task.yield()
        }
        let second = Task {
            await secondStarted.set()
            try await coordinator.syncNow()
            await secondFinished.set()
        }
        while !(await secondStarted.value()) {
            await Task.yield()
        }
        for _ in 0..<100 {
            if await secondFinished.value() { break }
            await Task.yield()
        }

        let finishedBeforeRelease = await secondFinished.value()
        XCTAssertFalse(finishedBeforeRelease)

        await client.releaseZoneRequest()
        try await first.value
        try await second.value
        let finishedAfterRelease = await secondFinished.value()
        XCTAssertTrue(finishedAfterRelease)
    }
}

private actor FakeCloudDatabaseClient: CloudDatabaseClient {
    private var result: CloudSendResult
    private var batches: [CloudChangeBatch]
    private var sentMutations: [CloudMutation] = []
    private var ensureZoneCalls = 0

    init(result: CloudSendResult, batches: [CloudChangeBatch] = []) {
        self.result = result
        self.batches = batches
    }

    func ensureZone(named: String) async throws {
        ensureZoneCalls += 1
        await Task.yield()
    }

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        sentMutations.append(contentsOf: mutations)
        return result
    }

    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        return batches.isEmpty ? CloudChangeBatch() : batches.removeFirst()
    }

    func sentMutationCount() -> Int { sentMutations.count }

    func firstSentMutation() -> CloudMutation? { sentMutations.first }

    func ensureZoneCallCount() -> Int { ensureZoneCalls }
}

private actor PausingCloudDatabaseClient: CloudDatabaseClient {
    private var ensureZoneCalls = 0
    private var zoneContinuation: CheckedContinuation<Void, Never>?

    func ensureZone(named: String) async throws {
        ensureZoneCalls += 1
        await withCheckedContinuation { continuation in
            zoneContinuation = continuation
        }
    }

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        CloudSendResult()
    }

    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        CloudChangeBatch()
    }

    func ensureZoneCallCount() -> Int { ensureZoneCalls }

    func releaseZoneRequest() {
        zoneContinuation?.resume()
        zoneContinuation = nil
    }
}

private actor AsyncFlag {
    private var isSet = false

    func set() { isSet = true }

    func value() -> Bool { isSet }
}
