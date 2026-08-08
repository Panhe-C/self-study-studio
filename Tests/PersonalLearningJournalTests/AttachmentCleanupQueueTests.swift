import XCTest
@testable import PersonalLearningJournal

@MainActor
final class AttachmentCleanupQueueTests: XCTestCase {
    func testCleanupQueueSurvivesCommitCrashAndRefusesLiveProjectCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AttachmentCleanupQueue(
            fileURL: root.appendingPathComponent("cleanup-queue.json")
        )
        let project = Project(
            name: "Crash project",
            area: "Test",
            goal: "Delete safely",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let path = root.appendingPathComponent("record.txt").path
        let proof = try Proof(
            projectId: project.id,
            type: .file,
            title: "Record",
            statement: "A record",
            localPath: path
        )
        var shouldFailCommit = true
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], proofs: [proof]),
            commitHook: { _ in
                if shouldFailCommit {
                    shouldFailCommit = false
                    throw InjectedQueueCommitFailure()
                }
            }
        )
        var deleteAttempts = 0
        let service = JournalArchiveService(
            removeAttachment: { _ in deleteAttempts += 1 },
            cleanupQueue: queue
        )

        XCTAssertThrowsError(
            try service.purge(projectID: project.id, snapshot: try repository.snapshot(), from: repository)
        )
        let queued = try queue.load()
        XCTAssertEqual(queued, [AttachmentCleanupEntry(projectID: project.id, paths: [path])])
        XCTAssertEqual(deleteAttempts, 0)

        XCTAssertThrowsError(
            try service.retryAttachmentCleanup(
                projectID: project.id,
                paths: [path],
                repository: repository
            )
        ) { error in
            XCTAssertEqual(error as? JournalArchiveError, .projectNotPurged(project.id))
        }
        XCTAssertEqual(deleteAttempts, 0)
        XCTAssertEqual(try queue.load(), queued)

        _ = try service.purge(projectID: project.id, snapshot: try repository.snapshot(), from: repository)
        XCTAssertEqual(deleteAttempts, 1)
        XCTAssertTrue(try queue.load().isEmpty)
    }

    func testPendingAttachmentCleanupSurvivesViewModelRestartAndRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let attachmentURL = root.appendingPathComponent("record.txt")
        try Data("record".utf8).write(to: attachmentURL)
        let queue = AttachmentCleanupQueue(
            fileURL: root.appendingPathComponent("cleanup-queue.json")
        )
        let project = Project(
            name: "Trash project",
            area: "Test",
            goal: "Delete safely",
            status: .trash,
            currentNextStep: "Review",
            deletedAt: Date(timeIntervalSince1970: 1_000),
            previousStatusBeforeTrash: .active
        )
        let proof = try Proof(
            projectId: project.id,
            type: .file,
            title: "Record",
            statement: "A record",
            localPath: attachmentURL.path
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], proofs: [proof])
        )
        let journalService = JournalService(repository: repository)
        let failingArchive = JournalArchiveService(
            removeAttachment: { _ in throw InjectedQueueDeletionFailure() }
        )
        let firstViewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            attachmentStore: AttachmentStore(rootDirectory: root),
            archiveService: failingArchive,
            cleanupQueue: queue,
            practiceService: PracticeService(repository: repository),
            practiceTimer: PracticeTimerRuntime(store: QueuePracticeTimerStateStore()),
            syncRepository: repository
        )

        XCTAssertThrowsError(try firstViewModel.permanentlyDelete(projectId: project.id))
        XCTAssertEqual(
            try queue.load(),
            [AttachmentCleanupEntry(projectID: project.id, paths: [attachmentURL.path])]
        )
        let queuedMutations = try repository.pendingMutations(limit: 100)
        let queuedPayload = String(
            data: try JSONEncoder().encode(queuedMutations),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(queuedPayload.contains(attachmentURL.path))

        let secondViewModel = JournalViewModel(
            journalService: journalService,
            reviewService: ReviewService(journalService: journalService),
            exportService: ExportService(),
            attachmentStore: AttachmentStore(rootDirectory: root),
            archiveService: JournalArchiveService(
                removeAttachment: { path in
                    try FileManager.default.removeItem(atPath: path)
                }
            ),
            cleanupQueue: queue,
            practiceService: PracticeService(repository: repository),
            practiceTimer: PracticeTimerRuntime(store: QueuePracticeTimerStateStore()),
            syncRepository: repository
        )

        XCTAssertEqual(secondViewModel.pendingAttachmentCleanupPaths, [attachmentURL.path])
        try secondViewModel.retryPendingAttachmentCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
        XCTAssertTrue(secondViewModel.pendingAttachmentCleanupPaths.isEmpty)
        XCTAssertTrue(try queue.load().isEmpty)
    }

    func testLegacyStringQueueMigratesProjectScopedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let legacyPath = root
            .appendingPathComponent("LearningJournal/Attachments/\(projectID.uuidString)/project/proof.txt")
        let queueURL = root.appendingPathComponent("cleanup-queue.json")
        try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([legacyPath.path]).write(to: queueURL, options: [.atomic])
        let queue = AttachmentCleanupQueue(fileURL: queueURL)

        XCTAssertEqual(
            try queue.load(),
            [AttachmentCleanupEntry(projectID: projectID, paths: [legacyPath.path])]
        )
        XCTAssertEqual(
            try JSONDecoder().decode([AttachmentCleanupEntry].self, from: Data(contentsOf: queueURL)),
            [AttachmentCleanupEntry(projectID: projectID, paths: [legacyPath.path])]
        )
    }

    func testUnrecoverableLegacyQueueRemainsAndReportsExplicitError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queueURL = root.appendingPathComponent("cleanup-queue.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyPaths = [root.appendingPathComponent("unknown/proof.txt").path]
        let legacyData = try JSONEncoder().encode(legacyPaths)
        try legacyData.write(to: queueURL, options: [.atomic])
        let queue = AttachmentCleanupQueue(fileURL: queueURL)

        XCTAssertThrowsError(try queue.load()) { error in
            XCTAssertEqual(
                error as? AttachmentCleanupQueueError,
                .legacyQueueNeedsReview(legacyPaths)
            )
        }
        XCTAssertEqual(try Data(contentsOf: queueURL), legacyData)
    }

    func testCorruptQueueRemainsAndReportsInvalidQueue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queueURL = root.appendingPathComponent("cleanup-queue.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corruptData = Data("{\"paths\": [".utf8)
        try corruptData.write(to: queueURL, options: [.atomic])

        XCTAssertThrowsError(try AttachmentCleanupQueue(fileURL: queueURL).load()) { error in
            XCTAssertEqual(error as? AttachmentCleanupQueueError, .invalidQueue)
        }
        XCTAssertEqual(try Data(contentsOf: queueURL), corruptData)
    }
}

private struct InjectedQueueDeletionFailure: Error {}
private struct InjectedQueueCommitFailure: Error {}

@MainActor
private final class QueuePracticeTimerStateStore: PracticeTimerStateStore {
    private var data: Data?

    func load() -> Data? { data }

    func save(_ data: Data?) throws {
        self.data = data
    }
}
