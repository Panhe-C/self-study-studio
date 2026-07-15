import Foundation

public enum CoursePlanningError: Error, Equatable, Sendable {
    case configurationRequired
    case invalidDraft([CoursePlanningValidationError])
    case providerUnavailable
}

public protocol CoursePlanningProvider: Sendable {
    func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft
}

public struct CoursePlanningContext: Codable, Equatable, Sendable {
    public var currentNextStep: String
    public var recentSessionSummaries: [String]
    public var recentProofSummaries: [String]

    public init(
        currentNextStep: String = "",
        recentSessionSummaries: [String] = [],
        recentProofSummaries: [String] = []
    ) {
        self.currentNextStep = currentNextStep
        self.recentSessionSummaries = recentSessionSummaries
        self.recentProofSummaries = recentProofSummaries
    }
}

public struct OpenAICompatibleCoursePlanningProvider: CoursePlanningProvider {
    private let client: OpenAICompatibleStructuredClient
    private let validator: CoursePlanValidator
    private let model: String

    public init(
        settings: AIReviewSettings,
        apiKey: String,
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport(),
        validator: CoursePlanValidator = CoursePlanValidator()
    ) {
        self.client = OpenAICompatibleStructuredClient(
            settings: settings,
            apiKey: apiKey,
            transport: transport
        )
        self.validator = validator
        self.model = settings.model
    }

    public func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft {
        do {
            let response: CoursePlanningResponse = try await client.completeJSON(
                system: Self.systemPrompt,
                user: try Self.requestPreview(input: input, context: context, model: model).encodedText
            )
            var draft = response.draft
            let validation = validator.validate(draft, input: input)
            guard validation.isValid else {
                throw CoursePlanningError.invalidDraft(validation.errors)
            }
            draft.warnings = Array(Set(draft.warnings + validation.warnings)).sorted()
            return draft
        } catch let error as CoursePlanningError {
            throw error
        } catch {
            throw CoursePlanningError.providerUnavailable
        }
    }

    private static let systemPrompt = """
    You create a practical, editable personal course study plan. Return only a JSON object with title, summary, phases, sessions, assumptions, and warnings. Each phase needs id, title, objective, expectedProof, ordinal, targetStart, and targetEnd. Each session needs id, phaseID, title, actionType, expectedProof, durationMinutes, and deadline. Use only the supplied course outline and learning context. Do not invent course-page content. State an assumption whenever the supplied outline is incomplete. Fit sessions within the provided weekly budget and preferred duration. Do not use or request calendar event content, contacts, location, or any data beyond the request.
    """

    private static func requestBody(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) throws -> String {
        let request = CoursePlanningRequest(input: input, context: context)
        return String(decoding: try JSONEncoder.journal.encode(request), as: UTF8.self)
    }

    public static func requestPreview(
        input: CoursePlanningInput,
        context: CoursePlanningContext,
        model: String
    ) throws -> AIRequestPackage {
        AIRequestPackage(
            encodedText: try requestBody(input: input, context: context),
            artifacts: [],
            model: model,
            sourceMetadata: [
                "source": "course-planning",
                "courseText": "exact-user-supplied",
                "authorization": "one-request"
            ]
        )
    }
}

public struct AdaptiveCoursePlanningProvider: CoursePlanningProvider {
    private let settingsStore: AIReviewSettingsStore
    private let transport: any AIHTTPTransport
    private let validator: CoursePlanValidator

    public init(
        settingsStore: AIReviewSettingsStore = AIReviewSettingsStore(),
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport(),
        validator: CoursePlanValidator = CoursePlanValidator()
    ) {
        self.settingsStore = settingsStore
        self.transport = transport
        self.validator = validator
    }

    public func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft {
        guard let settings = settingsStore.settings(),
              let apiKey = settingsStore.apiKey(),
              !apiKey.isEmpty
        else {
            throw CoursePlanningError.configurationRequired
        }
        return try await OpenAICompatibleCoursePlanningProvider(
            settings: settings,
            apiKey: apiKey,
            transport: transport,
            validator: validator
        ).makeDraft(input: input, context: context)
    }
}

private struct CoursePlanningRequest: Encodable {
    var input: CoursePlanningInput
    var context: CoursePlanningContext
}

private struct CoursePlanningResponse: Decodable, Sendable {
    var title: String
    var summary: String
    var phases: [CoursePlanDraftPhase]
    var sessions: [CoursePlanDraftSession]
    var assumptions: [String]
    var warnings: [String]

    var draft: CoursePlanDraft {
        CoursePlanDraft(
            title: title,
            summary: summary,
            phases: phases,
            sessions: sessions,
            assumptions: assumptions,
            warnings: warnings
        )
    }
}
