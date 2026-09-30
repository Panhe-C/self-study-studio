import XCTest
@testable import PersonalLearningJournal

/// Spec 13: notifications exist only for captures that really started and are
/// still pending; copy stays neutral; the deep link opens the capture's step
/// and falls back to Today for confirmed/deleted captures; permission denial
/// never affects the store-driven local recovery card.
@MainActor
final class PendingCaptureNotificationTests: XCTestCase {

    // MARK: - Notifiability rules (spec 13: 只有真实开始过且仍 pending 的 capture)

    func testUnstartedCaptureWithoutDurationIsNeverNotifiable() {
        // A capture that reached a pending stage without the timer ever
        // running (no elapsed seconds, no end timestamp) did not really
        // start: no notification.
        let capture = makeCapture(stage: .awaitingCheck, activeDurationSeconds: 0, endedAt: nil)
        XCTAssertFalse(PendingCaptureNotificationCoordinator.isNotifiable(capture))
    }

    func testStartedCaptureWithElapsedTimeIsNotifiable() {
        let capture = makeCapture(stage: .awaitingCheck, activeDurationSeconds: 5, endedAt: nil)
        XCTAssertTrue(PendingCaptureNotificationCoordinator.isNotifiable(capture))
    }

    func testStartedCaptureWithEndTimestampIsNotifiable() {
        let capture = makeCapture(stage: .savedForLater, activeDurationSeconds: 0, endedAt: Date())
        XCTAssertTrue(PendingCaptureNotificationCoordinator.isNotifiable(capture))
    }

    func testNonPendingStagesAreNeverNotifiable() {
        for stage in [PendingStudyCaptureStage.active, .paused, .recovered, .confirmed, .discarded] {
            let capture = makeCapture(stage: stage, activeDurationSeconds: 120, endedAt: Date())
            XCTAssertFalse(PendingCaptureNotificationCoordinator.isNotifiable(capture), "\(stage) must not notify")
            XCTAssertNil(PendingCaptureNotificationCoordinator.category(for: capture))
        }
    }

    // MARK: - Category mapping

    func testCategoryMappingFollowsCaptureStage() {
        let check = makeCapture(stage: .awaitingCheck, activeDurationSeconds: 10)
        XCTAssertEqual(
            PendingCaptureNotificationCoordinator.category(for: check),
            .pendingCompletionCheck
        )

        let awaitingRecord = makeCapture(
            stage: .awaitingRecordConfirmation,
            activeDurationSeconds: 10,
            recordDraft: makeRecordDraft()
        )
        XCTAssertEqual(
            PendingCaptureNotificationCoordinator.category(for: awaitingRecord),
            .pendingRecordConfirmation
        )

        let savedWithDraft = makeCapture(
            stage: .savedForLater,
            activeDurationSeconds: 10,
            recordDraft: makeRecordDraft()
        )
        XCTAssertEqual(
            PendingCaptureNotificationCoordinator.category(for: savedWithDraft),
            .pendingRecordConfirmation
        )

        let savedWithoutDraft = makeCapture(stage: .savedForLater, activeDurationSeconds: 10)
        XCTAssertEqual(
            PendingCaptureNotificationCoordinator.category(for: savedWithoutDraft),
            .pendingCompletionCheck
        )
    }

    // MARK: - Refresh scheduling against a real store

    func testRefreshSchedulesOneNotificationPerPendingStartedCapture() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try store.begin(projectID: UUID(), source: .timer)
        try store.noteElapsed(id: first.id, activeDurationSeconds: 120)
        _ = try store.end(id: first.id)

        let second = try store.begin(projectID: UUID(), source: .quickLog)
        try store.noteElapsed(id: second.id, activeDurationSeconds: 60)
        _ = try store.end(id: second.id)
        _ = try store.saveForLater(id: second.id)

        let scheduler = FakeNotificationScheduler()
        let coordinator = PendingCaptureNotificationCoordinator(scheduler: scheduler)
        await coordinator.refresh(from: store)

