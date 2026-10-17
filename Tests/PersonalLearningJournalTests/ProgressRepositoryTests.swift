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

    func testSessionKeepsSavedDataWhenDraftWriteFails() throws {
        let backing = try SwiftDataProgressRepository.inMemory()
        let project = try ContentProgress.createProject(name: "CS336", titles: ["Lecture 1"])
        let draft = ContentProgress.Draft(name: "React", units: [.init(title: "JSX")])
        try backing.save(project)
        try backing.save(draft)
        let repository = FailingProgressRepository(backing: backing)
        let session = ProgressApplicationSession(repository: repository)

        var edited = draft
        edited.name = "React 19"
        repository.failNextDraftSave = true
        XCTAssertFalse(session.saveDraft(edited))
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(session.projects, [project])
        XCTAssertEqual(session.drafts, [draft])
        XCTAssertEqual(try backing.draft(id: draft.id), draft)

        XCTAssertTrue(session.saveDraft(edited))
        XCTAssertEqual(session.drafts, [edited])
        XCTAssertNil(session.errorMessage)
    }

    func testSessionKeepsDraftWhenConfirmationWriteFails() throws {
        let backing = try SwiftDataProgressRepository.inMemory()
        let draft = ContentProgress.Draft(name: "React", units: [.init(title: "JSX")])
        try backing.save(draft)
        let repository = FailingProgressRepository(backing: backing)
        let session = ProgressApplicationSession(repository: repository)

        repository.failNextConfirmation = true
        XCTAssertNil(session.confirmDraft(id: draft.id))
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(session.drafts, [draft])
        XCTAssertTrue(session.projects.isEmpty)
        XCTAssertEqual(try backing.draft(id: draft.id), draft)
        XCTAssertNil(try backing.project(id: draft.id))

        XCTAssertEqual(session.confirmDraft(id: draft.id)?.id, draft.id)
        XCTAssertTrue(session.drafts.isEmpty)
        XCTAssertEqual(session.projects.map(\.id), [draft.id])
        XCTAssertNil(session.errorMessage)
    }
}

@MainActor
private final class FailingProgressRepository: ContentProgressRepository {
    let backing: SwiftDataProgressRepository
    var failNextDraftSave = false
    var failNextConfirmation = false

    init(backing: SwiftDataProgressRepository) { self.backing = backing }

    func projects() throws -> [ContentProgress.Project] { try backing.projects() }
    func project(id: UUID) throws -> ContentProgress.Project? { try backing.project(id: id) }
    func save(_ project: ContentProgress.Project) throws { try backing.save(project) }
    func draft(id: UUID) throws -> ContentProgress.Draft? { try backing.draft(id: id) }
    func drafts() throws -> [ContentProgress.Draft] { try backing.drafts() }
    func save(_ draft: ContentProgress.Draft) throws {
        if failNextDraftSave {
            failNextDraftSave = false
            throw Failure.write
        }
        try backing.save(draft)
    }
    func removeDraft(id: UUID) throws { try backing.removeDraft(id: id) }
    func confirmDraft(id: UUID, now: Date) throws -> ContentProgress.Project {
        if failNextConfirmation {
            failNextConfirmation = false
            throw Failure.write
        }
        return try backing.confirmDraft(id: id, now: now)
    }

    private enum Failure: Error { case write }
}
