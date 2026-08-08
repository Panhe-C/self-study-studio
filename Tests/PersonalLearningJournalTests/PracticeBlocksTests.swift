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

    func testPracticeRoutineValidationRejectsDuplicateAndNonContiguousBlocks() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = PracticeBlock(name: "Warm up", targetMinutes: 5, ordinal: 0)
        let second = PracticeBlock(name: "Scales", targetMinutes: 10, ordinal: 1)
        let base = PracticeRoutine(
            projectId: UUID(),
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 15,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )

        var duplicateID = base
        duplicateID.blocks = [first, PracticeBlock(id: first.id, name: second.name, targetMinutes: second.targetMinutes, ordinal: 1)]
        XCTAssertThrowsError(try duplicateID.validated())

        var duplicateOrdinal = base
        duplicateOrdinal.blocks = [first, PracticeBlock(name: second.name, targetMinutes: second.targetMinutes, ordinal: 0)]
        XCTAssertThrowsError(try duplicateOrdinal.validated())

        var nonContiguous = base
        nonContiguous.blocks = [first, PracticeBlock(name: second.name, targetMinutes: second.targetMinutes, ordinal: 2)]
        XCTAssertThrowsError(try nonContiguous.validated())
    }

    func testPracticeSummaryCombinesRepeatedSegmentsAndExcludesPause() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstBlock = PracticeBlock(
            name: "Warm up",
            targetMinutes: 5,
            ordinal: 0,
            focus: "Relaxed eighth notes",
            nextFocusCandidates: ["Add a metronome"]
        )
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
        XCTAssertEqual(summary.blockSummaries.first { $0.blockID == firstBlock.id }?.observedBlockName, firstBlock.name)
        XCTAssertEqual(summary.blockSummaries.first { $0.blockID == firstBlock.id }?.observedFocus, firstBlock.focus)
        XCTAssertEqual(summary.blockSummaries.first { $0.blockID == firstBlock.id }?.observedNextFocusCandidates, firstBlock.nextFocusCandidates)
        XCTAssertFalse(summary.blockSummaries.contains { $0.blockID == firstBlock.id && $0.activeDurationSeconds == 300 })
    }

    func testPracticeSessionPersistsSegmentsAndSummaryThroughCloudRecordMapper() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let block = PracticeBlock(
            name: "Warm up",
            targetMinutes: 5,
            ordinal: 0,
            focus: "Relaxed eighth notes",
            nextFocusCandidates: ["Add a metronome"]
        )
        let segment = PracticeSegment(
            block: block,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            activeDurationSeconds: 60
        )
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
        XCTAssertEqual(session.segments.first?.observedBlockName, "Warm up")
        XCTAssertEqual(session.summary?.blockSummaries.first?.observedNextFocusCandidates, ["Add a metronome"])
    }

    func testPracticeSessionValidationEnforcesCurrentSegmentSummaryRelationships() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let block = PracticeBlock(name: "Warm up", targetMinutes: 5, ordinal: 0)
        let segment = PracticeSegment(
            block: block,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            activeDurationSeconds: 60
        )
        let summary = PracticeSummary.from(blocks: [block], segments: [segment], attentionMarker: nil)
        let valid = PracticeSession(
            routineId: UUID(),
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            activeDurationSeconds: 60,
            segments: [segment],
            summary: summary,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        XCTAssertNoThrow(try valid.validated())

        var totalMismatch = valid
        totalMismatch.activeDurationSeconds = 61
        XCTAssertThrowsError(try totalMismatch.validated())

        var summaryBlockMismatch = summary.blockSummaries[0]
        summaryBlockMismatch = PracticeBlockSummary(
            blockID: summaryBlockMismatch.blockID,
            targetMinutes: summaryBlockMismatch.targetMinutes,
            activeDurationSeconds: 59,
            visitCount: summaryBlockMismatch.visitCount,
            wasSkipped: false,
            wasExtended: false,
            observedBlockName: summaryBlockMismatch.observedBlockName,
            observedFocus: summaryBlockMismatch.observedFocus,
            observedNextFocusCandidates: summaryBlockMismatch.observedNextFocusCandidates
        )
        var blockTotalMismatch = valid
        blockTotalMismatch.summary = PracticeSummary(
            totalActiveDurationSeconds: 60,
            blockSummaries: [summaryBlockMismatch]
        )
        XCTAssertThrowsError(try blockTotalMismatch.validated())

        var visitMismatch = valid
        visitMismatch.summary = PracticeSummary(
            totalActiveDurationSeconds: 60,
            blockSummaries: [PracticeBlockSummary(
                blockID: block.id,
                targetMinutes: block.targetMinutes,
                activeDurationSeconds: 60,
                visitCount: 2,
                wasSkipped: false,
                wasExtended: false
            )]
        )
        XCTAssertThrowsError(try visitMismatch.validated())

        var relationshipMismatch = valid
        relationshipMismatch.segments = [PracticeSegment(
            blockID: UUID(),
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            activeDurationSeconds: 60
        )]
        XCTAssertThrowsError(try relationshipMismatch.validated())

        var segmentsWithoutSummary = valid
        segmentsWithoutSummary.summary = nil
        XCTAssertThrowsError(try segmentsWithoutSummary.validated())

        var summaryWithoutSegments = valid
        summaryWithoutSegments.segments = []
        summaryWithoutSegments.activeDurationSeconds = 0
        summaryWithoutSegments.summary = PracticeSummary(
            totalActiveDurationSeconds: 0,
            blockSummaries: [PracticeBlockSummary(
                blockID: block.id,
                targetMinutes: block.targetMinutes,
                activeDurationSeconds: 0,
                visitCount: 0,
                wasSkipped: true,
                wasExtended: false
            )]
        )
        XCTAssertNoThrow(try summaryWithoutSegments.validated())

        var inconsistentEmptySummary = summaryWithoutSegments
        inconsistentEmptySummary.summary = PracticeSummary(
            totalActiveDurationSeconds: 0,
            blockSummaries: [PracticeBlockSummary(
                blockID: block.id,
                targetMinutes: block.targetMinutes,
                activeDurationSeconds: 0,
                visitCount: 1,
                wasSkipped: true,
                wasExtended: false
            )]
        )
        XCTAssertThrowsError(try inconsistentEmptySummary.validated())

        var emptyBlockSummary = summaryWithoutSegments
        emptyBlockSummary.summary = PracticeSummary(totalActiveDurationSeconds: 0, blockSummaries: [])
        XCTAssertThrowsError(try emptyBlockSummary.validated())

        let legacy = PracticeSession(
            routineId: UUID(),
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            activeDurationSeconds: 60,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        XCTAssertNoThrow(try legacy.validated())
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

    func testMigrationOnlyResolvesOperationalRoutinesAndMigratesHistoricalPlanSnapshots() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Practice",
            area: "Music",
            goal: "Learn",
            currentNextStep: "Play",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let activePlan = try LearningPlan(
            projectId: project.id,
            revision: 1,
            status: .active,
            courseURL: nil,
            courseTitle: "Current",
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
        let historicalPlan = try LearningPlan(
            projectId: project.id,
            revision: 2,
            planSeriesID: activePlan.planSeriesID,
            baseRevisionID: activePlan.revisionID,
            status: .archived,
            courseURL: nil,
            courseTitle: "Historical",
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
        var projectWithPlan = project
        projectWithPlan.activeCoursePlanId = activePlan.id
        let operational = PracticeRoutine(
            projectId: project.id,
            planRevisionID: activePlan.revisionID,
            planSeriesID: activePlan.planSeriesID,
            name: "Current",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 20,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let historical = PracticeRoutine(
            projectId: project.id,
            planRevisionID: historicalPlan.revisionID,
            planSeriesID: historicalPlan.planSeriesID,
            name: "Historical",
            symbolName: "music.note",
            color: .teal,
            targetMinutes: 30,
            weekdays: [3],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let snapshot = JournalSnapshot(
            projects: [projectWithPlan],
            coursePlans: [activePlan, historicalPlan],
            practiceRoutines: [operational, historical]
        )
        let migration = PracticeBlocksMigration(now: { timestamp })

        XCTAssertTrue(migration.dryRun(snapshot: snapshot).issues.isEmpty)
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("practice-blocks-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup) }
        let report = try migration.execute(snapshot: snapshot, repository: repository, backupDirectory: backup)

        XCTAssertEqual(report.migratedCount, 2)
        let migrated = try repository.snapshot().practiceRoutines
        XCTAssertEqual(migrated.map(\.blocks.count), [1, 1])
        XCTAssertTrue(migrated.allSatisfy { !$0.isArchived })
    }

    func testMigrationEnqueuesChangedRoutinePayloadsOnceAndIsIdempotent() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Practice", area: "Music", goal: "Learn", currentNextStep: "Play", createdAt: timestamp, updatedAt: timestamp)
        let routine = PracticeRoutine(projectId: project.id, name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 20, weekdays: [2], createdAt: timestamp, updatedAt: timestamp)
        let snapshot = JournalSnapshot(projects: [project], practiceRoutines: [routine])
        let migration = PracticeBlocksMigration(now: { timestamp })
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("practice-blocks-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup) }

        _ = try migration.execute(snapshot: snapshot, repository: repository, backupDirectory: backup)
        let firstPending = try repository.pendingMutations(limit: 100)
        XCTAssertEqual(firstPending.map(\.entity), [.init(.practiceRoutine, routine.id)])

        _ = try migration.execute(snapshot: snapshot, repository: repository, backupDirectory: backup)
        XCTAssertEqual(try repository.pendingMutations(limit: 100), firstPending)
    }

    func testLockedRoutineStructuralConflictIncludesBlocks() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let block = PracticeBlock(name: "Warm up", targetMinutes: 5, ordinal: 0)
        let base = PracticeRoutine(
            projectId: UUID(),
            isStructuralLocked: true,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 5,
            weekdays: [2],
            blocks: [block],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var local = base
        local.blocks = [PracticeBlock(id: block.id, name: "Changed", targetMinutes: 5, ordinal: 0)]
        var server = base
        server.updatedAt = timestamp.addingTimeInterval(10)

        let result = try SyncMergeService().merge(
            base: .practiceRoutine(base),
            local: .practiceRoutine(local),
            server: .practiceRoutine(server),
            now: timestamp
        )
        guard case let .conflict(conflict) = result else {
            return XCTFail("Expected structural conflict")
        }
        XCTAssertTrue(conflict.conflictingFields.contains("blocks"))
    }
}
