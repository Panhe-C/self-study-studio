import XCTest
@testable import PersonalLearningJournal

@MainActor
final class AttachmentCleanupQueueTests: XCTestCase {
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
        XCTAssertEqual(try queue.load(), [attachmentURL.path])
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
}

private struct InjectedQueueDeletionFailure: Error {}

@MainActor
private final class QueuePracticeTimerStateStore: PracticeTimerStateStore {
    private var data: Data?

    func load() -> Data? { data }

    func save(_ data: Data?) throws {
        self.data = data
    }
}
