import CloudKit
import XCTest
@testable import PersonalLearningJournal

final class PlanLifecycleGuardTests: XCTestCase {
    func testOfflineCreateActivateReviseActivateKeepsPlanningDependencyChainTogether() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Offline", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })

        let first = try service.saveDraft(input: planningInput(project.id), draft: planningDraft)
        _ = try service.activate(draftPlanID: first.id)
        let revised = try service.revise(
            planID: first.id,
            input: planningInput(project.id),
            draft: planningDraft
        )
        _ = try service.activate(draftPlanID: revised.id)

        let pending = try repository.pendingMutations(limit: 100)
        let planning = pending.filter {
            [.coursePlan, .planPhase, .plannedSession, .practiceRoutine].contains($0.entity.kind)
        }
        let planningTransactionIDs = Set(planning.map(\.transactionID))
        XCTAssertEqual(planningTransactionIDs.count, 1)
        let chainTransactionID = try XCTUnwrap(planningTransactionIDs.first)
        XCTAssertTrue(pending.contains { $0.entity.kind == .project && $0.transactionID == chainTransactionID })
        XCTAssertTrue(pending.contains { $0.entity.kind == .trailEvent && $0.transactionID == chainTransactionID })

        // Unrelated journal writes retain append semantics and do not join the plan chain.
        let session = try LearningSession(
            projectId: project.id, source: .quickLog, actionType: .course,
            startedAt: timestamp, endedAt: timestamp.addingTimeInterval(60), durationMinutes: 1,
            note: "Unrelated", nextStepBefore: "Read", nextStepAfter: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        try repository.commit(JournalTransaction(upserts: [.session(session)], origin: .user))
        let sessionMutation = try XCTUnwrap(
            repository.pendingMutations(limit: 100).first { $0.entity == .init(.session, session.id) }
        )
        XCTAssertNotEqual(sessionMutation.transactionID, chainTransactionID)
    }

    @MainActor
    func testPlanningCloudBatchDeduplicatesProjectAndPreservesTrailEvents() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Cloud chain", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let first = try service.saveDraft(input: planningInput(project.id), draft: planningDraft)
        _ = try service.activate(draftPlanID: first.id)
        let revised = try service.revise(
            planID: first.id,
            input: planningInput(project.id),
            draft: planningDraft
        )
        _ = try service.activate(draftPlanID: revised.id)

        let client = PlanningBatchCloudClient()
        try await CloudSyncCoordinator(repository: repository, client: client).syncNow()

        let groups = await client.groups()
        XCTAssertEqual(groups.count, 1)
        let references = try XCTUnwrap(groups.first)
        XCTAssertEqual(references.count, Set(references).count)
        XCTAssertEqual(references.filter { $0.kind == .project }.count, 1)
        XCTAssertEqual(references.filter { $0.kind == .trailEvent }.count, 2)
        XCTAssertTrue(try repository.pendingMutations(limit: 100).isEmpty)

