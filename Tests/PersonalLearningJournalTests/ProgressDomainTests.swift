import Foundation
import XCTest
@testable import PersonalLearningJournal

final class ProgressDomainTests: XCTestCase {
    private struct FixtureSuite: Decodable {
        let version: Int
        let valid: [Valid]
        let invalid: [Invalid]
        struct Valid: Decodable {
            let id: String
            let payload: ContentProgress.Project
            let expected: Expected
        }
        struct Expected: Decodable {
            let total: Int
            let completed: Int
            let percentage: Int
            let currentUnitID: UUID?
            let nextUnitID: UUID?
            let isAllCompleted: Bool
        }
        struct Invalid: Decodable {
            let id: String
            let payload: ContentProgress.Project
            let error: String
        }
    }

    private func fixtures() throws -> FixtureSuite {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "progress-fixtures-v1", withExtension: "json"))
        return try JSONDecoder.journal.decode(FixtureSuite.self, from: Data(contentsOf: url))
    }

    func testSharedFixturesAndProjection() throws {
        let suite = try fixtures()
        XCTAssertEqual(suite.version, ContentProgress.schemaVersion)
        for fixture in suite.valid {
            try ContentProgress.validate(fixture.payload)
            let result = ContentProgress.projection(for: fixture.payload)
            XCTAssertEqual(result.total, fixture.expected.total, fixture.id)
            XCTAssertEqual(result.completed, fixture.expected.completed, fixture.id)
            XCTAssertEqual(result.percentage, fixture.expected.percentage, fixture.id)
            XCTAssertEqual(result.currentUnitID, fixture.expected.currentUnitID, fixture.id)
            XCTAssertEqual(result.nextUnitID, fixture.expected.nextUnitID, fixture.id)
            XCTAssertEqual(result.isAllCompleted, fixture.expected.isAllCompleted, fixture.id)
        }
        for fixture in suite.invalid {
            XCTAssertThrowsError(try ContentProgress.validate(fixture.payload), fixture.id) { error in
                XCTAssertEqual(String(describing: error), fixture.error, fixture.id)
            }
        }
    }

    func testStrictDecodeRejectsUnknownFields() throws {
        let project = try XCTUnwrap(fixtures().valid.first?.payload)
        let encoded = try JSONEncoder.journal.encode(project)
        XCTAssertEqual(try ContentProgress.decode(encoded), project)
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dictionary["legacyGoal"] = "not part of progress"
        let unknown = try JSONSerialization.data(withJSONObject: dictionary)
        XCTAssertThrowsError(try ContentProgress.decode(unknown)) { error in
            XCTAssertEqual(error as? ContentProgress.ValidationError, .invalidShape)
        }
    }

    func testCommandsPreserveIdentityAndCompletionTime() throws {
        let original = try XCTUnwrap(fixtures().valid.first { $0.id == "partial" }?.payload)
        let completed = original.units[0]
        let later = original.updatedAt.addingTimeInterval(100)
        let same = try ContentProgress.setCompleted(original, unitID: completed.id, completed: true, now: later)
        XCTAssertEqual(same, original)
        let reordered = try ContentProgress.reorder(original, ids: original.units.map(\.id).reversed(), now: later)
        XCTAssertEqual(reordered.units.last?.id, completed.id)
        XCTAssertEqual(reordered.units.last?.completedAt, completed.completedAt)
        XCTAssertEqual(ContentProgress.projection(for: reordered).currentUnitID, original.units[2].id)
        let cancelled = try ContentProgress.setCompleted(reordered, unitID: completed.id, completed: false, now: later)
        XCTAssertNil(cancelled.units.last?.completedAt)
        let again = try ContentProgress.setCompleted(cancelled, unitID: completed.id, completed: true, now: later)
        XCTAssertEqual(again.units.last?.completedAt, later)
        let reduced = try ContentProgress.deleteUnit(again, unitID: original.units[1].id, now: later)
        XCTAssertEqual(reduced.units.map(\.order), [0, 1])
        XCTAssertEqual(ContentProgress.projection(for: reduced).percentage, 50)
    }

    func testPausedProjectRequiresResumeForCompletion() throws {
        let original = try XCTUnwrap(fixtures().valid.first { $0.id == "paused" }?.payload)
        XCTAssertThrowsError(try ContentProgress.setCompleted(original, unitID: original.units[1].id, completed: true))
        let resumed = try ContentProgress.setPaused(original, paused: false)
        XCTAssertFalse(resumed.isPaused)
        XCTAssertEqual(resumed.units, original.units)
    }
}
