import XCTest
@testable import PersonalLearningJournal

final class CalendarLayoutTests: XCTestCase {
    func testDraggingThirtyPointsMovesSessionThirtyMinutesWithoutChangingDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let frame = CalendarTimelineFrame(
            start: start,
            end: start.addingTimeInterval(45 * 60)
        )

        let result = WeekTimelineLayout(pointsPerMinute: 1).move(frame, byY: 30)

        XCTAssertEqual(result.start, frame.start.addingTimeInterval(30 * 60))
        XCTAssertEqual(result.duration, frame.duration)
    }

    func testResizingSnapsToFifteenMinutesAndKeepsMinimumHeight() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let frame = CalendarTimelineFrame(
            start: start,
            end: start.addingTimeInterval(30 * 60)
        )
        let layout = WeekTimelineLayout(pointsPerMinute: 1, minimumDurationMinutes: 15)

        let result = layout.resize(frame, byY: -40)

        XCTAssertEqual(result.duration, 15 * 60)
        XCTAssertEqual(layout.height(for: result), 15)
    }
}
