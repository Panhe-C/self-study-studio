import XCTest
@testable import PersonalLearningJournal

final class TerminalConflictRecoveryTests: XCTestCase {
    func testReplaceTerminalMutationUpdatesPayloadAndFreshGuardAtomically() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Project(
            name: "Original",
            area: "AI",
            goal: "Learn",
            currentNextStep: "Read",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository()
        try repository.commit(JournalTransaction(upserts: [.project(original)], origin: .user))
        let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        try repository.recordSyncFailures(retryable: [:], terminal: [mutation.id: "stale guard"])

        var replacement = original
        replacement.name = "Fresh"
        let expectation = RevisionGuardExpectation.existingTarget(
            revisionID: original.id,
            recordChangeTag: "server-v2"
        )
        try repository.replaceTerminalMutations([
            TerminalMutationReplacement(
                mutationID: mutation.id,
                entity: .project(replacement),
                revisionExpectation: expectation
            )
        ])

        let pending = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        XCTAssertEqual(pending.id, mutation.id)
        XCTAssertEqual(pending.revisionExpectation, expectation)
        XCTAssertEqual(pending.retryCount, 0)
        XCTAssertNil(pending.lastError)
        XCTAssertFalse(pending.isTerminal)
        XCTAssertEqual(try repository.snapshot().projects.first?.name, "Fresh")
        XCTAssertTrue(try repository.terminalMutations(limit: 10).isEmpty)
    }

    func testSwiftDataReplacementAndDiscardPersistAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.store")
        let project = Project(name: "Persisted", area: "AI", goal: "Learn", currentNextStep: "Read")
        var mutationID: UUID?

        try autoreleasepool {
            let repository = try SwiftDataJournalRepository(url: url)
            try repository.commit(JournalTransaction(upserts: [.project(project)], origin: .user))
            let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
            mutationID = mutation.id
            try repository.recordSyncFailures(retryable: [:], terminal: [mutation.id: "stale"])

            var replacement = project
            replacement.name = "Retry"
            try repository.replaceTerminalMutations([
                TerminalMutationReplacement(
                    mutationID: mutation.id,
                    entity: .project(replacement),
                    revisionExpectation: .existingTarget(
                        revisionID: project.id,
                        recordChangeTag: "server-v3"
                    )
                )
            ])
        }

        let reopened = try SwiftDataJournalRepository(url: url)
        let resolvedMutationID = try XCTUnwrap(mutationID)
        let pending = try XCTUnwrap(reopened.pendingMutations(limit: 1).first)
        XCTAssertEqual(pending.id, resolvedMutationID)
        XCTAssertEqual(pending.revisionExpectation?.recordChangeTag, "server-v3")
        XCTAssertEqual(try reopened.snapshot().projects.first?.name, "Retry")

        try reopened.recordSyncFailures(retryable: [:], terminal: [resolvedMutationID: "stale again"])
        try reopened.discardTerminalMutations([resolvedMutationID])
        XCTAssertTrue(try reopened.pendingMutations(limit: 10).isEmpty)
        XCTAssertTrue(try reopened.terminalMutations(limit: 10).isEmpty)

