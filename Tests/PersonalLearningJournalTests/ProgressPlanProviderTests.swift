import Foundation
import XCTest
@testable import PersonalLearningJournal

final class ProgressPlanProviderTests: XCTestCase {
    func testOutlineIsOnlyProjectContextSentToProvider() async throws {
        let transport = RecordingPlanTransport(content: #"{"units":[{"title":"组件"},{"title":"状态"}]}"#)
        let provider = ProgressPlanProvider(
            settings: AIReviewSettings(endpoint: URL(string: "https://example.com/v1")!, model: "test-model"),
            apiKey: "test-key", transport: transport
        )

        let titles = try await provider.generate(.init(
            name: "学习 React", outlineText: "第一章 组件；第二章 状态",
            courseURL: "https://example.org/course"
        ))
        XCTAssertEqual(titles, ["组件", "状态"])
        let capturedBody = await transport.requestBody()
        let body = try XCTUnwrap(capturedBody)
        XCTAssertTrue(body.contains("第一章 组件"))
        XCTAssertTrue(body.contains("pasted_outline"))
        XCTAssertFalse(body.contains("example.org/course"))
        XCTAssertFalse(body.contains("sessions"))
        XCTAssertFalse(body.contains("proofs"))
    }

    func testInvalidResponseAndUnreadLinkDoNotCreateUnits() async throws {
        let transport = RecordingPlanTransport(content: #"{"units":[{"title":"组件","duration":30}]}"#)
        let provider = ProgressPlanProvider(
            settings: AIReviewSettings(endpoint: URL(string: "https://example.com/v1")!, model: "test-model"),
            apiKey: "test-key", transport: transport
        )

        do {
            _ = try await provider.generate(.init(name: "学习 React", courseURL: "https://example.org/course"))
            XCTFail("An unread link must not be represented as a read source")
        } catch let error as ProgressPlanError {
            XCTAssertEqual(error, .linkNeedsReader)
        }
        let unsentBody = await transport.requestBody()
        XCTAssertNil(unsentBody)

        do {
            _ = try await provider.generate(.init(name: "学习 React"))
            XCTFail("Unexpected response fields must be rejected")
        } catch is DecodingError {
            // The response validator is intentionally strict.
        }
    }
}

private actor RecordingPlanTransport: AIHTTPTransport {
    private let content: String
    private var body: String?

    init(content: String) { self.content = content }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let responseBody: [String: Any] = ["choices": [["message": ["content": content]]]]
        let data = try JSONSerialization.data(withJSONObject: responseBody)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    func requestBody() -> String? { body }
}
