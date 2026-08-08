import CloudKit
import XCTest
@testable import PersonalLearningJournal

final class PracticeBlocksTests: XCTestCase {
    func testFlatRoutineMigratesToOneOrderedBlockWithoutChangingTargetOrIdentity() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let routine = PracticeRoutine(
            id: UUID(),
            projectId: UUID(),
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let migrated = try XCTUnwrap(routine.migratedToBlocks())
        XCTAssertEqual(migrated.id, routine.id)
        XCTAssertEqual(migrated.targetMinutes, routine.targetMinutes)
        XCTAssertEqual(migrated.blocks.count, 1)
        XCTAssertEqual(migrated.blocks[0].ordinal, 0)
        XCTAssertEqual(migrated.blocks[0].name, routine.name)
        XCTAssertEqual(migrated.blocks[0].targetMinutes, routine.targetMinutes)
    }

    func testPracticeSummaryCombinesRepeatedSegmentsAndExcludesPause() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstBlock = PracticeBlock(name: "Warm up", targetMinutes: 5, ordinal: 0)
        let secondBlock = PracticeBlock(name: "Scales", targetMinutes: 10, ordinal: 1)
        let segments = [
            PracticeSegment(blockID: firstBlock.id, startedAt: timestamp, endedAt: timestamp.addingTimeInterval(60), activeDurationSeconds: 60),
            PracticeSegment(blockID: secondBlock.id, startedAt: timestamp.addingTimeInterval(60), endedAt: timestamp.addingTimeInterval(180), activeDurationSeconds: 120),
            PracticeSegment(blockID: firstBlock.id, startedAt: timestamp.addingTimeInterval(300), endedAt: timestamp.addingTimeInterval(420), activeDurationSeconds: 120)
        ]
        let summary = PracticeSummary.from(
            blocks: [firstBlock, secondBlock],
            segments: segments,
            attentionMarker: nil
        )
        XCTAssertEqual(summary.totalActiveDurationSeconds, 300)
        XCTAssertEqual(summary.blockSummaries.first { $0.blockID == firstBlock.id }?.activeDurationSeconds, 180)
        XCTAssertEqual(summary.blockSummaries.first { $0.blockID == secondBlock.id }?.activeDurationSeconds, 120)
        XCTAssertFalse(summary.blockSummaries.contains { $0.blockID == firstBlock.id && $0.activeDurationSeconds == 300 })
    }

    func testPracticeSessionPersistsSegmentsAndSummaryThroughCloudRecordMapper() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let block = PracticeBlock(name: "Warm up", targetMinutes: 5, ordinal: 0)
        let segment = PracticeSegment(blockID: block.id, startedAt: timestamp, endedAt: timestamp.addingTimeInterval(60), activeDurationSeconds: 60)
        let summary = PracticeSummary.from(blocks: [block], segments: [segment], attentionMarker: nil)
        let session = try PracticeSession(
            routineId: UUID(),
            linkedProjectId: UUID(),
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            activeDurationSeconds: 60,
            segments: [segment],
            summary: summary,
            note: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        ).validated()
        let zoneID = CKRecordZone.ID(zoneName: CloudSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)
        let mapper = CloudRecordMapper()
        let record = try mapper.record(for: .practiceSession(session), zoneID: zoneID)
        let roundTrip = try mapper.entity(from: record)
        XCTAssertEqual(roundTrip, .practiceSession(session))
    }

    func testPlanRevisionDraftRoundTripsRoutineBlockSnapshot() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let projectID = UUID()
        let routine = PracticeRoutine(
            projectId: projectID,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            blocks: [
                PracticeBlock(name: "Warm up", targetMinutes: 5, ordinal: 0),
                PracticeBlock(name: "Scales", targetMinutes: 25, ordinal: 1)
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let plan = try LearningPlan(
            projectId: projectID,
            revision: 1,
            status: .draft,
            courseURL: nil,
            courseTitle: "Music",
            courseOutline: "",
            goal: "Practice",
            expectedOutcome: "Play",
            startsOn: timestamp,
            deadline: nil,
            weeklyBudgetMinutes: 30,
            summary: "",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let draft = PlanRevisionDraft(plan: plan, phases: [], sessions: [], practiceRoutines: [routine])

        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(PlanRevisionDraft.self, from: data)

        XCTAssertEqual(decoded.practiceRoutines.first?.blocks, routine.blocks)
    }

    func testMultipleActiveRoutinesRequireExplicitMergeOrArchiveAndPreserveHistory() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Practice", area: "Music", goal: "Learn", currentNextStep: "Play", createdAt: timestamp, updatedAt: timestamp)
        let first = PracticeRoutine(projectId: project.id, name: "Technique", symbolName: "guitars", color: .coral, targetMinutes: 20, weekdays: [2], createdAt: timestamp, updatedAt: timestamp)
        let second = PracticeRoutine(projectId: project.id, name: "Repertoire", symbolName: "music.note", color: .teal, targetMinutes: 30, weekdays: [3], createdAt: timestamp, updatedAt: timestamp)
        let snapshot = JournalSnapshot(projects: [project], practiceRoutines: [first, second])
        let migration = PracticeBlocksMigration(now: { timestamp })
        let dryRun = migration.dryRun(snapshot: snapshot)
        XCTAssertTrue(dryRun.issues.contains { issue in
            if case let .multipleActiveRoutines(projectID, ids) = issue {
                return projectID == project.id && Set(ids) == Set([first.id, second.id])
            }
            return false
        })
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("practice-blocks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup) }
        XCTAssertThrowsError(try migration.execute(snapshot: snapshot, repository: repository, backupDirectory: backup))
        _ = try migration.execute(
            snapshot: snapshot,
            repository: repository,
            backupDirectory: backup,
            resolutions: [.merge(survivorID: first.id)]
        )
        let migrated = try repository.snapshot()
        XCTAssertEqual(migrated.practiceRoutines.filter { !$0.isArchived }.map(\.id), [first.id])
        XCTAssertEqual(migrated.practiceRoutines.count, 2)
        XCTAssertEqual(migrated.practiceRoutines.first { $0.id == first.id }?.blocks.count, 2)
        XCTAssertTrue(try repository.hasCompletedMigration(identifier: PracticeBlocksMigration.identifier))
    }
}
