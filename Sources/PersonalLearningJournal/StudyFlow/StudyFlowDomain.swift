import Foundation

/// Where draft content (completion checks, record drafts) originated.
public enum DraftSource: String, Codable, CaseIterable, Sendable {
    case ai
    case ruleBased
}

public enum CompletionProgress: String, Codable, CaseIterable, Sendable {
    case notStarted
    case partial
    case mostlyCompleted
    case completed
}

public enum UnderstandingLevel: String, Codable, CaseIterable, Sendable {
    case unclear
    case needsReview
    case mostlyUnderstood
    case canExplainOrApply
}

public struct CompletionCriterion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// AI (or rule-based fallback) generated completion check. The app owns the
/// question structure; providers only supply wording and criteria. All answer
/// state starts unselected — drafts never carry preselected answers.
public struct CompletionCheckDraft: Codable, Equatable, Sendable {
    public var activityTitle: String
    public var progressOptions: [CompletionProgress]
    public var criteria: [CompletionCriterion]
    public var asksUnderstanding: Bool
    public var asksBlocker: Bool
    public var source: DraftSource

    public init(
        activityTitle: String,
        progressOptions: [CompletionProgress],
        criteria: [CompletionCriterion],
        asksUnderstanding: Bool,
        asksBlocker: Bool,
        source: DraftSource
    ) {
        self.activityTitle = activityTitle
        self.progressOptions = progressOptions
        self.criteria = criteria
        self.asksUnderstanding = asksUnderstanding
        self.asksBlocker = asksBlocker
        self.source = source
    }
}

/// The user's answers to a completion check. Everything starts empty/unselected.
public struct CompletionCheckAnswers: Codable, Equatable, Sendable {
    public var progress: CompletionProgress?
    public var completedCriterionIDs: [String]
    public var understanding: UnderstandingLevel?
    public var blocker: String?

    public init(
        progress: CompletionProgress? = nil,
        completedCriterionIDs: [String] = [],
        understanding: UnderstandingLevel? = nil,
        blocker: String? = nil
    ) {
        self.progress = progress
        self.completedCriterionIDs = completedCriterionIDs
        self.understanding = understanding
        self.blocker = blocker
    }
}

public enum LearningRecordAdjustmentSignal: String, Codable, CaseIterable, Sendable {
    case none
    case ordinary
    case structural
}

/// Editable learning-record draft shown for confirmation. Generated in a later
/// task; until the user confirms, it is not a journal fact.
public struct LearningRecordDraft: Codable, Equatable, Sendable {
    public var summary: String
    public var result: String
    public var blockers: String
    public var suggestedNextStep: String?
    public var adjustmentSignal: LearningRecordAdjustmentSignal
    /// Why the provider raised its adjustment signal (spec 12.3). Optional so
    /// drafts persisted before this field existed still decode (as `nil`).
    public var rationale: String?
    public var source: DraftSource

    public init(
        summary: String,
        result: String,
        blockers: String,
        suggestedNextStep: String?,
        adjustmentSignal: LearningRecordAdjustmentSignal,
        rationale: String? = nil,
        source: DraftSource
    ) {
        self.summary = summary
        self.result = result
        self.blockers = blockers
        self.suggestedNextStep = suggestedNextStep
        self.adjustmentSignal = adjustmentSignal
        self.rationale = rationale
        self.source = source
    }
}

/// A device-local staged attachment reference. Never holds binary data and
/// never syncs; the staged file itself stays in local storage.
public struct PendingAttachmentReference: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ProofType
    public var localPath: String
    public var displayName: String
    public var fileSize: Int64?

    public init(
        id: UUID,
        kind: ProofType,
        localPath: String,
        displayName: String,
        fileSize: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.localPath = localPath
        self.displayName = displayName
        self.fileSize = fileSize
    }
}

/// Lifecycle of a pending study capture (spec 5.1):
///
///     active ⇄ paused → awaitingCheck → awaitingRecordConfirmation → confirmed
///
/// Auxiliary terminal/recovery states: `discarded`, `savedForLater`,
/// `recovered`. Nothing transitions to `confirmed` automatically; the
/// confirmation transaction (a later task) removes the capture on success.
public enum PendingStudyCaptureStage: String, Codable, CaseIterable, Sendable {
    case active
    case paused
    case awaitingCheck
    case awaitingRecordConfirmation
    case confirmed
    case discarded
    case savedForLater
    case recovered

    /// Terminal captures no longer represent unresolved guided work. The
    /// journal confirmation path removes confirmed captures after its commit,
    /// while discarded captures remain only as an explicit local tombstone.
    public var isTerminal: Bool {
        self == .confirmed || self == .discarded
    }
}

/// Device-local, recoverable, deletable working draft of a study session that
/// has not been confirmed yet. It is NOT part of `JournalSnapshot`, never
/// exports, and never enters the CloudKit outbox.
public struct PendingStudyCapture: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var plannedSessionID: UUID?
    public var source: SessionSource
    public var stage: PendingStudyCaptureStage
    public var startedAt: Date
    public var endedAt: Date?
    public var activeDurationSeconds: Int
    /// Last time the timer was (re)started. Informational; callers hold the
    /// running elapsed value and persist it via pause/end/checkpoint.
    public var lastResumedAt: Date?
    public var checkDraft: CompletionCheckDraft?
    public var answers: CompletionCheckAnswers
    public var recordDraft: LearningRecordDraft?
    public var stagedAttachments: [PendingAttachmentReference]
    public var updatedAt: Date

    public init(
        id: UUID,
        projectID: UUID,
        plannedSessionID: UUID? = nil,
        source: SessionSource,
        stage: PendingStudyCaptureStage = .active,
        startedAt: Date,
        endedAt: Date? = nil,
        activeDurationSeconds: Int = 0,
        lastResumedAt: Date? = nil,
        checkDraft: CompletionCheckDraft? = nil,
        answers: CompletionCheckAnswers = CompletionCheckAnswers(),
        recordDraft: LearningRecordDraft? = nil,
        stagedAttachments: [PendingAttachmentReference] = [],
        updatedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.plannedSessionID = plannedSessionID
        self.source = source
        self.stage = stage
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationSeconds = activeDurationSeconds
        self.lastResumedAt = lastResumedAt
        self.checkDraft = checkDraft
        self.answers = answers
        self.recordDraft = recordDraft
        self.stagedAttachments = stagedAttachments
        self.updatedAt = updatedAt
    }
}

public enum PendingStudyCaptureError: Error, Equatable, Sendable {
    case captureNotFound(UUID)
    case activeCaptureAlreadyExists(UUID)
    case illegalTransition(from: PendingStudyCaptureStage, to: PendingStudyCaptureStage)
}

extension PendingStudyCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .captureNotFound(id):
            return "No pending study capture exists with id \(id.uuidString)."
        case let .activeCaptureAlreadyExists(id):
            return "Capture \(id.uuidString) already occupies the study timer. End, save, or discard it before starting a new one."
        case let .illegalTransition(from, to):
            return "A pending study capture cannot move from \(from.rawValue) to \(to.rawValue)."
        }
    }
}
