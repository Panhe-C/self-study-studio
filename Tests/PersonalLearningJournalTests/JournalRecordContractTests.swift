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
            let input = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixture.payload) as? [String: Any]
            )
            XCTAssertEqual(Set(payload.keys), Set(input.keys), fixture.id)

            if fixture.kind == .session {
                XCTAssertEqual(payload["note"] as? String, "Read chapter one", fixture.id)
                XCTAssertEqual(payload["nextStepBefore"] as? String, "Start", fixture.id)
                XCTAssertEqual(payload["nextStepAfter"] as? String, "Continue", fixture.id)
            }
            if fixture.kind == .practiceRoutine {
                XCTAssertEqual(payload["name"] as? String, "Focused build", fixture.id)
                XCTAssertEqual(payload["symbolName"] as? String, "hammer", fixture.id)
            }
            if fixture.kind == .practiceSession {
                XCTAssertEqual(payload["note"] as? String, "Keep the loop small", fixture.id)
            }
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
            let payloadData = try JournalRecordContractEncoder.encode(record)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
            let fields = try XCTUnwrap(document.records[fixture.kind.rawValue]?.fields)
            XCTAssertTrue(
                Set(payload.keys).isSubset(of: Set(fields.keys)),
                "Encoded fields drifted outside the contract: \(fixture.id)"
            )
            let required = Set(
                fields.compactMap { $0.value.isRequired ? $0.key : nil }
            )
            XCTAssertTrue(
                required.isSubset(of: Set(payload.keys)),
                "Required contract fields are missing from encoding: \(fixture.id)"
            )
        }
    }
}
