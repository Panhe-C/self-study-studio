import XCTest
@testable import PersonalLearningJournal

final class CalendarClientTests: XCTestCase {
    func testDeniedAuthorizationReturnsNoEventsAndInternalCalendarCanContinue() async throws {
        let client = FakeCalendarClient(authorization: .denied, intervals: [])

        let authorization = await client.authorizationState()
        XCTAssertEqual(authorization, .denied)
        do {
            _ = try await client.busyIntervals(in: range)
            XCTFail("Expected access denied")
        } catch {
            XCTAssertEqual(error as? CalendarClientError, .accessDenied)
        }
    }

    func testBusyIntervalsExposeOnlyStartAndEnd() async throws {
        let interval = BusyInterval(start: start, end: end)
        let client = FakeCalendarClient(authorization: .fullAccess, intervals: [interval])

        let intervals = try await client.busyIntervals(in: range)

        XCTAssertEqual(intervals, [interval])
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let end = Date(timeIntervalSince1970: 1_700_001_800)
    private var range: DateInterval { DateInterval(start: start, end: end.addingTimeInterval(3_600)) }
}

private actor FakeCalendarClient: CalendarClient {
    let authorization: CalendarAuthorizationState
    let intervals: [BusyInterval]

    init(authorization: CalendarAuthorizationState, intervals: [BusyInterval]) {
        self.authorization = authorization
        self.intervals = intervals
    }

    func authorizationState() async -> CalendarAuthorizationState { authorization }
    func requestFullAccess() async throws -> CalendarAuthorizationState { authorization }
    func writableCalendars() async throws -> [CalendarDescriptor] { [] }

    func busyIntervals(in range: DateInterval) async throws -> [BusyInterval] {
        guard authorization == .fullAccess else { throw CalendarClientError.accessDenied }
        return intervals
    }

    func event(identifier: String) async throws -> CalendarEventSnapshot? { nil }
    func save(_ event: CalendarEventDraft) async throws -> CalendarEventSnapshot { throw CalendarClientError.calendarUnavailable }
    func delete(identifier: String) async throws {}
}
