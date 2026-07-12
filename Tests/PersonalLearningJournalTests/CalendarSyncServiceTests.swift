import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CalendarSyncServiceTests: XCTestCase {
    func testPreviewDoesNotCallCalendarClientWrites() async throws {
        let repository = InMemoryJournalRepository()
        try repository.saveTargetCalendarIdentifier("study-calendar")
        let client = FakeWritableCalendarClient()
        let service = CalendarSyncService(repository: repository, calendarClient: client)

        let changes = try await service.previewChanges(for: scheduleDraft)

        XCTAssertFalse(changes.items.isEmpty)
        let saveCallCount = await client.saveCalls()
        let deleteCallCount = await client.deleteCalls()
        XCTAssertEqual(saveCallCount, 0)
        XCTAssertEqual(deleteCallCount, 0)
    }

    func testExternalEditRequiresDecisionBeforeOverwrite() async throws {
        let repository = InMemoryJournalRepository()
        let binding = CalendarBinding(
            plannedSessionId: sessionID,
            eventIdentifier: "event-1",
            calendarIdentifier: "study-calendar",
            lastWrittenTitle: "Study",
            lastWrittenStart: start,
            lastWrittenEnd: end,
            lastObservedAt: start,
            state: .linked
        )
        try repository.saveCalendarBinding(binding)
        let client = FakeWritableCalendarClient(events: [
            "event-1": CalendarEventSnapshot(
                identifier: "event-1",
                calendarIdentifier: "study-calendar",
                title: "Study",
                start: start.addingTimeInterval(3_600),
                end: end.addingTimeInterval(3_600)
            )
        ])
        let service = CalendarSyncService(repository: repository, calendarClient: client)

        let result = try await service.reconcileBindings()

        XCTAssertEqual(result.first?.state, .externallyModified)
        let saveCallCount = await client.saveCalls()
        XCTAssertEqual(saveCallCount, 0)
    }

    func testExternalDeletionOnlyRecreatesAfterUserChoosesIt() async throws {
        let repository = InMemoryJournalRepository()
        let binding = CalendarBinding(
            plannedSessionId: sessionID,
            eventIdentifier: "event-1",
            calendarIdentifier: "study-calendar",
            lastWrittenTitle: "Study",
            lastWrittenStart: start,
            lastWrittenEnd: end,
            lastObservedAt: start,
            state: .linked
        )
        try repository.saveCalendarBinding(binding)
        let client = FakeWritableCalendarClient()
        let service = CalendarSyncService(repository: repository, calendarClient: client)

        let items = try await service.reconcileBindings()
        let saveCallsBeforeDecision = await client.saveCalls()

        XCTAssertEqual(items.first?.state, .externallyDeleted)
        XCTAssertEqual(saveCallsBeforeDecision, 0)

        try await service.resolve(try XCTUnwrap(items.first), action: .recreateDeleted)

        let saveCallsAfterDecision = await client.saveCalls()
        XCTAssertEqual(saveCallsAfterDecision, 1)
        XCTAssertEqual(try repository.calendarBinding(for: sessionID)?.state, .linked)
    }

    func testReconciliationRelinksWhenExternalEventMatchesLastWrittenSnapshot() async throws {
        let repository = InMemoryJournalRepository()
        let binding = CalendarBinding(
            plannedSessionId: sessionID,
            eventIdentifier: "event-1",
            calendarIdentifier: "study-calendar",
            lastWrittenTitle: "Study",
            lastWrittenStart: start,
            lastWrittenEnd: end,
            lastObservedAt: start,
            state: .externallyModified
        )
        try repository.saveCalendarBinding(binding)
        let client = FakeWritableCalendarClient(events: [
            "event-1": CalendarEventSnapshot(
                identifier: "event-1",
                calendarIdentifier: "study-calendar",
                title: "Study",
                start: start,
                end: end
            )
        ])
        let service = CalendarSyncService(repository: repository, calendarClient: client)

        let items = try await service.reconcileBindings()

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(try repository.calendarBinding(for: sessionID)?.state, .linked)
    }

    func testPartialFailurePersistsSuccessfulBindingAndRetryableFailure() async throws {
        let repository = InMemoryJournalRepository()
        try repository.saveTargetCalendarIdentifier("study-calendar")
        let client = FakeWritableCalendarClient(failingStarts: [end])
        let service = CalendarSyncService(repository: repository, calendarClient: client)
        let draft = ScheduleDraft(
            range: DateInterval(start: start, end: end.addingTimeInterval(86_400)),
            placements: [
                ScheduledPlacement(sessionID: sessionID, start: start, end: end),
                ScheduledPlacement(sessionID: failedSessionID, start: end, end: end.addingTimeInterval(30 * 60))
            ],
            unscheduledSessionIDs: [],
            conflicts: [],
            generatedAt: start
        )
        let changes = try await service.previewChanges(for: draft)

        let result = await service.applyConfirmed(changes)

        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(result.failed[0].isRetryable)
        XCTAssertNotNil(try repository.calendarBinding(for: sessionID))
    }

    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let failedSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var end: Date { start.addingTimeInterval(30 * 60) }

    private var scheduleDraft: ScheduleDraft {
        ScheduleDraft(
            range: DateInterval(start: start, end: end.addingTimeInterval(86_400)),
            placements: [ScheduledPlacement(sessionID: sessionID, start: start, end: end)],
            unscheduledSessionIDs: [],
            conflicts: [],
            generatedAt: start
        )
    }
}

private actor FakeWritableCalendarClient: CalendarClient {
    private var events: [String: CalendarEventSnapshot]
    private let failingStarts: Set<Date>
    private(set) var saveCallCount = 0
    private(set) var deleteCallCount = 0

    init(events: [String: CalendarEventSnapshot] = [:], failingStarts: Set<Date> = []) {
        self.events = events
        self.failingStarts = failingStarts
    }

    func authorizationState() async -> CalendarAuthorizationState { .fullAccess }
    func requestFullAccess() async throws -> CalendarAuthorizationState { .fullAccess }
    func writableCalendars() async throws -> [CalendarDescriptor] { [] }
    func busyIntervals(in range: DateInterval) async throws -> [BusyInterval] { [] }
    func event(identifier: String) async throws -> CalendarEventSnapshot? { events[identifier] }

    func save(_ event: CalendarEventDraft) async throws -> CalendarEventSnapshot {
        saveCallCount += 1
        if failingStarts.contains(event.start) { throw CalendarClientError.calendarUnavailable }
        let identifier = event.identifier ?? "event-\(saveCallCount)"
        let snapshot = CalendarEventSnapshot(
            identifier: identifier,
            calendarIdentifier: event.calendarIdentifier,
            title: event.title,
            start: event.start,
            end: event.end
        )
        events[identifier] = snapshot
        return snapshot
    }

    func delete(identifier: String) async throws {
        deleteCallCount += 1
        events.removeValue(forKey: identifier)
    }

    func saveCalls() -> Int { saveCallCount }
    func deleteCalls() -> Int { deleteCallCount }
}
