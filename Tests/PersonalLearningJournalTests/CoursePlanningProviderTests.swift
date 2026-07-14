import XCTest
@testable import PersonalLearningJournal

final class CoursePlanningProviderTests: XCTestCase {
    func testPlanningRequestContainsCourseInputButNoCalendarEventContent() async throws {
        let transport = RecordingAIHTTPTransport(data: try completionData)
        let provider = OpenAICompatibleCoursePlanningProvider(
            settings: settings,
            apiKey: "test-key",
            transport: transport
        )

        _ = try await provider.makeDraft(
            input: input,
            context: CoursePlanningContext(
                currentNextStep: "Implement a tokenizer",
                recentSessionSummaries: ["session: tokenization notes"],
                recentProofSummaries: ["proof: notebook cell output"]
            )
        )

        let requestBody = await transport.lastRequestBodyString
        let body = try XCTUnwrap(requestBody)
        XCTAssertTrue(body.contains("Lecture 1: tokenization"))
        XCTAssertTrue(body.contains("availableMinutesByWeekday"))
        XCTAssertFalse(body.contains("Dentist appointment"))
        XCTAssertFalse(body.contains("calendarEvent"))
    }

    func testProviderRejectsInvalidGeneratedDraft() async throws {
        let invalidResponse = try completionData(for: #"{"title":"CS336","summary":"","phases":[],"sessions":[],"assumptions":[],"warnings":[]}"#)
        let provider = OpenAICompatibleCoursePlanningProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordingAIHTTPTransport(data: invalidResponse)
        )

        do {
            _ = try await provider.makeDraft(input: input, context: .init())
            XCTFail("Expected invalid generated draft")
        } catch let error as CoursePlanningError {
            guard case .invalidDraft(let errors) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(errors.isEmpty)
        }
    }

    private let projectID = UUID()
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private var settings: AIReviewSettings {
        AIReviewSettings(endpoint: URL(string: "https://example.test/v1")!, model: "test-model")
    }

    private var input: CoursePlanningInput {
        CoursePlanningInput(
            projectId: projectID,
            courseTitle: "CS336",
            courseOutline: "Lecture 1: tokenization",
            goal: "Build a tokenizer",
            expectedOutcome: "Tokenizer notebook",
            startsOn: timestamp,
            deadline: timestamp.addingTimeInterval(7 * 86_400),
            weeklyBudgetMinutes: 180,
            preferredSessionMinutes: 45,
            availableMinutesByWeekday: [2: 90, 4: 90]
        )
    }

    private var completionData: Data {
        get throws {
            try completionData(for: #"{"title":"CS336 plan","summary":"Start with tokenization.","phases":[{"id":"foundations","title":"Foundations","objective":"Understand tokenization","expectedProof":"Tokenizer notebook","ordinal":0,"targetStart":"2023-11-14T22:13:20Z","targetEnd":"2023-11-15T22:13:20Z"}],"sessions":[{"id":"tokenizer","phaseID":"foundations","title":"Implement a tokenizer","actionType":"course","expectedProof":"Tokenizer notebook","durationMinutes":45,"deadline":"2023-11-15T22:13:20Z"}],"assumptions":["Use the supplied outline only."],"warnings":[]}"#)
        }
    }

    private func completionData(for content: String) throws -> Data {
        let escaped = content.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Data(#"{"choices":[{"message":{"content":"\#(escaped)"}}]}"#.utf8)
    }
}

private actor RecordingAIHTTPTransport: AIHTTPTransport {
    private let responseData: Data
    private var requestBody: Data?

    init(data: Data) {
        self.responseData = data
    }

    var lastRequestBodyString: String? {
        return requestBody.flatMap { String(data: $0, encoding: .utf8) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestBody = request.httpBody
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }
}
