import XCTest
import CloudKit
@testable import PersonalLearningJournal

final class PendingStudyCaptureStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) }) -> PendingStudyCaptureStore {
        PendingStudyCaptureStore(directory: root, now: now)
    }

    private func makeCheckDraft() -> CompletionCheckDraft {
        CompletionCheckDraft(
            activityTitle: "Read chapter 3",
            progressOptions: CompletionProgress.allCases,
            criteria: [
                CompletionCriterion(id: "c1", text: "Summarized the chapter"),
                CompletionCriterion(id: "c2", text: "Solved the exercises")
            ],
            asksUnderstanding: true,
            asksBlocker: true,
            source: .ruleBased
        )
    }

    private func makeRecordDraft() -> LearningRecordDraft {
        LearningRecordDraft(
            summary: "Read chapter 3 and solved most exercises.",
            result: "Exercises 1-4 done",
            blockers: "Exercise 5 unclear",
            suggestedNextStep: "Review exercise 5",
            adjustmentSignal: .ordinary,
            source: .ai
        )
    }

    // MARK: - Begin / single active capture

    func testBeginCreatesActiveCaptureWithUnselectedAnswers() throws {
        let store = makeStore()
        let projectID = UUID()
        let plannedSessionID = UUID()

        let capture = try store.begin(
            projectID: projectID,
            plannedSessionID: plannedSessionID,
            source: .timer
        )

        XCTAssertEqual(capture.stage, .active)
        XCTAssertEqual(capture.projectID, projectID)
        XCTAssertEqual(capture.plannedSessionID, plannedSessionID)
        XCTAssertEqual(capture.source, .timer)
        XCTAssertEqual(capture.activeDurationSeconds, 0)
        XCTAssertNil(capture.endedAt)
        XCTAssertNil(capture.checkDraft)
        XCTAssertNil(capture.recordDraft)
        XCTAssertTrue(capture.stagedAttachments.isEmpty)
        // All answer state starts unselected: nothing preselected anywhere.
        XCTAssertNil(capture.answers.progress)
        XCTAssertTrue(capture.answers.completedCriterionIDs.isEmpty)
        XCTAssertNil(capture.answers.understanding)
        XCTAssertNil(capture.answers.blocker)
        XCTAssertEqual(try store.activeCapture()?.id, capture.id)
    }

    func testBeginWhileTimerSlotOccupiedThrows() throws {
        let store = makeStore()
        let first = try store.begin(projectID: UUID(), source: .timer)
        try store.pause(id: first.id)

        XCTAssertThrowsError(try store.begin(projectID: UUID(), source: .quickLog)) { error in
            XCTAssertEqual(error as? PendingStudyCaptureError, .activeCaptureAlreadyExists(first.id))
        }
    }

    func testFailedBeginKeepsMemoryAndDiskAtPreviousSnapshot() throws {
        var failWrites = false
        let store = PendingStudyCaptureStore(
            directory: root,
            now: { Date(timeIntervalSince1970: 1_000) },
            writeData: { data, url in
                guard !failWrites else { throw TestWriteError.failed }
                try data.write(to: url, options: [.atomic])
            }
        )
        let first = try store.begin(projectID: UUID(), source: .timer)
        failWrites = true

        XCTAssertThrowsError(try store.begin(projectID: UUID(), source: .quickLog))
        XCTAssertEqual(try store.allCaptures(), [first])

        let reloaded = PendingStudyCaptureStore(directory: root)
        XCTAssertEqual(try reloaded.allCaptures().first?.id, first.id)
        XCTAssertEqual(try reloaded.allCaptures().count, 1)
    }

    func testFailedTransitionAndRemoveKeepPreviousMemoryAndDiskSnapshot() throws {
        var failWrites = false
        let store = PendingStudyCaptureStore(
            directory: root,
            now: { Date(timeIntervalSince1970: 1_000) },
            writeData: { data, url in
                guard !failWrites else { throw TestWriteError.failed }
                try data.write(to: url, options: [.atomic])
            }
        )
        let capture = try store.begin(projectID: UUID(), source: .timer)
        failWrites = true

        XCTAssertThrowsError(try store.pause(id: capture.id))
        XCTAssertEqual(try store.activeCapture()?.stage, .active)
        XCTAssertEqual(
            try PendingStudyCaptureStore(directory: root).allCaptures().first?.stage,
            .recovered
        )

        XCTAssertThrowsError(try store.remove(id: capture.id))
        XCTAssertEqual(try store.allCaptures().map(\.id), [capture.id])
    }

    func testBeginAllowedWhenOnlyAwaitingConfirmationCapturesExist() throws {
        let store = makeStore()
        let first = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: first.id)

        let second = try store.begin(projectID: UUID(), source: .quickLog)
        XCTAssertEqual(second.stage, .active)
        XCTAssertEqual(try store.allCaptures().count, 2)
    }

    // MARK: - Pause / resume / end

    func testPauseResumeCyclePersistsEachStep() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)

        try store.noteElapsed(id: capture.id, activeDurationSeconds: 120)
        let paused = try store.pause(id: capture.id)
        XCTAssertEqual(paused.stage, .paused)
        XCTAssertEqual(paused.activeDurationSeconds, 120)

        let resumed = try store.resume(id: capture.id)
        XCTAssertEqual(resumed.stage, .active)
        XCTAssertNotNil(resumed.lastResumedAt)

        // Every key state change is persisted: a fresh store sees the capture
        // (auto-recovered, since it was left active — crash-recovery rule).
        let reloaded = PendingStudyCaptureStore(directory: root)
        XCTAssertEqual(try reloaded.allCaptures().first?.stage, .recovered)
    }

    func testPauseFromAwaitingCheckThrowsIllegalTransition() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)

        XCTAssertThrowsError(try store.pause(id: capture.id)) { error in
            XCTAssertEqual(
                error as? PendingStudyCaptureError,
                .illegalTransition(from: .awaitingCheck, to: .paused)
            )
        }
    }

    func testResumeFromActiveThrowsIllegalTransition() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)

        XCTAssertThrowsError(try store.resume(id: capture.id)) { error in
            XCTAssertEqual(
                error as? PendingStudyCaptureError,
                .illegalTransition(from: .active, to: .active)
            )
        }
    }

    func testEndFreezesDurationAndMovesToAwaitingCheck() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.noteElapsed(id: capture.id, activeDurationSeconds: 300)
        let endDate = Date(timeIntervalSince1970: 2_000)

        let ended = try store.end(id: capture.id, at: endDate)

        XCTAssertEqual(ended.stage, .awaitingCheck)
        XCTAssertEqual(ended.endedAt, endDate)
        XCTAssertEqual(ended.activeDurationSeconds, 300)
        XCTAssertNil(try store.activeCapture())
    }

    func testEndFromPausedIsAllowed() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.pause(id: capture.id)

        let ended = try store.end(id: capture.id)
        XCTAssertEqual(ended.stage, .awaitingCheck)
    }

    // MARK: - Completion check and record draft

    func testAttachCheckDraftOnlyAllowedInAwaitingCheck() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)

        XCTAssertThrowsError(try store.attachCheckDraft(id: capture.id, draft: makeCheckDraft())) { error in
            XCTAssertEqual(
                error as? PendingStudyCaptureError,
                .illegalTransition(from: .active, to: .awaitingCheck)
            )
        }

        try store.end(id: capture.id)
        let updated = try store.attachCheckDraft(id: capture.id, draft: makeCheckDraft())
        XCTAssertEqual(updated.checkDraft, makeCheckDraft())
        XCTAssertEqual(updated.stage, .awaitingCheck)
    }

    func testRecordAnswersKeepsHalfFilledCheck() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)
        try store.attachCheckDraft(id: capture.id, draft: makeCheckDraft())

        let answers = CompletionCheckAnswers(
            progress: .partial,
            completedCriterionIDs: ["c1"],
            understanding: nil,
            blocker: nil
        )
        let updated = try store.recordAnswers(id: capture.id, answers: answers)

        XCTAssertEqual(updated.answers, answers)
        XCTAssertNil(updated.answers.understanding)
    }

    func testAttachRecordDraftMovesToAwaitingRecordConfirmation() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)
        try store.attachCheckDraft(id: capture.id, draft: makeCheckDraft())

        let updated = try store.attachRecordDraft(id: capture.id, draft: makeRecordDraft())

        XCTAssertEqual(updated.stage, .awaitingRecordConfirmation)
        XCTAssertEqual(updated.recordDraft, makeRecordDraft())
    }

    func testAttachRecordDraftFromActiveThrowsIllegalTransition() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)

        XCTAssertThrowsError(try store.attachRecordDraft(id: capture.id, draft: makeRecordDraft())) { error in
            XCTAssertEqual(
                error as? PendingStudyCaptureError,
                .illegalTransition(from: .active, to: .awaitingRecordConfirmation)
            )
        }
    }

    // MARK: - Save for later / discard / remove

    func testSaveForLaterFromAwaitingStages() throws {
        let store = makeStore()
        let first = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: first.id)
        let savedFromCheck = try store.saveForLater(id: first.id)
        XCTAssertEqual(savedFromCheck.stage, .savedForLater)

        let second = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: second.id)
        try store.attachRecordDraft(id: second.id, draft: makeRecordDraft())
        let savedFromConfirmation = try store.saveForLater(id: second.id)
        XCTAssertEqual(savedFromConfirmation.stage, .savedForLater)

        // Multiple saved-for-later captures may coexist.
        XCTAssertEqual(try store.allCaptures().count, 2)
    }

    func testSaveForLaterFromActiveThrowsIllegalTransition() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)

        XCTAssertThrowsError(try store.saveForLater(id: capture.id)) { error in
            XCTAssertEqual(
                error as? PendingStudyCaptureError,
                .illegalTransition(from: .active, to: .savedForLater)
            )
        }
    }

    func testDiscardMarksCaptureDiscarded() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)

        let discarded = try store.discard(id: capture.id)

        XCTAssertEqual(discarded.stage, .discarded)
        XCTAssertNil(try store.activeCapture())
        XCTAssertEqual(try store.allCaptures().count, 1)
    }

    func testRemoveDeletesCaptureAfterConfirmation() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)

        try store.remove(id: capture.id)

        XCTAssertTrue(try store.allCaptures().isEmpty)
        let reloaded = PendingStudyCaptureStore(directory: root)
        XCTAssertTrue(try reloaded.allCaptures().isEmpty)
    }

    func testMutatingUnknownCaptureThrowsNotFound() throws {
        let store = makeStore()
        let missing = UUID()

        XCTAssertThrowsError(try store.pause(id: missing)) { error in
            XCTAssertEqual(error as? PendingStudyCaptureError, .captureNotFound(missing))
        }
    }

    // MARK: - Timer ticks vs persistence

    func testNoteElapsedUpdatesMemoryWithoutWritingToDisk() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)

        try store.noteElapsed(id: capture.id, activeDurationSeconds: 42)
        XCTAssertEqual(try store.activeCapture()?.activeDurationSeconds, 42)

        // The on-disk file still holds the last checkpointed value.
        let onDisk = try PendingStudyCaptureStore(directory: root).allCaptures()
        XCTAssertEqual(onDisk.first?.activeDurationSeconds, 0)

        // An explicit checkpoint persists the accumulated seconds.
        try store.checkpoint(id: capture.id, activeDurationSeconds: 42)
        let checkpointed = try PendingStudyCaptureStore(directory: root).allCaptures()
        XCTAssertEqual(checkpointed.first?.activeDurationSeconds, 42)
    }

    // MARK: - Crash recovery

    func testCrashRecoveryActiveTimerReloadsAsRecoveredKeepingSeconds() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.checkpoint(id: capture.id, activeDurationSeconds: 180)

        // Simulate a crash: a brand-new store instance loads the file.
        let recovered = PendingStudyCaptureStore(directory: root)
        let captures = try recovered.allCaptures()

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.stage, .recovered)
        XCTAssertEqual(captures.first?.activeDurationSeconds, 180)
        XCTAssertEqual(captures.first?.id, capture.id)
        // The recovered capture still holds the single timer slot.
        XCTAssertEqual(try recovered.activeCapture()?.id, capture.id)
        XCTAssertThrowsError(try recovered.begin(projectID: UUID(), source: .timer))
    }

    func testCrashRecoveryPausedCaptureReloadsAsRecovered() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.pause(id: capture.id)

        let reloaded = PendingStudyCaptureStore(directory: root)
        XCTAssertEqual(try reloaded.allCaptures().first?.stage, .recovered)
    }

    func testRecoveredCaptureCanResumeAndEnd() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.checkpoint(id: capture.id, activeDurationSeconds: 90)

        let recovered = PendingStudyCaptureStore(directory: root)
        let resumed = try recovered.resume(id: capture.id)
        XCTAssertEqual(resumed.stage, .active)
        XCTAssertEqual(resumed.activeDurationSeconds, 90)

        let ended = try recovered.end(id: capture.id)
        XCTAssertEqual(ended.stage, .awaitingCheck)
    }

    func testCrashRecoveryHalfFilledCheckSurvivesReload() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)
        try store.attachCheckDraft(id: capture.id, draft: makeCheckDraft())
        let answers = CompletionCheckAnswers(
            progress: .mostlyCompleted,
            completedCriterionIDs: ["c1", "c2"],
            understanding: .needsReview,
            blocker: nil
        )
        try store.recordAnswers(id: capture.id, answers: answers)

        let reloaded = PendingStudyCaptureStore(directory: root)
        let restored = try reloaded.allCaptures().first

        XCTAssertEqual(restored?.stage, .awaitingCheck)
        XCTAssertEqual(restored?.checkDraft, makeCheckDraft())
        XCTAssertEqual(restored?.answers, answers)
    }

    func testCrashRecoveryAwaitingRecordConfirmationSurvivesReload() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)
        try store.attachCheckDraft(id: capture.id, draft: makeCheckDraft())
        try store.attachRecordDraft(id: capture.id, draft: makeRecordDraft())

        let reloaded = PendingStudyCaptureStore(directory: root)
        let restored = try reloaded.allCaptures().first

        XCTAssertEqual(restored?.stage, .awaitingRecordConfirmation)
        XCTAssertEqual(restored?.recordDraft, makeRecordDraft())
        XCTAssertEqual(try reloaded.pendingConfirmations().map(\.id), [capture.id])
    }

    func testPendingConfirmationsIncludesSavedForLater() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)
        try store.saveForLater(id: capture.id)

        XCTAssertEqual(try store.pendingConfirmations().map(\.id), [capture.id])
    }

    // MARK: - Staged attachments

    func testStagedAttachmentsRoundTripWithoutBinaryData() throws {
        let store = makeStore()
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)

        let reference = PendingAttachmentReference(
            id: UUID(),
            kind: .image,
            localPath: "StagedAttachments/photo.jpg",
            displayName: "Whiteboard photo",
            fileSize: 128_000
        )
        let updated = try store.stageAttachment(id: capture.id, attachment: reference)

        XCTAssertEqual(updated.stagedAttachments, [reference])
        let reloaded = PendingStudyCaptureStore(directory: root)
        XCTAssertEqual(try reloaded.allCaptures().first?.stagedAttachments, [reference])
    }

    // MARK: - Isolation from journal facts

    func testCaptureStoreStaysOutOfJournalSnapshotAndExport() throws {
        let store = makeStore()
        _ = try store.begin(projectID: UUID(), source: .timer)

        // A journal store sitting in the same directory is unaffected.
        let journalStore = JSONJournalStore(
            fileURL: root.appendingPathComponent("journal.json")
        )
        let snapshot = JournalSnapshot(projects: [Project(name: "Guitar", area: "Music", goal: "Play", currentNextStep: "Practice")])
        try journalStore.save(snapshot)
        // The loaded snapshot is the canonical on-disk form (iso8601 dates);
        // it must round-trip byte-stable regardless of the capture store.
        let loaded = try journalStore.load()
        try journalStore.save(loaded)
        XCTAssertEqual(try journalStore.load(), loaded)
        XCTAssertEqual(loaded.projects.map(\.id), snapshot.projects.map(\.id))

        // JournalSnapshot Codable has no pending-capture surface.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshotData = try encoder.encode(loaded)
        XCTAssertEqual(try decoder.decode(JournalSnapshot.self, from: snapshotData), loaded)
        XCTAssertFalse(
            String(decoding: snapshotData, as: UTF8.self).contains("pendingStudyCapture")
        )

        // Export output contains confirmed records only, never capture drafts.
        let exportData = try ExportService().exportJSON(snapshot: snapshot)
        XCTAssertFalse(
            String(decoding: exportData, as: UTF8.self).contains("pendingStudyCapture")
        )
    }

    // MARK: - App session wiring

    @MainActor
    func testApplicationSessionCheckpointsPendingCaptures() throws {
        let store = PendingStudyCaptureStore(directory: root)
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.noteElapsed(id: capture.id, activeDurationSeconds: 55)

        let session = JournalApplicationSession(
            documentsDirectory: root,
            accountProvider: LocalOnlyAccountProvider(),
            repositoryOverride: InMemoryJournalRepository(),
            pendingCaptureStore: store
        )
        session.pendingCaptureCheckpoint()

        let reloaded = try PendingStudyCaptureStore(directory: root).allCaptures()
        XCTAssertEqual(reloaded.first?.activeDurationSeconds, 55)
    }
}

private enum TestWriteError: Error {
    case failed
}

private actor LocalOnlyAccountProvider: CloudAccountProviding {
    func accountStatus() async throws -> CKAccountStatus { .noAccount }

    func currentUserRecordName() async throws -> String? { nil }
}
