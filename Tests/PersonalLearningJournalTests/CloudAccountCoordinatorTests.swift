import CloudKit
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CloudAccountCoordinatorTests: XCTestCase {
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor FakeAccountProvider: CloudAccountProviding {
    let status: CKAccountStatus

    init(status: CKAccountStatus) {
        self.status = status
    }

    func accountStatus() async throws -> CKAccountStatus { status }

    func currentUserRecordName() async throws -> String? { "account-a" }
}
