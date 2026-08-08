import XCTest
@testable import PersonalLearningJournal

final class LearningPlanRevisionMigrationTests: XCTestCase {
    func testDryRunAndExecuteMapLegacyRevisionIntegersToStableSeriesWithoutLoss() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let projectID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let first = try plan(
            id: firstID,
            projectID: projectID,
            revision: 1,
            status: .active,
            date: timestamp
        )
        let second = try plan(
            id: secondID,
            projectID: projectID,
            revision: 2,
            status: .active,
            date: timestamp.addingTimeInterval(60)
        )
        let project = Project(
            id: projectID,
            name: "CS336",
            area: "AI",
            goal: "Learn",
            currentNextStep: "Read",
            createdAt: timestamp,
            updatedAt: timestamp,
            activeCoursePlanId: secondID
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], coursePlans: [first, second])
        )
        let backupDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: backupDirectory) }
        let migration = PlanRevisionMigration()

        let dryRun = migration.dryRun(snapshot: try repository.snapshot())
        XCTAssertEqual(dryRun.planCount, 2)
        XCTAssertEqual(dryRun.seriesCount, 1)

        let report = try migration.execute(
            snapshot: try repository.snapshot(),
            repository: repository,
            backupDirectory: backupDirectory
        )
        XCTAssertTrue(report.isValid)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backupDirectory.appendingPathComponent("learning-plan-revisions-v1-backup.json").path
        ))

        let migrated = try repository.snapshot()
        XCTAssertEqual(migrated.coursePlans.count, 2)
        let migratedFirst = try XCTUnwrap(migrated.coursePlans.first { $0.id == firstID })
        let migratedSecond = try XCTUnwrap(migrated.coursePlans.first { $0.id == secondID })
        XCTAssertEqual(migratedFirst.planSeriesID, firstID)
        XCTAssertEqual(migratedSecond.planSeriesID, firstID)
        XCTAssertEqual(migratedSecond.baseRevisionID, firstID)
        XCTAssertEqual(migratedSecond.supersedesID, firstID)
        XCTAssertEqual(migratedFirst.status, .archived)
        XCTAssertEqual(migratedSecond.status, .active)
        XCTAssertEqual(migrated.projects.first?.activeCoursePlanId, secondID)
        XCTAssertTrue(try repository.hasCompletedMigration(identifier: PlanRevisionMigration.identifier))
    }

    func testMigrationIsIdempotentAfterCompletion() throws {
        let plan = try self.plan(
            id: UUID(),
            projectID: UUID(),
            revision: 1,
            status: .draft,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let project = Project(
            id: plan.projectId,
            name: "CS336",
            area: "AI",
            goal: "Learn",
            currentNextStep: "Read",
            createdAt: plan.createdAt,
            updatedAt: plan.updatedAt
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], coursePlans: [plan])
        )
        let backupDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: backupDirectory) }
        let migration = PlanRevisionMigration()
        _ = try migration.execute(
            snapshot: try repository.snapshot(),
            repository: repository,
            backupDirectory: backupDirectory
        )
        let before = try repository.snapshot()
        let second = try migration.execute(
            snapshot: before,
            repository: repository,
            backupDirectory: backupDirectory
        )

        XCTAssertTrue(second.isValid)
        XCTAssertEqual(second.migratedCount, 0)
        XCTAssertEqual(try repository.snapshot(), before)
    }

    private func plan(
        id: UUID,
        projectID: UUID,
        revision: Int,
        status: CoursePlanStatus,
        date: Date
    ) throws -> CoursePlan {
        try CoursePlan(
            id: id,
            projectId: projectID,
            revision: revision,
            status: status,
            courseURL: nil,
            courseTitle: "CS336",
            courseOutline: "Outline",
            goal: "Learn",
            expectedOutcome: "Notebook",
            startsOn: date,
            deadline: nil,
            weeklyBudgetMinutes: 120,
            summary: "Summary",
            createdAt: date,
            updatedAt: date
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-plan-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
