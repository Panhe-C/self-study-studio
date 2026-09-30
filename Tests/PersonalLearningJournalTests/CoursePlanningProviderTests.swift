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

    func testPlanningRequestIncludesVNextInputFieldsAndStaysRequestScoped() throws {
        var vnextInput = input
        vnextInput.studyPeriodWeeks = 8
        vnextInput.prerequisites = "Basic Python"
        vnextInput.constraints = "No GPU; evenings only"

        let package = try OpenAICompatibleCoursePlanningProvider.requestPreview(
            input: vnextInput,
            context: CoursePlanningContext(currentNextStep: "Implement a tokenizer"),
            model: "test-model"
        )

        XCTAssertTrue(package.encodedText.contains("studyPeriodWeeks"))
        XCTAssertTrue(package.encodedText.contains("Basic Python"))
        XCTAssertTrue(package.encodedText.contains("No GPU; evenings only"))
        XCTAssertTrue(package.encodedText.contains("Implement a tokenizer"))
        XCTAssertFalse(package.encodedText.contains("Dentist appointment"))
        XCTAssertFalse(package.encodedText.contains("calendarEvent"))
        XCTAssertFalse(package.encodedText.contains("contact"))
        XCTAssertFalse(package.encodedText.contains("location"))
    }

    func testProviderDecodesSessionsWithCompletionCriteriaAndRecommendationReason() async throws {
        let response = try completionData(for: #"{"title":"CS336 plan","summary":"Start with tokenization.","phases":[{"id":"foundations","title":"Foundations","objective":"Understand tokenization","expectedProof":"Tokenizer notebook","ordinal":0,"targetStart":"2023-11-14T22:13:20Z","targetEnd":"2023-11-15T22:13:20Z"}],"sessions":[{"id":"tokenizer","phaseID":"foundations","title":"Implement a tokenizer","actionType":"course","expectedProof":"Tokenizer notebook","durationMinutes":45,"deadline":"2023-11-15T22:13:20Z","completionCriteria":["Tokenizer notebook runs end to end","Merge loop unit test passes"],"recommendationReason":"First activity in the Foundations phase"}],"assumptions":[],"warnings":[]}"#)
        let provider = OpenAICompatibleCoursePlanningProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordingAIHTTPTransport(data: response)
        )

        let draft = try await provider.makeDraft(input: input, context: .init())

        XCTAssertEqual(
            draft.sessions.first?.completionCriteria,
            ["Tokenizer notebook runs end to end", "Merge loop unit test passes"]
        )
        XCTAssertEqual(
            draft.sessions.first?.recommendationReason,
            "First activity in the Foundations phase"
        )
    }

    func testProviderAcceptsLegacySessionsWithoutCriteriaAndSurfacesWarning() async throws {
        let provider = OpenAICompatibleCoursePlanningProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordingAIHTTPTransport(data: try completionData)
        )

        let draft = try await provider.makeDraft(input: input, context: .init())

        XCTAssertEqual(draft.sessions.first?.completionCriteria, [])
        XCTAssertTrue(draft.warnings.contains { $0.contains("completion criteria") })
    }

    func testProviderAcceptsMissingOptionalAssumptionsAndWarnings() async throws {
        let response = try completionData(for: #"{"title":"CS336 plan","summary":"Start with tokenization.","phases":[{"id":"foundations","title":"Foundations","objective":"Understand tokenization","expectedProof":"Tokenizer notebook","ordinal":0,"targetStart":"2023-11-14T22:13:20Z","targetEnd":"2023-11-15T22:13:20Z"}],"sessions":[{"id":"tokenizer","phaseID":"foundations","title":"Implement a tokenizer","actionType":"course","expectedProof":"Tokenizer notebook","durationMinutes":45,"deadline":"2023-11-15T22:13:20Z"}]}"#)
        let provider = OpenAICompatibleCoursePlanningProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordingAIHTTPTransport(data: response)
        )

        let draft = try await provider.makeDraft(input: input, context: .init())

        XCTAssertEqual(draft.assumptions, [])
        XCTAssertTrue(draft.warnings.contains { $0.contains("completion criteria") })
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

    func testRegeneratePhaseRequestContainsOnlyTargetPhaseAndUserInput() throws {
        let package = try OpenAICompatibleCoursePlanningProvider.phaseRegenerationRequestPreview(
            input: input,
            context: CoursePlanningContext(currentNextStep: "Implement a tokenizer"),
            phase: CoursePlanDraftPhase(
                id: "foundations",
                title: "Foundations",
                objective: "Understand tokenization",
                expectedProof: "Tokenizer notebook",
                ordinal: 0,
                targetStart: timestamp,
                targetEnd: timestamp.addingTimeInterval(86_400)
            ),
            model: "test-model"
        )

        XCTAssertTrue(package.encodedText.contains("Lecture 1: tokenization"))
        XCTAssertTrue(package.encodedText.contains("Foundations"))
        XCTAssertTrue(package.encodedText.contains("Understand tokenization"))
        XCTAssertFalse(package.encodedText.contains("Scaling"))
        XCTAssertFalse(package.encodedText.contains("Dentist appointment"))
        XCTAssertFalse(package.encodedText.contains("calendarEvent"))
    }

    func testRegeneratePhaseDecodesPhaseAndSessionsBoundToThatPhase() async throws {
        let response = try completionData(for: #"{"phase":{"id":"foundations-v2","title":"Foundations rebuilt","objective":"Understand BPE","expectedProof":"BPE notebook","ordinal":0,"targetStart":"2023-11-14T22:13:20Z","targetEnd":"2023-11-15T22:13:20Z"},"sessions":[{"id":"bpe","phaseID":"foundations-v2","title":"Implement BPE","actionType":"course","expectedProof":"BPE notebook","durationMinutes":45,"deadline":"2023-11-15T22:13:20Z","completionCriteria":["BPE merges reproduce the lecture example"],"recommendationReason":"Core exercise of the phase"}]}"#)
        let provider = OpenAICompatibleCoursePlanningProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordingAIHTTPTransport(data: response)
        )

        let regeneration = try await provider.regeneratePhase(
            input: input,
            context: .init(),
            phase: targetPhase
        )

        XCTAssertEqual(regeneration.phase.id, "foundations-v2")
        XCTAssertEqual(regeneration.phase.title, "Foundations rebuilt")
        XCTAssertEqual(regeneration.sessions.count, 1)
        XCTAssertEqual(regeneration.sessions.first?.phaseID, "foundations-v2")
        XCTAssertEqual(
            regeneration.sessions.first?.completionCriteria,
            ["BPE merges reproduce the lecture example"]
        )
    }

    func testRegeneratePhaseRejectsInvalidOutput() async throws {
        let invalidResponse = try completionData(for: #"{"phase":{"id":"foundations-v2","title":"","objective":"Understand BPE","expectedProof":"BPE notebook","ordinal":0,"targetStart":"2023-11-14T22:13:20Z","targetEnd":"2023-11-15T22:13:20Z"},"sessions":[]}"#)
        let provider = OpenAICompatibleCoursePlanningProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordingAIHTTPTransport(data: invalidResponse)
        )

        do {
            _ = try await provider.regeneratePhase(input: input, context: .init(), phase: targetPhase)
            XCTFail("Expected invalid regenerated phase")
        } catch let error as CoursePlanningError {
            guard case .invalidDraft(let errors) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(errors.isEmpty)
        }
    }

    private let projectID = UUID()
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private var targetPhase: CoursePlanDraftPhase {
        CoursePlanDraftPhase(
            id: "foundations",
            title: "Foundations",
            objective: "Understand tokenization",
            expectedProof: "Tokenizer notebook",
            ordinal: 0,
            targetStart: timestamp,
            targetEnd: timestamp.addingTimeInterval(86_400)
        )
    }

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
