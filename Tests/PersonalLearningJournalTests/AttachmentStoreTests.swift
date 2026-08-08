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

    func testRemovingAttachmentIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(rootDirectory: root)
        let file = try store.saveData(
            Data("proof".utf8),
            projectId: UUID(),
            sessionId: nil,
            proofId: UUID(),
            originalFileName: "proof.txt",
            mimeType: "text/plain"
        )

        try store.removeAttachment(at: file.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path))
        XCTAssertNoThrow(try store.removeAttachment(at: file.fileURL))
    }

    func testRemovingAttachmentRejectsTraversalOutsideAttachmentRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("do not delete".utf8).write(to: outside)
        let traversal = root
            .appendingPathComponent("LearningJournal/Attachments/project/session/../../../../outside.txt")

        XCTAssertThrowsError(try AttachmentStore(rootDirectory: root).removeAttachment(at: traversal)) { error in
            XCTAssertEqual(error as? AttachmentStoreError, .unsafePath(traversal.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testRemovingAttachmentRejectsSymlinkEvenWhenItPointsInsideRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(rootDirectory: root)
        let real = try store.saveData(
            Data("proof".utf8),
            projectId: UUID(),
            sessionId: nil,
            proofId: UUID(),
            originalFileName: "proof.txt",
            mimeType: "text/plain"
        )
        let symlink = real.fileURL.deletingLastPathComponent().appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: real.fileURL)

        XCTAssertThrowsError(try store.removeAttachment(at: symlink)) { error in
            XCTAssertEqual(error as? AttachmentStoreError, .unsafePath(symlink.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.fileURL.path))
    }

    func testRemovingImportedCloudAssetIsAllowedWithinImportedAssetsRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("cloud".utf8).write(to: source)
        let store = AttachmentStore(rootDirectory: root)
        let imported = try store.importCloudAsset(at: source, proofId: UUID())

        try store.removeAttachment(at: imported)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
    }

    func testRemovingImportedCloudAssetRejectsSymlinkAndTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AttachmentStore(rootDirectory: root)
        try Data("cloud".utf8).write(to: source)
        let imported = try store.importCloudAsset(at: source, proofId: UUID())
        let link = imported.deletingLastPathComponent().appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: imported)

        XCTAssertThrowsError(try store.removeAttachment(at: link)) { error in
            XCTAssertEqual(error as? AttachmentStoreError, .unsafePath(link.path))
        }
        XCTAssertThrowsError(
            try store.removeAttachment(
                at: root.appendingPathComponent("LearningJournal/ImportedAssets/../../source.bin")
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
    }
}