        let guardGroups = await client.guardGroups()
        let planGuard = try XCTUnwrap(
            guardGroups.flatMap { $0 }.first { $0.key == revised.reference }
        )
        XCTAssertEqual(planGuard.value.recordState, .existingRecord)
    }

    @MainActor
    func testPendingPaginationKeepsLargeTransactionAtomicAndSendsOtherTransactionSeparately() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstTransactionID = UUID()
        let projects = (0..<121).map { index in
            Project(
                name: "Batch \(index)", area: "AI", goal: "Learn",
                currentNextStep: "Read", createdAt: timestamp, updatedAt: timestamp
            )
        }
        let otherProject = Project(
            name: "Other", area: "AI", goal: "Learn", currentNextStep: "Read",
            createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository()
        try repository.commit(
            JournalTransaction(
                upserts: projects.map(JournalEntity.project),
                origin: .user,
                transactionID: firstTransactionID
            )
        )
        try repository.commit(JournalTransaction(upserts: [.project(otherProject)], origin: .user))

        let client = PlanningBatchCloudClient()
        try await CloudSyncCoordinator(repository: repository, client: client).syncNow()

        let groups = await client.groups()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.count)), Set([121, 1]))
        XCTAssertTrue(try repository.pendingMutations(limit: 1_000).isEmpty)
    }

    func testProductionEquivalentGuardAcceptsBaseRevisionCreatedEarlierInSameBatch() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: CloudSyncCoordinator.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let baseID = UUID()
        let baseRecord = CKRecord(
            recordType: "CoursePlan",
            recordID: CKRecord.ID(recordName: baseID.uuidString, zoneID: zoneID)
        )
        var state = CKSyncEngineBatchPreflightState()
        state.stage(baseRecord)

        let target = try LearningPlan(
            projectId: UUID(),
            revision: 2,
            baseRevisionID: baseID,
            status: .active,
            courseURL: nil,
            courseTitle: "Revision",
            courseOutline: "",
            goal: "Learn",
            expectedOutcome: "Notes",
            startsOn: Date(timeIntervalSince1970: 1_700_000_000),
            deadline: nil,
            weeklyBudgetMinutes: 60,
            summary: "Summary"
        )
        let expectation = CloudRevisionExpectation(
            entity: target.reference,
            revisionExpectation: .existing(baseRevisionID: baseID, recordChangeTag: nil)
        )

        XCTAssertNoThrow(
            try state.validateBaseRevision(
                baseRecordID: baseRecord.recordID,
                expectation: expectation,
                entity: .coursePlan(target)
            )
        )

        let staleExpectation = CloudRevisionExpectation(
            entity: target.reference,
            revisionExpectation: .existing(baseRevisionID: baseID, recordChangeTag: "server-v1")
        )
        XCTAssertThrowsError(
            try state.validateBaseRevision(
                baseRecordID: baseRecord.recordID,
                expectation: staleExpectation,
                entity: .coursePlan(target)
            )
        )
    }

    @MainActor
    func testOfflineRevisionLifecyclePassesStatefulProductionEquivalentBatchGuard() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Offline cloud guard", area: "AI", goal: "Learn",
            currentNextStep: "Read", createdAt: timestamp, updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let first = try service.saveDraft(input: planningInput(project.id), draft: planningDraft)
        _ = try service.activate(draftPlanID: first.id)
        let revised = try service.revise(
            planID: first.id,
            input: planningInput(project.id),
            draft: planningDraft
        )
        _ = try service.activate(draftPlanID: revised.id)

        let client = StatefulProductionEquivalentCloudClient()
        try await CloudSyncCoordinator(repository: repository, client: client).syncNow()

        let sendCallCount = await client.sendCallCount()
        let guardFailures = await client.guardFailures()
        XCTAssertEqual(sendCallCount, 1)
        XCTAssertTrue(guardFailures.isEmpty)
        XCTAssertTrue(try repository.pendingMutations(limit: 1_000).isEmpty)
    }

    func testSyncedNewDraftActivationRetainsCapturedTargetExpectation() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Draft", area: "AI", goal: "Learn", currentNextStep: "Read", createdAt: timestamp, updatedAt: timestamp)
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let plan = try service.saveDraft(input: planningInput(project.id), draft: planningDraft)
        let capturedMetadata = SyncRecordMetadata(
            entity: plan.reference,
            zoneName: CloudSyncCoordinator.zoneName,
            recordName: plan.id.uuidString,
            recordChangeTag: "draft-v1",
            state: .synced
        )
        try repository.acknowledge([], metadata: [capturedMetadata])

        let captured = try service.revisionGuardExpectation(for: plan.id)
        XCTAssertEqual(captured.targetRecordState, .existingRecord)
        _ = try service.activate(draftPlanID: plan.id, expectation: captured)

        let mutation = try XCTUnwrap(
            repository.pendingMutations(limit: 100).first { $0.entity == plan.reference }
        )
        XCTAssertEqual(mutation.revisionExpectation, captured)
        XCTAssertEqual(mutation.revisionExpectation?.targetRecordState, .existingRecord)
    }

    func testInFlightPlanningAckDoesNotReplaceActivationGuard() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_050)
        let project = Project(
            name: "Draft",
            area: "AI",
            goal: "Learn",
            currentNextStep: "Read",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let plan = try service.saveDraft(input: planningInput(project.id), draft: planningDraft)
        let baseMutation = try XCTUnwrap(
            repository.pendingMutations(limit: 100)
                .first(where: { $0.entity == plan.reference })
        )
        let activationExpectation = RevisionGuardExpectation.existing(
            baseRevisionID: UUID(),
            recordChangeTag: "base-v1"
        )
        try repository.commit(
            JournalTransaction(
                upserts: [.coursePlan(plan)],
                origin: .user,
                transactionID: baseMutation.transactionID,
                revisionExpectations: [plan.reference: activationExpectation]
            )
        )
        let replacement = try XCTUnwrap(
            repository.pendingMutations(limit: 100)
                .first(where: { $0.entity == plan.reference })
        )
        XCTAssertNotEqual(replacement.id, baseMutation.id)
        XCTAssertEqual(replacement.revisionExpectation, activationExpectation)

        try repository.acknowledge(
            [baseMutation.id],
            metadata: [
                SyncRecordMetadata(
                    entity: plan.reference,
                    zoneName: CloudSyncCoordinator.zoneName,
                    recordName: plan.id.uuidString,
                    recordChangeTag: "server-v2",
                    state: .synced
                )
            ]
        )

        let afterAck = try XCTUnwrap(
            repository.pendingMutations(limit: 100)
                .first(where: { $0.entity == plan.reference })
        )
        XCTAssertEqual(afterAck.id, replacement.id)
        XCTAssertEqual(afterAck.revisionExpectation, activationExpectation)
    }

    func testSyncedRevisionDraftActivationRetainsCapturedTargetExpectation() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Revision", area: "AI", goal: "Learn", currentNextStep: "Read", createdAt: timestamp, updatedAt: timestamp)
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { timestamp })
        let first = try service.saveDraft(input: planningInput(project.id), draft: planningDraft)
        _ = try service.activate(draftPlanID: first.id)
        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: first.reference,
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: first.id.uuidString,
                recordChangeTag: "active-v1",
                state: .synced
            )
        ])

        let revised = try service.revise(
            planID: first.id,
            input: planningInput(project.id),
            draft: planningDraft
        )
        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: revised.reference,
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: revised.id.uuidString,
                recordChangeTag: "draft-v2",
                state: .synced
            )
        ])
        let captured = try service.revisionGuardExpectation(for: revised.id)
        XCTAssertEqual(captured.targetRecordState, .existingRecord)
        _ = try service.activate(draftPlanID: revised.id, expectation: captured)

        let mutation = try XCTUnwrap(
            repository.pendingMutations(limit: 100).first { $0.entity == revised.reference }
        )
        XCTAssertEqual(mutation.revisionExpectation, captured)
        XCTAssertEqual(mutation.revisionExpectation?.targetRecordState, .existingRecord)

        let archivedMutation = try XCTUnwrap(
            repository.pendingMutations(limit: 100).first { $0.entity == first.reference }
        )
        XCTAssertEqual(archivedMutation.revisionExpectation?.targetRecordState, .existingRecord)
        XCTAssertEqual(archivedMutation.revisionExpectation?.recordChangeTag, "active-v1")
    }

    func testLockedRoutineEditAndArchiveAreRejectedWithoutChangingIdentity() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Practice", area: "Music", goal: "Learn", currentNextStep: "Play", createdAt: timestamp, updatedAt: timestamp)
        let routine = PracticeRoutine(
            projectId: project.id,
            planRevisionID: UUID(),
            planSeriesID: UUID(),
            isStructuralLocked: true,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], practiceRoutines: [routine])
        )
        let service = PracticeService(repository: repository, now: { timestamp })

        XCTAssertThrowsError(
            try service.updateRoutine(
                routineId: routine.id,
                name: "Piano",
                symbolName: routine.symbolName,
                color: routine.color,
                targetMinutes: routine.targetMinutes,
                weekdays: routine.weekdays
            )
        ) { error in
            XCTAssertEqual(error as? PracticeServiceError, .lockedRoutineCannotBeModified)
        }
        XCTAssertThrowsError(try service.archiveRoutine(routine.id)) { error in
            XCTAssertEqual(error as? PracticeServiceError, .lockedRoutineCannotBeModified)
        }
        XCTAssertEqual(try repository.snapshot().practiceRoutines, [routine])
    }

    func testLockedRoutineDeleteIsRejectedWithoutChangingIdentity() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            name: "Practice", area: "Music", goal: "Learn", currentNextStep: "Play",
            createdAt: timestamp, updatedAt: timestamp
        )
        let routine = PracticeRoutine(
            projectId: project.id,
            planRevisionID: UUID(),
            planSeriesID: UUID(),
            isStructuralLocked: true,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], practiceRoutines: [routine])
        )
        let service = PracticeService(repository: repository, now: { timestamp })

        XCTAssertThrowsError(try service.deleteRoutineIfUnused(routine.id)) { error in
            XCTAssertEqual(error as? PracticeServiceError, .lockedRoutineCannotBeModified)
        }
        XCTAssertEqual(try repository.snapshot().practiceRoutines, [routine])
        XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
    }

    func testPracticeManagerDraftCannotSavePublishedRoutineAndExposesRevisionGuidanceState() {
        let routine = PracticeRoutine(
            projectId: UUID(),
            planRevisionID: UUID(),
            planSeriesID: UUID(),
            isStructuralLocked: true,
            name: "Guitar",
            symbolName: "guitars",
            color: .coral,
            targetMinutes: 30,
            weekdays: [2]
        )
        let draft = PracticeRoutineDraft(routine: routine)

        XCTAssertTrue(draft.isStructuralLocked)
        XCTAssertFalse(draft.canSave(comparedWith: [routine]))
    }

    func testOperationalRoutinePresentationUsesLegacyAndActiveRevisionOnlyAfterRevisionActivation() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(name: "Practice", area: "Music", goal: "Learn", currentNextStep: "Play", createdAt: timestamp, updatedAt: timestamp)
        let activePlan = try LearningPlan(
            projectId: project.id, revision: 1, status: .active,
            courseURL: nil, courseTitle: "Current", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: timestamp, deadline: nil,
            weeklyBudgetMinutes: 60, summary: "Current", createdAt: timestamp, updatedAt: timestamp
        )
        var linkedProject = project
        linkedProject.activeCoursePlanId = activePlan.id
        let presentationWeekday = utcCalendar.component(.weekday, from: timestamp)
        let legacy = PracticeRoutine(
            projectId: project.id, name: "Legacy", symbolName: "guitars", color: .coral,
            targetMinutes: 20, weekdays: [presentationWeekday], createdAt: timestamp, updatedAt: timestamp
        )
        let current = PracticeRoutine(
            projectId: project.id, planRevisionID: activePlan.revisionID,
            planSeriesID: activePlan.planSeriesID, isStructuralLocked: true,
            name: "Current routine", symbolName: "guitars", color: .teal,
            targetMinutes: 30, weekdays: [presentationWeekday], createdAt: timestamp, updatedAt: timestamp
        )
        let superseded = PracticeRoutine(
            projectId: project.id, planRevisionID: UUID(),
            planSeriesID: activePlan.planSeriesID, isStructuralLocked: true,
            name: "Old routine", symbolName: "guitars", color: .blue,
            targetMinutes: 40, weekdays: [presentationWeekday], createdAt: timestamp, updatedAt: timestamp
        )
        let snapshot = JournalSnapshot(
            projects: [linkedProject], coursePlans: [activePlan],
            practiceRoutines: [legacy, current, superseded]
        )

        XCTAssertEqual(
            Set(snapshot.operationalPracticeRoutines.map(\.id)),
            Set([legacy.id, current.id])
        )
        XCTAssertEqual(
            Set(snapshot.practiceRoutineHistory.map(\.id)),
            Set([legacy.id, current.id, superseded.id])
        )
        let cards = StudioPresentation.practiceCards(
            routines: snapshot.operationalPracticeRoutines,
            sessions: [],
            activeRoutineId: nil,
            now: timestamp,
            calendar: utcCalendar
        )
        XCTAssertEqual(Set(cards.map(\.routine.id)), Set([legacy.id, current.id]))
        XCTAssertFalse(cards.contains { $0.routine.id == superseded.id })
    }

    private var planningDraft: CoursePlanDraft {
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

    private func planningInput(_ projectID: UUID) -> CoursePlanningInput {
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

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private actor PlanningBatchCloudClient: CloudDatabaseClient {
    private var sentGroups: [[JournalEntityReference]] = []
    private var sentGuardGroups: [[JournalEntityReference: CloudRevisionExpectation]] = []

    func ensureZone(named: String) async throws {}

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        try await send(mutations, revisionExpectations: [:])
    }

    func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: CloudRevisionExpectation]
    ) async throws -> CloudSendResult {
        let references = mutations.map { mutation -> JournalEntityReference in
            switch mutation {
            case let .save(_, entity): entity.reference
            case let .delete(_, reference): reference
            }
        }
        sentGroups.append(references)
        sentGuardGroups.append(revisionExpectations)
        let acknowledgedIDs = Set(mutations.map { mutation in
            switch mutation {
            case let .save(id, _), let .delete(id, _): id
            }
        })
        let metadata = references.map {
            SyncRecordMetadata(
                entity: $0,
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: $0.id.uuidString,
                recordChangeTag: "returned-\($0.id.uuidString)",
                state: .synced
            )
        }
        return CloudSendResult(
            acknowledgedMutationIDs: acknowledgedIDs,
            metadata: metadata
        )
    }

    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        CloudChangeBatch()
    }

    func groups() -> [[JournalEntityReference]] { sentGroups }

    func guardGroups() -> [[JournalEntityReference: CloudRevisionExpectation]] {
        sentGuardGroups
    }
}

