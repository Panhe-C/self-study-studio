import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CoursePlanningServiceTests: XCTestCase {
    func testSavingDraftPersistsItWithoutActivatingProject() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })

        let draftPlan = try service.saveDraft(input: input, draft: draft)

        XCTAssertEqual(draftPlan.status, .draft)
        XCTAssertNil(try repository.snapshot().projects.first?.activeCoursePlanId)
        XCTAssertEqual(try repository.snapshot().coursePlans.map(\.id), [draftPlan.id])
        XCTAssertEqual(try repository.snapshot().plannedSessions.count, 1)
    }

    func testActivationUpdatesProjectAndArchivesPreviousPlan() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let firstDraft = try service.saveDraft(input: input, draft: draft)
        _ = try service.activate(draftPlanID: firstDraft.id)
        let secondDraft = try service.saveDraft(input: input, draft: draft)

        let proposal = try service.activate(draftPlanID: secondDraft.id)
        let snapshot = try repository.snapshot()
        let activated = try XCTUnwrap(snapshot.coursePlans.first { $0.id == secondDraft.id })

        XCTAssertEqual(activated.status, .active)
        XCTAssertEqual(proposal?.title, "Implement tokenizer")
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, "Read lecture 1")
        XCTAssertEqual(snapshot.projects.first?.activeCoursePlanId, secondDraft.id)
        XCTAssertEqual(snapshot.coursePlans.first { $0.id == firstDraft.id }?.status, .archived)
        XCTAssertEqual(snapshot.trailEvents.filter { $0.type == .planActivated }.count, 2)
    }

    func testCompletingPlannedSessionProposesButDoesNotReplaceCanonicalNextStep() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let draftPlan = try service.saveDraft(input: input, draft: draftWithTwoSessions)
        _ = try service.activate(draftPlanID: draftPlan.id)
        let first = try XCTUnwrap(try repository.snapshot().plannedSessions.first { $0.title == "Implement tokenizer" })

        let proposal = try service.complete(plannedSessionID: first.id, with: UUID())

        XCTAssertEqual(proposal?.title, "Review tokenizer")
        XCTAssertEqual(try repository.snapshot().projects.first?.currentNextStep, "Read lecture 1")
    }

    func testRescheduleMutatesOnlySelectedSessionAndAuditsOriginalWindow() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let draftPlan = try service.saveDraft(input: input, draft: draftWithTwoSessions)
        _ = try service.activate(draftPlanID: draftPlan.id)
        let before = try repository.snapshot()
        let selected = try XCTUnwrap(before.plannedSessions.first { $0.title == "Implement tokenizer" })
        let sibling = try XCTUnwrap(before.plannedSessions.first { $0.title == "Review tokenizer" })
        let newDeadline = timestamp.addingTimeInterval(3 * 86_400)

        let updated = try service.reschedule(
            plannedSessionID: selected.id,
            newDeadline: newDeadline
        )
        let after = try repository.snapshot()

        XCTAssertEqual(updated.id, selected.id)
        XCTAssertEqual(updated.deadline, newDeadline)
        XCTAssertEqual(updated.status, .scheduled)
        XCTAssertEqual(
            after.plannedSessions.first(where: { $0.id == sibling.id }),
            sibling
        )
        XCTAssertEqual(after.coursePlans, before.coursePlans)
        XCTAssertEqual(after.planPhases, before.planPhases)
        let audit = try XCTUnwrap(
            after.trailEvents.last(where: {
                $0.type == .scheduleChanged && $0.sourceId == selected.id
            })
        )
        XCTAssertTrue(audit.detail.contains("Original window:"))
        XCTAssertTrue(audit.detail.contains("New deadline:"))
        let originalPhase = try XCTUnwrap(before.planPhases.first { $0.id == selected.phaseId })
        XCTAssertTrue(audit.detail.contains(originalPhase.targetStart.ISO8601Format()))
        XCTAssertTrue(audit.detail.contains((selected.deadline ?? originalPhase.targetEnd).ISO8601Format()))
        XCTAssertTrue(audit.detail.contains(newDeadline.ISO8601Format()))
        XCTAssertEqual(audit.projectId, selected.projectId)
    }

    func testGenerationFailureLeavesJournalUnchanged() async throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(
            repository: repository,
            provider: UnavailableCoursePlanningProvider(),
            now: { self.timestamp }
        )

        do {
            _ = try await service.generateDraft(input: input, context: .init())
            XCTFail("Expected AI configuration error")
        } catch let error as CoursePlanningError {
            XCTAssertEqual(error, .configurationRequired)
        }
        XCTAssertTrue(try repository.snapshot().coursePlans.isEmpty)
    }

    func testStructuralRevisionCreatesLinkedDraftWithoutMutatingPublishedRevision() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let firstDraft = try service.saveDraft(input: input, draft: draft)
        _ = try service.activate(draftPlanID: firstDraft.id)

        let revised = try service.revise(planID: firstDraft.id, input: input, draft: draft)
        let snapshot = try repository.snapshot()
        let original = try XCTUnwrap(snapshot.coursePlans.first { $0.id == firstDraft.id })

        XCTAssertEqual(revised.status, .draft)
        XCTAssertEqual(revised.planSeriesID, firstDraft.planSeriesID)
        XCTAssertEqual(revised.baseRevisionID, firstDraft.revisionID)
        XCTAssertEqual(revised.supersedesID, firstDraft.revisionID)
        XCTAssertEqual(original.status, .active)
        XCTAssertEqual(original.revisionID, firstDraft.revisionID)
    }

    func testStaleRevisionGuardFailsBeforeActivationWritesOrEnqueues() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let firstDraft = try service.saveDraft(input: input, draft: draft)
        _ = try service.activate(draftPlanID: firstDraft.id)
        let revised = try service.revise(planID: firstDraft.id, input: input, draft: draft)
        let metadata = SyncRecordMetadata(
            entity: .init(.coursePlan, firstDraft.id),
            zoneName: CloudSyncCoordinator.zoneName,
            recordName: firstDraft.id.uuidString,
            recordChangeTag: "server-v2",
            state: .synced
        )
        try repository.acknowledge([], metadata: [metadata])
        let before = try repository.snapshot()
        let pendingBefore = try repository.pendingMutations(limit: 100)

        XCTAssertThrowsError(
            try service.activate(
                draftPlanID: revised.id,
                expectation: RevisionGuardExpectation(
                    baseRevisionID: firstDraft.revisionID,
                    recordChangeTag: "stale-v1"
                )
            )
        ) { error in
            guard case let RevisionGuardError.stale(baseRevisionID, expected, actual) = error else {
                return XCTFail("Expected stale revision guard, got \(error)")
            }
            XCTAssertEqual(baseRevisionID, firstDraft.revisionID)
            XCTAssertEqual(expected, "stale-v1")
            XCTAssertEqual(actual, "server-v2")
        }

        XCTAssertEqual(try repository.snapshot(), before)
        XCTAssertEqual(try repository.pendingMutations(limit: 100), pendingBefore)
    }

    func testActivatingAnAlreadyActiveRevisionIsIdempotent() throws {
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let plan = try service.saveDraft(input: input, draft: draft)
        _ = try service.activate(draftPlanID: plan.id)
        let before = try repository.snapshot()
        let pendingBefore = try repository.pendingMutations(limit: 100)

        _ = try service.activate(draftPlanID: plan.id)

        XCTAssertEqual(try repository.snapshot(), before)
        XCTAssertEqual(try repository.pendingMutations(limit: 100), pendingBefore)
    }

    func testOverCapacityActivationRequiresAcknowledgementButDoesNotBlockAfterAcknowledgement() throws {
        var capacityCalendar = Calendar.current
        capacityCalendar.timeZone = TimeZone.current
        let weekday = capacityCalendar.component(.weekday, from: timestamp)
        let availability = try AvailabilityRule(
            weekday: weekday,
            startMinute: 18 * 60,
            endMinute: 18 * 60 + 30,
            timeZoneIdentifier: capacityCalendar.timeZone.identifier,
            minimumSessionMinutes: 15,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project],
                availabilityRules: [availability]
            )
        )
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let draftPlan = try service.saveDraft(input: input, draft: draft)
        let before = try repository.snapshot()

        XCTAssertThrowsError(
            try service.activate(
                draftPlanID: draftPlan.id,
                expectation: try service.revisionGuardExpectation(for: draftPlan.id)
            )
        ) { error in
            XCTAssertEqual(error as? CoursePlanningError, .capacityAcknowledgementRequired)
        }
        XCTAssertEqual(try repository.snapshot(), before)

        _ = try service.activate(
            draftPlanID: draftPlan.id,
            expectation: try service.revisionGuardExpectation(for: draftPlan.id),
            capacityAcknowledged: true
        )
        XCTAssertEqual(try repository.snapshot().coursePlans.first?.status, .active)
    }

    func testOverCapacityRescheduleRequiresAcknowledgementBeforeMutation() throws {
        let weekday = Calendar.current.component(.weekday, from: timestamp)
        let availability = try AvailabilityRule(
            weekday: weekday,
            startMinute: 18 * 60,
            endMinute: 18 * 60 + 30,
            timeZoneIdentifier: Calendar.current.timeZone.identifier,
            minimumSessionMinutes: 15,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], availabilityRules: [availability])
        )
        let service = CoursePlanningService(repository: repository, now: { self.timestamp })
        let plan = try service.saveDraft(input: input, draft: draft)
        _ = try service.activate(draftPlanID: plan.id, capacityAcknowledged: true)
        let session = try XCTUnwrap(try repository.snapshot().plannedSessions.first)
        let before = try repository.snapshot()

        XCTAssertThrowsError(
            try service.reschedule(
                plannedSessionID: session.id,
                newDeadline: timestamp.addingTimeInterval(3 * 86_400)
            )
        ) { error in
            XCTAssertEqual(error as? CoursePlanningError, .capacityAcknowledgementRequired)
        }
        XCTAssertEqual(try repository.snapshot(), before)

        let updated = try service.reschedule(
            plannedSessionID: session.id,
            newDeadline: timestamp.addingTimeInterval(3 * 86_400),
            capacityAcknowledged: true
        )
        XCTAssertEqual(updated.status, .scheduled)
        XCTAssertEqual(updated.deadline, timestamp.addingTimeInterval(3 * 86_400))
    }

    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let projectID = UUID()

    private var project: Project {
        Project(
            id: projectID,
            name: "CS336",
            area: "AI",
            goal: "Build a model",
            currentNextStep: "Read lecture 1",
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private var input: CoursePlanningInput {
        CoursePlanningInput(
            projectId: projectID,
            courseTitle: "CS336",
            courseOutline: "Language models",
            goal: project.goal,
            expectedOutcome: "Notebook",
            startsOn: timestamp,
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45
        )
    }

    private var draft: CoursePlanDraft {
        CoursePlanDraft(
            title: "CS336 Plan",
            summary: "Build a model",
            phases: [
                CoursePlanDraftPhase(
                    id: "foundations",
                    title: "Foundations",
                    objective: "Understand tokenization",
                    expectedProof: "Tokenizer notebook",
                    ordinal: 0,
                    targetStart: timestamp,
                    targetEnd: timestamp.addingTimeInterval(86_400)
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "tokenizer",
                    phaseID: "foundations",
                    title: "Implement tokenizer",
                    actionType: .course,
                    durationMinutes: 45
                )
            ]
        )
    }

    private var draftWithTwoSessions: CoursePlanDraft {
        var value = draft
        value.sessions.append(
            CoursePlanDraftSession(
                id: "review",
                phaseID: "foundations",
                title: "Review tokenizer",
                actionType: .review,
                durationMinutes: 30
            )
        )
        return value
    }
}

private struct UnavailableCoursePlanningProvider: CoursePlanningProvider {
    func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft {
        throw CoursePlanningError.configurationRequired
    }
}
