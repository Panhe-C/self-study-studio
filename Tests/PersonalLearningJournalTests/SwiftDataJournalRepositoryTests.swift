import XCTest
@testable import PersonalLearningJournal

final class SwiftDataJournalRepositoryTests: XCTestCase {
    func testSwiftDataRepositoryRoundTripsEntityAndOutboxAcrossInstances() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal-v2.store")
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )

        try autoreleasepool {
            let first = try SwiftDataJournalRepository(url: url)
            try first.commit(
                JournalTransaction(upserts: [.project(project)], origin: .user)
            )
        }

        let second = try SwiftDataJournalRepository(url: url)
        XCTAssertEqual(try second.snapshot().projects.map(\.id), [project.id])
        XCTAssertEqual(try second.pendingMutations(limit: 10).count, 1)
    }

    func testRemoteTransactionPersistsWithoutCreatingOutbox() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let project = Project(
            name: "Guitar",
            area: "Music",
            goal: "Play three songs",
            currentNextStep: "Practice verse one",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = try SwiftDataJournalRepository(
            url: root.appendingPathComponent("journal-v2.store")
        )

        try repository.commit(
            JournalTransaction(upserts: [.project(project)], origin: .remote)
        )

        XCTAssertEqual(try repository.snapshot().projects, [project])
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
    }

    func testDeletionPersistsAsHiddenTombstoneAndOutboundMutation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal-v2.store")
        let project = Project(
            name: "DaVinci",
            area: "Color",
            goal: "Finish",
            currentNextStep: "Practice"
        )

        try autoreleasepool {
            let first = try SwiftDataJournalRepository(url: url)
            try first.commit(
                JournalTransaction(upserts: [.project(project)], origin: .remote)
            )
            try first.commit(
                JournalTransaction(
                    deletions: [.init(.project, project.id)],
                    origin: .user
                )
            )
        }

        let second = try SwiftDataJournalRepository(url: url)
        XCTAssertTrue(try second.snapshot().projects.isEmpty)
        XCTAssertEqual(
            try second.pendingMutations(limit: 10).map(\.operation),
            [.delete]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
