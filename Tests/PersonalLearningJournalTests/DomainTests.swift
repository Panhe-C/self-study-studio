import XCTest
@testable import PersonalLearningJournal

final class DomainTests: XCTestCase {
    func testLegacyProjectDecodesWithCurrentSchemaAndNoDeletion() throws {
        let data = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"CS336","area":"AI","goal":"Finish","status":"active","currentNextStep":"Lecture 1","lastActionType":"course","defaultDurationMinutes":30,"createdAt":"2001-01-01T00:00:00Z","updatedAt":"2001-01-01T00:00:00Z"}"#.utf8
        )

        let project = try JSONDecoder.journal.decode(Project.self, from: data)

        XCTAssertNil(project.deletedAt)
        XCTAssertEqual(project.schemaVersion, JournalSchema.currentVersion)
    }

    func testLegacySnapshotDecodesEmptyPracticeCollections() throws {
        let data = Data(#"{"projects":[],"sessions":[],"proofs":[],"reviews":[],"trailEvents":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(JournalSnapshot.self, from: data)
        XCTAssertEqual(snapshot.practiceRoutines, [])
        XCTAssertEqual(snapshot.practiceSessions, [])
    }

    func testLegacyJournalEntitiesDecodeWithCurrentSchemaAndNoDeletion() throws {
        let projectId = UUID()
        let sourceId = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let entities: [(Data, (Data) throws -> (Date?, Int))] = [
            (
                try legacyData(for: LearningSession(
                    projectId: projectId,
                    source: .quickLog,
                    actionType: .course,
                    startedAt: date,
                    endedAt: date.addingTimeInterval(1_800),
                    durationMinutes: 30,
                    note: "Read chapter one",
                    nextStepBefore: "Start",
                    nextStepAfter: "Continue"
                )),
                { data in
                    let value = try JSONDecoder.journal.decode(LearningSession.self, from: data)
                    return (value.deletedAt, value.schemaVersion)
                }
            ),
            (
                try legacyData(for: Proof(
                    projectId: projectId,
                    type: .link,
                    title: "Notes",
                    statement: "Shows the chapter was summarized"
                )),
                { data in
                    let value = try JSONDecoder.journal.decode(Proof.self, from: data)
                    return (value.deletedAt, value.schemaVersion)
                }
            ),
            (
                try legacyData(for: Review(
                    periodStart: date,
                    periodEnd: date.addingTimeInterval(86_400),
                    facts: [],
                    patterns: [],
                    decisions: [],
                    projectRecommendations: [:],
                    nextSteps: [:],
                    aiSourceSummary: []
                )),
                { data in
                    let value = try JSONDecoder.journal.decode(Review.self, from: data)
                    return (value.deletedAt, value.schemaVersion)
                }
            ),
            (
                try legacyData(for: TrailEvent(
                    projectId: projectId,
                    type: .session,
                    sourceId: sourceId,
                    occurredAt: date,
                    title: "Study session",
                    detail: "Read chapter one"
                )),
                { data in
                    let value = try JSONDecoder.journal.decode(TrailEvent.self, from: data)
                    return (value.deletedAt, value.schemaVersion)
                }
            )
        ]

        for (data, decodeMetadata) in entities {
            let (deletedAt, schemaVersion) = try decodeMetadata(data)
            XCTAssertNil(deletedAt)
            XCTAssertEqual(schemaVersion, JournalSchema.currentVersion)
        }
    }

    func testActiveProjectRequiresANextStepForContinue() {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            currentNextStep: "整理 perplexity"
        )

        XCTAssertTrue(project.canContinue)
    }

    func testActiveProjectWithoutNextStepDoesNotContinue() {
        let project = Project(
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱 3 首歌",
            currentNextStep: ""
        )

        XCTAssertFalse(project.canContinue)
    }

    func testPausedProjectDoesNotContinueEvenWithNextStep() {
        let project = Project(
            name: "DaVinci",
            area: "Color",
            goal: "掌握基础调色工作流",
            status: .paused,
            currentNextStep: "做一组 before/after"
        )

        XCTAssertFalse(project.canContinue)
    }

    func testProofStatementMustExplainWhatItProves() {
        XCTAssertThrowsError(
            try Proof(
                projectId: UUID(),
                type: .image,
                title: "Before after",
                statement: " "
            )
        )
    }

    private func legacyData<T: Encodable>(for value: T) throws -> Data {
        let encoded = try JSONEncoder.journal.encode(value)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "deletedAt")
        object.removeValue(forKey: "schemaVersion")
        return try JSONSerialization.data(withJSONObject: object)
    }
}
