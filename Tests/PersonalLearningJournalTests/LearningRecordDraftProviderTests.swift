import XCTest
@testable import PersonalLearningJournal

final class LearningRecordDraftProviderTests: XCTestCase {

    // MARK: - Codable I/O (summary, result, blockers, suggestedNextStep, adjustmentSignal, rationale)

    func testLearningRecordDraftRoundTripsAllFields() throws {
        let draft = LearningRecordDraft(
            summary: "Studied tokenization for 45 minutes. Progress: partially completed.",
            result: "Vocabulary builds",
            blockers: "Byte-pair edge cases",
            suggestedNextStep: "Review tokenizer edge cases",
            adjustmentSignal: .ordinary,
            rationale: "Recurring blocker suggests an ordinary adjustment.",
            source: .ai
        )

        let data = try JSONEncoder.journal.encode(draft)
        let decoded = try JSONDecoder.journal.decode(LearningRecordDraft.self, from: data)

        XCTAssertEqual(decoded, draft)
        XCTAssertEqual(decoded.adjustmentSignal, .ordinary)
        XCTAssertEqual(decoded.rationale, "Recurring blocker suggests an ordinary adjustment.")
    }

    func testLearningRecordDraftDecodesLegacyJSONWithoutRationale() throws {
        let legacyJSON = """
        {
          "summary": "Studied tokenization.",
          "result": "",
          "blockers": "",
          "suggestedNextStep": null,
          "adjustmentSignal": "none",
          "source": "ruleBased"
        }
        """

        let decoded = try JSONDecoder.journal.decode(
            LearningRecordDraft.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.summary, "Studied tokenization.")
        XCTAssertEqual(decoded.adjustmentSignal, .none)
        XCTAssertNil(decoded.rationale)
    }

