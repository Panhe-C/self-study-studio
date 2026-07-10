import XCTest
@testable import PersonalLearningJournal

final class JournalStoreTests: XCTestCase {
    func testSwiftDataStoreRoundTripsEachJournalEntity() throws {
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let proofID = UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
        let reviewID = UUID(uuidString: "00000000-0000-0000-0000-000000000404")!
        let trailID = UUID(uuidString: "00000000-0000-0000-0000-000000000405")!
        let createdAt = Date(timeIntervalSince1970: 10_000)
        let project = Project(
            id: projectID,
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            currentNextStep: "写 notebook",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let session = try LearningSession(
            id: sessionID,
            projectId: projectID,
            source: .quickLog,
            actionType: .output,
            startedAt: createdAt,
            endedAt: createdAt.addingTimeInterval(30 * 60),
            durationMinutes: 30,
            note: "写完第一版 bigram",
            nextStepBefore: "写 notebook",
            nextStepAfter: "记录 loss",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let proof = try Proof(
            id: proofID,
            projectId: projectID,
            sessionId: sessionID,
            type: .link,
            title: "Notebook",
            statement: "证明完成第一版 bigram",
            url: URL(string: "https://github.com/example/notebook"),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let review = Review(
            id: reviewID,
            periodStart: createdAt,
            periodEnd: createdAt.addingTimeInterval(7 * 24 * 60 * 60),
            facts: ["CS336: 1 session."],
            patterns: ["Output is attached."],
            decisions: ["Continue one notebook."],
            projectRecommendations: [projectID: .active],
            nextSteps: [projectID: "记录 loss"],
            aiSourceSummary: ["session 00000000: 写完第一版 bigram"],
            sourceReferences: ["Continue one notebook.": ["session 00000000: 写完第一版 bigram"]],
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let event = TrailEvent(
            id: trailID,
            projectId: projectID,
            type: .session,
            sourceId: sessionID,
            occurredAt: createdAt,
            title: "30 min · output",
            detail: "写完第一版 bigram"
        )
        let snapshot = JournalSnapshot(
            projects: [project],
            sessions: [session],
            proofs: [proof],
            reviews: [review],
            trailEvents: [event],
            hasCompletedOnboarding: true
        )
        let store = try SwiftDataJournalStore.inMemory()

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
    }

    func testDefaultStoreImportsLegacyJSONWhenSwiftDataIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root
            .appendingPathComponent("LearningJournal", isDirectory: true)
            .appendingPathComponent("journal.json")
        let project = Project(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            currentNextStep: "练第一段"
        )
        let legacySnapshot = JournalSnapshot(projects: [project], hasCompletedOnboarding: true)
        let legacyStore = JSONJournalStore(fileURL: legacyURL)
        try legacyStore.save(legacySnapshot)
        let decodedLegacySnapshot = try legacyStore.load()

        let store = try JournalStoreFactory.makeDefault(documentsDirectory: root)

        XCTAssertEqual(try store.load(), decodedLegacySnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }
}
