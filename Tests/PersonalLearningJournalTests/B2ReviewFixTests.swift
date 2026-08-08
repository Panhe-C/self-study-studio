import CloudKit
import XCTest
@testable import PersonalLearningJournal

final class B2ReviewFixTests: XCTestCase {
    func testRevisionDraftPersistsGuardAndChildIdentity() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let projectID = UUID()
        let plan = try LearningPlan(
            projectId: projectID,
            revision: 1,
            status: .draft,
            courseURL: nil,
            courseTitle: "Linear Algebra",
            courseOutline: "",
            goal: "Understand vectors",
            expectedOutcome: "Notes",
            startsOn: timestamp,
            deadline: nil,
            weeklyBudgetMinutes: 120,
            summary: "Summary",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let phase = try PlanPhase(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            title: "Vectors",
            objective: "Build intuition",
            expectedProof: "Diagram",
            ordinal: 0,
            targetStart: timestamp,
            targetEnd: timestamp.addingTimeInterval(3600),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let session = try PlannedSession(
            planId: plan.id,
            planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID,
            phaseId: phase.id,
            projectId: projectID,
            title: "Read",
            actionType: .reading,
            durationMinutes: 30,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let expectation = RevisionGuardExpectation.existing(
            baseRevisionID: plan.revisionID,
            recordChangeTag: nil
        )
        let draft = PlanRevisionDraft(
            plan: plan,
            phases: [phase],
            sessions: [session],
            guardExpectation: expectation
        )

        let roundTrip = try JSONDecoder.journal.decode(
            PlanRevisionDraft.self,
            from: JSONEncoder.journal.encode(draft)
        )

        XCTAssertEqual(roundTrip.guardExpectation, expectation)
        XCTAssertEqual(roundTrip.phases.first?.planRevisionID, plan.revisionID)
        XCTAssertEqual(roundTrip.sessions.first?.planSeriesID, plan.planSeriesID)
    }

    func testNewRecordGuardRequiresRecordAbsence() throws {
        let expectation = RevisionGuardExpectation.newRecord()
        XCTAssertNoThrow(
            try RevisionGuard.validate(
                expectation: expectation,
                currentRevisionID: UUID(),
                currentRecordChangeTag: nil,
                currentRecordExists: false
            )
        )
        XCTAssertThrowsError(
            try RevisionGuard.validate(
                expectation: expectation,
                currentRevisionID: UUID(),
                currentRecordChangeTag: "server-v1",
                currentRecordExists: true
            )
        )
    }

    func testReviseRejectsCrossProjectInputWithoutWrites() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstProject = Project(
            name: "First", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let secondProject = Project(
            name: "Second", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [firstProject, secondProject])
        )
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let plan = try service.saveDraft(input: input(projectID: firstProject.id), draft: draft)
        let before = try repository.snapshot()
        let pendingBefore = try repository.pendingMutations(limit: 100)

        XCTAssertThrowsError(
            try service.revise(
                planID: plan.id,
                input: input(projectID: secondProject.id),
                draft: draft
            )
        ) { error in
            XCTAssertEqual(error as? CoursePlanningError, .projectMismatch)
        }
        XCTAssertEqual(try repository.snapshot(), before)
        XCTAssertEqual(try repository.pendingMutations(limit: 100), pendingBefore)
    }

    func testAdjustmentGuardCapturedAtOpenRemainsStaleAfterMetadataRefresh() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Project", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let first = try service.saveDraft(input: input(projectID: project.id), draft: draft)
        _ = try service.activate(draftPlanID: first.id)
        let revised = try service.revise(planID: first.id, input: input(projectID: project.id), draft: draft)
        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: .init(.coursePlan, first.id),
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: first.id.uuidString,
                recordChangeTag: "server-v1",
                state: .synced
            )
        ])
        let captured = try service.revisionGuardExpectation(for: revised.id)
        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: .init(.coursePlan, first.id),
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: first.id.uuidString,
                recordChangeTag: "server-v2",
                state: .synced
            )
        ])

        XCTAssertEqual(captured.recordChangeTag, "server-v1")
        XCTAssertThrowsError(try service.activate(draftPlanID: revised.id, expectation: captured))
    }

    func testMultipleActiveMigrationDryRunReportsExplicitIssueAndDoesNotExecute() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Project", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let first = try LearningPlan(
            projectId: project.id, revision: 1, status: .active,
            courseURL: nil, courseTitle: "First", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "First", createdAt: timestamp, updatedAt: timestamp
        )
        let second = try LearningPlan(
            projectId: project.id, revision: 2, status: .active,
            courseURL: nil, courseTitle: "Second", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "Second", createdAt: timestamp, updatedAt: timestamp
        )
        let snapshot = JournalSnapshot(projects: [project], coursePlans: [first, second])
        let repository = InMemoryJournalRepository(snapshot: snapshot)
        let migration = PlanRevisionMigration()
        let dryRun = migration.dryRun(snapshot: snapshot)

        XCTAssertTrue(dryRun.issues.contains(.multipleActivePlans(project.id)))
        XCTAssertThrowsError(
            try migration.execute(
                snapshot: snapshot,
                repository: repository,
                backupDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
        ) { error in
            XCTAssertEqual(error as? PlanRevisionMigrationError, .multipleActivePlans(project.id))
        }
        XCTAssertEqual(try repository.snapshot(), snapshot)
    }

    func testExplicitMigrationSurvivorArchivesOtherActiveRevisionAndLocksChildren() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Project", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let first = try LearningPlan(
            projectId: project.id, revision: 1, status: .active,
            courseURL: nil, courseTitle: "First", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "First", createdAt: timestamp, updatedAt: timestamp
        )
        let second = try LearningPlan(
            projectId: project.id, revision: 2, status: .active,
            courseURL: nil, courseTitle: "Second", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "Second", createdAt: timestamp, updatedAt: timestamp
        )
        let phase = try PlanPhase(
            planId: second.id,
            title: "Phase",
            objective: "Objective",
            expectedProof: "Proof",
            ordinal: 0,
            targetStart: timestamp,
            targetEnd: timestamp.addingTimeInterval(60),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], coursePlans: [first, second], planPhases: [phase])
        )
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-plan-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backupDirectory) }

        _ = try PlanRevisionMigration().execute(
            snapshot: try repository.snapshot(),
            repository: repository,
            backupDirectory: backupDirectory,
            activePlanSurvivors: [project.id: first.id]
        )
        let migrated = try repository.snapshot()
        XCTAssertEqual(migrated.coursePlans.filter { $0.status == .active }.map(\.id), [first.id])
        XCTAssertEqual(migrated.coursePlans.first { $0.id == second.id }?.status, .archived)
        XCTAssertEqual(migrated.planPhases.first?.planRevisionID, second.revisionID)
        XCTAssertTrue(migrated.planPhases.first?.isStructuralLocked == true)
    }

    func testPendingMutationRetainsGuardTagAfterMetadataRefresh() throws {
        let project = Project(name: "Project", area: "AI", goal: "Learn", currentNextStep: "Read")
        let repository = InMemoryJournalRepository()
        let expectation = RevisionGuardExpectation.existing(
            baseRevisionID: project.id,
            recordChangeTag: "server-v1"
        )
        let transactionID = UUID()
        try repository.commit(
            JournalTransaction(
                upserts: [.project(project)],
                origin: .user,
                transactionID: transactionID,
                revisionExpectations: [.init(.project, project.id): expectation]
            )
        )
        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: .init(.project, project.id),
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: project.id.uuidString,
                recordChangeTag: "server-v2",
                state: .synced
            )
        ])

        let pending = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        XCTAssertEqual(pending.transactionID, transactionID)
        XCTAssertEqual(pending.revisionExpectation, expectation)
    }

    @MainActor
    func testStaleAtomicGroupDoesNotBlockUnrelatedTransaction() async throws {
        let first = Project(name: "First", area: "AI", goal: "Learn", currentNextStep: "Read")
        let second = Project(name: "Second", area: "AI", goal: "Learn", currentNextStep: "Read")
        let repository = InMemoryJournalRepository()
        let firstExpectation = RevisionGuardExpectation.existing(
            baseRevisionID: first.id,
            recordChangeTag: "stale-v1"
        )
        try repository.commit(
            JournalTransaction(
                upserts: [.project(first)],
                origin: .user,
                revisionExpectations: [.init(.project, first.id): firstExpectation]
            )
        )
        try repository.commit(JournalTransaction(upserts: [.project(second)], origin: .user))
        let client = GroupingCloudClient()
        try await CloudSyncCoordinator(repository: repository, client: client).syncNow()

        let groups = await client.groups()
        XCTAssertEqual(groups.count, 2)
        let pending = try repository.pendingMutations(limit: 10)
        let stale = try XCTUnwrap(pending.first { $0.entity.id == first.id })
        XCTAssertTrue(stale.lastError?.contains("stale") == true)
        XCTAssertFalse(pending.contains { $0.entity.id == second.id })
    }

    func testPublishedPlanAndPhaseStructuralEditsBecomeConflicts() throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let base = try LearningPlan(
            projectId: UUID(), revision: 1, status: .active,
            courseURL: nil, courseTitle: "Base", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "Base", createdAt: timestamp, updatedAt: timestamp
        )
        var local = base
        local.courseTitle = "Local structural edit"
        var server = base
        server.updatedAt = timestamp.addingTimeInterval(60)
        let planResult = try SyncMergeService().merge(
            base: .coursePlan(base), local: .coursePlan(local), server: .coursePlan(server)
        )
        guard case let .conflict(planConflict) = planResult else {
            return XCTFail("Published plan structural edits must conflict")
        }
        XCTAssertTrue(planConflict.conflictingFields.contains("courseTitle"))

        let phase = try PlanPhase(
            planId: base.id,
            planRevisionID: base.revisionID,
            planSeriesID: base.planSeriesID,
            isStructuralLocked: true,
            title: "Phase",
            objective: "Objective",
            expectedProof: "Proof",
            ordinal: 0,
            targetStart: timestamp,
            targetEnd: timestamp.addingTimeInterval(60),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var localPhase = phase
        localPhase.title = "Changed"
        let phaseResult = try SyncMergeService().merge(
            base: .planPhase(phase), local: .planPhase(localPhase), server: .planPhase(phase)
        )
        guard case let .conflict(phaseConflict) = phaseResult else {
            return XCTFail("Published phase structural edits must conflict")
        }
        XCTAssertTrue(phaseConflict.conflictingFields.contains("title"))
    }

    private var draft: CoursePlanDraft {
        CoursePlanDraft(
            title: "Plan",
            summary: "Summary",
            phases: [
                CoursePlanDraftPhase(
                    id: "phase-1", title: "Phase", objective: "Objective", expectedProof: "Proof",
                    ordinal: 0, targetStart: Date(timeIntervalSince1970: 1_000),
                    targetEnd: Date(timeIntervalSince1970: 2_000)
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "session-1", phaseID: "phase-1", title: "Read", actionType: .reading,
                    durationMinutes: 30
                )
            ]
        )
    }

    private func input(projectID: UUID) -> CoursePlanningInput {
        CoursePlanningInput(
            projectId: projectID,
            courseTitle: "Plan",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Notes",
            startsOn: Date(timeIntervalSince1970: 1_000),
            weeklyBudgetMinutes: 60,
            preferredSessionMinutes: 30
        )
    }
}

private actor GroupingCloudClient: CloudDatabaseClient {
    private var sentGroups: [[UUID]] = []

    func ensureZone(named: String) async throws {}

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        CloudSendResult(acknowledgedMutationIDs: Set(mutations.map { mutation in
            switch mutation {
            case let .save(id, _), let .delete(id, _): return id
            }
        }))
    }

    func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: CloudRevisionExpectation]
    ) async throws -> CloudSendResult {
        sentGroups.append(mutations.map { mutation in
            switch mutation {
            case let .save(id, _), let .delete(id, _): return id
            }
        })
        let ids = Set(mutations.map { mutation in
            switch mutation {
            case let .save(id, _), let .delete(id, _): return id
            }
        })
        if !revisionExpectations.isEmpty {
            return CloudSendResult(
                terminalErrors: Dictionary(uniqueKeysWithValues: ids.map { ($0, "stale guard") })
            )
        }
        return CloudSendResult(acknowledgedMutationIDs: ids)
    }

    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        CloudChangeBatch()
    }

    func groups() -> [[UUID]] { sentGroups }
}
