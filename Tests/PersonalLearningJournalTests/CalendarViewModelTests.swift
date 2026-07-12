import XCTest
@testable import PersonalLearningJournal

@MainActor
final class CalendarViewModelTests: XCTestCase {
    func testWeekModeRangeStartsAtUserCalendarWeekBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        calendar.firstWeekday = 2
        let focusedDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-01-03T04:00:00Z"))
        let expectedStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2023-12-31T16:00:00Z"))
        let expectedEnd = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-01-07T16:00:00Z"))
        let repository = InMemoryJournalRepository()
        let client = CalendarViewModelClient(authorization: .denied)
        let viewModel = CalendarViewModel(
            repository: repository,
            calendarClient: client,
            calendar: calendar,
            focusedDate: focusedDate
        )

        viewModel.setMode(.week, focusedDate: focusedDate)

        XCTAssertEqual(viewModel.visibleRange.start, expectedStart)
        XCTAssertEqual(viewModel.visibleRange.end, expectedEnd)
    }

    func testDeniedPermissionStillRefreshesInternalPlannedSessions() async throws {
        let plannedSession = try makePlannedSession()
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(plannedSessions: [plannedSession])
        )
        let client = CalendarViewModelClient(authorization: .denied)
        let viewModel = CalendarViewModel(repository: repository, calendarClient: client)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.authorization, .denied)
        XCTAssertEqual(viewModel.items.map(\.plannedSessionID), [plannedSession.id])
        XCTAssertFalse(viewModel.canReadBusyTime)
    }

    func testEditingDraftPlacementDoesNotWriteCalendar() async throws {
        let plannedSession = try makePlannedSession()
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(plannedSessions: [plannedSession])
        )
        let client = CalendarViewModelClient(authorization: .fullAccess)
        let viewModel = CalendarViewModel(repository: repository, calendarClient: client)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = ScheduleDraft(
            range: DateInterval(start: start, duration: 86_400),
            placements: [
                ScheduledPlacement(
                    sessionID: plannedSession.id,
                    start: start,
                    end: start.addingTimeInterval(30 * 60)
                )
            ],
            unscheduledSessionIDs: [],
            conflicts: []
        )
        viewModel.replaceScheduleDraft(draft)

        viewModel.movePlacement(plannedSession.id, byMinutes: 30)

        let writeCount = await client.writeCount()
        XCTAssertEqual(
            viewModel.scheduleDraft?.placements.first?.start,
            start.addingTimeInterval(30 * 60)
        )
        XCTAssertEqual(writeCount, 0)
    }

    func testDraftPlacementsDriveTimelineItemsBeforeConfirmation() throws {
        let plannedSession = try makePlannedSession()
        let repository = InMemoryJournalRepository(
            snapshot: JournalSnapshot(plannedSessions: [plannedSession])
        )
        let client = CalendarViewModelClient(authorization: .denied)
        let viewModel = CalendarViewModel(repository: repository, calendarClient: client)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let range = DateInterval(start: start, duration: 86_400)
        viewModel.replaceScheduleDraft(
            ScheduleDraft(
                range: range,
                placements: [
                    ScheduledPlacement(
                        sessionID: plannedSession.id,
                        start: start,
                        end: start.addingTimeInterval(30 * 60)
                    )
                ],
                unscheduledSessionIDs: [],
                conflicts: []
            )
        )

        let timelineItems = viewModel.items(in: range)

        XCTAssertEqual(timelineItems.first?.start, start)
        XCTAssertEqual(viewModel.workloadMinutes(on: start), 30)
    }

    private func makePlannedSession() throws -> PlannedSession {
        try PlannedSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            planId: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            phaseId: UUID(uuidString: "00000000-0000-0000-0000-000000000200")!,
            projectId: UUID(uuidString: "00000000-0000-0000-0000-000000000300")!,
            title: "Read lesson",
            actionType: .course,
            durationMinutes: 30
        )
    }
}

private actor CalendarViewModelClient: CalendarClient {
    private let authorization: CalendarAuthorizationState
    private var writes = 0

    init(authorization: CalendarAuthorizationState) {
        self.authorization = authorization
    }

    func authorizationState() async -> CalendarAuthorizationState { authorization }
    func requestFullAccess() async throws -> CalendarAuthorizationState { authorization }
    func writableCalendars() async throws -> [CalendarDescriptor] { [] }
    func busyIntervals(in range: DateInterval) async throws -> [BusyInterval] { [] }
    func event(identifier: String) async throws -> CalendarEventSnapshot? { nil }

    func save(_ event: CalendarEventDraft) async throws -> CalendarEventSnapshot {
        writes += 1
        return CalendarEventSnapshot(
            identifier: event.identifier ?? UUID().uuidString,
            calendarIdentifier: event.calendarIdentifier,
            title: event.title,
            start: event.start,
            end: event.end
        )
    }

    func delete(identifier: String) async throws {
        writes += 1
    }

    func writeCount() -> Int { writes }
}
