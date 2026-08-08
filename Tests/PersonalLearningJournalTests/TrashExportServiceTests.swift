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

    func testPrepareExportsOnlySelectedProjectDependenciesAndAttachments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let selectedAttachment = root.appendingPathComponent("selected.txt")
        let otherAttachment = root.appendingPathComponent("other.txt")
        try Data("selected".utf8).write(to: selectedAttachment)
        try Data("other".utf8).write(to: otherAttachment)
        let selected = Project(
            name: "Selected",
            area: "Test",
            goal: "Keep",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let other = Project(
            name: "Other",
            area: "Test",
            goal: "Keep",
            status: .active,
            currentNextStep: "Review"
        )
        let selectedProof = try Proof(
            projectId: selected.id,
            type: .file,
            title: "Selected proof",
            statement: "Selected record",
            localPath: selectedAttachment.path
        )
        let otherProof = try Proof(
            projectId: other.id,
            type: .file,
            title: "Other proof",
            statement: "Other record",
            localPath: otherAttachment.path
        )
        let review = Review(
            periodStart: Date(timeIntervalSince1970: 500),
            periodEnd: Date(timeIntervalSince1970: 900),
            facts: [],
            patterns: [],
            decisions: [],
            projectRecommendations: [selected.id: .active, other.id: .paused],
            nextSteps: [selected.id: "Selected", other.id: "Other"],
            aiSourceSummary: []
        )
        let snapshot = JournalSnapshot(
            projects: [selected, other],
            proofs: [selectedProof, otherProof],
            reviews: [review]
        )

        let document = try TrashExportService(
            archiveService: JournalArchiveService(derivationRounds: 20)
        ).prepare(
            snapshot: snapshot,
            project: selected,
            to: root.appendingPathComponent("Exports", isDirectory: true)
        )
        let envelope = try JSONDecoder.journal.decode(
            JournalArchiveEnvelope.self,
            from: Data(contentsOf: document.url)
        )
        let preview = try JournalArchiveService(derivationRounds: 20).preview(envelope, password: nil)

        XCTAssertEqual(preview.snapshot.projects.map(\.id), [selected.id])
        XCTAssertEqual(preview.snapshot.proofs.map(\.id), [selectedProof.id])
        XCTAssertEqual(preview.snapshot.reviews.count, 1)
        XCTAssertEqual(preview.snapshot.reviews[0].projectRecommendations, [selected.id: .active])
        XCTAssertEqual(preview.snapshot.reviews[0].nextSteps, [selected.id: "Selected"])
        XCTAssertEqual(Array(preview.attachmentData.values), [Data("selected".utf8)])
    }

    func testPrepareFailsWhenExpectedAttachmentIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = Project(
            name: "Selected",
            area: "Test",
            goal: "Keep",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let missingPath = root.appendingPathComponent("missing.txt").path
        let proof = try Proof(
            projectId: project.id,
            type: .file,
            title: "Missing proof",
            statement: "Must not export incomplete data",
            localPath: missingPath
        )

        XCTAssertThrowsError(
            try TrashExportService(
                archiveService: JournalArchiveService(derivationRounds: 20)
            ).prepare(
                snapshot: JournalSnapshot(projects: [project], proofs: [proof]),
                project: project,
                to: root.appendingPathComponent("Exports", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual(error as? JournalArchiveError, .missingAttachment(missingPath))
        }
    }
}
