import Foundation

public enum LearningRecordDraftError: Error, Equatable, Sendable {
    /// The provider could not produce a usable record draft (configuration,
    /// transport, parse, or validation failure). Callers fall back to the
    /// rule-based provider.
    case providerUnavailable
}

/// Everything a learning-record-draft provider may see (spec 12.3): the
/// activity title, the timer facts, the user's completion-check answers, the
/// texts of the check criteria (keyed by ID), staged attachment METADATA
/// (never content), and the current Next Step. Nothing else may be sent — no
/// other courses, no calendar, contacts, location, or attachment content.
public struct LearningRecordDraftInput: Equatable, Sendable, Encodable {
    public var activityTitle: String
    public var startedAt: Date
    public var endedAt: Date?
    public var activeDurationSeconds: Int
    public var answers: CompletionCheckAnswers
    /// Every criterion from the check draft, keyed by criterion ID. Providers
    /// may only reference criteria the user actually selected
    /// (`answers.completedCriterionIDs`).
    public var criteriaByID: [String: String]
    /// Staged attachment references. `PendingAttachmentReference` holds only
    /// metadata (kind, local path, display name, size) — never binary content.
    public var attachments: [PendingAttachmentReference]
    public var currentNextStep: String

    public init(
        activityTitle: String,
        startedAt: Date,
        endedAt: Date?,
        activeDurationSeconds: Int,
        answers: CompletionCheckAnswers,
        criteriaByID: [String: String],
        attachments: [PendingAttachmentReference],
        currentNextStep: String
    ) {
        self.activityTitle = activityTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationSeconds = activeDurationSeconds
        self.answers = answers
        self.criteriaByID = criteriaByID
        self.attachments = attachments
        self.currentNextStep = currentNextStep
    }

    /// Builds the provider input from a capture's own facts. Only timer
    /// facts, answers, criterion texts, attachment metadata, and the supplied
    /// current Next Step cross the boundary.
    public init(
        capture: PendingStudyCapture,
        activityTitle: String,
        currentNextStep: String
    ) {
        self.init(
            activityTitle: activityTitle,
            startedAt: capture.startedAt,
            endedAt: capture.endedAt,
            activeDurationSeconds: capture.activeDurationSeconds,
            answers: capture.answers,
            criteriaByID: Dictionary(
                uniqueKeysWithValues: (capture.checkDraft?.criteria ?? []).map { ($0.id, $0.text) }
            ),
            attachments: capture.stagedAttachments,
            currentNextStep: currentNextStep
        )
    }
}

public protocol LearningRecordDraftProvider: Sendable {
    func makeRecordDraft(input: LearningRecordDraftInput) async throws -> LearningRecordDraft
}

