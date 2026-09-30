import Foundation

public enum CoursePlanningError: Error, Equatable, Sendable {
    case configurationRequired
    /// Activation remains possible after the learner explicitly acknowledges
    /// a deterministic weekly capacity warning.
    case capacityAcknowledgementRequired
    case invalidDraft([CoursePlanningValidationError])
    case providerUnavailable
    case projectMismatch
    case multipleActivePlans(UUID)
}

public protocol CoursePlanningProvider: Sendable {
    func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft

    /// Regenerates a single phase and its sessions. The caller splices the
    /// result into the draft with
    /// `CoursePlanDraftEditingService.replacingPhase`, so the output may only
    /// replace the target phase and its sessions.
    func regeneratePhase(
        input: CoursePlanningInput,
        context: CoursePlanningContext,
        phase: CoursePlanDraftPhase
    ) async throws -> CoursePlanPhaseRegeneration
}

/// A regenerated single phase plus its replacement sessions.
public struct CoursePlanPhaseRegeneration: Equatable, Sendable {
    public var phase: CoursePlanDraftPhase
    public var sessions: [CoursePlanDraftSession]

    public init(phase: CoursePlanDraftPhase, sessions: [CoursePlanDraftSession]) {
        self.phase = phase
        self.sessions = sessions
    }
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

    public func regeneratePhase(
        input: CoursePlanningInput,
        context: CoursePlanningContext,
        phase: CoursePlanDraftPhase
    ) async throws -> CoursePlanPhaseRegeneration {
        do {
            let response: CoursePhaseRegenerationResponse = try await client.completeJSON(
                system: Self.phaseRegenerationSystemPrompt,
                user: try Self.phaseRegenerationRequestPreview(
                    input: input,
                    context: context,
                    phase: phase,
                    model: model
                ).encodedText
            )
            let regeneration = response.regeneration
            // Reuse the validator's phase- and session-level rules on a
            // synthetic single-phase draft.
            let validation = validator.validate(
                CoursePlanDraft(
                    title: input.courseTitle,
                    summary: "",
                    phases: [regeneration.phase],
                    sessions: regeneration.sessions
                ),
                input: input
            )
            guard validation.isValid else {
                throw CoursePlanningError.invalidDraft(validation.errors)
            }
            return regeneration
        } catch let error as CoursePlanningError {
            throw error
        } catch {
            throw CoursePlanningError.providerUnavailable
        }
    }

    private static let phaseRegenerationSystemPrompt = """
    You regenerate one phase of a practical, editable personal Learning Plan. Return one JSON object with phase and sessions. Do not wrap the JSON in Markdown or add explanatory text. The phase needs string id, string title, string objective, string expectedProof, integer ordinal, targetStart, and targetEnd. Each session needs string id, string phaseID, string title, actionType, optional string expectedProof, integer durationMinutes, optional deadline, completionCriteria, and optional recommendationReason. actionType must be exactly "course" or "practice". All dates must be ISO-8601 UTC timestamps like "2026-08-12T14:30:00Z"; use null for an optional date instead of an empty string. completionCriteria must contain 1 to 5 observable string checks the learner can judge as done or not done (concrete behaviors or results, never vague outcomes like "understand the chapter"). Replace only the supplied phase; do not include any other phase or its sessions. Use only the supplied optional course outline, prerequisites, constraints, and learning context. Do not invent course-page content. Fit sessions within the provided weekly budget, preferred duration, and study period or deadline. Do not use or request calendar event content, contacts, location, or any data beyond the request.
    """

    private static func phaseRegenerationRequestBody(
        input: CoursePlanningInput,
        context: CoursePlanningContext,
        phase: CoursePlanDraftPhase
    ) throws -> String {
        let request = CoursePhaseRegenerationRequest(input: input, context: context, phase: phase)
        return String(decoding: try JSONEncoder.journal.encode(request), as: UTF8.self)
    }

    public static func phaseRegenerationRequestPreview(
        input: CoursePlanningInput,
        context: CoursePlanningContext,
        phase: CoursePlanDraftPhase,
        model: String
    ) throws -> AIRequestPackage {
        AIRequestPackage(
            encodedText: try phaseRegenerationRequestBody(input: input, context: context, phase: phase),
            artifacts: [],
            model: model,
            sourceMetadata: [
                "source": "course-planning-phase-regeneration",
                "courseText": "exact-user-supplied",
                "phase": "target-phase-only",
                "authorization": "one-request"
            ]
        )
    }

    private static let systemPrompt = """
    You create a practical, editable personal Learning Plan. Return one JSON object with title, summary, phases, sessions, assumptions, and warnings. Do not wrap the JSON in Markdown or add explanatory text. title and summary are strings; assumptions and warnings are arrays of strings. Each phase needs string id, string title, string objective, string expectedProof, integer ordinal, targetStart, and targetEnd. Each session needs string id, string phaseID, string title, actionType, optional string expectedProof, integer durationMinutes, optional deadline, completionCriteria, and optional recommendationReason. actionType must be exactly "course" or "practice". All dates must be ISO-8601 UTC timestamps like "2026-08-12T14:30:00Z"; use null for an optional date instead of an empty string. completionCriteria must contain 1 to 5 observable string checks the learner can judge as done or not done (concrete behaviors or results, never vague outcomes like "understand the chapter"). Use only the supplied optional course outline, prerequisites, constraints, and learning context. Do not invent course-page content. State an assumption whenever the supplied outline is incomplete. Fit sessions within the provided weekly budget, preferred duration, and study period or deadline. Do not use or request calendar event content, contacts, location, or any data beyond the request.
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

    public func regeneratePhase(
        input: CoursePlanningInput,
        context: CoursePlanningContext,
        phase: CoursePlanDraftPhase
    ) async throws -> CoursePlanPhaseRegeneration {
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
        ).regeneratePhase(input: input, context: context, phase: phase)
    }
}

private struct CoursePlanningRequest: Encodable {
    var input: CoursePlanningInput
    var context: CoursePlanningContext
}

private struct CoursePhaseRegenerationRequest: Encodable {
    var input: CoursePlanningInput
    var context: CoursePlanningContext
    var phase: CoursePlanDraftPhase
}

private struct CoursePhaseRegenerationResponse: Decodable, Sendable {
    var phase: CoursePlanDraftPhase
    var sessions: [CoursePlanDraftSession]

    /// Sessions are bound to the regenerated phase regardless of the id the
    /// provider echoed back.
    var regeneration: CoursePlanPhaseRegeneration {
        var boundSessions = sessions
        for index in boundSessions.indices {
            boundSessions[index].phaseID = phase.id
        }
        return CoursePlanPhaseRegeneration(phase: phase, sessions: boundSessions)
    }
}

private struct CoursePlanningResponse: Decodable, Sendable {
    var title: String
    var summary: String
    var phases: [CoursePlanDraftPhase]
    var sessions: [CoursePlanDraftSession]
    var assumptions: [String]
    var warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case title, summary, phases, sessions, assumptions, warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        phases = try container.decode([CoursePlanDraftPhase].self, forKey: .phases)
        sessions = try container.decode([CoursePlanDraftSession].self, forKey: .sessions)
        assumptions = try container.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

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
