import XCTest
@testable import PersonalLearningJournal

final class CoursePlanDraftEditingTests: XCTestCase {
    func testEditSessionUpdatesTitleDurationCriteriaAndReason() {
        let updated = CoursePlanDraftEditingService.editSession(draft, sessionID: "s1") { session in
            session.title = "Rewrite the tokenizer"
            session.durationMinutes = 60
            session.completionCriteria = ["Notebook runs end to end"]
            session.recommendationReason = "Core exercise"
        }

        let session = updated.sessions.first { $0.id == "s1" }
        XCTAssertEqual(session?.title, "Rewrite the tokenizer")
        XCTAssertEqual(session?.durationMinutes, 60)
        XCTAssertEqual(session?.completionCriteria, ["Notebook runs end to end"])
        XCTAssertEqual(session?.recommendationReason, "Core exercise")
        XCTAssertEqual(updated.sessions.count, draft.sessions.count)
        XCTAssertEqual(updated.phases, draft.phases)
    }

    func testDeleteSessionRemovesOnlyThatSession() {
        let updated = CoursePlanDraftEditingService.deleteSession(draft, sessionID: "s2")

        XCTAssertEqual(updated.sessions.map(\.id), ["s1", "s3"])
        XCTAssertEqual(updated.phases, draft.phases)
    }

    func testAddSessionAppendsToTargetPhase() {
        let newSession = CoursePlanDraftSession(
            id: "s4",
            phaseID: "p2",
            title: "Train a small model",
            actionType: .practice,
            durationMinutes: 45
        )

        let updated = CoursePlanDraftEditingService.addSession(draft, session: newSession)

        XCTAssertEqual(updated.sessions.map(\.id), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(updated.sessions.last?.phaseID, "p2")
    }

    func testMoveSessionSwapsOrder() {
        let updated = CoursePlanDraftEditingService.moveSession(draft, sessionID: "s1", by: 1)

        XCTAssertEqual(updated.sessions.map(\.id), ["s2", "s1", "s3"])
    }

    func testMoveSessionOutOfBoundsLeavesOrderUntouched() {
        let updated = CoursePlanDraftEditingService.moveSession(draft, sessionID: "s1", by: -1)

        XCTAssertEqual(updated.sessions, draft.sessions)
    }

    func testMovePhaseRenumbersOrdinals() {
        let updated = CoursePlanDraftEditingService.movePhase(draft, phaseID: "p2", by: -1)

        XCTAssertEqual(updated.phases.map(\.id), ["p2", "p1"])
        XCTAssertEqual(updated.phases.map(\.ordinal), [0, 1])
        XCTAssertEqual(updated.sessions, draft.sessions)
    }

    func testAddPhaseAppendsWithNextOrdinal() {
        let phase = CoursePlanDraftPhase(
            id: "p3",
            title: "Advanced",
            objective: "Scale up",
            expectedProof: "Larger model",
            ordinal: 99,
            targetStart: start,
            targetEnd: end
        )

        let updated = CoursePlanDraftEditingService.addPhase(draft, phase: phase)

        XCTAssertEqual(updated.phases.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(updated.phases.map(\.ordinal), [0, 1, 2])
    }

    func testDeletePhaseRemovesPhaseAndItsSessions() {
        let updated = CoursePlanDraftEditingService.deletePhase(draft, phaseID: "p1")

        XCTAssertEqual(updated.phases.map(\.id), ["p2"])
        XCTAssertEqual(updated.phases.map(\.ordinal), [0])
        XCTAssertEqual(updated.sessions.map(\.id), ["s3"])
        XCTAssertTrue(updated.sessions.allSatisfy { $0.phaseID == "p2" })
    }

    func testUndoRestoresMostRecentEdit() {
        var state = CoursePlanDraftEditingState(draft: draft)
        state.apply { CoursePlanDraftEditingService.deleteSession($0, sessionID: "s1") }
        state.apply { CoursePlanDraftEditingService.editSession($0, sessionID: "s2") { $0.title = "Edited" } }

        XCTAssertTrue(state.canUndo)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.draft.sessions.first { $0.id == "s2" }?.title, "Review examples")
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.draft, draft)
        XCTAssertFalse(state.canUndo)
        XCTAssertFalse(state.undo())
    }