        let reopenedAgain = try SwiftDataJournalRepository(url: url)
        XCTAssertTrue(try reopenedAgain.pendingMutations(limit: 10).isEmpty)
        XCTAssertTrue(try reopenedAgain.terminalMutations(limit: 10).isEmpty)
        XCTAssertEqual(try reopenedAgain.snapshot().projects.first?.name, "Retry")
    }

    func testRecoveryServiceUsesCurrentMetadataTagWhenRetrying() throws {
        let project = Project(name: "Guard", area: "AI", goal: "Learn", currentNextStep: "Read")
        let reference = JournalEntityReference(.project, project.id)
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        try repository.commit(
            JournalTransaction(
                upserts: [.project(project)],
                origin: .user,
                revisionExpectations: [reference: .existingTarget(
                    revisionID: project.id,
                    recordChangeTag: "server-v1"
                )]
            )
        )
        let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        try repository.recordSyncFailures(retryable: [:], terminal: [mutation.id: "stale"])
        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: reference,
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: project.id.uuidString,
                recordChangeTag: "server-v4",
                state: .synced
            )
        ])

        try SyncConflictRecoveryService(repository: repository).retryTerminalMutation(id: mutation.id)

        let retried = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        XCTAssertEqual(retried.revisionExpectation?.recordChangeTag, "server-v4")
        XCTAssertEqual(retried.revisionExpectation?.targetRecordState, .existingRecord)
    }

    func testLegacyRequeueEntryPointAlsoRefreshesGuard() throws {
        let project = Project(name: "Legacy", area: "AI", goal: "Learn", currentNextStep: "Read")
        let reference = JournalEntityReference(.project, project.id)
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        try repository.commit(
            JournalTransaction(
                upserts: [.project(project)],
                origin: .user,
                revisionExpectations: [reference: .existingTarget(
                    revisionID: project.id,
                    recordChangeTag: "old"
                )]
            )
        )
        let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        try repository.recordSyncFailures(retryable: [:], terminal: [mutation.id: "stale"])
        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: reference,
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: project.id.uuidString,
                recordChangeTag: "new",
                state: .synced
            )
        ])

        try repository.requeueTerminalMutations([mutation.id])

        XCTAssertEqual(
            try XCTUnwrap(repository.pendingMutations(limit: 1).first).revisionExpectation?.recordChangeTag,
            "new"
        )
    }

    @MainActor
    func testDiscardedTerminalMutationDoesNotKeepCoordinatorFailed() async throws {
        let project = Project(name: "Discard", area: "AI", goal: "Learn", currentNextStep: "Read")
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        try repository.commit(JournalTransaction(upserts: [.project(project)], origin: .user))
        let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        try repository.recordSyncFailures(retryable: [:], terminal: [mutation.id: "stale"])
        let coordinator = CloudSyncCoordinator(
            repository: repository,
            client: TerminalRecoveryCloudClient()
        )

        try await coordinator.syncNow()
        guard case .failed = coordinator.status else {
            return XCTFail("terminal mutation should initially fail")
        }

        try SyncConflictRecoveryService(repository: repository)
            .discardTerminalMutation(id: mutation.id)
        try await coordinator.syncNow()

        guard case .synced = coordinator.status else {
            return XCTFail("discarding terminal mutation should clear failed status on next sync")
        }
    }

    @MainActor
    func testViewModelExposesAndDiscardsTerminalRecoveryItem() async throws {
        let project = Project(name: "Visible", area: "AI", goal: "Learn", currentNextStep: "Read")
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        try repository.commit(JournalTransaction(upserts: [.project(project)], origin: .user))
        let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        try repository.recordSyncFailures(retryable: [:], terminal: [mutation.id: "stale"])
        let journalService = JournalService(repository: repository)
        let viewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            practiceService: PracticeService(repository: repository),
            practiceTimer: PracticeTimerRuntime(store: TerminalRecoveryTimerStateStore()),
            syncRepository: repository
        )

        await viewModel.refreshSyncSummary()
        XCTAssertEqual(viewModel.syncTerminalMutations.map(\.id), [mutation.id])

        try viewModel.discardTerminalMutation(id: mutation.id)

        XCTAssertTrue(viewModel.syncTerminalMutations.isEmpty)
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
        XCTAssertTrue(try repository.terminalMutations(limit: 10).isEmpty)
    }
}

private actor TerminalRecoveryCloudClient: CloudDatabaseClient {
    func ensureZone(named: String) async throws {}
    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        CloudSendResult()
    }
    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        CloudChangeBatch()
    }
}

@MainActor
private final class TerminalRecoveryTimerStateStore: PracticeTimerStateStore {
    private var data: Data?

    func load() -> Data? { data }

    func save(_ data: Data?) throws {
        self.data = data
    }
}
