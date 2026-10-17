import Foundation
import XCTest
@testable import PersonalLearningJournal

@MainActor
final class ProgressRepositoryTests: XCTestCase {
    func testDraftConfirmationIsAtomicAndIdempotent() throws {
        let repository = try SwiftDataProgressRepository.inMemory()
        let draft = ContentProgress.Draft(
            name: " 学习 React ",
            units: [ContentProgress.DraftUnit(title: "JSX"), ContentProgress.DraftUnit(title: "Hooks")]
        )
        try repository.save(draft)
        XCTAssertEqual(try repository.drafts().map(\.id), [draft.id])
        let confirmed = try repository.confirmDraft(id: draft.id)
        XCTAssertEqual(confirmed.id, draft.id)
        XCTAssertEqual(confirmed.units.map(\.id), draft.units.map(\.id))
        XCTAssertNil(try repository.draft(id: draft.id))
        XCTAssertEqual(try repository.confirmDraft(id: draft.id), confirmed)
        XCTAssertEqual(try repository.projects().count, 1)
    }

    func testInvalidDraftRemainsWhenConfirmationFails() throws {
        let repository = try SwiftDataProgressRepository.inMemory()
        let draft = ContentProgress.Draft(name: " ", units: [])
        try repository.save(draft)
        XCTAssertThrowsError(try repository.confirmDraft(id: draft.id))
        XCTAssertNotNil(try repository.draft(id: draft.id))
        XCTAssertTrue(try repository.projects().isEmpty)
    }

    func testProjectPersistsAcrossRepositoryReopen() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-store-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("progress.sqlite")
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try ContentProgress.createProject(name: "CS336", titles: ["Lecture 1"])
        do {
            let repository = try SwiftDataProgressRepository(url: url)
            try repository.save(project)
        }
        let reopened = try SwiftDataProgressRepository(url: url)
        XCTAssertEqual(try reopened.project(id: project.id), project)
    }
}
