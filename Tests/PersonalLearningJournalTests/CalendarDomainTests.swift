import XCTest
@testable import PersonalLearningJournal

final class CalendarDomainTests: XCTestCase {
    func testAvailabilityRejectsEndBeforeStart() {
        XCTAssertThrowsError(
            try AvailabilityRule(
                weekday: 2,
                startMinute: 18 * 60,
                endMinute: 17 * 60,
                timeZoneIdentifier: "Asia/Shanghai",
                minimumSessionMinutes: 30
            )
        ) { error in
            XCTAssertEqual(error as? CalendarValidationError, .invalidAvailabilityRange)
        }
    }

    func testCalendarBindingPersistsLocallyButNeverExports() throws {
        let repository = InMemoryJournalRepository()
        let plannedSessionID = UUID()
        let binding = CalendarBinding(
            plannedSessionId: plannedSessionID,
            eventIdentifier: "EKEvent-local-only",
            calendarIdentifier: "calendar-local-only",
            lastWrittenTitle: "Study: CS336",
            lastWrittenStart: .distantPast,
            lastWrittenEnd: .distantFuture,
            lastObservedAt: Date(),
            state: .linked
        )

        try repository.saveCalendarBinding(binding)

        XCTAssertEqual(try repository.calendarBinding(for: plannedSessionID), binding)
        let export = try ExportService().exportJSON(snapshot: repository.snapshot())
        XCTAssertFalse(String(decoding: export, as: UTF8.self).contains(binding.eventIdentifier))
        XCTAssertFalse(String(decoding: export, as: UTF8.self).contains(binding.calendarIdentifier))
    }

    func testSwiftDataBindingAndTargetCalendarPersistLocally() throws {
        let repository = try SwiftDataJournalRepository.inMemory()
        let binding = CalendarBinding(
            plannedSessionId: UUID(),
            eventIdentifier: "event-local",
            calendarIdentifier: "calendar-local",
            lastWrittenTitle: "Study",
            lastWrittenStart: .distantPast,
            lastWrittenEnd: .distantFuture,
            lastObservedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .linked
        )

        try repository.saveCalendarBinding(binding)
        try repository.saveTargetCalendarIdentifier(binding.calendarIdentifier)

        XCTAssertEqual(try repository.calendarBinding(for: binding.plannedSessionId), binding)
        XCTAssertEqual(try repository.targetCalendarIdentifier(), binding.calendarIdentifier)
        XCTAssertTrue(try repository.snapshot().availabilityRules.isEmpty)
    }
}