    func testInputEncodesOnlyAllowedFacts() throws {
        let data = try JSONEncoder.journal.encode(input)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(payload.keys),
            [
                "activityTitle", "startedAt", "endedAt", "activeDurationSeconds",
                "answers", "criteriaByID", "attachments", "currentNextStep"
            ]
        )
        let answers = try XCTUnwrap(payload["answers"] as? [String: Any])
        XCTAssertEqual(
            Set(answers.keys),
            ["progress", "completedCriterionIDs", "understanding", "blocker"]
        )
    }

    func testInputBuildsFromCaptureFactsAndCurrentNextStepOnly() throws {
        let capture = PendingStudyCapture(
            id: UUID(),
            projectID: UUID(),
            source: .timer,
            stage: .awaitingCheck,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_002_700),
            activeDurationSeconds: 2700,
            checkDraft: CompletionCheckDraft(
                activityTitle: "Implement a tokenizer",
                progressOptions: CompletionProgress.allCases,
                criteria: [
                    CompletionCriterion(id: "criterion-1", text: "Vocabulary builds"),
                    CompletionCriterion(id: "criterion-2", text: "Encode round-trips")
                ],
                asksUnderstanding: true,
                asksBlocker: true,
                source: .ruleBased
            ),
            answers: input.answers,
            stagedAttachments: input.attachments,
            updatedAt: Date(timeIntervalSince1970: 1_700_002_700)
        )

        let built = LearningRecordDraftInput(
            capture: capture,
            activityTitle: "Implement a tokenizer",
            currentNextStep: "Review tokenizer edge cases"
        )

        XCTAssertEqual(built, input)
    }

    // MARK: - Rule-based fallback: composes a readable summary strictly from facts

    func testRuleBasedProviderComposesSummaryFromAnswersOnly() async throws {
        let provider = RuleBasedLearningRecordDraftProvider()

        let draft = try await provider.makeRecordDraft(input: input)

        XCTAssertEqual(draft.source, .ruleBased)
        XCTAssertEqual(draft.adjustmentSignal, .none)
        XCTAssertNil(draft.suggestedNextStep)
        XCTAssertEqual(draft.blockers, "Byte-pair edge cases")
        XCTAssertEqual(draft.result, "")
        XCTAssertTrue(draft.summary.contains("Implement a tokenizer"))
        XCTAssertTrue(draft.summary.contains("45 minutes"))
        XCTAssertTrue(draft.summary.contains("partially completed"))
        XCTAssertTrue(draft.summary.contains("Vocabulary builds"))
        XCTAssertTrue(draft.summary.contains("needs review"))
        XCTAssertTrue(draft.summary.contains("Byte-pair edge cases"))
        // Never infers completion of items the user did not select.
        XCTAssertFalse(draft.summary.contains("Encode round-trips"))
    }

    func testRuleBasedProviderOmitsUnansweredClauses() async throws {
        let provider = RuleBasedLearningRecordDraftProvider()
        var sparse = input
        sparse.answers = CompletionCheckAnswers()
        sparse.activeDurationSeconds = 0

        let draft = try await provider.makeRecordDraft(input: sparse)

        XCTAssertEqual(draft.source, .ruleBased)
        XCTAssertEqual(draft.summary, "Studied Implement a tokenizer.")
        XCTAssertEqual(draft.blockers, "")
        XCTAssertEqual(draft.result, "")
    }

    // MARK: - OpenAI-compatible provider

    func testOpenAIProviderBuildsEditableDraftFromResponse() async throws {
        let response = try completionData(for: """
        {"summary":" Studied tokenization for 45 minutes. ",\
        "result":" Vocabulary builds ",\
        "blockers":" Byte-pair edge cases ",\
        "suggestedNextStep":" Review tokenizer edge cases ",\
        "adjustmentSignal":"ordinary",\
        "rationale":" Blocker repeats across sessions. "}
        """)
        let provider = OpenAICompatibleLearningRecordDraftProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordDraftRecordingTransport(data: response)
        )

        let draft = try await provider.makeRecordDraft(input: input)

        XCTAssertEqual(draft.source, .ai)
        XCTAssertEqual(draft.summary, "Studied tokenization for 45 minutes.")
        XCTAssertEqual(draft.result, "Vocabulary builds")
        XCTAssertEqual(draft.blockers, "Byte-pair edge cases")
        XCTAssertEqual(draft.suggestedNextStep, "Review tokenizer edge cases")
        XCTAssertEqual(draft.adjustmentSignal, .ordinary)
        XCTAssertEqual(draft.rationale, "Blocker repeats across sessions.")
    }

    func testOpenAIProviderRejectsBlankSummary() async throws {
        let response = try completionData(for: """
        {"summary":"   ","result":"","blockers":"","adjustmentSignal":"none"}
        """)
        let provider = OpenAICompatibleLearningRecordDraftProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordDraftRecordingTransport(data: response)
        )

        do {
            _ = try await provider.makeRecordDraft(input: input)
            XCTFail("Expected providerUnavailable")
        } catch let error as LearningRecordDraftError {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    func testOpenAIProviderRejectsInvalidAdjustmentSignal() async throws {
        let response = try completionData(for: """
        {"summary":"Studied tokenization.","result":"","blockers":"",\
        "adjustmentSignal":"catastrophic"}
        """)
        let provider = OpenAICompatibleLearningRecordDraftProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordDraftRecordingTransport(data: response)
        )

        do {
            _ = try await provider.makeRecordDraft(input: input)
            XCTFail("Expected providerUnavailable")
        } catch let error as LearningRecordDraftError {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    func testOpenAIProviderRejectsUnparseableResponse() async throws {
        let response = try completionData(for: #"{"unexpected":true}"#)
        let provider = OpenAICompatibleLearningRecordDraftProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordDraftRecordingTransport(data: response)
        )

        do {
            _ = try await provider.makeRecordDraft(input: input)
            XCTFail("Expected providerUnavailable")
        } catch let error as LearningRecordDraftError {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    func testOpenAIProviderWrapsTransportFailureAsProviderUnavailable() async throws {
        let provider = OpenAICompatibleLearningRecordDraftProvider(
            settings: settings,
            apiKey: "test-key",
            transport: RecordDraftFailingTransport()
        )

        do {
            _ = try await provider.makeRecordDraft(input: input)
            XCTFail("Expected providerUnavailable")
        } catch let error as LearningRecordDraftError {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    // MARK: - Request package contents

    func testRequestContainsOnlyAllowedFieldsAndNoAttachmentContent() async throws {
        let transport = RecordDraftRecordingTransport(
            data: try completionData(for: """
            {"summary":"Studied tokenization.","result":"","blockers":"","adjustmentSignal":"none"}
            """)
        )
        let provider = OpenAICompatibleLearningRecordDraftProvider(
            settings: settings,
            apiKey: "test-key",
            transport: transport
        )

        _ = try await provider.makeRecordDraft(input: input)

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
            [
                "activityTitle", "startedAt", "endedAt", "activeDurationSeconds",
                "answers", "criteriaByID", "attachments", "currentNextStep"
            ]
        )
        for forbidden in ["calendar", "contacts", "contact", "location", "content", "courses", "projects", "sessions", "proofs", "snapshot"] {
            XCTAssertFalse(
                userContent.localizedCaseInsensitiveContains(forbidden),
                "Request leaked \(forbidden): \(userContent)"
            )
        }
    }

    func testRequestPreviewCarriesNoArtifactsAndMarksPurpose() throws {
        let package = try OpenAICompatibleLearningRecordDraftProvider.requestPreview(
            input: input,
            model: "test-model"
        )

        XCTAssertTrue(package.artifacts.isEmpty)
        XCTAssertEqual(package.model, "test-model")
        XCTAssertEqual(package.sourceMetadata["source"], "learning-record-draft")
        XCTAssertEqual(package.sourceMetadata["authorization"], "one-request")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(package.encodedText.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(payload.keys),
            [
                "activityTitle", "startedAt", "endedAt", "activeDurationSeconds",
                "answers", "criteriaByID", "attachments", "currentNextStep"
            ]
        )
    }

    // MARK: - Adaptive provider

    func testAdaptiveProviderFallsBackToRuleBasedWhenNotConfigured() async throws {
        let provider = AdaptiveLearningRecordDraftProvider(
            settingsStore: makeSettingsStore(),
            transport: RecordDraftFailingTransport()
        )

        let draft = try await provider.makeRecordDraft(input: input)

        XCTAssertEqual(draft.source, .ruleBased)
        XCTAssertEqual(draft.adjustmentSignal, .none)
        XCTAssertTrue(draft.summary.contains("Implement a tokenizer"))
    }

    func testAdaptiveProviderFallsBackOnProviderFailure() async throws {
        let provider = AdaptiveLearningRecordDraftProvider(
            settingsStore: try makeConfiguredSettingsStore(),
            transport: RecordDraftFailingTransport()
        )

        let draft = try await provider.makeRecordDraft(input: input)

        XCTAssertEqual(draft.source, .ruleBased)
    }

    func testAdaptiveProviderFallsBackOnInvalidOutput() async throws {
        let provider = AdaptiveLearningRecordDraftProvider(
            settingsStore: try makeConfiguredSettingsStore(),
            transport: RecordDraftRecordingTransport(
                data: try completionData(for: """
                {"summary":" ","result":"","blockers":"","adjustmentSignal":"none"}
                """)
            )
        )

        let draft = try await provider.makeRecordDraft(input: input)

        XCTAssertEqual(draft.source, .ruleBased)
    }

    func testAdaptiveProviderUsesAIWhenConfiguredAndHealthy() async throws {
        let provider = AdaptiveLearningRecordDraftProvider(
            settingsStore: try makeConfiguredSettingsStore(),
            transport: RecordDraftRecordingTransport(
                data: try completionData(for: """
                {"summary":"Studied tokenization.","result":"","blockers":"","adjustmentSignal":"none"}
                """)
            )
        )

        let draft = try await provider.makeRecordDraft(input: input)

        XCTAssertEqual(draft.source, .ai)
        XCTAssertEqual(draft.summary, "Studied tokenization.")
    }

    // MARK: - Store integration: drafts go to PendingStudyCaptureStore, never the Journal

    func testAIFailureFallbackDraftSurvivesStoreReloadAndUserEdits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // No JournalRepository/JournalSnapshot is injected anywhere in this
        // flow: the draft can only land in the pending-capture store.
        let store = PendingStudyCaptureStore(directory: directory)
        let capture = try store.begin(projectID: UUID(), source: .timer)
        try store.end(id: capture.id, at: Date(timeIntervalSince1970: 1_700_002_700))
        try store.checkpoint(id: capture.id, activeDurationSeconds: 2700)
        try store.recordAnswers(id: capture.id, answers: input.answers)

        let generator = LearningRecordDraftGenerator(
            provider: AdaptiveLearningRecordDraftProvider(
                settingsStore: try makeConfiguredSettingsStore(),
                transport: RecordDraftFailingTransport()
            )
        )
        let ended = try XCTUnwrap(store.allCaptures().first { $0.id == capture.id })
        let captureInput = LearningRecordDraftInput(
            capture: ended,
            activityTitle: "Implement a tokenizer",
            currentNextStep: "Review tokenizer edge cases"
        )
        let attached = try await generator.generateAndAttach(
            captureID: capture.id,
            input: captureInput,
            store: store
        )

        XCTAssertEqual(attached.stage, .awaitingRecordConfirmation)
        XCTAssertEqual(attached.recordDraft?.source, .ruleBased)

        // Simulated app restart: a fresh store instance reloads from disk.
        let reloaded = PendingStudyCaptureStore(directory: directory)
        let restored = try XCTUnwrap(reloaded.allCaptures().first { $0.id == capture.id })
        XCTAssertEqual(restored.recordDraft, attached.recordDraft)
        XCTAssertEqual(restored.stage, .awaitingRecordConfirmation)

        // Simulated user edits: the user revises the draft and it is
        // attached again, still unconfirmed, never a journal fact.
        var edited = try XCTUnwrap(restored.recordDraft)
        edited.summary = "Edited: studied tokenization, got stuck on merges."
        edited.blockers = "Edited blocker"
        edited.suggestedNextStep = "Edited next step"
        try reloaded.attachRecordDraft(id: capture.id, draft: edited)

        let restartedAgain = PendingStudyCaptureStore(directory: directory)
        let final = try XCTUnwrap(restartedAgain.allCaptures().first { $0.id == capture.id })
        XCTAssertEqual(final.recordDraft, edited)
        XCTAssertEqual(final.recordDraft?.summary, "Edited: studied tokenization, got stuck on merges.")
        XCTAssertEqual(final.stage, .awaitingRecordConfirmation)
    }

    // MARK: - Fixtures

    private var settings: AIReviewSettings {
        AIReviewSettings(
            endpoint: URL(string: "https://example.test/v1")!,
            model: "test-model"
        )
    }

    private var input: LearningRecordDraftInput {
        LearningRecordDraftInput(
            activityTitle: "Implement a tokenizer",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_002_700),
            activeDurationSeconds: 2700,
            answers: CompletionCheckAnswers(
                progress: .partial,
                completedCriterionIDs: ["criterion-1"],
                understanding: .needsReview,
                blocker: "Byte-pair edge cases"
            ),
            criteriaByID: [
                "criterion-1": "Vocabulary builds",
                "criterion-2": "Encode round-trips"
            ],
            attachments: [
                PendingAttachmentReference(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                    kind: .image,
                    localPath: "/tmp/staged-note.png",
                    displayName: "staged-note.png",
                    fileSize: 1234
                )
            ],
            currentNextStep: "Review tokenizer edge cases"
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
            keyStore: RecordDraftTestAPIKeyStore()
        )
    }

    private func makeConfiguredSettingsStore() throws -> AIReviewSettingsStore {
        let store = makeSettingsStore()
        try store.save(settings: settings, apiKey: "test-key")
        return store
    }
}

private actor RecordDraftRecordingTransport: AIHTTPTransport {
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

private struct RecordDraftFailingTransport: AIHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class RecordDraftTestAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? {
        values[key]
    }

    func setValue(_ value: String?, for key: String) throws {
        values[key] = value
    }
}
