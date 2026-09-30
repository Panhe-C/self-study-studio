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

    func testStructuredClientAcceptsJSONWrappedInMarkdownCodeFence() async throws {
        let nestedJSON = """
        ```json
        {"value":"ok"}
        ```
        """
        let completion = try completionData(content: nestedJSON)
        let client = OpenAICompatibleStructuredClient(
            settings: AIReviewSettings(endpoint: URL(string: "https://example.com/v1")!, model: "test-model"),
            apiKey: "key",
            transport: StubAIHTTPTransport(data: completion)
        )

        let result: StubResult = try await client.completeJSON(system: "system", user: "user")

        XCTAssertEqual(result, StubResult(value: "ok"))
    }

    func testStructuredClientAcceptsJSONSurroundedByProviderText() async throws {
        let completion = try completionData(content: "Here is the requested JSON: {\"value\":\"ok\"} Done.")
        let client = OpenAICompatibleStructuredClient(
            settings: AIReviewSettings(endpoint: URL(string: "https://example.com/v1")!, model: "test-model"),
            apiKey: "key",
            transport: StubAIHTTPTransport(data: completion)
        )

        let result: StubResult = try await client.completeJSON(system: "system", user: "user")

        XCTAssertEqual(result, StubResult(value: "ok"))
    }

    func testMiniMaxUsesItsOpenAICompatibilityOptions() async throws {
        let nestedJSON = #"{"value":"ok"}"#
        let completion = #"{"choices":[{"message":{"content":"\#(nestedJSON.replacingOccurrences(of: "\"", with: "\\\""))"}}]}"#
        let transport = CapturingAIHTTPTransport(data: Data(completion.utf8))
        let settings = try XCTUnwrap(AIProviderPreset.miniMax.makeSettings())
        let client = OpenAICompatibleStructuredClient(
            settings: settings,
            apiKey: "key",
            transport: transport
        )

        let result: StubResult = try await client.completeJSON(system: "system", user: "user")
        let request = try XCTUnwrap(transport.request)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(result, StubResult(value: "ok"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.minimaxi.com/v1/chat/completions")
        XCTAssertEqual(payload["reasoning_split"] as? Bool, true)
        XCTAssertNil(payload["response_format"])
    }

    func testStructuredClientSendsImageAndExtractedDocumentContent() async throws {
        let nestedJSON = #"{"value":"ok"}"#
        let completion = try completionData(content: nestedJSON)
        let transport = CapturingAIHTTPTransport(data: completion)
        let client = OpenAICompatibleStructuredClient(
            settings: AIReviewSettings(endpoint: URL(string: "https://example.com/v1")!, model: "test-model"),
            apiKey: "key",
            transport: transport
        )
        let attachments = [
            AIInputAttachment(
                kind: .image,
                fileName: "diagram.png",
                mimeType: "image/png",
                data: Data([0x01, 0x02])
            ),
            AIInputAttachment(
                kind: .document,
                fileName: "notes.md",
                mimeType: "text/markdown",
                data: Data("# Notes".utf8),
                extractedText: "# Notes"
            )
        ]

        let result: StubResult = try await client.completeJSON(
            system: "system",
            user: "Explain these",
            attachments: attachments
        )
        let request = try XCTUnwrap(transport.request)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])

        XCTAssertEqual(result, StubResult(value: "ok"))
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url", "text"])
        let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: String])
        XCTAssertTrue(imageURL["url"]?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertTrue((parts[2]["text"] as? String)?.contains("# Notes") == true)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("diagram.png"))
    }
}

private func completionData(content: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": content]]]
    ])
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

private final class CapturingAIHTTPTransport: AIHTTPTransport, @unchecked Sendable {
    let data: Data
    private(set) var request: URLRequest?

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
