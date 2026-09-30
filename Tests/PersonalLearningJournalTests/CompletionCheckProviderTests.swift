import XCTest
@testable import PersonalLearningJournal

final class CompletionCheckProviderTests: XCTestCase {

    // MARK: - Fixed schema (progress required, criteria 1–5, understanding/blocker optional prompts)

    func testRuleBasedProviderUsesActivityCriteriaWithAppControlledStructure() async throws {
        let provider = RuleBasedCompletionCheckProvider()
        let input = CompletionCheckInput(
            activityTitle: "Implement a tokenizer",
            completionCriteria: ["  Vocabulary builds  ", "Encode round-trips", "Vocabulary builds", ""],
            expectedProof: "Tokenizer notebook",
            phaseObjective: "Understand tokenization",
            prerequisitesSummary: "Knows Python"
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.activityTitle, "Implement a tokenizer")
        XCTAssertEqual(draft.progressOptions, CompletionProgress.allCases)
        XCTAssertEqual(draft.criteria, [
            CompletionCriterion(id: "criterion-1", text: "Vocabulary builds"),
            CompletionCriterion(id: "criterion-2", text: "Encode round-trips")
        ])
        XCTAssertTrue(draft.asksUnderstanding)
        XCTAssertTrue(draft.asksBlocker)
        XCTAssertEqual(draft.source, .ruleBased)
    }

    func testRuleBasedProviderCapsCriteriaAtFive() async throws {
        let provider = RuleBasedCompletionCheckProvider()
        let input = CompletionCheckInput(
            activityTitle: "Read chapter 3",
            completionCriteria: ["a", "b", "c", "d", "e", "f", "g"],
            expectedProof: nil,
            phaseObjective: nil,
            prerequisitesSummary: nil
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.criteria.map(\.text), ["a", "b", "c", "d", "e"])
    }

    func testRuleBasedProviderSynthesizesOneCriterionFromExpectedProofForLegacyActivity() async throws {
        let provider = RuleBasedCompletionCheckProvider()
        let input = CompletionCheckInput(
            activityTitle: "Read chapter 3",
            completionCriteria: [],
            expectedProof: "Chapter 3 notes",
            phaseObjective: nil,
            prerequisitesSummary: nil
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.criteria, [
            CompletionCriterion(id: "criterion-1", text: "Chapter 3 notes")
        ])
        XCTAssertEqual(draft.source, .ruleBased)
    }

    func testRuleBasedProviderFallsBackToActivityTitleWhenNoCriteriaOrProof() async throws {
        let provider = RuleBasedCompletionCheckProvider()
        let input = CompletionCheckInput(
            activityTitle: "Read chapter 3",
            completionCriteria: ["   "],
            expectedProof: "  ",
            phaseObjective: nil,
            prerequisitesSummary: nil
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.criteria, [
            CompletionCriterion(id: "criterion-1", text: "Read chapter 3")
        ])
    }

    // MARK: - OpenAI-compatible provider

