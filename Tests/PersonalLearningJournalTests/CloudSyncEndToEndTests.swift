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

    func testInFlightBaseAckUpgradesReflectionGuardAndPreventsOverwrite() async throws {
        let timestamp = Date(timeIntervalSince1970: 20_000)
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
        let baseTransactionID = try XCTUnwrap(
            repository.pendingMutations(limit: 100)
                .first(where: { $0.entity == sessionReference })?.transactionID
        )

        let cloud = InFlightPracticeCloudClient()
        let coordinator = CloudSyncCoordinator(repository: repository, client: cloud)
        let syncTask = Task { try await coordinator.syncNow() }
        await cloud.waitUntilFirstSendStarted()

        _ = try service.updateSessionReflection(
            sessionId: sessionID,
            routineId: routine.id,
            linkedProjectId: routine.projectId,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: 120,
            note: "Enriched reflection"
        )
        await cloud.releaseFirstSend()
        try await syncTask.value

        let pendingAfterAck = try repository.pendingMutations(limit: 100)
        let replacement = try XCTUnwrap(
            pendingAfterAck.first(where: { $0.entity == sessionReference })
        )
        XCTAssertEqual(replacement.transactionID, baseTransactionID)
        XCTAssertEqual(
            replacement.revisionExpectation,
            .existingTarget(revisionID: sessionID, recordChangeTag: "server-v1")
        )
        XCTAssertEqual(
            pendingAfterAck.filter { $0.entity.kind == .practiceSession }.count,
            1
        )
        XCTAssertEqual(try repository.snapshot().practiceSessions.first?.note, "Enriched reflection")

        try await cloud.queueRemotePracticeEdit(sessionID: sessionID, note: "Remote edit")
        try await coordinator.syncNow()

        let conflicts = try repository.conflicts()
        XCTAssertTrue(conflicts.contains { $0.entity == sessionReference })
        let serverNote = try await cloud.serverPracticeNote(sessionID: sessionID)
        XCTAssertEqual(serverNote, "Remote edit")
        XCTAssertEqual(try repository.snapshot().practiceSessions.first?.note, "Enriched reflection")
        XCTAssertEqual(
            try repository.terminalMutations(limit: 100)
                .filter { $0.entity == sessionReference }.count,
            1
        )
    }

    func testInFlightBaseTerminalResultPropagatesToReflectionReplacement() async throws {
        let timestamp = Date(timeIntervalSince1970: 30_000)
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
        let baseMutation = try XCTUnwrap(
            repository.pendingMutations(limit: 100)
                .first(where: { $0.entity == sessionReference })
        )

        let cloud = InFlightPracticeCloudClient(terminalizeFirstSend: true)
        let coordinator = CloudSyncCoordinator(repository: repository, client: cloud)
        let syncTask = Task { try await coordinator.syncNow() }
        await cloud.waitUntilFirstSendStarted()

        _ = try service.updateSessionReflection(
            sessionId: sessionID,
            routineId: routine.id,
            linkedProjectId: routine.projectId,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationSeconds: 120,
            note: "Enriched reflection"
        )
        let replacement = try XCTUnwrap(
            repository.pendingMutations(limit: 100)
                .first(where: { $0.entity == sessionReference })
        )
        XCTAssertNotEqual(replacement.id, baseMutation.id)
        XCTAssertTrue(replacement.supersededMutationIDs.contains(baseMutation.id))

        await cloud.releaseFirstSend()
        try await syncTask.value

        XCTAssertTrue(try repository.pendingMutations(limit: 100).isEmpty)
        let terminal = try repository.terminalMutations(limit: 100)
        let transactionIDs = Set(terminal.map(\.transactionID))
        XCTAssertEqual(transactionIDs.count, 1)
        XCTAssertTrue(terminal.allSatisfy { $0.transactionID == replacement.transactionID })
        let terminalReplacement = try XCTUnwrap(
            terminal.first(where: { $0.entity == sessionReference })
        )
        XCTAssertEqual(terminalReplacement.id, replacement.id)
        XCTAssertEqual(terminalReplacement.lastError, "stale server tag")
        XCTAssertTrue(terminalReplacement.isTerminal)
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

private actor InFlightPracticeCloudClient: CloudDatabaseClient {
    private let terminalizeFirstSend: Bool
    private let mapper = CloudRecordMapper()
    private let zoneID = CKRecordZone.ID(
        zoneName: CloudSyncCoordinator.zoneName,
        ownerName: CKCurrentUserDefaultName
    )
    private var records: [String: CKRecord] = [:]
    private var serverTags: [JournalEntityReference: String] = [:]
    private var queuedChanges: [CloudRemoteChange] = []
    private var didPauseFirstSend = false
    private var firstSendReleased = false
    private var sendStartedContinuation: CheckedContinuation<Void, Never>?
    private var sendReleaseContinuation: CheckedContinuation<Void, Never>?
    private var fetchTokenIssued = false

    init(terminalizeFirstSend: Bool = false) {
        self.terminalizeFirstSend = terminalizeFirstSend
    }

    func ensureZone(named: String) async throws {}

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        try await send(mutations, revisionExpectations: [:])
    }

    func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: CloudRevisionExpectation]
    ) async throws -> CloudSendResult {
        var acknowledged: Set<UUID> = []
        var metadata: [SyncRecordMetadata] = []
        var terminalErrors: [UUID: String] = [:]
        let shouldTerminalize = terminalizeFirstSend && !didPauseFirstSend
        for mutation in mutations {
            guard case let .save(mutationID, entity) = mutation else { continue }
            if shouldTerminalize {
                terminalErrors[mutationID] = "stale server tag"
                continue
            }
            let currentTag = serverTags[entity.reference]
            if let expectation = revisionExpectations[entity.reference],
               expectation.targetRecordState == .existingRecord,
               currentTag != expectation.targetRecordChangeTag {
                terminalErrors[mutationID] = "stale server tag"
                continue
            }
            let record = try mapper.record(for: entity, zoneID: zoneID)
            records[key(for: record)] = record
            let serverTag = currentTag ?? "server-v1"
            serverTags[entity.reference] = serverTag
            acknowledged.insert(mutationID)
            metadata.append(
                SyncRecordMetadata(
                    entity: entity.reference,
                    zoneName: CloudSyncCoordinator.zoneName,
                    recordName: record.recordID.recordName,
                    recordChangeTag: serverTag,
                    lastSyncedPayload: try JSONEncoder.journal.encode(entity),
                    lastSyncedAt: Date(),
                    state: .synced
                )
            )
        }

        if !didPauseFirstSend {
            didPauseFirstSend = true
            sendStartedContinuation?.resume()
            sendStartedContinuation = nil
            if !firstSendReleased {
                await withCheckedContinuation { continuation in
                    sendReleaseContinuation = continuation
                }
            }
        }
        return CloudSendResult(
            acknowledgedMutationIDs: acknowledged,
            metadata: metadata,
            terminalErrors: terminalErrors
        )
    }

    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        if !fetchTokenIssued {
            fetchTokenIssued = true
            return CloudChangeBatch(tokenData: Data("race-v1".utf8))
        }
        let changes = queuedChanges
        queuedChanges.removeAll()
        return CloudChangeBatch(
            changes: changes,
            tokenData: Data("race-v2".utf8)
        )
    }

    func waitUntilFirstSendStarted() async {
        if didPauseFirstSend { return }
        await withCheckedContinuation { continuation in
            sendStartedContinuation = continuation
        }
    }

    func releaseFirstSend() {
        firstSendReleased = true
        sendReleaseContinuation?.resume()
        sendReleaseContinuation = nil
    }

    func queueRemotePracticeEdit(sessionID: UUID, note: String) throws {
        let reference = JournalEntityReference(.practiceSession, sessionID)
        guard let record = records[key(kind: .practiceSession, id: sessionID)] else {
            throw CloudRecordMapperError.mismatchedRecordIdentifier
        }
        guard case var .practiceSession(session) = try mapper.entity(from: record) else {
            throw CloudRecordMapperError.mismatchedRecordIdentifier
        }
        session.note = note
        let edited = try mapper.record(for: .practiceSession(session), zoneID: zoneID)
        records[key(for: edited)] = edited
        serverTags[reference] = "server-v2"
        queuedChanges.append(.save(edited))
    }

    func serverPracticeNote(sessionID: UUID) throws -> String? {
        guard let record = records[key(kind: .practiceSession, id: sessionID)] else {
            return nil
        }
        guard case let .practiceSession(session) = try mapper.entity(from: record) else {
            return nil
        }
        return session.note
    }

    private func key(for record: CKRecord) -> String {
        key(kind: record.recordType, id: record.recordID.recordName)
    }

    private func key(kind: JournalEntityKind, id: UUID) -> String {
        let recordType = kind == .practiceSession ? "PracticeSession" : kind.rawValue
        return key(kind: recordType, id: id.uuidString)
    }

    private func key(kind: String, id: String) -> String {
        "\(kind):\(id)"
    }
}
