import XCTest
@testable import PersonalLearningJournal

final class AttachmentStoreTests: XCTestCase {
    func testSavesDataIntoLearningJournalAttachmentFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(rootDirectory: root)
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let sessionId = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let proofId = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!

        let attachment = try store.saveData(
            Data("image-bytes".utf8),
            projectId: projectId,
            sessionId: sessionId,
            proofId: proofId,
            originalFileName: "before-after.png",
            mimeType: "image/png"
        )

        let expectedURL = root
            .appendingPathComponent("LearningJournal")
            .appendingPathComponent("Attachments")
            .appendingPathComponent(projectId.uuidString)
            .appendingPathComponent(sessionId.uuidString)
            .appendingPathComponent("\(proofId.uuidString).png")
        XCTAssertEqual(attachment.fileURL, expectedURL)
        XCTAssertEqual(attachment.fileSize, 11)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(try Data(contentsOf: expectedURL), Data("image-bytes".utf8))
    }

    func testCopiesFileIntoProjectLevelAttachmentFolderWhenSessionIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("notes.pdf")
        try Data("pdf".utf8).write(to: sourceFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let proofId = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let attachment = try AttachmentStore(rootDirectory: root).copyFile(
            from: sourceFile,
            projectId: projectId,
            sessionId: nil,
            proofId: proofId,
            mimeType: "application/pdf"
        )

        XCTAssertEqual(
            attachment.fileURL.path,
            root
                .appendingPathComponent("LearningJournal")
                .appendingPathComponent("Attachments")
                .appendingPathComponent(projectId.uuidString)
                .appendingPathComponent("project")
                .appendingPathComponent("\(proofId.uuidString).pdf")
                .path
        )
        XCTAssertEqual(try Data(contentsOf: attachment.fileURL), Data("pdf".utf8))
    }
}
