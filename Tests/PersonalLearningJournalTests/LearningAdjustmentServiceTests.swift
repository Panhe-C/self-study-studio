import XCTest
@testable import PersonalLearningJournal

final class LearningAdjustmentServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Round trip

    func testSuggestionCodableAndRepositoryRoundTrip() throws {
        let suggestion = makeSuggestion(kind: .nextStep)

        let decoded = try JSONDecoder.journal.decode(
            LearningAdjustmentSuggestion.self,
            from: JSONEncoder.journal.encode(suggestion)
        )
        XCTAssertEqual(decoded, suggestion)

        let inMemory = InMemoryJournalRepository(snapshot: JournalSnapshot())
        try inMemory.commit(
            JournalTransaction(upserts: [.learningAdjustmentSuggestion(suggestion)], origin: .user)
        )
        XCTAssertEqual(try inMemory.snapshot().learningAdjustmentSuggestions, [suggestion])

        let swiftData = try SwiftDataJournalRepository.inMemory(now: { self.now })
        try swiftData.commit(
            JournalTransaction(upserts: [.learningAdjustmentSuggestion(suggestion)], origin: .user)
        )
        XCTAssertEqual(try swiftData.snapshot().learningAdjustmentSuggestions, [suggestion])
        let fetched = try swiftData.entity(for: suggestion.reference)
        guard case let .learningAdjustmentSuggestion(value) = fetched else {
            return XCTFail("Expected learningAdjustmentSuggestion entity")
        }
        XCTAssertEqual(value, suggestion)

        try swiftData.commit(
            JournalTransaction(
                deletions: [suggestion.reference],
                origin: .user
            )
        )
        XCTAssertTrue(try swiftData.snapshot().learningAdjustmentSuggestions.isEmpty)
    }

    // MARK: - Rule-based detection

    func testDetectRepeatedPartialProgressOnSamePlannedActivity() throws {
        let fixture = try makeRepeatedPartialFixture(progress: .partial, assessedCount: 2)
        let service = LearningAdjustmentService(repository: fixture.repository, now: { self.now })

        let suggestions = try service.detectSuggestions(projectID: fixture.projectID)

        XCTAssertEqual(suggestions.count, 1)
        let suggestion = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(suggestion.kind, .nextStep)
        XCTAssertEqual(suggestion.title, "Repeated partial progress on Read Chapter 3")
        XCTAssertEqual(suggestion.sourceSessionIDs, fixture.sessionIDs)
        XCTAssertEqual(suggestion.decision, .pending)
        XCTAssertEqual(suggestion.planRevisionDraftID, nil)
        XCTAssertEqual(suggestion.createdAt, now)
        XCTAssertEqual(
            try fixture.repository.snapshot().learningAdjustmentSuggestions.count, 1
        )
    }

    func testDetectIgnoresUnassessedSessions() throws {
        // One confirmed partial record plus one unassessed (unconfirmed)
        // session for the same activity must NOT trigger: detection reads
        // only confirmed records.
        let fixture = try makeRepeatedPartialFixture(progress: .partial, assessedCount: 1)
        let service = LearningAdjustmentService(repository: fixture.repository, now: { self.now })

        XCTAssertEqual(try service.detectSuggestions(projectID: fixture.projectID), [])
    }

    func testDetectDoesNotTriggerOnNonPartialProgress() throws {
        let fixture = try makeRepeatedPartialFixture(progress: .completed, assessedCount: 2)
        let service = LearningAdjustmentService(repository: fixture.repository, now: { self.now })

        XCTAssertEqual(try service.detectSuggestions(projectID: fixture.projectID), [])
    }

    func testDetectRepeatedBlockerNormalizesCaseAndWhitespace() throws {
        let project = makeProject()
        let first = try makeConfirmedSession(
            projectID: project.id, note: "First", blocker: "Missing example", confirmedOffset: 0
        )
        let second = try makeConfirmedSession(
            projectID: project.id, note: "Second", blocker: "  missing EXAMPLE ", confirmedOffset: 1
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project], sessions: [first, second])
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        let suggestions = try service.detectSuggestions(projectID: project.id)

        XCTAssertEqual(suggestions.count, 1)
        let suggestion = try XCTUnwrap(suggestions.first)
        // Documented choice: a persistent blocker maps to a next-step
        // suggestion proposing a blocker-resolution step, because the
        // canonical Next Step command is the safe executable action.
        XCTAssertEqual(suggestion.kind, .nextStep)
        XCTAssertEqual(suggestion.title, "Repeated blocker: missing EXAMPLE")
        XCTAssertEqual(suggestion.proposedValue, "Resolve blocker: missing EXAMPLE")
        XCTAssertEqual(suggestion.sourceSessionIDs, [first.id, second.id])
    }

    func testPersistSuggestionsDedupesOneBatchAndNormalizesIdentity() throws {
        let project = makeProject()
        let sourceID = UUID()
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(projects: [project]))
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        let created = try service.persistSuggestions([
            LearningAdjustmentSuggestionDraft(
                kind: .nextStep,
                title: "  Review   Tokens  ",
                rationale: " first ",
                proposedValue: " Read the tokenizer notes ",
                sourceSessionIDs: [sourceID, sourceID]
            ),
            LearningAdjustmentSuggestionDraft(
                kind: .nextStep,
                title: "review tokens",
                rationale: "duplicate",
                proposedValue: "A second proposal"
            ),
            LearningAdjustmentSuggestionDraft(
                kind: .reschedule,
                title: " review tokens ",
                rationale: "different command",
                proposedValue: "Move the session"
            )
        ], projectID: project.id)

        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[0].title, "Review   Tokens")
        XCTAssertEqual(created[0].sourceSessionIDs, [sourceID])
        XCTAssertEqual(created[1].kind, .reschedule)
        XCTAssertEqual(
            try repository.snapshot().learningAdjustmentSuggestions.count,
            2
        )
    }

    func testTypedCommandRejectsKindMismatchWithoutMutation() throws {
        let project = makeProject()
        let suggestion = makeSuggestion(projectID: project.id, kind: .nextStep)
        let repository = InMemoryJournalRepository(snapshot: JournalSnapshot(
            projects: [project], learningAdjustmentSuggestions: [suggestion]
        ))
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        XCTAssertThrowsError(try service.adopt(
            suggestionID: suggestion.id,
            command: .temporaryDuration(target: TemporaryDurationAdoptionTarget(
                plannedSessionID: UUID(), minutes: 20
            ))
        )) { error in
            XCTAssertEqual(
                error as? LearningAdjustmentError,
                .commandKindMismatch(expected: .nextStep, actual: .temporaryDuration)
            )
        }
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.learningAdjustmentSuggestions.first?.decision, .pending)
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, project.currentNextStep)
    }

    func testDetectPhaseWindowRiskRescheduleWhenShortfallIsSmall() throws {
        let fixture = try makePhaseRiskFixture(completedCount: 3, incompleteCount: 1)
        let service = LearningAdjustmentService(repository: fixture.repository, now: { self.now })

        let suggestions = try service.detectSuggestions(projectID: fixture.projectID)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.kind, .reschedule)
        XCTAssertEqual(
            suggestions.first?.title,
            "Phase \"Foundations\" window closes soon"
        )
    }

    func testDetectPhaseWindowRiskStructuralWhenShortfallIsLarge() throws {
        let fixture = try makePhaseRiskFixture(completedCount: 1, incompleteCount: 3)
        let service = LearningAdjustmentService(repository: fixture.repository, now: { self.now })

        let suggestions = try service.detectSuggestions(projectID: fixture.projectID)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.kind, .structuralRevision)
        XCTAssertEqual(
            suggestions.first?.title,
            "Phase \"Foundations\" needs structural revision"
        )
    }

    func testDetectPhaseWindowRiskSkipsComfortableWindows() throws {
        let fixture = try makePhaseRiskFixture(
            completedCount: 0, incompleteCount: 2, targetEndOffset: 10 * 86_400
        )
        let service = LearningAdjustmentService(repository: fixture.repository, now: { self.now })

        XCTAssertEqual(try service.detectSuggestions(projectID: fixture.projectID), [])
    }

    func testDetectDedupesEquivalentPendingSuggestions() throws {
        let fixture = try makeRepeatedPartialFixture(progress: .partial, assessedCount: 2)
        let service = LearningAdjustmentService(repository: fixture.repository, now: { self.now })

        XCTAssertEqual(try service.detectSuggestions(projectID: fixture.projectID).count, 1)
        XCTAssertEqual(try service.detectSuggestions(projectID: fixture.projectID), [])
        XCTAssertEqual(
            try fixture.repository.snapshot().learningAdjustmentSuggestions.count, 1
        )
    }

    // MARK: - Decisions

    func testAdoptNextStepAppliesProjectTrailAndDecisionInOneCommit() throws {
        let project = makeProject(nextStep: "Old step")
        let suggestion = makeSuggestion(
            projectID: project.id, kind: .nextStep, proposedValue: "Review tokenizer edge cases"
        )
        var commitCount = 0
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project], learningAdjustmentSuggestions: [suggestion]
            ),
            commitHook: { _ in commitCount += 1 }
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        try service.adopt(
            suggestionID: suggestion.id,
            command: .nextStep(value: suggestion.proposedValue)
        )

        XCTAssertEqual(commitCount, 1)
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, "Review tokenizer edge cases")
        let trail = try XCTUnwrap(snapshot.trailEvents.first { $0.type == .nextStepChange })
        XCTAssertTrue(trail.detail.contains("Old step"))
        XCTAssertTrue(trail.detail.contains("Review tokenizer edge cases"))
        let stored = try XCTUnwrap(snapshot.learningAdjustmentSuggestions.first)
        XCTAssertEqual(stored.decision, .adopted)
        XCTAssertEqual(stored.decidedAt, now)
    }

    func testAdoptDailyOrderPersistsDecisionOnly() throws {
        // Day-scoped Today overrides are intentionally not journal records:
        // the caller applies the in-memory override first, so the repository
        // transaction persists only the decision.
        let project = makeProject()
        let suggestion = makeSuggestion(projectID: project.id, kind: .dailyOrder)
        var commitCount = 0
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project], learningAdjustmentSuggestions: [suggestion]
            ),
            commitHook: { _ in commitCount += 1 }
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        try service.adopt(
            suggestionID: suggestion.id,
            command: .dailyOrder(target: DailyOrderAdoptionTarget(
                day: now,
                source: .nextStep,
                sourceID: project.id,
                position: .upNext
            ))
        )

        XCTAssertEqual(commitCount, 1)
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.learningAdjustmentSuggestions.first?.decision, .adopted)
        XCTAssertTrue(snapshot.trailEvents.isEmpty)
    }

    func testAdoptRescheduleAppliesTypedTargetAndDecisionInOneCommit() throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id, title: "Read")
        let newDeadline = now.addingTimeInterval(3 * 86_400)
        let suggestion = makeSuggestion(projectID: project.id, kind: .reschedule)
        var commitCount = 0
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project],
                plannedSessions: [planned],
                learningAdjustmentSuggestions: [suggestion]
            ),
            commitHook: { _ in commitCount += 1 }
        )
        let planning = CoursePlanningService(repository: repository, now: { self.now })
        let service = LearningAdjustmentService(
            repository: repository, planningService: planning, now: { self.now }
        )

        try service.adopt(
            suggestionID: suggestion.id,
            command: .reschedule(target: RescheduleAdoptionTarget(
                plannedSessionID: planned.id, newDeadline: newDeadline
            ))
        )

        XCTAssertEqual(commitCount, 1)
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.plannedSessions.first?.deadline, newDeadline)
        XCTAssertEqual(snapshot.plannedSessions.first?.status, .scheduled)
        XCTAssertEqual(snapshot.learningAdjustmentSuggestions.first?.decision, .adopted)
        XCTAssertTrue(snapshot.trailEvents.contains { $0.type == .scheduleChanged })
    }

    func testAdoptRescheduleWithoutTargetThrows() throws {
        let project = makeProject()
        let suggestion = makeSuggestion(projectID: project.id, kind: .reschedule)
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project], learningAdjustmentSuggestions: [suggestion]
            )
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        XCTAssertThrowsError(try service.adopt(
            suggestionID: suggestion.id,
            command: .nextStep(value: suggestion.proposedValue)
        )) { error in
            XCTAssertEqual(
                error as? LearningAdjustmentError,
                .commandKindMismatch(expected: .reschedule, actual: .nextStep)
            )
        }
        XCTAssertEqual(
            try repository.snapshot().learningAdjustmentSuggestions.first?.decision, .pending
        )
    }

    func testAdoptTemporaryDurationAppliesTypedTargetInOneCommit() throws {
        let project = makeProject()
        let planned = try makePlannedSession(projectID: project.id, title: "Read", duration: 30)
        let suggestion = makeSuggestion(projectID: project.id, kind: .temporaryDuration)
        var commitCount = 0
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project],
                plannedSessions: [planned],
                learningAdjustmentSuggestions: [suggestion]
            ),
            commitHook: { _ in commitCount += 1 }
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        try service.adopt(
            suggestionID: suggestion.id,
            command: .temporaryDuration(target: TemporaryDurationAdoptionTarget(
                plannedSessionID: planned.id, minutes: 45
            ))
        )

        XCTAssertEqual(commitCount, 1)
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.plannedSessions.first?.durationMinutes, 30)
        XCTAssertEqual(snapshot.learningAdjustmentSuggestions.first?.decision, .adopted)
        XCTAssertTrue(snapshot.trailEvents.isEmpty)
        XCTAssertEqual(
            snapshot.learningAdjustmentSuggestions.first?.appliedCommand,
            .temporaryDuration(target: TemporaryDurationAdoptionTarget(
                plannedSessionID: planned.id, minutes: 45
            ))
        )
    }

    func testIgnoreSuggestionMarksDecisionInOneCommit() throws {
        let project = makeProject()
        let suggestion = makeSuggestion(projectID: project.id, kind: .nextStep)
        var commitCount = 0
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project], learningAdjustmentSuggestions: [suggestion]
            ),
            commitHook: { _ in commitCount += 1 }
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        try service.ignore(suggestionID: suggestion.id)

        XCTAssertEqual(commitCount, 1)
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.learningAdjustmentSuggestions.first?.decision, .ignored)
        XCTAssertEqual(snapshot.learningAdjustmentSuggestions.first?.decidedAt, now)
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, project.currentNextStep)
        XCTAssertTrue(snapshot.trailEvents.isEmpty)
    }

    func testModifyAppliesEditedValueWithModifiedDecision() throws {
        let project = makeProject(nextStep: "Old step")
        let suggestion = makeSuggestion(
            projectID: project.id, kind: .nextStep, proposedValue: "Original proposal"
        )
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project], learningAdjustmentSuggestions: [suggestion]
            )
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        try service.modify(
            suggestionID: suggestion.id,
            command: .nextStep(value: "Edited next step")
        )

        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.projects.first?.currentNextStep, "Edited next step")
        let stored = try XCTUnwrap(snapshot.learningAdjustmentSuggestions.first)
        XCTAssertEqual(stored.decision, .modified)
        XCTAssertEqual(stored.proposedValue, "Edited next step")
        XCTAssertEqual(stored.decidedAt, now)
    }

    func testDecidingTwiceThrows() throws {
        let project = makeProject()
        let suggestion = makeSuggestion(projectID: project.id, kind: .nextStep)
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project], learningAdjustmentSuggestions: [suggestion]
            )
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })

        try service.ignore(suggestionID: suggestion.id)
        XCTAssertThrowsError(try service.adopt(
            suggestionID: suggestion.id,
            command: .nextStep(value: suggestion.proposedValue)
        )) { error in
            XCTAssertEqual(error as? LearningAdjustmentError, .alreadyDecided)
        }
        XCTAssertThrowsError(try service.ignore(suggestionID: suggestion.id)) { error in
            XCTAssertEqual(error as? LearningAdjustmentError, .alreadyDecided)
        }
    }

    // MARK: - Structural suggestions

    func testStructuralPrepareCreatesDraftKeepsBaseActiveAndNeverActivates() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project])
        )
        let planning = CoursePlanningService(repository: repository, now: { self.now })
        let base = try planning.saveDraft(
            input: planningInput(project.id), draft: planningDraft
        )
        _ = try planning.activate(draftPlanID: base.id)
        let activePhase = try XCTUnwrap(
            try repository.snapshot().planPhases.first { $0.planId == base.id }
        )
        let suggestion = makeSuggestion(
            projectID: project.id,
            kind: .structuralRevision,
            structuralChange: LearningAdjustmentStructuralChange(
                phaseID: activePhase.id,
                phaseObjective: "A revised objective"
            )
        )
        try repository.commit(
            JournalTransaction(upserts: [.learningAdjustmentSuggestion(suggestion)], origin: .user)
        )
        let service = LearningAdjustmentService(
            repository: repository, planningService: planning, now: { self.now }
        )

        let draft = try service.prepareStructuralDraft(suggestionID: suggestion.id)

        var snapshot = try repository.snapshot()
        XCTAssertEqual(draft.plan.status, .draft)
        XCTAssertEqual(draft.plan.baseRevisionID, base.revisionID)
        XCTAssertEqual(
            snapshot.coursePlans.first(where: { $0.id == base.id })?.status, .active
        )
        var stored = try XCTUnwrap(snapshot.learningAdjustmentSuggestions.first)
        XCTAssertEqual(stored.planRevisionDraftID, draft.plan.id)
        XCTAssertEqual(stored.revisionGuardExpectation, draft.guardExpectation)
        XCTAssertEqual(stored.decision, .pending)
        let aggregate = try XCTUnwrap(
            snapshot.learningPlanAggregates(for: project.id).first
        )
        let activeRevision = try XCTUnwrap(aggregate.activeRevision)
        let diff = PlanRevisionDiffEngine.compute(
            base: activeRevision,
            candidate: draft.materializedRevision()
        )
        XCTAssertFalse(diff.isEmpty)
        XCTAssertTrue(
            diff.phaseChanges.contains { change in
                change.fieldChanges.contains { $0.field == "objective" }
            }
        )

        // Adopting a structural suggestion directly is impossible.
        XCTAssertThrowsError(try service.adopt(
            suggestionID: suggestion.id,
            command: .structuralRevision(draftID: UUID())
        )) { error in
            XCTAssertEqual(
                error as? LearningAdjustmentError, .structuralRevisionRequiresDraftActivation
            )
        }
        // It cannot be marked adopted before the user activates the revision.
        XCTAssertThrowsError(try service.markAdoptedAfterActivation(suggestionID: suggestion.id)) { error in
            XCTAssertEqual(error as? LearningAdjustmentError, .revisionNotActivated)
        }

        try repository.acknowledge([], metadata: [
            SyncRecordMetadata(
                entity: .init(.coursePlan, base.id),
                zoneName: CloudSyncCoordinator.zoneName,
                recordName: base.id.uuidString,
                recordChangeTag: "server-v2",
                state: .synced
            )
        ])
        XCTAssertThrowsError(try planning.activate(
            draftPlanID: draft.plan.id, expectation: draft.guardExpectation
        )) { error in
            guard case let RevisionGuardError.stale(baseRevisionID, _, actual) = error else {
                return XCTFail("Expected stale base-plan guard, got \(error)")
            }
            XCTAssertEqual(baseRevisionID, base.revisionID)
            XCTAssertEqual(actual, "server-v2")
        }
        _ = try planning.activate(
            draftPlanID: draft.plan.id,
            expectation: try planning.revisionGuardExpectation(for: draft.plan.id)
        )
        try service.markAdoptedAfterActivation(suggestionID: suggestion.id)
        XCTAssertNoThrow(try service.markAdoptedAfterActivation(suggestionID: suggestion.id))

        snapshot = try repository.snapshot()
        XCTAssertEqual(
            snapshot.coursePlans.first(where: { $0.id == base.id })?.status, .archived
        )
        stored = try XCTUnwrap(snapshot.learningAdjustmentSuggestions.first)
        XCTAssertEqual(stored.decision, .adopted)
        XCTAssertEqual(stored.decidedAt, now)
    }

    func testStructuralPrepareRejectsMissingInvalidAndNoOpPayloadWithoutDraft() throws {
        let project = makeProject()
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project])
        )
        let planning = CoursePlanningService(repository: repository, now: { self.now })
        let base = try planning.saveDraft(
            input: planningInput(project.id), draft: planningDraft
        )
        _ = try planning.activate(draftPlanID: base.id)
        let service = LearningAdjustmentService(
            repository: repository, planningService: planning, now: { self.now }
        )

        func assertRejected(
            _ structuralChange: LearningAdjustmentStructuralChange?,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let suggestion = makeSuggestion(
                projectID: project.id,
                kind: .structuralRevision,
                structuralChange: structuralChange
            )
            try repository.commit(
                JournalTransaction(
                    upserts: [.learningAdjustmentSuggestion(suggestion)],
                    origin: .user
                )
            )
            XCTAssertThrowsError(
                try service.prepareStructuralDraft(suggestionID: suggestion.id),
                file: file,
                line: line
            ) { error in
                XCTAssertEqual(
                    error as? LearningAdjustmentError,
                    .invalidStructuralChange,
                    file: file,
                    line: line
                )
            }
            let snapshot = try repository.snapshot()
            XCTAssertEqual(snapshot.coursePlans.count, 1, file: file, line: line)
            XCTAssertNil(
                snapshot.learningAdjustmentSuggestions
                    .first { $0.id == suggestion.id }?.planRevisionDraftID,
                file: file,
                line: line
            )
        }

        try assertRejected(nil)
        try assertRejected(LearningAdjustmentStructuralChange())
        try assertRejected(
            LearningAdjustmentStructuralChange(
                weeklyBudgetMinutes: base.weeklyBudgetMinutes
            )
        )
        try assertRejected(LearningAdjustmentStructuralChange(weeklyBudgetMinutes: 0))
    }

    // MARK: - Diff engine

    func testDiffEngineReportsPlanPhaseAndSessionChanges() throws {
        let base = try makeRevision(
            weeklyBudget: 60,
            phases: [(0, "Basics", "Objective A")],
            sessions: [
                (0, "Read", 30, ["a"]),
                (0, "Write", 20, ["b"])
            ]
        )
        let candidate = try makeRevision(
            weeklyBudget: 90,
            deadline: now,
            phases: [(0, "Basics", "Objective B"), (1, "Advanced", "Objective C")],
            sessions: [
                (0, "Read", 45, ["a", "b"]),
                (1, "Build", 60, ["c"])
            ]
        )

        let diff = PlanRevisionDiffEngine.compute(base: base, candidate: candidate)

        XCTAssertFalse(diff.isEmpty)
        XCTAssertTrue(diff.planFieldChanges.contains(
            .init(field: "weeklyBudgetMinutes", base: "60", candidate: "90")
        ))
        XCTAssertTrue(diff.planFieldChanges.contains(
            .init(field: "deadline", base: nil, candidate: JournalISO8601Codec.string(from: now))
        ))

        let changedPhase = try XCTUnwrap(diff.phaseChanges.first { $0.kind == .changed })
        XCTAssertEqual(changedPhase.ordinal, 0)
        XCTAssertEqual(changedPhase.fieldChanges, [
            .init(field: "objective", base: "Objective A", candidate: "Objective B")
        ])
        XCTAssertEqual(diff.phaseChanges.first { $0.kind == .added }?.title, "Advanced")

        let changedSession = try XCTUnwrap(diff.sessionChanges.first { $0.kind == .changed })
        XCTAssertEqual(changedSession.title, "Read")
        XCTAssertTrue(changedSession.fieldChanges.contains(
            .init(field: "durationMinutes", base: "30", candidate: "45")
        ))
        XCTAssertTrue(changedSession.fieldChanges.contains(
            .init(field: "completionCriteria", base: "a", candidate: "a; b")
        ))
        XCTAssertEqual(diff.sessionChanges.first { $0.kind == .removed }?.title, "Write")
        XCTAssertEqual(diff.sessionChanges.first { $0.kind == .added }?.title, "Build")
    }

    func testDiffEngineIdenticalRevisionsAreEmpty() throws {
        let revision = try makeRevision(
            weeklyBudget: 60,
            phases: [(0, "Basics", "Objective A")],
            sessions: [(0, "Read", 30, ["a"])]
        )
        XCTAssertTrue(PlanRevisionDiffEngine.compute(base: revision, candidate: revision).isEmpty)
    }

    // MARK: - AI provider

    func testAdjustmentInputScopeIsLimitedToActivePlanAndConfirmedSessions() throws {
        let target = makeProject(name: "Algebra")
        let other = makeProject(name: "Biology")
        let targetPlan = try makeActivePlan(projectID: target.id, title: "Algebra Plan")
        let otherPlan = try makeActivePlan(projectID: other.id, title: "Biology Plan")
        var sessions: [LearningSession] = []
        for index in 0..<12 {
            sessions.append(try makeConfirmedSession(
                projectID: target.id,
                note: "Record \(index)",
                blocker: index >= 10 ? "Stuck" : nil,
                confirmedOffset: TimeInterval(index)
            ))
        }
        sessions.append(try makeConfirmedSession(
            projectID: other.id, note: "Bio record", confirmedOffset: 0
        ))
        let unconfirmed = try LearningSession(
            projectId: target.id, source: .quickLog, actionType: .course,
            startedAt: now, endedAt: now.addingTimeInterval(60), durationMinutes: 1,
            note: "unconfirmed draft note", nextStepBefore: "", nextStepAfter: "",
            createdAt: now, updatedAt: now
        )
        let snapshot = JournalSnapshot(
            projects: [target, other],
            sessions: sessions + [unconfirmed],
            coursePlans: [targetPlan, otherPlan]
        )

        let input = LearningAdjustmentInput(
            snapshot: snapshot, projectID: target.id, userRequest: "Help me adjust"
        )

        XCTAssertEqual(input.activePlan?.courseTitle, "Algebra Plan")
        XCTAssertEqual(input.recentConfirmedSessions.count, 10)
        XCTAssertEqual(input.recentConfirmedSessions.first?.summary, "Record 11")
        XCTAssertEqual(input.unresolvedBlockers, ["Stuck"])

        let package = try OpenAICompatibleLearningAdjustmentProvider.requestPreview(
            input: input, model: "test-model"
        )
        XCTAssertEqual(package.sourceMetadata["source"], "learning-adjustment")
        XCTAssertEqual(package.sourceMetadata["authorization"], "one-request")
        XCTAssertFalse(package.encodedText.contains("Biology"))
        XCTAssertFalse(package.encodedText.contains("Bio record"))
        XCTAssertFalse(package.encodedText.contains("unconfirmed draft note"))
    }

    func testOpenAIProviderDecodesValidatedDraftsAndNeverTrustsDecisions() async throws {
        let sessionID = UUID()
        let input = makeAdjustmentInput(sessionIDs: [sessionID])
        let content = """
        {"suggestions":[{"kind":"nextStep","title":"Insert a review step","rationale":"Two partials","proposedValue":"Review chapter","sourceSessionIDs":["\(sessionID.uuidString)","\(UUID().uuidString)"],"decision":"adopted","activatePlan":true}]}
        """
        let transport = AdjustmentRecordingTransport(data: try completionData(for: content))
        let provider = OpenAICompatibleLearningAdjustmentProvider(
            settings: settings, apiKey: "test-key", transport: transport
        )

        let drafts = try await provider.makeSuggestions(input: input)

        XCTAssertEqual(drafts.count, 1)
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.kind, .nextStep)
        // Unknown session references are dropped; hostile decision /
        // activation keys can never survive decoding because drafts carry no
        // such fields.
        XCTAssertEqual(draft.sourceSessionIDs, [sessionID])

        let project = makeProject()
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(projects: [project])
        )
        let service = LearningAdjustmentService(repository: repository, now: { self.now })
        let persisted = try service.persistSuggestions(drafts, projectID: project.id)
        XCTAssertEqual(persisted.first?.decision, .pending)
        XCTAssertEqual(persisted.first?.planRevisionDraftID, nil)
    }

    func testOpenAIProviderRejectsUnknownKind() async throws {
        let content = """
        {"suggestions":[{"kind":"deleteEverything","title":"Bad","proposedValue":"Bad"}]}
        """
        let transport = AdjustmentRecordingTransport(data: try completionData(for: content))
        let provider = OpenAICompatibleLearningAdjustmentProvider(
            settings: settings, apiKey: "test-key", transport: transport
        )

        await XCTAssertThrowsErrorAsync(
            { try await provider.makeSuggestions(input: self.makeAdjustmentInput()) }
        ) { error in
            XCTAssertEqual(error as? LearningAdjustmentProviderError, .providerUnavailable)
        }
    }

    func testAdaptiveProviderFallsBackToRuleBasedWithoutThrowing() async throws {
        let expected = LearningAdjustmentSuggestionDraft(
            kind: .nextStep, title: "Rule draft", rationale: "Rules", proposedValue: "Do it"
        )
        let fallback = StubLearningAdjustmentProvider(drafts: [expected])
        let store = makeSettingsStore()
        try store.save(settings: settings, apiKey: "test-key")
        let adaptive = AdaptiveLearningAdjustmentProvider(
            settingsStore: store,
            transport: AdjustmentFailingTransport(),
            fallback: fallback
        )

        let drafts = try await adaptive.makeSuggestions(input: makeAdjustmentInput())
        XCTAssertEqual(drafts, [expected])

        // Without configuration the fallback answers directly.
        let unconfigured = AdaptiveLearningAdjustmentProvider(
            settingsStore: makeSettingsStore(),
            transport: AdjustmentFailingTransport(),
            fallback: fallback
        )
        let unconfiguredDrafts = try await unconfigured.makeSuggestions(input: makeAdjustmentInput())
        XCTAssertEqual(unconfiguredDrafts, [expected])
    }

    func testRuleBasedProviderWrapsDetection() async throws {
        let expected = LearningAdjustmentSuggestionDraft(
            kind: .reschedule, title: "Detected", rationale: "Window", proposedValue: "Move"
        )
        let provider = RuleBasedLearningAdjustmentProvider(
            detector: StubAdjustmentDetector(drafts: [expected]),
            now: { [now] in now }
        )

        let drafts = try await provider.makeSuggestions(input: makeAdjustmentInput())
        XCTAssertEqual(drafts, [expected])
    }

    // MARK: - Fixtures

    private struct DetectionFixture {
        var repository: InMemoryJournalRepository
        var projectID: UUID
        var sessionIDs: [UUID]
    }

    private struct PhaseRiskFixture {
        var repository: InMemoryJournalRepository
        var projectID: UUID
    }

    private func makeProject(
        id: UUID = UUID(), name: String = "Course", nextStep: String = "Read"
    ) -> Project {
        Project(
            id: id, name: name, area: "AI", goal: "Learn", currentNextStep: nextStep,
            createdAt: now, updatedAt: now
        )
    }

    private func makeSuggestion(
        projectID: UUID = UUID(),
        kind: LearningAdjustmentKind,
        proposedValue: String = "Proposed value",
        structuralChange: LearningAdjustmentStructuralChange? = nil
    ) -> LearningAdjustmentSuggestion {
        LearningAdjustmentSuggestion(
            projectID: projectID,
            sourceSessionIDs: [UUID()],
            kind: kind,
            title: "Suggestion",
            rationale: "Rationale",
            proposedValue: proposedValue,
            structuralChange: structuralChange,
            createdAt: now
        )
    }

    private func makeConfirmedSession(
        projectID: UUID,
        note: String,
        progress: CompletionProgress = .partial,
        blocker: String? = nil,
        confirmedOffset: TimeInterval
    ) throws -> LearningSession {
        try LearningSession(
            projectId: projectID, source: .timer, actionType: .course,
            startedAt: now, endedAt: now.addingTimeInterval(1_800), durationMinutes: 30,
            note: note, nextStepBefore: "", nextStepAfter: "",
            createdAt: now, updatedAt: now,
            assessment: LearningRecordAssessment(
                progress: progress,
                completedCriterionIDs: [],
                blocker: blocker,
                aiDraftedSummary: false,
                userEditedSummary: false,
                confirmedAt: now.addingTimeInterval(confirmedOffset),
                revision: 1
            )
        )
    }

    private func makePlannedSession(
        projectID: UUID,
        title: String,
        duration: Int = 30,
        status: PlannedSessionStatus = .unscheduled,
        completedSessionID: UUID? = nil,
        planID: UUID = UUID(),
        phaseID: UUID = UUID()
    ) throws -> PlannedSession {
        try PlannedSession(
            planId: planID, phaseId: phaseID, projectId: projectID,
            title: title, actionType: .reading, durationMinutes: duration,
            status: status, completedSessionId: completedSessionID,
            createdAt: now, updatedAt: now
        )
    }

    /// Builds `assessedCount` confirmed records (progress `progress`) linked
    /// to planned sessions sharing the same activity title, plus enough
    /// unassessed sessions to reach two records total.
    private func makeRepeatedPartialFixture(
        progress: CompletionProgress, assessedCount: Int
    ) throws -> DetectionFixture {
        let project = makeProject()
        let planID = UUID()
        let phaseID = UUID()
        var sessions: [LearningSession] = []
        var planned: [PlannedSession] = []
        for index in 0..<assessedCount {
            let session = try makeConfirmedSession(
                projectID: project.id,
                note: "Attempt \(index)",
                progress: progress,
                confirmedOffset: TimeInterval(index)
            )
            sessions.append(session)
            planned.append(try makePlannedSession(
                projectID: project.id,
                title: "Read Chapter 3",
                status: .completed,
                completedSessionID: session.id,
                planID: planID,
                phaseID: phaseID
            ))
        }
        for index in assessedCount..<2 {
            sessions.append(try LearningSession(
                projectId: project.id, source: .quickLog, actionType: .course,
                startedAt: now, endedAt: now.addingTimeInterval(60), durationMinutes: 1,
                note: "Unconfirmed \(index)", nextStepBefore: "", nextStepAfter: "",
                createdAt: now, updatedAt: now
            ))
        }
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project], sessions: sessions, plannedSessions: planned
            )
        )
        return DetectionFixture(
            repository: repository,
            projectID: project.id,
            sessionIDs: sessions.filter { $0.assessment != nil }.map(\.id)
        )
    }

    private func makePhaseRiskFixture(
        completedCount: Int,
        incompleteCount: Int,
        targetEndOffset: TimeInterval = 86_400
    ) throws -> PhaseRiskFixture {
        let project = makeProject()
        let plan = try makeActivePlan(projectID: project.id, title: "Plan")
        let phase = try PlanPhase(
            planId: plan.id,
            title: "Foundations",
            objective: "Objective",
            expectedProof: "Proof",
            progress: .active,
            ordinal: 0,
            targetStart: now.addingTimeInterval(-7 * 86_400),
            targetEnd: now.addingTimeInterval(targetEndOffset),
            createdAt: now,
            updatedAt: now
        )
        var planned: [PlannedSession] = []
        for index in 0..<completedCount {
            planned.append(try makePlannedSession(
                projectID: project.id,
                title: "Done \(index)",
                status: .completed,
                planID: plan.id,
                phaseID: phase.id
            ))
        }
        for index in 0..<incompleteCount {
            planned.append(try makePlannedSession(
                projectID: project.id,
                title: "Pending \(index)",
                status: .unscheduled,
                planID: plan.id,
                phaseID: phase.id
            ))
        }
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(
                projects: [project],
                coursePlans: [plan],
                planPhases: [phase],
                plannedSessions: planned
            )
        )
        return PhaseRiskFixture(repository: repository, projectID: project.id)
    }

    private func makeActivePlan(projectID: UUID, title: String) throws -> LearningPlan {
        try LearningPlan(
            projectId: projectID, revision: 1, status: .active,
            courseURL: nil, courseTitle: title, courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: now.addingTimeInterval(-7 * 86_400),
            deadline: nil, weeklyBudgetMinutes: 120, summary: "Summary",
            createdAt: now, updatedAt: now
        )
    }

    private func makeRevision(
        weeklyBudget: Int,
        deadline: Date? = nil,
        phases: [(ordinal: Int, title: String, objective: String)],
        sessions: [(phaseOrdinal: Int, title: String, duration: Int, criteria: [String])]
    ) throws -> PlanRevision {
        let plan = try LearningPlan(
            projectId: UUID(), revision: 1, status: .active,
            courseURL: nil, courseTitle: "Plan", courseOutline: "", goal: "Learn",
            expectedOutcome: "Notes", startsOn: now, deadline: deadline,
            weeklyBudgetMinutes: weeklyBudget, summary: "Summary",
            createdAt: now, updatedAt: now
        )
        let planPhases = try phases.map { item in
            try PlanPhase(
                planId: plan.id, title: item.title, objective: item.objective,
                expectedProof: "Proof", ordinal: item.ordinal,
                targetStart: now, targetEnd: now.addingTimeInterval(86_400),
                createdAt: now, updatedAt: now
            )
        }
        let planned = try sessions.map { item in
            let phase = planPhases.first { $0.ordinal == item.phaseOrdinal }!
            return try PlannedSession(
                planId: plan.id, phaseId: phase.id, projectId: plan.projectId,
                title: item.title, actionType: .reading,
                durationMinutes: item.duration, completionCriteria: item.criteria,
                createdAt: now, updatedAt: now
            )
        }
        return PlanRevision(plan: plan, phases: planPhases, sessions: planned)
    }

    private func makeAdjustmentInput(sessionIDs: [UUID] = []) -> LearningAdjustmentInput {
        LearningAdjustmentInput(
            projectID: UUID(),
            activePlan: nil,
            currentPhase: nil,
            recentConfirmedSessions: sessionIDs.map {
                .init(
                    id: $0, activityTitle: nil, progress: "partial",
                    blocker: nil, summary: "Summary", confirmedAt: now
                )
            },
            unresolvedBlockers: [],
            userRequest: "Help"
        )
    }

    private var settings: AIReviewSettings {
        AIReviewSettings(
            endpoint: URL(string: "https://example.test/v1")!,
            model: "test-model"
        )
    }

    private func completionData(for content: String) throws -> Data {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Data(#"{"choices":[{"message":{"content":"\#(escaped)"}}]}"#.utf8)
    }

    private func makeSettingsStore() -> AIReviewSettingsStore {
        let suiteName = "PersonalLearningJournalTests.\(UUID().uuidString)"
        return AIReviewSettingsStore(
            userDefaults: UserDefaults(suiteName: suiteName)!,
            keyStore: AdjustmentTestAPIKeyStore()
        )
    }

    private var planningDraft: CoursePlanDraft {
        CoursePlanDraft(
            title: "Plan",
            summary: "Summary",
            phases: [
                CoursePlanDraftPhase(
                    id: "phase-1", title: "Phase", objective: "Objective",
                    expectedProof: "Proof", ordinal: 0,
                    targetStart: Date(timeIntervalSince1970: 1_000),
                    targetEnd: Date(timeIntervalSince1970: 2_000)
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "session-1", phaseID: "phase-1", title: "Read",
                    actionType: .reading, durationMinutes: 30
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
}

private actor AdjustmentRecordingTransport: AIHTTPTransport {
    private let responseData: Data
    private var requestBody: Data?

    init(data: Data) {
        self.responseData = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestBody = request.httpBody
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }
}

private struct AdjustmentFailingTransport: AIHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class AdjustmentTestAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? {
        values[key]
    }

    func setValue(_ value: String?, for key: String) throws {
        values[key] = value
    }
}

private struct StubAdjustmentDetector: LearningAdjustmentRuleDetector {
    var drafts: [LearningAdjustmentSuggestionDraft]

    func detectDrafts(projectID: UUID, now: Date) throws -> [LearningAdjustmentSuggestionDraft] {
        drafts
    }
}

private struct StubLearningAdjustmentProvider: LearningAdjustmentProvider {
    var drafts: [LearningAdjustmentSuggestionDraft]

    func makeSuggestions(
        input: LearningAdjustmentInput
    ) async throws -> [LearningAdjustmentSuggestionDraft] {
        drafts
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Any,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
