import XCTest
@testable import PersonalLearningJournal

final class ExportServiceTests: XCTestCase {
    func testExportContainsDomainSchemaButNoSyncMetadata() throws {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let proof = try Proof(
            projectId: project.id,
            type: .file,
            title: "Local notes",
            statement: "Shows the notes were captured",
            localPath: "/private/user/Documents/notes.md"
        )

        let data = try ExportService().exportJSON(
            snapshot: JournalSnapshot(projects: [project], proofs: [proof])
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let export = try JSONDecoder.journal.decode(JournalExport.self, from: data)

        XCTAssertTrue(json.contains("schemaVersion"))
        XCTAssertFalse(json.contains("recordChangeTag"))
        XCTAssertFalse(json.contains("accountRecordName"))
        XCTAssertFalse(json.contains("/private/user/Documents/notes.md"))
        XCTAssertNil(export.proofs.first?.localPath)
    }

    func testExportJSONContainsVersionAndJournalData() throws {
        let service = JournalService(store: InMemoryJournalStore())
        let project = try service.createProject(
            name: "CS336",
            area: "AI",
            goal: "复现课程",
            nextStep: "整理 perplexity"
        )
        let session = try service.quickLog(
            projectId: project.id,
            durationMinutes: 20,
            note: "补记一次学习",
            nextStep: "继续整理"
        )
        let proof = try service.addProof(
            projectId: project.id,
            sessionId: session.id,
            type: .link,
            title: "Notebook",
            statement: "证明完成了第一版 bigram baseline"
        )

        let exportedData = try ExportService().exportJSON(snapshot: service.snapshot())
        let export = try JSONDecoder.journal.decode(JournalExport.self, from: exportedData)

        XCTAssertEqual(export.version, "v0.1")
        XCTAssertEqual(export.projects.map(\.id), [project.id])
        XCTAssertEqual(export.sessions.map(\.id), [session.id])
        XCTAssertEqual(export.proofs.map(\.id), [proof.id])
    }

    func testAttachmentManifestUsesProjectSessionProofFolderShape() throws {
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let sessionId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let proof = try Proof(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            projectId: projectId,
            sessionId: sessionId,
            type: .audio,
            title: "练习录音",
            statement: "证明第一段能弹完",
            localPath: "recording.m4a"
        )

        let path = ExportService().attachmentExportPath(for: proof)

        XCTAssertEqual(
            path,
            "Attachments/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002/00000000-0000-0000-0000-000000000003.m4a"
        )
    }

    func testExportAttachmentsCopiesLocalFilesIntoManifestShape() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let exportDirectory = temporaryRoot.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let sourceFile = sourceDirectory.appendingPathComponent("recording.m4a")
        try Data("audio".utf8).write(to: sourceFile)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            name: "Guitar",
            area: "Music",
            goal: "完整弹唱",
            currentNextStep: "练第一段"
        )
        let proof = try Proof(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            projectId: project.id,
            sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            type: .audio,
            title: "练习录音",
            statement: "证明第一段能弹完",
            localPath: sourceFile.path
        )
        let snapshot = JournalSnapshot(projects: [project], proofs: [proof])

        let copiedFiles = try ExportService().exportAttachments(
            snapshot: snapshot,
            to: exportDirectory
        )

        let expectedFile = exportDirectory
            .appendingPathComponent("Attachments")
            .appendingPathComponent(project.id.uuidString)
            .appendingPathComponent(proof.sessionId!.uuidString)
            .appendingPathComponent("\(proof.id.uuidString).m4a")
        XCTAssertEqual(copiedFiles, [expectedFile])
        XCTAssertEqual(try Data(contentsOf: expectedFile), Data("audio".utf8))
    }

    func testExportBundleWritesJournalJSONAndAttachmentsTogether() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let exportDirectory = temporaryRoot.appendingPathComponent("LearningJournalExport", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let sourceFile = sourceDirectory.appendingPathComponent("before-after.png")
        try Data("image".utf8).write(to: sourceFile)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            name: "DaVinci",
            area: "Color",
            goal: "掌握基础调色工作流",
            currentNextStep: "做一组 before/after"
        )
        let proof = try Proof(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
            projectId: project.id,
            sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            type: .image,
            title: "before/after",
            statement: "证明能控制白平衡",
            localPath: sourceFile.path
        )
        let snapshot = JournalSnapshot(projects: [project], proofs: [proof])

        let bundle = try ExportService().exportBundle(
            snapshot: snapshot,
            to: exportDirectory
        )

        XCTAssertEqual(bundle.jsonURL, exportDirectory.appendingPathComponent("journal.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.jsonURL.path))
        let export = try JSONDecoder.journal.decode(
            JournalExport.self,
            from: Data(contentsOf: bundle.jsonURL)
        )
        XCTAssertEqual(export.projects.map(\.id), [project.id])

        let expectedAttachment = exportDirectory
            .appendingPathComponent("Attachments")
            .appendingPathComponent(project.id.uuidString)
            .appendingPathComponent(proof.sessionId!.uuidString)
            .appendingPathComponent("\(proof.id.uuidString).png")
        XCTAssertEqual(bundle.attachmentURLs, [expectedAttachment])
        XCTAssertEqual(try Data(contentsOf: expectedAttachment), Data("image".utf8))
    }
}
