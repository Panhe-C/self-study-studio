import XCTest
@testable import PersonalLearningJournal

final class TrashExportServiceTests: XCTestCase {
    func testPrepareCreatesShareableArchiveContainingJournalAndAttachments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let attachment = root.appendingPathComponent("record.m4a")
        try Data("audio".utf8).write(to: attachment)
        let project = Project(
            name: "Trash export",
            area: "Test",
            goal: "Keep history",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_700_000_000),
            previousStatusBeforeTrash: .active
        )
        let proof = try Proof(
            projectId: project.id,
            type: .audio,
            title: "Recording",
            statement: "A recording",
            localPath: attachment.path
        )
        let snapshot = JournalSnapshot(projects: [project], proofs: [proof])

        let document = try TrashExportService(
            archiveService: JournalArchiveService(derivationRounds: 20)
        ).prepare(
            snapshot: snapshot,
            project: project,
            to: root.appendingPathComponent("Exports", isDirectory: true)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: document.url.path))
        XCTAssertEqual(document.attachmentCount, 1)
        let envelope = try JSONDecoder.journal.decode(
            JournalArchiveEnvelope.self,
            from: Data(contentsOf: document.url)
        )
        let preview = try JournalArchiveService(derivationRounds: 20).preview(envelope, password: nil)
        XCTAssertEqual(preview.snapshot.projects, [project])
        XCTAssertEqual(preview.attachmentData.values.first, Data("audio".utf8))
    }

    func testPreparePropagatesExportFailureAndNeverReturnsReadyDocument() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedDirectory = root.appendingPathComponent("blocked", isDirectory: true)
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let project = Project(
            name: "Trash export",
            area: "Test",
            goal: "Keep history",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_700_000_000),
            previousStatusBeforeTrash: .active
        )

        XCTAssertThrowsError(
            try TrashExportService(
                archiveService: JournalArchiveService(derivationRounds: 20)
            ).prepare(snapshot: JournalSnapshot(projects: [project]), project: project, to: blockedDirectory)
        )
    }
}
