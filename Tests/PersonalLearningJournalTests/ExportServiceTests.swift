import XCTest
@testable import PersonalLearningJournal

final class ExportServiceTests: XCTestCase {
    func testExportArchiveUsesRecoverableEncryptedEnvelope() throws {
        let project = Project(name: "Archive", area: "Learning", goal: "Recover", currentNextStep: "Export")
        let snapshot = JournalSnapshot(projects: [project])
        let envelope = try ExportService().exportArchive(
            snapshot: snapshot,
            attachments: ["attachments/note.txt": Data("note".utf8)],
            password: "secret",
            derivationRounds: 20
        )

        let preview = try JournalArchiveService(derivationRounds: 20).preview(envelope, password: "secret")

        XCTAssertTrue(envelope.encrypted)
        XCTAssertEqual(try JournalArchiveService().restore(preview).snapshot, snapshot)
    }

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
        XCTAssertFalse(json.contains("accountHash"))
        XCTAssertFalse(json.contains("PendingMutation"))
        XCTAssertFalse(json.contains("lastError"))
        XCTAssertFalse(json.contains("SyncConflict"))
        XCTAssertFalse(json.contains("CalendarBinding"))
        XCTAssertFalse(json.contains("eventIdentifier"))
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

        XCTAssertEqual(export.version, "v0.2")
        XCTAssertEqual(export.projects.map(\.id), [project.id])
        XCTAssertEqual(export.sessions.map(\.id), [session.id])
        XCTAssertEqual(export.proofs.map(\.id), [proof.id])
    }

    func testExportJSONIncludesPracticeRoutineAndSession() throws {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let routine = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let session = PracticeSession(
            routineId: routine.id,
            linkedProjectId: UUID(),
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(120),
            activeDurationSeconds: 120,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let data = try ExportService().exportJSON(
            snapshot: JournalSnapshot(practiceRoutines: [routine], practiceSessions: [session])
        )
        let export = try JSONDecoder.journal.decode(JournalExport.self, from: data)

        XCTAssertEqual(export.practiceRoutines, [routine])
        XCTAssertEqual(export.practiceSessions, [session])
    }

    func testLegacyExportDecodesWithEmptyPracticeCollections() throws {
        let export = JournalExport(
            exportedAt: Date(timeIntervalSince1970: 10_000),
            projects: [],
            sessions: [],
            proofs: [],
            reviews: []
        )
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.journal.encode(export)) as? [String: Any]
        )
        payload.removeValue(forKey: "practiceRoutines")
        payload.removeValue(forKey: "practiceSessions")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder.journal.decode(JournalExport.self, from: legacyData)

        XCTAssertTrue(decoded.practiceRoutines.isEmpty)
        XCTAssertTrue(decoded.practiceSessions.isEmpty)
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

    func testExportJSONRoundTripsConfirmedSessionAssessmentAndRevisions() throws {
        let confirmedAt = Date(timeIntervalSince1970: 1_000)
        let project = Project(name: "CS336", area: "AI", goal: "Finish", currentNextStep: "Lecture 1")
        let assessment = LearningRecordAssessment(
            progress: .mostlyCompleted,
            completedCriterionIDs: ["criterion-1", "criterion-2"],
            understanding: .mostlyUnderstood,
            blocker: "Need an example for the edge case",
            aiDraftedSummary: true,
            userEditedSummary: true,
            confirmedAt: confirmedAt,
            revision: 2
        )
        let session = try LearningSession(
            projectId: project.id,
            source: .timer,
            actionType: .course,
            startedAt: confirmedAt,
            endedAt: confirmedAt.addingTimeInterval(1_800),
            durationMinutes: 30,
            note: "Implemented the merge loop",
            nextStepBefore: "Write the merge loop",
            nextStepAfter: "Add tests",
            createdAt: confirmedAt,
            updatedAt: confirmedAt,
            assessment: assessment
        )
        let revision = LearningRecordRevision(
            sessionID: session.id,
            revision: 2,
            previousNote: "Read chapter one",
            previousAssessment: LearningRecordAssessment(
                progress: .partial,
                completedCriterionIDs: [],
                blocker: "Missing example",
                aiDraftedSummary: false,
                userEditedSummary: false,
                confirmedAt: confirmedAt,
                revision: 1
            ),
            revisedAt: confirmedAt.addingTimeInterval(3_600)
        )
        let snapshot = JournalSnapshot(
            projects: [project],
            sessions: [session],
            learningRecordRevisions: [revision]
        )

        let data = try ExportService().exportJSON(snapshot: snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let firstPass = try JSONDecoder.journal.decode(JournalExport.self, from: data)
        let secondPass = try JSONDecoder.journal.decode(
            JournalExport.self,
            from: JSONEncoder.journal.encode(firstPass)
        )

        XCTAssertTrue(json.contains("\"assessment\""))
        XCTAssertEqual(secondPass.sessions, [session])
        XCTAssertEqual(secondPass.sessions.first?.assessment, assessment)
        XCTAssertEqual(secondPass.learningRecordRevisions, [revision])
        XCTAssertEqual(
            secondPass.learningRecordRevisions.first?.previousAssessment,
            revision.previousAssessment
        )
    }

    func testExportJSONRoundTripsAdjustmentSuggestionDecisions() throws {
        let createdAt = Date(timeIntervalSince1970: 4_000)
        let decidedAt = Date(timeIntervalSince1970: 5_000)
        let project = Project(name: "Guitar", area: "Music", goal: "Daily habit", currentNextStep: "Pentatonic")
        let pending = LearningAdjustmentSuggestion(
            projectID: project.id,
            sourceSessionIDs: [UUID()],
            kind: .nextStep,
            title: "Repeated partial progress",
            rationale: "The last 2 confirmed records ended partially.",
            proposedValue: "Split the checkpoint",
            createdAt: createdAt
        )
        let adopted = LearningAdjustmentSuggestion(
            projectID: project.id,
            kind: .temporaryDuration,
            title: "Shorten late-night sessions",
            rationale: "Late-night sessions keep slipping.",
            proposedValue: "25 minutes for 3 days",
            decision: .adopted,
            createdAt: createdAt,
            decidedAt: decidedAt
        )
        let snapshot = JournalSnapshot(
            projects: [project],
            learningAdjustmentSuggestions: [pending, adopted]
        )

        let data = try ExportService().exportJSON(snapshot: snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let firstPass = try JSONDecoder.journal.decode(JournalExport.self, from: data)
        let secondPass = try JSONDecoder.journal.decode(
            JournalExport.self,
            from: JSONEncoder.journal.encode(firstPass)
        )

        XCTAssertTrue(json.contains("\"learningAdjustmentSuggestions\""))
        XCTAssertEqual(secondPass.learningAdjustmentSuggestions, [pending, adopted])
        XCTAssertEqual(secondPass.learningAdjustmentSuggestions.last?.decision, .adopted)
        XCTAssertEqual(secondPass.learningAdjustmentSuggestions.last?.decidedAt, decidedAt)
    }

    func testExportJSONContainsNoPendingStudyCaptureContent() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = PendingStudyCaptureStore(directory: temporaryDirectory)
        let capture = try store.begin(projectID: UUID(), source: .timer)
        let project = Project(name: "CS336", area: "AI", goal: "Finish", currentNextStep: "Lecture 1")

        let data = try ExportService().exportJSON(snapshot: JournalSnapshot(projects: [project]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains(capture.id.uuidString))
        XCTAssertFalse(json.contains("pendingStudyCapture"))
        XCTAssertFalse(json.contains("PendingStudyCapture"))
        XCTAssertFalse(json.contains("pending-study-captures"))
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
