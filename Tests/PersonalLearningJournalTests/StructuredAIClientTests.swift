import XCTest
@testable import PersonalLearningJournal

final class StructuredAIClientTests: XCTestCase {
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