    func testOpenAIProviderBuildsDraftFromRewrittenCriteria() async throws {
        let response = try completionData(for: #"{"criteria":["Vocabulary builds","Encode round-trips"]}"#)
        let provider = OpenAICompatibleCompletionCheckProvider(
            settings: settings,
            apiKey: "test-key",
            transport: CompletionCheckRecordingTransport(data: response)
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.activityTitle, input.activityTitle)
        XCTAssertEqual(draft.progressOptions, CompletionProgress.allCases)
        XCTAssertEqual(draft.criteria, [
            CompletionCriterion(id: "criterion-1", text: "Vocabulary builds"),
            CompletionCriterion(id: "criterion-2", text: "Encode round-trips")
        ])
        XCTAssertTrue(draft.asksUnderstanding)
        XCTAssertTrue(draft.asksBlocker)
        XCTAssertEqual(draft.source, .ai)
    }

    func testOpenAIProviderTrimsDedupesAndCapsCriteriaAtFive() async throws {
        let response = try completionData(
            for: #"{"criteria":[" one ","","two","one","three","four","five","six"]}"#
        )
        let provider = OpenAICompatibleCompletionCheckProvider(
            settings: settings,
            apiKey: "test-key",
            transport: CompletionCheckRecordingTransport(data: response)
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.criteria.map(\.text), ["one", "two", "three", "four", "five"])
    }

    func testOpenAIProviderRejectsResponseWithZeroValidCriteria() async throws {
        let response = try completionData(for: #"{"criteria":["  ",""]}"#)
        let provider = OpenAICompatibleCompletionCheckProvider(
            settings: settings,
            apiKey: "test-key",
            transport: CompletionCheckRecordingTransport(data: response)
        )

        do {
            _ = try await provider.makeCheckDraft(input: input)
            XCTFail("Expected providerUnavailable")
        } catch let error as CompletionCheckError {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    func testOpenAIProviderRejectsUnparseableResponse() async throws {
        let response = try completionData(for: #"{"unexpected":true}"#)
        let provider = OpenAICompatibleCompletionCheckProvider(
            settings: settings,
            apiKey: "test-key",
            transport: CompletionCheckRecordingTransport(data: response)
        )

        do {
            _ = try await provider.makeCheckDraft(input: input)
            XCTFail("Expected providerUnavailable")
        } catch let error as CompletionCheckError {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    func testOpenAIProviderWrapsTransportFailureAsProviderUnavailable() async throws {
        let provider = OpenAICompatibleCompletionCheckProvider(
            settings: settings,
            apiKey: "test-key",
            transport: CompletionCheckFailingTransport()
        )

        do {
            _ = try await provider.makeCheckDraft(input: input)
            XCTFail("Expected providerUnavailable")
        } catch let error as CompletionCheckError {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    // MARK: - Safety: no preselected answers, verdicts, or plan mutations

    func testAIOutputCannotPreselectAnswersOrMutatePlan() async throws {
        let response = try completionData(for: """
        {"criteria":["Vocabulary builds"],\
        "progress":"completed",\
        "completedCriterionIDs":["criterion-1"],\
        "understanding":"canExplainOrApply",\
        "blocker":"none",\
        "verdict":"done",\
        "answers":{"progress":"completed"},\
        "plan":{"phases":[]},\
        "progressOptions":["completed"],\
        "asksUnderstanding":false}
        """)
        let provider = OpenAICompatibleCompletionCheckProvider(
            settings: settings,
            apiKey: "test-key",
            transport: CompletionCheckRecordingTransport(data: response)
        )

        let draft = try await provider.makeCheckDraft(input: input)

        // Only criteria wording may flow from the provider. Structure stays app-owned.
        XCTAssertEqual(
            draft,
            CompletionCheckDraft(
                activityTitle: input.activityTitle,
                progressOptions: CompletionProgress.allCases,
                criteria: [CompletionCriterion(id: "criterion-1", text: "Vocabulary builds")],
                asksUnderstanding: true,
                asksBlocker: true,
                source: .ai
            )
        )
        // The answers type has no preselection path: a fresh check starts empty.
        let answers = CompletionCheckAnswers()
        XCTAssertNil(answers.progress)
        XCTAssertTrue(answers.completedCriterionIDs.isEmpty)
        XCTAssertNil(answers.understanding)
        XCTAssertNil(answers.blocker)
    }

    // MARK: - Request package contents

    func testRequestContainsOnlyCompletionCheckInputFields() async throws {
        let transport = CompletionCheckRecordingTransport(
            data: try completionData(for: #"{"criteria":["Vocabulary builds"]}"#)
        )
        let provider = OpenAICompatibleCompletionCheckProvider(
            settings: settings,
            apiKey: "test-key",
            transport: transport
        )

        _ = try await provider.makeCheckDraft(input: input)

        let recordedBody = await transport.lastRequestBodyString
        let body = try XCTUnwrap(recordedBody)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
        let userContent = try XCTUnwrap(userMessage["content"] as? String)
        let userPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(userContent.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(userPayload.keys),
            ["activityTitle", "completionCriteria", "expectedProof", "phaseObjective", "prerequisitesSummary"]
        )
        for forbidden in ["calendar", "contacts", "contact", "location", "attachment", "courses", "projects", "sessions", "proofs"] {
            XCTAssertFalse(
                userContent.localizedCaseInsensitiveContains(forbidden),
                "Request leaked \(forbidden): \(userContent)"
            )
        }
    }

    func testRequestPreviewCarriesNoArtifactsAndMarksPurpose() throws {
        let package = try OpenAICompatibleCompletionCheckProvider.requestPreview(
            input: input,
            model: "test-model"
        )

        XCTAssertTrue(package.artifacts.isEmpty)
        XCTAssertEqual(package.model, "test-model")
        XCTAssertEqual(package.sourceMetadata["source"], "completion-check")
        XCTAssertEqual(package.sourceMetadata["authorization"], "one-request")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(package.encodedText.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(payload.keys),
            ["activityTitle", "completionCriteria", "expectedProof", "phaseObjective", "prerequisitesSummary"]
        )
    }

    // MARK: - Adaptive provider

    func testAdaptiveProviderFallsBackToRuleBasedWhenNotConfigured() async throws {
        let store = makeSettingsStore()
        let provider = AdaptiveCompletionCheckProvider(
            settingsStore: store,
            transport: CompletionCheckFailingTransport()
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.source, .ruleBased)
        XCTAssertEqual(draft.criteria.map(\.text), input.completionCriteria)
        XCTAssertEqual(draft.progressOptions, CompletionProgress.allCases)
    }

    func testAdaptiveProviderFallsBackOnProviderFailure() async throws {
        let store = try makeConfiguredSettingsStore()
        let provider = AdaptiveCompletionCheckProvider(
            settingsStore: store,
            transport: CompletionCheckFailingTransport()
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.source, .ruleBased)
        XCTAssertEqual(draft.criteria.map(\.text), input.completionCriteria)
    }

    func testAdaptiveProviderFallsBackOnInvalidOutput() async throws {
        let store = try makeConfiguredSettingsStore()
        let provider = AdaptiveCompletionCheckProvider(
            settingsStore: store,
            transport: CompletionCheckRecordingTransport(
                data: try completionData(for: #"{"criteria":[]}"#)
            )
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.source, .ruleBased)
        XCTAssertEqual(draft.criteria.map(\.text), input.completionCriteria)
    }

    func testAdaptiveProviderUsesAIWhenConfiguredAndHealthy() async throws {
        let store = try makeConfiguredSettingsStore()
        let provider = AdaptiveCompletionCheckProvider(
            settingsStore: store,
            transport: CompletionCheckRecordingTransport(
                data: try completionData(for: #"{"criteria":["Rewritten criterion"]}"#)
            )
        )

        let draft = try await provider.makeCheckDraft(input: input)

        XCTAssertEqual(draft.source, .ai)
        XCTAssertEqual(draft.criteria.map(\.text), ["Rewritten criterion"])
    }

    // MARK: - Integration: produced draft survives the pending-capture store

    func testProducedDraftAttachesToPendingCaptureStoreAndSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let draft = try await RuleBasedCompletionCheckProvider().makeCheckDraft(input: input)

        let store = PendingStudyCaptureStore(directory: directory)
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id)
        try store.attachCheckDraft(id: capture.id, draft: draft)

        let reloaded = PendingStudyCaptureStore(directory: directory)
        let restored = try XCTUnwrap(reloaded.load().first { $0.id == capture.id })
        XCTAssertEqual(restored.checkDraft, draft)
        XCTAssertEqual(restored.answers, CompletionCheckAnswers())
    }

    // MARK: - Fixtures

    private var settings: AIReviewSettings {
        AIReviewSettings(
            endpoint: URL(string: "https://example.test/v1")!,
            model: "test-model"
        )
    }

    private var input: CompletionCheckInput {
        CompletionCheckInput(
            activityTitle: "Implement a tokenizer",
            completionCriteria: ["Vocabulary builds", "Encode round-trips"],
            expectedProof: "Tokenizer notebook",
            phaseObjective: "Understand tokenization",
            prerequisitesSummary: "Knows Python"
        )
    }

    private func completionData(for content: String) throws -> Data {
        let escaped = content.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Data(#"{"choices":[{"message":{"content":"\#(escaped)"}}]}"#.utf8)
    }

    private func makeSettingsStore() -> AIReviewSettingsStore {
        let suiteName = "PersonalLearningJournalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return AIReviewSettingsStore(
            userDefaults: defaults,
            keyStore: CompletionCheckTestAPIKeyStore()
        )
    }

    private func makeConfiguredSettingsStore() throws -> AIReviewSettingsStore {
        let store = makeSettingsStore()
        try store.save(settings: settings, apiKey: "test-key")
        return store
    }
}

private actor CompletionCheckRecordingTransport: AIHTTPTransport {
    private let responseData: Data
    private var requestBody: Data?

    init(data: Data) {
        self.responseData = data
    }

    var lastRequestBodyString: String? {
        requestBody.flatMap { String(data: $0, encoding: .utf8) }
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

private struct CompletionCheckFailingTransport: AIHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class CompletionCheckTestAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? {
        values[key]
    }

    func setValue(_ value: String?, for key: String) throws {
        values[key] = value
    }
}
