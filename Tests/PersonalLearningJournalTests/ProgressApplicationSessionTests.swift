import Foundation
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class ProgressApplicationSessionTests: XCTestCase {
    func testManualProjectFlowSurvivesSessionReopen() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let session = ProgressApplicationSession(documentsDirectory: folder)
        var draft = try XCTUnwrap(session.startDraft())
        draft.name = "学习 React"
        draft.units = [
            .init(title: "组件"),
            .init(title: "状态")
        ]
        XCTAssertTrue(session.saveDraft(draft))
        let project = try XCTUnwrap(session.confirmDraft(id: draft.id))
        XCTAssertEqual(session.projects.count, 1)
        XCTAssertTrue(session.drafts.isEmpty)

        session.updateProject(id: project.id) {
            try ContentProgress.setCompleted($0, unitID: project.units[0].id, completed: true)
        }
        XCTAssertEqual(ContentProgress.projection(for: try XCTUnwrap(session.projects.first)).percentage, 50)

        let reopened = ProgressApplicationSession(documentsDirectory: folder)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.projects.count, 1)
        XCTAssertEqual(ContentProgress.projection(for: try XCTUnwrap(reopened.projects.first)).currentUnitID,
                       project.units[1].id)
    }
}
