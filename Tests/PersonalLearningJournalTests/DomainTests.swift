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
}