    func testReplacingPhaseLeavesOtherPhasesIDsTextAndOrderUntouched() {
        var generatedIDs = ["fresh-1", "fresh-2"].makeIterator()
        let regeneration = CoursePlanPhaseRegeneration(
            phase: CoursePlanDraftPhase(
                id: "p1-regenerated",
                title: "Foundations rebuilt",
                objective: "New milestone",
                expectedProof: "New proof",
                ordinal: 7,
                targetStart: start,
                targetEnd: end
            ),
            sessions: [
                CoursePlanDraftSession(
                    id: "ai-1",
                    phaseID: "anything",
                    title: "New activity",
                    actionType: .course,
                    durationMinutes: 30
                ),
                CoursePlanDraftSession(
                    id: "ai-2",
                    phaseID: "anything",
                    title: "Another new activity",
                    actionType: .review,
                    durationMinutes: 15
                )
            ]
        )

        let updated = CoursePlanDraftEditingService.replacingPhase(
            draft,
            phaseID: "p1",
            with: regeneration,
            sessionIDGenerator: { generatedIDs.next() ?? "exhausted" }
        )

        // Position and ordinal of the target phase are preserved.
        XCTAssertEqual(updated.phases.map(\.id), ["p1-regenerated", "p2"])
        XCTAssertEqual(updated.phases.map(\.ordinal), [0, 1])
        XCTAssertEqual(updated.phases[0].title, "Foundations rebuilt")
        // The untouched phase keeps its exact identity and text.
        XCTAssertEqual(updated.phases[1], draft.phases[1])
        // Old sessions of the target phase are gone; other sessions are untouched
        // in identity, text, and order; regenerated sessions come last with
        // fresh draft-scoped ids bound to the new phase id.
        XCTAssertEqual(updated.sessions.map(\.id), ["s3", "fresh-1", "fresh-2"])
        XCTAssertEqual(updated.sessions[0], draft.sessions[2])
        XCTAssertEqual(updated.sessions[1].phaseID, "p1-regenerated")
        XCTAssertEqual(updated.sessions[2].phaseID, "p1-regenerated")
    }

    func testReplacingUnknownPhaseLeavesDraftUnchanged() {
        let regeneration = CoursePlanPhaseRegeneration(
            phase: draft.phases[0],
            sessions: []
        )

        let updated = CoursePlanDraftEditingService.replacingPhase(
            draft,
            phaseID: "missing",
            with: regeneration
        )

        XCTAssertEqual(updated, draft)
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var end: Date { start.addingTimeInterval(7 * 86_400) }

    private var draft: CoursePlanDraft {
        CoursePlanDraft(
            title: "CS336 plan",
            summary: "Tokenizer foundation",
            phases: [
                CoursePlanDraftPhase(
                    id: "p1",
                    title: "Foundations",
                    objective: "Understand tokenization",
                    expectedProof: "Tokenizer notebook",
                    ordinal: 0,
                    targetStart: start,
                    targetEnd: end
                ),
                CoursePlanDraftPhase(
                    id: "p2",
                    title: "Scaling",
                    objective: "Train a model",
                    expectedProof: "Training run",
                    ordinal: 1,
                    targetStart: start,
                    targetEnd: end
                )
            ],
            sessions: [
                CoursePlanDraftSession(
                    id: "s1",
                    phaseID: "p1",
                    title: "Implement tokenizer",
                    actionType: .course,
                    durationMinutes: 45
                ),
                CoursePlanDraftSession(
                    id: "s2",
                    phaseID: "p1",
                    title: "Review examples",
                    actionType: .review,
                    durationMinutes: 30
                ),
                CoursePlanDraftSession(
                    id: "s3",
                    phaseID: "p2",
                    title: "Run training",
                    actionType: .practice,
                    durationMinutes: 60
                )
            ]
        )
    }
}
