import XCTest
@testable import PersonalLearningJournal

final class DomainTests: XCTestCase {
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
