import XCTest
@testable import PersonalLearningJournal

final class RepositoryMigrationTests: XCTestCase {
    func testMigrationImportsLegacySnapshotOnceWithoutCreatingOutbox() throws {
        let project = Project(
            name: "CS336",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Lecture 1"
        )
        let legacy = InMemoryJournalStore(
            snapshot: JournalSnapshot(
                projects: [project],
                hasCompletedOnboarding: false,
                pendingFirstRecordProjectId: project.id
            )
        )
        let repository = InMemoryJournalRepository()

        try RepositoryMigration().migrateIfNeeded(from: legacy, to: repository)
        try RepositoryMigration().migrateIfNeeded(from: legacy, to: repository)

        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.projects.map(\.id), [project.id])
        XCTAssertFalse(snapshot.hasCompletedOnboarding)
        XCTAssertEqual(snapshot.pendingFirstRecordProjectId, project.id)
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
    }

    func testMigrationWritesBackupBeforeImport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(
            name: "Guitar",
            area: "Music",
            goal: "Play three songs",
            currentNextStep: "Practice"
        )

        try RepositoryMigration().migrateIfNeeded(
            from: InMemoryJournalStore(snapshot: JournalSnapshot(projects: [project])),
            to: InMemoryJournalRepository(),
            backupDirectory: root
        )

        let backupURL = root.appendingPathComponent("journal-v1-backup.json")
        let backup = try JSONDecoder.journal.decode(
            JournalSnapshot.self,
            from: Data(contentsOf: backupURL)
        )
        XCTAssertEqual(backup.projects.map(\.id), [project.id])
    }

    func testMigrationMarkerSurvivesRepositoryRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("journal-v2.store")
        let firstProject = Project(
            name: "First",
            area: "AI",
            goal: "Finish",
            currentNextStep: "Start"
        )
        let legacy = InMemoryJournalStore(
            snapshot: JournalSnapshot(projects: [firstProject])
        )

        try autoreleasepool {
            let repository = try SwiftDataJournalRepository(url: storeURL)
            try RepositoryMigration().migrateIfNeeded(from: legacy, to: repository)
        }
        let secondProject = Project(
            name: "Second",
            area: "Music",
            goal: "Finish",
            currentNextStep: "Start"
        )
        try legacy.save(JournalSnapshot(projects: [firstProject, secondProject]))

        let reopened = try SwiftDataJournalRepository(url: storeURL)
        try RepositoryMigration().migrateIfNeeded(from: legacy, to: reopened)

        XCTAssertEqual(try reopened.snapshot().projects.map(\.id), [firstProject.id])
    }

    func testMigrationImportsPracticeRoutineAndSessionWithoutCreatingOutbox() throws {
        let routine = PracticeRoutine(
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let session = PracticeSession(
            routineId: routine.id,
            startedAt: Date(timeIntervalSince1970: 10_000),
            endedAt: Date(timeIntervalSince1970: 10_120),
            activeDurationSeconds: 120
        )
        let legacy = InMemoryJournalStore(
            snapshot: JournalSnapshot(practiceRoutines: [routine], practiceSessions: [session])
        )
        let repository = InMemoryJournalRepository()

        try RepositoryMigration().migrateIfNeeded(from: legacy, to: repository)

        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.practiceRoutines, [routine])
        XCTAssertEqual(snapshot.practiceSessions, [session])
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
    }
}
