import CloudKit
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CloudAccountCoordinatorTests: XCTestCase {
    func testSystemProviderDoesNotLoadCloudKitWithoutEntitlement() async throws {
        let provider = SystemCloudAccountProvider(
            hasCloudKitEntitlement: { false },
            accountStatusLoader: { throw UnexpectedCloudKitCall() },
            userRecordNameLoader: { throw UnexpectedCloudKitCall() }
        )

        let status = try await provider.accountStatus()
        let recordName = try await provider.currentUserRecordName()

        XCTAssertEqual(status, .noAccount)
        XCTAssertNil(recordName)
    }

    func testDifferentAccountRecordNamesResolveDifferentStoreURLs() throws {
        let coordinator = CloudAccountCoordinator(rootDirectory: temporaryDirectory())

        let first = coordinator.storeURL(forAccountRecordName: "account-a")
        let second = coordinator.storeURL(forAccountRecordName: "account-b")

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.path.contains("account-a"))
        XCTAssertFalse(second.path.contains("account-b"))
    }

    func testNoAccountKeepsLocalStoreAvailable() async throws {
        let coordinator = CloudAccountCoordinator(rootDirectory: temporaryDirectory())
        await coordinator.refresh(using: FakeAccountProvider(status: .noAccount))

        XCTAssertEqual(coordinator.state.mode, .localOnly)
        XCTAssertNotNil(coordinator.activeRepository)
    }

    func testBootstrapPreviewsThenEnqueuesExistingEntitiesOnlyAfterConfirmation() throws {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project])
        )
        let coordinator = CloudAccountCoordinator(
            rootDirectory: temporaryDirectory(),
            repositoryFactory: { _ in repository }
        )

        XCTAssertEqual(try coordinator.prepareExistingLocalDataForCloud(), 1)
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)

        try coordinator.confirmExistingLocalDataUpload()

        XCTAssertEqual(try repository.pendingMutations(limit: 10).map(\.entity), [.init(.project, project.id)])
    }

    func testBootstrapCopiesLocalDataToCloudStoreOnlyAfterConfirmation() async throws {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let root = temporaryDirectory()
        let localRepository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project])
        )
        let cloudRepository = InMemoryJournalRepository()
        let coordinator = CloudAccountCoordinator(
            rootDirectory: root,
            repositoryFactory: { url in
                url.path.contains("/local/") ? localRepository : cloudRepository
            }
        )

        await coordinator.refresh(using: FakeAccountProvider(status: .available))

        XCTAssertEqual(try coordinator.prepareExistingLocalDataForCloud(), 1)
        XCTAssertTrue(try cloudRepository.pendingMutations(limit: 10).isEmpty)
        XCTAssertTrue(try localRepository.pendingMutations(limit: 10).isEmpty)

        try coordinator.confirmExistingLocalDataUpload()

        XCTAssertEqual(
            try cloudRepository.pendingMutations(limit: 10).map(\.entity),
            [.init(.project, project.id)]
        )
        XCTAssertTrue(try localRepository.pendingMutations(limit: 10).isEmpty)
    }

    func testBootstrapCopiesPracticeDataToCloudStoreOnlyAfterConfirmation() async throws {
        let routine = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let session = PracticeSession(
            routineId: routine.id,
            startedAt: Date(timeIntervalSince1970: 10_000),
            endedAt: Date(timeIntervalSince1970: 10_120),
            activeDurationSeconds: 120
        )
        let localRepository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(practiceRoutines: [routine], practiceSessions: [session])
        )
        let cloudRepository = InMemoryJournalRepository()
        let coordinator = CloudAccountCoordinator(
            rootDirectory: temporaryDirectory(),
            repositoryFactory: { url in
                url.path.contains("/local/") ? localRepository : cloudRepository
            }
        )

        await coordinator.refresh(using: FakeAccountProvider(status: .available))

        XCTAssertEqual(try coordinator.prepareExistingLocalDataForCloud(), 2)
        try coordinator.confirmExistingLocalDataUpload()

        XCTAssertEqual(
            try cloudRepository.pendingMutations(limit: 10).map(\.entity),
            [.init(.practiceRoutine, routine.id), .init(.practiceSession, session.id)]
        )
        XCTAssertTrue(try localRepository.pendingMutations(limit: 10).isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct UnexpectedCloudKitCall: Error {}

private actor FakeAccountProvider: CloudAccountProviding {
    let status: CKAccountStatus

    init(status: CKAccountStatus) {
        self.status = status
    }

    func accountStatus() async throws -> CKAccountStatus { status }

    func currentUserRecordName() async throws -> String? { "account-a" }
}