/// String sanitizing shared by providers: trims whitespace; whitespace-only
/// optionals become `nil`.
enum LearningRecordDraftSanitizer {
    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func trimToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = trim(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Deterministic fallback: composes a readable summary strictly from facts —
/// the progress selection, the SELECTED criterion texts only, understanding
/// if answered, the blocker if provided, and the active duration. It never
/// infers completion of items the user did not select, never invents
/// outcomes (`result` stays empty for the user to fill), and never proposes
/// plan changes (signal `.none`, no next-step suggestion — those come from
/// the adjustment service).
public struct RuleBasedLearningRecordDraftProvider: LearningRecordDraftProvider {
    public init() {}

    public func makeRecordDraft(input: LearningRecordDraftInput) async throws -> LearningRecordDraft {
        let answers = input.answers

        var opening = "Studied \(input.activityTitle)"
        if let duration = Self.durationPhrase(seconds: input.activeDurationSeconds) {
            opening += " for \(duration)"
        }
        var sentences = [opening + "."]

        if let progress = answers.progress {
            sentences.append("Progress: \(Self.progressPhrase(progress)).")
        }
        let completed = answers.completedCriterionIDs.compactMap { input.criteriaByID[$0] }
        if !completed.isEmpty {
            sentences.append("Completed: \(completed.joined(separator: "; ")).")
        }
        if let understanding = answers.understanding {
            sentences.append("Understanding: \(Self.understandingPhrase(understanding)).")
        }
        let blocker = LearningRecordDraftSanitizer.trim(answers.blocker ?? "")
        if !blocker.isEmpty {
            sentences.append("Blocker: \(blocker).")
        }

        return LearningRecordDraft(
            summary: sentences.joined(separator: " "),
            result: "",
            blockers: blocker,
            suggestedNextStep: nil,
            adjustmentSignal: .none,
            source: .ruleBased
        )
    }

    static func durationPhrase(seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        let minutes = seconds / 60
        guard minutes >= 1 else { return "\(seconds) seconds" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func progressPhrase(_ progress: CompletionProgress) -> String {
        switch progress {
        case .notStarted: return "not started"
        case .partial: return "partially completed"
        case .mostlyCompleted: return "mostly completed"
        case .completed: return "completed"
        }
    }

    static func understandingPhrase(_ understanding: UnderstandingLevel) -> String {
        switch understanding {
        case .unclear: return "unclear"
        case .needsReview: return "needs review"
        case .mostlyUnderstood: return "mostly understood"
        case .canExplainOrApply: return "can explain or apply"
        }
    }
}

public struct OpenAICompatibleLearningRecordDraftProvider: LearningRecordDraftProvider {
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

    public func makeRecordDraft(input: LearningRecordDraftInput) async throws -> LearningRecordDraft {
        do {
            // Strict decoding: an adjustmentSignal outside the enum fails
            // decoding and becomes .providerUnavailable, so the adaptive
            // provider falls back instead of trusting the draft.
            let response: LearningRecordDraftResponse = try await client.completeJSON(
                system: Self.systemPrompt,
                user: try Self.requestPreview(input: input, model: model).encodedText
            )
            let summary = LearningRecordDraftSanitizer.trim(response.summary)
            guard !summary.isEmpty else {
                throw LearningRecordDraftError.providerUnavailable
            }
            return LearningRecordDraft(
                summary: summary,
                result: LearningRecordDraftSanitizer.trim(response.result),
                blockers: LearningRecordDraftSanitizer.trim(response.blockers),
                suggestedNextStep: LearningRecordDraftSanitizer.trimToNil(response.suggestedNextStep),
                adjustmentSignal: response.adjustmentSignal,
                rationale: LearningRecordDraftSanitizer.trimToNil(response.rationale),
                source: .ai
            )
        } catch let error as LearningRecordDraftError {
            throw error
        } catch {
            throw LearningRecordDraftError.providerUnavailable
        }
    }

    private static let systemPrompt = """
    You draft an editable learning record for a personal study session from timer facts, the learner's completion-check answers, staged attachment metadata (never content), and the current next step. Return only a JSON object of the form {"summary": "...", "result": "...", "blockers": "...", "suggestedNextStep": "..." or null, "adjustmentSignal": "none" | "ordinary" | "structural", "rationale": "..." or null}. The summary must describe only what the learner reported: their progress selection, the check items they selected as done, their understanding, and their blocker. Never claim completion of items the learner did not select, never invent outcomes, and never change any plan. adjustmentSignal is "none" unless the record clearly motivates an adjustment; "ordinary" for small next-step tweaks, "structural" only for plan reshaping, with a short rationale when not "none". Do not use or request calendar event content, contacts, location, attachment content, or any data beyond the request.
    """

    public static func requestPreview(
        input: LearningRecordDraftInput,
        model: String
    ) throws -> AIRequestPackage {
        AIRequestPackage(
            encodedText: String(decoding: try JSONEncoder.journal.encode(input), as: UTF8.self),
            artifacts: [],
            model: model,
            sourceMetadata: [
                "source": "learning-record-draft",
                "input": "capture-facts-only",
                "authorization": "one-request"
            ]
        )
    }
}

/// Prefers the AI provider when configured; on missing configuration or ANY
/// provider failure (transport, parse, invalid output) returns the
/// deterministic rule-based draft marked `source = .ruleBased`. Never throws
/// for provider failure.
public struct AdaptiveLearningRecordDraftProvider: LearningRecordDraftProvider {
    private let settingsStore: AIReviewSettingsStore
    private let transport: any AIHTTPTransport
    private let fallback: any LearningRecordDraftProvider

    public init(
        settingsStore: AIReviewSettingsStore = AIReviewSettingsStore(),
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport(),
        fallback: any LearningRecordDraftProvider = RuleBasedLearningRecordDraftProvider()
    ) {
        self.settingsStore = settingsStore
        self.transport = transport
        self.fallback = fallback
    }

    public func makeRecordDraft(input: LearningRecordDraftInput) async throws -> LearningRecordDraft {
        guard let settings = settingsStore.settings(),
              let apiKey = settingsStore.apiKey(),
              !apiKey.isEmpty
        else {
            return try await fallback.makeRecordDraft(input: input)
        }

        do {
            return try await OpenAICompatibleLearningRecordDraftProvider(
                settings: settings,
                apiKey: apiKey,
                transport: transport
            ).makeRecordDraft(input: input)
        } catch {
            return try await fallback.makeRecordDraft(input: input)
        }
    }
}

/// Thin orchestration between a draft provider and the pending-capture store.
/// Drafts are written ONLY to `PendingStudyCaptureStore` as editable,
/// unconfirmed working state — never to the journal.
public struct LearningRecordDraftGenerator: Sendable {
    private let provider: any LearningRecordDraftProvider

    public init(provider: any LearningRecordDraftProvider = AdaptiveLearningRecordDraftProvider()) {
        self.provider = provider
    }

    public func makeDraft(input: LearningRecordDraftInput) async throws -> LearningRecordDraft {
        try await provider.makeRecordDraft(input: input)
    }

    @discardableResult
    public func generateAndAttach(
        captureID: UUID,
        input: LearningRecordDraftInput,
        store: PendingStudyCaptureStore
    ) async throws -> PendingStudyCapture {
        let draft = try await provider.makeRecordDraft(input: input)
        return try store.attachRecordDraft(id: captureID, draft: draft)
    }
}

private struct LearningRecordDraftResponse: Decodable, Sendable {
    var summary: String
    var result: String
    var blockers: String
    var suggestedNextStep: String?
    var adjustmentSignal: LearningRecordAdjustmentSignal
    var rationale: String?
}
