import XCTest
@testable import PersonalLearningJournal

final class JournalRecordContractTests: XCTestCase {
    func testSharedFixturesCoverEveryJournalRecordKind() throws {
        let suite = try JournalContractFixtures.load()
        XCTAssertEqual(suite.version, JournalRecordContract.version)
        XCTAssertEqual(
            Set(suite.valid.map(\.kind)),
            Set(JournalRecordKind.allCases)
        )

        for fixture in suite.valid {
            let record = try JournalRecordContractDecoder.decode(
                fixture.payload,
                kind: fixture.kind
            )
            XCTAssertEqual(record.reference.kind, fixture.kind)
        }
    }

    func testFractionalISOFixtureIsAccepted() throws {
        let suite = try JournalContractFixtures.load()
        let fixture = try XCTUnwrap(suite.valid.first(where: { $0.id == "session-fractional" }))
        XCTAssertNoThrow(
            try JournalRecordContractDecoder.decode(fixture.payload, kind: fixture.kind),
            fixture.id
        )
    }

    func testValidFixturesNormalizeThroughJournalEntityEncoding() throws {
        let suite = try JournalContractFixtures.load()
        for fixture in suite.valid {
            let record = try JournalRecordContractDecoder.decode(
                fixture.payload,
                kind: fixture.kind
            )
            let payloadData = try JournalRecordContractEncoder.encode(record)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            )
            let expected = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixture.expectedNormalized) as? [String: Any]
            )
            XCTAssertEqual(payload as NSDictionary, expected as NSDictionary, fixture.id)
        }
    }

    func testInvalidFixturesRejectBeforeDomainUse() throws {
        let suite = try JournalContractFixtures.load()
        for fixture in suite.invalid {
            XCTAssertThrowsError(
                try JournalRecordContractDecoder.decode(fixture.payload, kind: fixture.kind),
                fixture.id
            )
        }
    }

    func testContractListsEveryEncodedJournalEntityField() throws {
        let document = try JournalRecordContract.load()
        XCTAssertEqual(Set(document.records.keys), Set(JournalRecordKind.allCases.map(\.rawValue)))

        for fixture in try JournalContractFixtures.load().valid {
            let record = try JournalRecordContractDecoder.decode(fixture.payload, kind: fixture.kind)
            let fields = try XCTUnwrap(document.records[fixture.kind.rawValue]?.fields)
            XCTAssertEqual(
                storedFieldNames(record),
                Set(fields.keys),
                "Contract and decoded JournalEntity fields drifted: \(fixture.id)"
            )
        }
    }

    func testNestedAndDateInvalidFixturesReject() throws {
        let suite = try JournalContractFixtures.load()
        let requiredIDs = [
            "project-invalid-safe-integer",
            "session-invalid-date",
            "proof-invalid-artifact",
            "evidence-contract-invalid-trigger",
            "practice-routine-invalid-reminder",
            "review-invalid-map"
        ]
        let invalidIDs = Set(suite.invalid.map(\.id))
        XCTAssertEqual(Set(requiredIDs), Set(requiredIDs).intersection(invalidIDs))
        for id in requiredIDs {
            let fixture = try XCTUnwrap(suite.invalid.first(where: { $0.id == id }))
            XCTAssertThrowsError(
                try JournalRecordContractDecoder.decode(fixture.payload, kind: fixture.kind),
                id
            )
        }
    }

    private func storedFieldNames(_ entity: JournalEntity) -> Set<String> {
        func labels<T>(_ value: T) -> Set<String> {
            Set(Mirror(reflecting: value).children.compactMap(\.label))
        }
        switch entity {
        case let .project(value): return labels(value)
        case let .session(value): return labels(value)
        case let .proof(value): return labels(value)
        case let .review(value): return labels(value)
        case let .evidenceContract(value): return labels(value)
        case let .evidenceAcceptance(value): return labels(value)
        case let .proofRevision(value): return labels(value)
        case let .reviewDecision(value): return labels(value)
        case let .trailEvent(value): return labels(value)
        case let .coursePlan(value): return labels(value)
        case let .planPhase(value): return labels(value)
        case let .plannedSession(value): return labels(value)
        case let .availabilityRule(value): return labels(value)
        case let .schedulingPreferences(value): return labels(value)
        case let .practiceRoutine(value): return labels(value)
        case let .practiceSession(value): return labels(value)
        }
    }
}
