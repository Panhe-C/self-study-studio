import Foundation

public enum CompletionCheckError: Error, Equatable, Sendable {
    /// The provider could not produce a usable check (configuration,
    /// transport, parse, or validation failure). Callers fall back to the
    /// rule-based provider.
    case providerUnavailable
}

/// Everything a completion-check provider may see (spec 12.2): the activity
/// title, its completion criteria, the expected proof, the phase objective,
/// and a learner prerequisites summary. Nothing else may be sent — no other
/// courses, no calendar, contacts, location, or attachment content.
public struct CompletionCheckInput: Equatable, Sendable, Encodable {
    public var activityTitle: String
    public var completionCriteria: [String]
    public var expectedProof: String?
    public var phaseObjective: String?
    public var prerequisitesSummary: String?

    public init(
        activityTitle: String,
        completionCriteria: [String],
        expectedProof: String?,
        phaseObjective: String?,
        prerequisitesSummary: String?
    ) {
        self.activityTitle = activityTitle
        self.completionCriteria = completionCriteria
        self.expectedProof = expectedProof
        self.phaseObjective = phaseObjective
        self.prerequisitesSummary = prerequisitesSummary
    }
}

public protocol CompletionCheckProvider: Sendable {
    func makeCheckDraft(input: CompletionCheckInput) async throws -> CompletionCheckDraft
}

/// Shared draft assembly and criteria sanitizing. The app owns the question
/// structure: progress options are always the full set, understanding and
/// blocker prompts are always asked with fixed app copy, and providers only
/// supply criteria wording. Drafts therefore can never carry preselected
/// answers, completion verdicts, or plan mutations.
enum CompletionCheckDraftBuilder {
    static let maximumCriteria = 5

    /// Trims blanks, dedupes (first occurrence wins), caps at 5.
    static func sanitize(criteria: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for criterion in criteria {
            let trimmed = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == maximumCriteria { break }
        }
        return result
    }

    static func makeDraft(
        activityTitle: String,
        criteria: [String],
        source: DraftSource
    ) -> CompletionCheckDraft {
        CompletionCheckDraft(
            activityTitle: activityTitle,
            progressOptions: CompletionProgress.allCases,
            criteria: criteria.enumerated().map { index, text in
                CompletionCriterion(id: "criterion-\(index + 1)", text: text)
            },
            asksUnderstanding: true,
            asksBlocker: true,
            source: source
        )
    }
}

public struct RuleBasedCompletionCheckProvider: CompletionCheckProvider {
    public init() {}

    /// Uses the activity's own criteria directly. Legacy activities without
    /// criteria get exactly one local check item synthesized from the
    /// expected proof, falling back to the activity title.
    public func makeCheckDraft(input: CompletionCheckInput) async throws -> CompletionCheckDraft {
        var criteria = CompletionCheckDraftBuilder.sanitize(criteria: input.completionCriteria)
        if criteria.isEmpty {
            let proof = input.expectedProof?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            criteria = [proof.isEmpty ? input.activityTitle : proof]
        }
        return CompletionCheckDraftBuilder.makeDraft(
            activityTitle: input.activityTitle,
            criteria: criteria,
            source: .ruleBased
        )
    }
}

public struct OpenAICompatibleCompletionCheckProvider: CompletionCheckProvider {
    private let client: OpenAICompatibleStructuredClient
    private let model: String

    public init(
        settings: AIReviewSettings,
        apiKey: String,
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport()
    ) {
        self.client = OpenAICompatibleStructuredClient(
            settings: settings,
            apiKey: apiKey,
            transport: transport
        )
        self.model = settings.model
    }

    public func makeCheckDraft(input: CompletionCheckInput) async throws -> CompletionCheckDraft {
        do {
            // The response schema carries only criteria wording. Answer,
            // verdict, and plan fields have no decoding path into the draft.
            let response: CompletionCheckResponse = try await client.completeJSON(
                system: Self.systemPrompt,
                user: try Self.requestPreview(input: input, model: model).encodedText
            )
            let criteria = CompletionCheckDraftBuilder.sanitize(criteria: response.criteria)
            guard !criteria.isEmpty else {
                throw CompletionCheckError.providerUnavailable
            }
            return CompletionCheckDraftBuilder.makeDraft(
                activityTitle: input.activityTitle,
                criteria: criteria,
                source: .ai
            )
        } catch let error as CompletionCheckError {
            throw error
        } catch {
            throw CompletionCheckError.providerUnavailable
        }
    }

    private static let systemPrompt = """
    You rewrite completion criteria for a personal learning activity so the learner can judge each item as done or not done. Return only a JSON object of the form {"criteria": ["...", "..."]} with 1 to 5 short, observable check items derived from the supplied activity title, completion criteria, expected proof, and phase objective. Never include selected answers, progress values, completion verdicts, plan changes, or any other field. Do not use or request calendar event content, contacts, location, attachment content, or any data beyond the request.
    """

    public static func requestPreview(
        input: CompletionCheckInput,
        model: String
    ) throws -> AIRequestPackage {
        AIRequestPackage(
            encodedText: String(decoding: try JSONEncoder.journal.encode(input), as: UTF8.self),
            artifacts: [],
            model: model,
            sourceMetadata: [
                "source": "completion-check",
                "input": "activity-only",
                "authorization": "one-request"
            ]
        )
    }
}

/// Prefers the AI provider when configured; on missing configuration or ANY
/// provider failure (transport, parse, invalid output) returns the
/// deterministic rule-based result marked `source = .ruleBased`. Never
/// throws for provider failure.
public struct AdaptiveCompletionCheckProvider: CompletionCheckProvider {
    private let settingsStore: AIReviewSettingsStore
    private let transport: any AIHTTPTransport
    private let fallback: any CompletionCheckProvider

    public init(
        settingsStore: AIReviewSettingsStore = AIReviewSettingsStore(),
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport(),
        fallback: any CompletionCheckProvider = RuleBasedCompletionCheckProvider()
    ) {
        self.settingsStore = settingsStore
        self.transport = transport
        self.fallback = fallback
    }

    public func makeCheckDraft(input: CompletionCheckInput) async throws -> CompletionCheckDraft {
        guard let settings = settingsStore.settings(),
              let apiKey = settingsStore.apiKey(),
              !apiKey.isEmpty
        else {
            return try await fallback.makeCheckDraft(input: input)
        }

        do {
            return try await OpenAICompatibleCompletionCheckProvider(
                settings: settings,
                apiKey: apiKey,
                transport: transport
            ).makeCheckDraft(input: input)
        } catch {
            return try await fallback.makeCheckDraft(input: input)
        }
    }
}

private struct CompletionCheckResponse: Decodable, Sendable {
    var criteria: [String]
}