/// Models the production preflight rule that a base record may be either
/// server-backed or one of the saves in the current atomic request. It is
/// intentionally stateful so an offline create/revise/activate sequence does
/// not accidentally pass only because the fake blindly acknowledges writes.
private actor StatefulProductionEquivalentCloudClient: CloudDatabaseClient {
    private var serverTags: [JournalEntityReference: String] = [:]
    private var calls = 0
    private var failures: [String] = []

    func ensureZone(named: String) async throws {}

    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult {
        try await send(mutations, revisionExpectations: [:])
    }

    func send(
        _ mutations: [CloudMutation],
        revisionExpectations: [JournalEntityReference: CloudRevisionExpectation]
    ) async throws -> CloudSendResult {
        calls += 1
        let savedReferences = Set(mutations.compactMap { mutation -> JournalEntityReference? in
            guard case let .save(_, entity) = mutation else { return nil }
            return entity.reference
        })

        do {
            for mutation in mutations {
                guard case let .save(_, entity) = mutation else { continue }
                guard let expectation = revisionExpectations[entity.reference] else { continue }

                if let baseRevisionID = expectation.baseRevisionID,
                   baseRevisionID != entity.reference.id {
                    let baseReference = JournalEntityReference(.coursePlan, baseRevisionID)
                    let baseExists = serverTags[baseReference] != nil
                        || savedReferences.contains(baseReference)
                    let actualTag = serverTags[baseReference]
                    guard baseExists, actualTag == expectation.baseRecordChangeTag else {
                        throw CloudRevisionGuardError.stale(
                            entity: entity.reference,
                            expectedRecordChangeTag: expectation.baseRecordChangeTag,
                            actualRecordChangeTag: actualTag
                        )
                    }
                }

                let targetTag = serverTags[entity.reference]
                switch expectation.targetRecordState {
                case .newRecord:
                    guard targetTag == nil else {
                        throw CloudRevisionGuardError.stale(
                            entity: entity.reference,
                            expectedRecordChangeTag: expectation.targetRecordChangeTag,
                            actualRecordChangeTag: targetTag
                        )
                    }
                case .existingRecord:
                    guard targetTag == expectation.targetRecordChangeTag else {
                        throw CloudRevisionGuardError.stale(
                            entity: entity.reference,
                            expectedRecordChangeTag: expectation.targetRecordChangeTag,
                            actualRecordChangeTag: targetTag
                        )
                    }
                }
            }
        } catch let error as CloudRevisionGuardError {
            failures.append(String(describing: error))
            throw error
        }

        let acknowledged = Set(mutations.map { mutation in
            switch mutation {
            case let .save(id, _), let .delete(id, _): id
            }
        })
        var metadata: [SyncRecordMetadata] = []
        for mutation in mutations {
            guard case let .save(_, entity) = mutation else { continue }
            let tag = "server-v\(serverTags.count + 1)"
            serverTags[entity.reference] = tag
            metadata.append(
                SyncRecordMetadata(
                    entity: entity.reference,
                    zoneName: CloudSyncCoordinator.zoneName,
                    recordName: entity.reference.id.uuidString,
                    recordChangeTag: tag,
                    state: .synced
                )
            )
        }
        return CloudSendResult(acknowledgedMutationIDs: acknowledged, metadata: metadata)
    }

    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch {
        CloudChangeBatch()
    }

    func sendCallCount() -> Int { calls }

    func guardFailures() -> [String] { failures }
}
