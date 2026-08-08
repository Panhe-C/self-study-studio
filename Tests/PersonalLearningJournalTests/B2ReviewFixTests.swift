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
        let terminal = try repository.terminalMutations(limit: 10)
        let stale = try XCTUnwrap(terminal.first { $0.entity.id == first.id })
        XCTAssertTrue(stale.lastError?.contains("stale") == true)
        XCTAssertFalse(terminal.contains { $0.entity.id == second.id })
    }

    @MainActor
    func testTerminalStaleMutationIsExcludedFromPendingRetainedForRecoveryAndFailsStatus() async throws {
        let project = Project(name: "Stale", area: "AI", goal: "Learn", currentNextStep: "Read")
        let repository = InMemoryJournalRepository()
        try repository.commit(
            JournalTransaction(
                upserts: [.project(project)],
                origin: .user,
                revisionExpectations: [JournalEntityReference(.project, project.id): .existing(
                    baseRevisionID: project.id,
                    recordChangeTag: "stale-v1"
                )]
            )
        )
        let mutation = try XCTUnwrap(repository.pendingMutations(limit: 1).first)
        try repository.recordSyncFailures(
            retryable: [:],
            terminal: [mutation.id: "stale guard"]
        )

        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
        let terminal = try XCTUnwrap(repository.terminalMutations(limit: 10).first)
        XCTAssertTrue(terminal.isTerminal)
        XCTAssertEqual(terminal.lastError, "stale guard")

        let client = GroupingCloudClient()
        let coordinator = CloudSyncCoordinator(repository: repository, client: client)
        try await coordinator.syncNow()
        guard case .failed = coordinator.status else {
            return XCTFail("A terminal stale mutation must not report synced")
        }
        let groups = await client.groups()
        XCTAssertEqual(groups.count, 0)
    }

    @MainActor
    func testCreateThenActivateCoalescesSameEntityOutboxAndSendsLatestState() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Project", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let plan = try service.saveDraft(input: input(projectID: project.id), draft: draft)
        _ = try service.activate(draftPlanID: plan.id)

        let pending = try repository.pendingMutations(limit: 100)
        XCTAssertEqual(pending.filter { $0.entity == plan.reference }.count, 1)
        XCTAssertEqual(pending.filter { $0.entity.kind == .planPhase }.count, 1)
        XCTAssertEqual(pending.filter { $0.entity.kind == .plannedSession }.count, 1)

        let client = AcknowledgingCloudClient()
        try await CloudSyncCoordinator(repository: repository, client: client).syncNow()
        XCTAssertTrue(try repository.pendingMutations(limit: 100).isEmpty)
        XCTAssertTrue(try repository.terminalMutations(limit: 100).isEmpty)
        let sentPlans = await client.sentPlanStatuses()
        XCTAssertEqual(sentPlans, [.active])
    }

    @MainActor
    func testReviseThenActivateCoalescesEachRevisionWithoutRandomGroupOrder() async throws {
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
        _ = try service.activate(draftPlanID: revised.id)

        let planMutations = try repository.pendingMutations(limit: 100).filter { $0.entity.kind == .coursePlan }
        XCTAssertEqual(planMutations.count, 2)
        XCTAssertEqual(Set(planMutations.map(\.entity.id)), Set([first.id, revised.id]))

        let client = AcknowledgingCloudClient()
        try await CloudSyncCoordinator(repository: repository, client: client).syncNow()
        XCTAssertTrue(try repository.pendingMutations(limit: 100).isEmpty)
        XCTAssertTrue(try repository.terminalMutations(limit: 100).isEmpty)
        let statuses = await client.sentPlanStatuses().sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(statuses, [.active, .archived])
    }

    func testCloudPlanChildrenRoundTripCurrentAndLegacyIdentity() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = try LearningPlan(
            projectId: UUID(), revision: 2, status: .active,
            courseURL: nil, courseTitle: "Plan", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "Summary", createdAt: timestamp, updatedAt: timestamp
        )
        let phase = try PlanPhase(
            planId: plan.id, planRevisionID: plan.revisionID, planSeriesID: plan.planSeriesID,
            isStructuralLocked: true, title: "Phase", objective: "Objective", expectedProof: "Proof",
            ordinal: 0, targetStart: timestamp, targetEnd: timestamp,
            createdAt: timestamp, updatedAt: timestamp
        )
        let session = try PlannedSession(
            planId: plan.id, planRevisionID: plan.revisionID, planSeriesID: plan.planSeriesID,
            isStructuralLocked: true, phaseId: phase.id, projectId: plan.projectId,
            title: "Read", actionType: .reading, durationMinutes: 30,
            createdAt: timestamp, updatedAt: timestamp
        )
        let mapper = CloudRecordMapper()
        let zoneID = CKRecordZone.ID(zoneName: CloudSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)
        let phaseRecord = try mapper.record(for: .planPhase(phase), zoneID: zoneID)
        let sessionRecord = try mapper.record(for: .plannedSession(session), zoneID: zoneID)
        XCTAssertEqual(try mapper.entity(from: phaseRecord), .planPhase(phase))
        XCTAssertEqual(try mapper.entity(from: sessionRecord), .plannedSession(session))

        phaseRecord["planRevisionID"] = nil
        phaseRecord["planSeriesID"] = nil
        phaseRecord["isStructuralLocked"] = nil
        sessionRecord["planRevisionID"] = nil
        sessionRecord["planSeriesID"] = nil
        sessionRecord["isStructuralLocked"] = nil
        let legacyPhase = try XCTUnwrap(try mapper.entity(from: phaseRecord).planPhaseValue)
        let legacySession = try XCTUnwrap(try mapper.entity(from: sessionRecord).plannedSessionValue)
        XCTAssertEqual(legacyPhase.planRevisionID, phase.planId)
        XCTAssertEqual(legacyPhase.planSeriesID, phase.planId)
        XCTAssertFalse(legacyPhase.isStructuralLocked)
        XCTAssertEqual(legacySession.planRevisionID, session.planId)
        XCTAssertEqual(legacySession.planSeriesID, session.planId)
        XCTAssertFalse(legacySession.isStructuralLocked)
    }

    func testPlanRevisionCarriesRevisionScopedRoutineAndActivationLocksIt() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Project", area: "AI", goal: "Learn", currentNextStep: "Read", createdAt: timestamp, updatedAt: timestamp)
        let plan = try LearningPlan(
            projectId: project.id, revision: 1, status: .draft,
            courseURL: nil, courseTitle: "Plan", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "Summary", createdAt: timestamp, updatedAt: timestamp
        )
        let routine = PracticeRoutine(
            id: UUID(), projectId: project.id, planRevisionID: plan.revisionID,
            planSeriesID: plan.planSeriesID, isStructuralLocked: false,
            name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30,
            weekdays: [2], createdAt: timestamp, updatedAt: timestamp
        )
        let revision = PlanRevision(plan: plan, phases: [], sessions: [], practiceRoutines: [routine])
        XCTAssertEqual(revision.practiceRoutines, [routine])

        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project], coursePlans: [plan], practiceRoutines: [routine]))
        _ = try CoursePlanningService(repository: repository, now: { timestamp }).activate(draftPlanID: plan.id)
        let activatedRoutine = try XCTUnwrap(try repository.snapshot().practiceRoutines.first)
        XCTAssertEqual(activatedRoutine.planRevisionID, plan.revisionID)
        XCTAssertTrue(activatedRoutine.isStructuralLocked)
    }

    func testRevisionDraftCarriesForwardRoutineStructureAsNewSnapshot() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Project", area: "AI", goal: "Learn", currentNextStep: "Read", createdAt: timestamp, updatedAt: timestamp)
        let plan = try LearningPlan(
            projectId: project.id, revision: 1, status: .active,
            courseURL: nil, courseTitle: "Plan", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "Summary", createdAt: timestamp, updatedAt: timestamp
        )
        let routine = PracticeRoutine(
            projectId: project.id, planRevisionID: plan.revisionID, planSeriesID: plan.planSeriesID,
            isStructuralLocked: true, name: "Guitar", symbolName: "guitars", color: .coral,
            targetMinutes: 30, weekdays: [2], createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], coursePlans: [plan], practiceRoutines: [routine])
        )
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let revised = try service.revise(planID: plan.id, input: input(projectID: project.id), draft: draft)
        let routines = try repository.snapshot().practiceRoutines
        let revisedRoutine = try XCTUnwrap(routines.first { $0.planRevisionID == revised.revisionID })
        XCTAssertNotEqual(revisedRoutine.id, routine.id)
        XCTAssertEqual(revisedRoutine.planSeriesID, plan.planSeriesID)
        XCTAssertFalse(revisedRoutine.isStructuralLocked)
        XCTAssertEqual(routines.first { $0.id == routine.id }?.planRevisionID, plan.revisionID)
    }

    func testPlanRevisionMigrationBindsLegacyRoutineToPublishedRevision() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Project", area: "AI", goal: "Learn", currentNextStep: "Read", createdAt: timestamp, updatedAt: timestamp)
        let plan = try LearningPlan(
            projectId: project.id, revision: 1, status: .active,
            courseURL: nil, courseTitle: "Plan", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "Summary", createdAt: timestamp, updatedAt: timestamp
        )
        let routine = PracticeRoutine(
            projectId: project.id, name: "Guitar", symbolName: "guitars", color: .coral,
            targetMinutes: 30, weekdays: [2], createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project], coursePlans: [plan], practiceRoutines: [routine]))
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("plan-routine-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup) }
        _ = try PlanRevisionMigration().execute(snapshot: try repository.snapshot(), repository: repository, backupDirectory: backup)
        let migrated = try XCTUnwrap(try repository.snapshot().practiceRoutines.first)
        XCTAssertEqual(migrated.planRevisionID, plan.revisionID)
        XCTAssertEqual(migrated.planSeriesID, plan.planSeriesID)
        XCTAssertTrue(migrated.isStructuralLocked)
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

    func testLockedRevisionScopedRoutineStructuralEditBecomesConflict() throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let planRevisionID = UUID()
        let planSeriesID = UUID()
        let base = PracticeRoutine(
            projectId: UUID(), planRevisionID: planRevisionID, planSeriesID: planSeriesID,
            isStructuralLocked: true, name: "Guitar", symbolName: "guitars", color: .coral,
            targetMinutes: 30, weekdays: [2], createdAt: timestamp, updatedAt: timestamp
        )
        var local = base
        local.name = "Piano"
        var server = base
        server.updatedAt = timestamp.addingTimeInterval(60)
        let result = try SyncMergeService().merge(
            base: .practiceRoutine(base), local: .practiceRoutine(local), server: .practiceRoutine(server)
        )
        guard case let .conflict(conflict) = result else {
            return XCTFail("Locked revision routine structure must conflict")
        }
        XCTAssertTrue(conflict.conflictingFields.contains("name"))
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

private extension JournalEntity {
    var planPhaseValue: PlanPhase? {
        if case let .planPhase(value) = self { return value }
        return nil
    }

    var plannedSessionValue: PlannedSession? {
        if case let .plannedSession(value) = self { return value }
        return nil
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

private actor AcknowledgingCloudClient: CloudDatabaseClient {
    private var planStatuses: [CoursePlanStatus] = []

    func ensureZone(named: String) async throws {}

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        for mutation in mutations {
            if case let .save(_, .coursePlan(plan)) = mutation {
                planStatuses.append(plan.status)
            }
        }
        let ids = Set(mutations.map { mutation in
            switch mutation {
            case let .save(id, _), let .delete(id, _): return id
            }
        })
        return CloudSendResult(acknowledgedMutationIDs: ids)
    }

    func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: CloudRevisionExpectation]
    ) async throws -> CloudSendResult {
        try await send(mutations)
    }

    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch { CloudChangeBatch() }

    func sentPlanStatuses() -> [CoursePlanStatus] { planStatuses }
}
