import XCTest
@testable import PersonalLearningJournal

final class StudySchedulingEngineTests: XCTestCase {
    func testSchedulerPlacesSessionInFirstAvailableWindowWithoutOverlappingBusyTime() throws {
        let draft = try StudySchedulingEngine().makeDraft(
            SchedulingRequest(
                sessions: [session],
                availability: [mondayEvening],
                preferences: preferences,
                busyIntervals: [BusyInterval(start: mondayAt18, end: mondayAt19)],
                pinnedPlacements: [],
                range: weekRange,
                timeZoneIdentifier: "Asia/Shanghai",
                now: mondayAt17
            )
        )

        XCTAssertEqual(draft.placements.first?.sessionID, session.id)
        XCTAssertEqual(draft.placements.first?.start, mondayAt19)
        XCTAssertEqual(draft.placements.first?.end, mondayAt19.addingTimeInterval(30 * 60))
    }

    func testSchedulerDoesNotMutatePlannedSessionsAndIsDeterministic() throws {
        let second = try makeSession(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Second")
        let original = [session, second]
        let request = SchedulingRequest(
            sessions: original,
            availability: [mondayEvening],
            preferences: preferences,
            busyIntervals: [],
            pinnedPlacements: [],
            range: weekRange,
            timeZoneIdentifier: "Asia/Shanghai",
            now: mondayAt17
        )

        let firstDraft = try StudySchedulingEngine().makeDraft(request)
        let secondDraft = try StudySchedulingEngine().makeDraft(request)

        XCTAssertEqual(request.sessions, original)
        XCTAssertEqual(firstDraft.placements.map(\.sessionID), secondDraft.placements.map(\.sessionID))
        XCTAssertEqual(firstDraft.placements.map(\.start), secondDraft.placements.map(\.start))
    }

    func testSchedulerLeavesWorkUnscheduledWhenDailyLimitIsReached() throws {
        let second = try makeSession(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Second")
        var limitedPreferences = preferences
        limitedPreferences.maximumDailyMinutes = 30

        let draft = try StudySchedulingEngine().makeDraft(
            SchedulingRequest(
                sessions: [session, second],
                availability: [mondayEvening],
                preferences: limitedPreferences,
                busyIntervals: [],
                pinnedPlacements: [],
                range: weekRange,
                timeZoneIdentifier: "Asia/Shanghai",
                now: mondayAt17
            )
        )

        XCTAssertEqual(draft.placements.count, 1)
        XCTAssertEqual(draft.unscheduledSessionIDs.count, 1)
        XCTAssertTrue(draft.conflicts.contains { $0.reason == .exceedsDailyLimit })
    }

    func testPinnedSessionIsNeverMovedWhenNewDeadlineWorkIsAdded() throws {
        let pinned = ScheduledPlacement(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            start: mondayAt18,
            end: mondayAt18.addingTimeInterval(30 * 60),
            isPinned: true
        )
        let urgent = try makeSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            title: "Urgent"
        )
        let draft = try StudySchedulingEngine().makeDraft(
            SchedulingRequest(
                sessions: [urgent],
                availability: [mondayEvening],
                preferences: preferences,
                busyIntervals: [],
                pinnedPlacements: [pinned],
                range: weekRange,
                timeZoneIdentifier: "Asia/Shanghai",
                now: mondayAt17
            )
        )

        XCTAssertEqual(draft.placements.first(where: { $0.sessionID == pinned.sessionID })?.start, pinned.start)
        XCTAssertEqual(draft.placements.first(where: { $0.sessionID == urgent.id })?.start, mondayAt18.addingTimeInterval(30 * 60))
    }

    func testSpringForwardDayUsesCalendarArithmeticWithoutInvalidLocalTime() throws {
        let zone = "America/Los_Angeles"
        let dayStart = date("2024-03-10T08:00:00Z")
        let session = try PlannedSession(
            planId: UUID(),
            phaseId: UUID(),
            projectId: UUID(),
            title: "DST session",
            actionType: .course,
            durationMinutes: 30,
            deadline: date("2024-03-10T19:00:00Z")
        )
        let availability = try AvailabilityRule(
            weekday: 1,
            startMinute: 2 * 60,
            endMinute: 4 * 60,
            timeZoneIdentifier: zone,
            minimumSessionMinutes: 30
        )
        let draft = try StudySchedulingEngine().makeDraft(
            SchedulingRequest(
                sessions: [session],
                availability: [availability],
                preferences: preferences,
                busyIntervals: [],
                pinnedPlacements: [],
                range: DateInterval(start: dayStart, end: dayStart.addingTimeInterval(24 * 60 * 60)),
                timeZoneIdentifier: zone,
                now: dayStart
            )
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!

        XCTAssertFalse(draft.placements.contains { calendar.component(.hour, from: $0.start) == 2 })
    }

    func testImpossibleDeadlineReturnsUnscheduledReason() throws {
        let urgent = try PlannedSession(
            planId: UUID(),
            phaseId: UUID(),
            projectId: UUID(),
            title: "Impossible",
            actionType: .course,
            durationMinutes: 60,
            deadline: mondayAt18.addingTimeInterval(30 * 60)
        )
        let draft = try StudySchedulingEngine().makeDraft(
            SchedulingRequest(
                sessions: [urgent],
                availability: [mondayEvening],
                preferences: preferences,
                busyIntervals: [],
                pinnedPlacements: [],
                range: weekRange,
                timeZoneIdentifier: "Asia/Shanghai",
                now: mondayAt17
            )
        )

        XCTAssertEqual(draft.unscheduledSessionIDs, [urgent.id])
        XCTAssertTrue(draft.conflicts.contains { $0.reason == .insufficientCapacityBeforeDeadline })
    }

    private let mondayAt17 = date("2024-01-01T09:00:00Z")
    private let mondayAt18 = date("2024-01-01T10:00:00Z")
    private let mondayAt19 = date("2024-01-01T11:00:00Z")

    private var weekRange: DateInterval {
        DateInterval(start: mondayAt17, end: mondayAt17.addingTimeInterval(7 * 24 * 60 * 60))
    }

    private var mondayEvening: AvailabilityRule {
        try! AvailabilityRule(
            weekday: 2,
            startMinute: 18 * 60,
            endMinute: 21 * 60,
            timeZoneIdentifier: "Asia/Shanghai",
            minimumSessionMinutes: 30
        )
    }

    private var preferences: SchedulingPreferences {
        try! SchedulingPreferences(
            preferredSessionMinutes: 30,
            maximumDailyMinutes: 120,
            minimumGapMinutes: 0
        )
    }

    private var session: PlannedSession {
        try! makeSession(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "First")
    }

    private func makeSession(id: UUID, title: String) throws -> PlannedSession {
        try PlannedSession(
            id: id,
            planId: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            phaseId: UUID(uuidString: "00000000-0000-0000-0000-000000000200")!,
            projectId: UUID(uuidString: "00000000-0000-0000-0000-000000000300")!,
            title: title,
            actionType: .course,
            durationMinutes: 30,
            deadline: mondayAt19.addingTimeInterval(2 * 60 * 60)
        )
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
