import XCTest
@testable import PersonalLearningJournal

final class StructuredAIClientTests: XCTestCase {
    func testAIPackageExcludesUnselectedArtifactsAndCalendarData() throws {
        let project = Project(name: "CS", area: "AI", goal: "Learn", status: .idea, currentNextStep: "")
        let proof = try Proof.text(
            projectId: project.id,
            title: "Notes",
            artifactBody: "private artifact body",
            statement: "Explains the result"
        )
        let package = try AIRequestPackageBuilder(model: "test-model").makePackage(
            snapshot: JournalSnapshot(
                projects: [project],
                proofs: [proof],
                plannedSessions: []
            ),
            selectedProofIDs: []
        )

        XCTAssertTrue(package.artifacts.isEmpty)
        XCTAssertTrue(package.encodedText.contains("Explains the result"))
        XCTAssertFalse(package.encodedText.contains("private artifact body"))
        XCTAssertFalse(package.encodedText.contains("localPath"))
        XCTAssertFalse(package.encodedText.contains("eventIdentifier"))
        XCTAssertFalse(package.encodedText.contains("attendees"))
    }

    func testSelectedArtifactAuthorizationAppliesToOnePackageOnly() throws {
        let project = Project(name: "CS", area: "AI", goal: "Learn", status: .idea, currentNextStep: "")
        let proof = try Proof.text(
            projectId: project.id,
            title: "Notes",
            artifactBody: "authorized body",
            statement: "Explains the result"
        )
        let builder = AIRequestPackageBuilder(model: "test-model")

        let authorized = try builder.makePackage(
            snapshot: JournalSnapshot(projects: [project], proofs: [proof]),
            selectedProofIDs: [proof.id]
        )
        let nextRequest = try builder.makePackage(
            snapshot: JournalSnapshot(projects: [project], proofs: [proof]),
            selectedProofIDs: []
        )

        XCTAssertEqual(authorized.artifacts.map(\.proofID), [proof.id])
        XCTAssertEqual(authorized.artifacts.first?.data, Data("authorized body".utf8))
        XCTAssertTrue(nextRequest.artifacts.isEmpty)
    }

    func testStructuredClientReturnsDecodedJSONContent() async throws {
        let nestedJSON = #"{"value":"ok"}"#
        let completion = #"{"choices":[{"message":{"content":"\#(nestedJSON.replacingOccurrences(of: "\"", with: "\\\""))"}}]}"#
        let client = OpenAICompatibleStructuredClient(
            settings: AIReviewSettings(endpoint: URL(string: "https://example.com/v1")!, model: "test-model"),
            apiKey: "key",
            transport: StubAIHTTPTransport(data: Data(completion.utf8))
        )

        let result: StubResult = try await client.completeJSON(system: "system", user: "user")

        XCTAssertEqual(result, StubResult(value: "ok"))
    }
}

private struct StubResult: Codable, Equatable, Sendable {
    var value: String
}

private struct StubAIHTTPTransport: AIHTTPTransport {
    let data: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
