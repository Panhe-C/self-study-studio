import XCTest
@testable import PersonalLearningJournal

final class PracticeDomainTests: XCTestCase {
    func testRoutineRequiresNameTargetAndWeekday() throws {
        let valid = PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2, 4, 6])
        XCTAssertNoThrow(try valid.validated())
        XCTAssertThrowsError(try PracticeRoutine(name: " ", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2]).validated())
        XCTAssertThrowsError(try PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 0, weekdays: [2]).validated())
        XCTAssertThrowsError(try PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: []).validated())
        XCTAssertThrowsError(try PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [8]).validated())
    }

    func testSessionRejectsImpossibleDuration() {
        let session = PracticeSession(routineId: UUID(), startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 90), activeDurationSeconds: 20)
        XCTAssertThrowsError(try session.validated())
    }
}