        XCTAssertEqual(
            Set(scheduler.scheduled.keys),
            [
                PendingCaptureNotificationCoordinator.notificationID(for: first.id),
                PendingCaptureNotificationCoordinator.notificationID(for: second.id)
            ]
        )
        XCTAssertEqual(scheduler.scheduled[PendingCaptureNotificationCoordinator.notificationID(for: first.id)]?.payload.category, .pendingCompletionCheck)
        XCTAssertEqual(scheduler.scheduled[PendingCaptureNotificationCoordinator.notificationID(for: second.id)]?.payload.category, .pendingCompletionCheck)

        // Repeating refresh keeps exactly one notification per capture.
        await coordinator.refresh(from: store)
        XCTAssertEqual(scheduler.scheduled.count, 2)
    }

    func testRefreshSchedulesRecordReminderOnceRecordDraftExists() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: capture.id)
        _ = try store.attachRecordDraft(id: capture.id, draft: makeRecordDraft())

        let scheduler = FakeNotificationScheduler()
        let coordinator = PendingCaptureNotificationCoordinator(scheduler: scheduler)
        await coordinator.refresh(from: store)

        let id = PendingCaptureNotificationCoordinator.notificationID(for: capture.id)
        XCTAssertEqual(scheduler.scheduled[id]?.payload.category, .pendingRecordConfirmation)
    }

    func testDiscardCancelsScheduledNotification() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: capture.id)

        let scheduler = FakeNotificationScheduler()
        let coordinator = PendingCaptureNotificationCoordinator(scheduler: scheduler)
        await coordinator.refresh(from: store)
        let id = PendingCaptureNotificationCoordinator.notificationID(for: capture.id)
        XCTAssertNotNil(scheduler.scheduled[id])

        _ = try store.discard(id: capture.id)
        await coordinator.refresh(from: store)

        XCTAssertTrue(scheduler.scheduled.isEmpty)
        XCTAssertTrue(scheduler.cancelled.flatMap { $0 }.contains(id))
    }

    func testRemovalAfterConfirmCancelsScheduledNotification() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: capture.id)

        let scheduler = FakeNotificationScheduler()
        let coordinator = PendingCaptureNotificationCoordinator(scheduler: scheduler)
        await coordinator.refresh(from: store)
        let id = PendingCaptureNotificationCoordinator.notificationID(for: capture.id)
        XCTAssertNotNil(scheduler.scheduled[id])

        // The confirmation transaction removes the capture from the store.
        try store.remove(id: capture.id)
        await coordinator.refresh(from: store)

        XCTAssertTrue(scheduler.scheduled.isEmpty)
    }

    func testCategoryChangeReSchedulesWithUpdatedPayload() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: capture.id)

        let scheduler = FakeNotificationScheduler()
        let coordinator = PendingCaptureNotificationCoordinator(scheduler: scheduler)
        await coordinator.refresh(from: store)
        let id = PendingCaptureNotificationCoordinator.notificationID(for: capture.id)
        XCTAssertEqual(scheduler.scheduled[id]?.payload.category, .pendingCompletionCheck)

        _ = try store.attachRecordDraft(id: capture.id, draft: makeRecordDraft())
        await coordinator.refresh(from: store)
        XCTAssertEqual(scheduler.scheduled[id]?.payload.category, .pendingRecordConfirmation)
    }

    // MARK: - Permission denial (spec 13/15: 本地恢复卡片不受影响)

    func testPermissionDenialSchedulesNothingAndLeavesStoreUntouched() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: capture.id)
        let before = try store.allCaptures()

        let scheduler = FakeNotificationScheduler()
        scheduler.authorized = false
        let coordinator = PendingCaptureNotificationCoordinator(scheduler: scheduler)
        await coordinator.refresh(from: store)

        XCTAssertTrue(scheduler.scheduled.isEmpty)
        XCTAssertEqual(try store.allCaptures(), before)
        // The recovery card reads the store, not the scheduler: the capture
        // is still pending and recoverable.
        XCTAssertEqual(try store.pendingConfirmations().map(\.id), [capture.id])
    }

    func testFailingSchedulerDoesNotThrowAndLeavesStoreUntouched() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: capture.id)
        let before = try store.allCaptures()

        let scheduler = FakeNotificationScheduler()
        scheduler.scheduleError = FakeNotificationScheduler.Error.simulatedFailure
        let coordinator = PendingCaptureNotificationCoordinator(scheduler: scheduler)
        await coordinator.refresh(from: store)

        XCTAssertEqual(try store.allCaptures(), before)
    }

    // MARK: - Deep link (spec 13: 深链打开对应 pending capture)

    func testDeepLinkParsesPendingCaptureURL() {
        let id = UUID()
        let url = PendingCaptureDeepLink.url(for: id)
        XCTAssertEqual(PendingCaptureDeepLink.parse(url), id)
    }

    func testDeepLinkRejectsForeignURLs() {
        XCTAssertNil(PendingCaptureDeepLink.parse(URL(string: "https://example.com/pending-capture/\(UUID().uuidString)")!))
        XCTAssertNil(PendingCaptureDeepLink.parse(URL(string: "selfstudystudio://today")!))
        XCTAssertNil(PendingCaptureDeepLink.parse(URL(string: "selfstudystudio://pending-capture/not-a-uuid")!))
    }

    func testDeepLinkResolvesPendingCapture() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: capture.id)

        let resolved = PendingCaptureDeepLink.resolve(capture.id, in: store)
        XCTAssertEqual(resolved?.id, capture.id)
        XCTAssertEqual(resolved?.stage, .awaitingCheck)
    }

    func testDeepLinkFallsBackToTodayForStaleOrFinishedCaptures() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Unknown capture: nothing to open, stay on Today.
        XCTAssertNil(PendingCaptureDeepLink.resolve(UUID(), in: store))

        let capture = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: capture.id)

        // Discarded capture: fall back to Today.
        _ = try store.discard(id: capture.id)
        XCTAssertNil(PendingCaptureDeepLink.resolve(capture.id, in: store))

        // Confirmed (removed) capture: fall back to Today.
        let confirmed = try store.begin(projectID: UUID(), source: .timer)
        _ = try store.end(id: confirmed.id)
        try store.remove(id: confirmed.id)
        XCTAssertNil(PendingCaptureDeepLink.resolve(confirmed.id, in: store))
    }

    // MARK: - Fixtures

    private func makeStore() -> (PendingStudyCaptureStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (PendingStudyCaptureStore(directory: directory), directory)
    }

    private func makeCapture(
        stage: PendingStudyCaptureStage,
        activeDurationSeconds: Int,
        endedAt: Date? = nil,
        recordDraft: LearningRecordDraft? = nil
    ) -> PendingStudyCapture {
        PendingStudyCapture(
            id: UUID(),
            projectID: UUID(),
            source: .timer,
            stage: stage,
            startedAt: Date(),
            endedAt: endedAt,
            activeDurationSeconds: activeDurationSeconds,
            recordDraft: recordDraft,
            updatedAt: Date()
        )
    }

    private func makeRecordDraft() -> LearningRecordDraft {
        LearningRecordDraft(
            summary: "summary",
            result: "result",
            blockers: "",
            suggestedNextStep: nil,
            adjustmentSignal: .none,
            source: .ruleBased
        )
    }
}

/// In-memory scheduler for tests. Records intent; never touches the OS.
private final class FakeNotificationScheduler: @unchecked Sendable, NotificationScheduling {
    enum Error: Swift.Error {
        case simulatedFailure
    }

    var authorized = true
    var scheduleError: Swift.Error?
    private(set) var scheduled: [String: (payload: LearningNotificationPayload, date: Date)] = [:]
    private(set) var cancelled: [[String]] = []

    func requestAuthorization() async -> Bool { authorized }

    func schedule(id: String, payload: LearningNotificationPayload, date: Date) async throws {
        if let scheduleError { throw scheduleError }
        scheduled[id] = (payload, date)
    }

    func cancel(ids: [String]) async {
        cancelled.append(ids)
        for id in ids { scheduled[id] = nil }
    }

    func pendingIDs() async -> Set<String> {
        Set(scheduled.keys)
    }
}
