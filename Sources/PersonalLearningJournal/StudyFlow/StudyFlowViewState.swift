import Foundation

/// Identity of the pending capture a study-flow screen is bound to.
public struct StudyFlowContext: Equatable, Sendable {
    public var captureID: UUID
    public var projectID: UUID
    public var plannedSessionID: UUID?

    public init(captureID: UUID, projectID: UUID, plannedSessionID: UUID? = nil) {
        self.captureID = captureID
        self.projectID = projectID
        self.plannedSessionID = plannedSessionID
    }
}

/// View-level state machine for the guided study flow (spec 5.1, 9). Mirrors
/// the pending-capture stages so a view never has to inspect the store to
/// know which screen to show. Terminal UI states (`completed`, `failed`) have
/// no store counterpart: confirmation removes the capture, and a failure
/// leaves it untouched for retry.
public enum StudyFlowViewState: Equatable, Sendable {
    case idle
    case active(StudyFlowContext)
    case paused(StudyFlowContext)
    case awaitingCheck(StudyFlowContext)
    case awaitingRecordConfirmation(StudyFlowContext)
    case completed(sessionID: UUID)
    indirect case failed(message: String, returnTo: StudyFlowViewState)

    public var context: StudyFlowContext? {
        switch self {
        case let .active(context), let .paused(context),
             let .awaitingCheck(context), let .awaitingRecordConfirmation(context):
            return context
        case let .failed(_, returnTo):
            return returnTo.context
        case .idle, .completed:
            return nil
        }
    }

    public var captureID: UUID? { context?.captureID }
    public var projectID: UUID? { context?.projectID }
    public var plannedSessionID: UUID? { context?.plannedSessionID }

    /// A running or paused timer owns the single timer slot, so the sheet may
    /// not be swipe-dismissed into a phantom running capture: leaving requires
    /// an explicit end, save, or discard.
    public var requiresExplicitExit: Bool {
        switch self {
        case .active, .paused:
            return true
        case .idle, .awaitingCheck, .awaitingRecordConfirmation, .completed, .failed:
            return false
        }
    }

    /// Dynamic Type layout switch (spec 16): at accessibility text sizes the
    /// flow's cards stack their actions vertically instead of side by side.
    public static func prefersVerticalLayout(isAccessibilitySize: Bool) -> Bool {
        isAccessibilitySize
    }
}

/// Events the views send into the flow. The reducer only maps state; the
/// controller performs the matching store/service calls in the same order.
public enum StudyFlowEvent: Equatable, Sendable {
    case begin(StudyFlowContext)
    case pause
    case resume
    case end
    case checkDraftAttached
    case answersSubmitted
    case recordDraftAttached
    case backToCheck
    case confirmSucceeded(sessionID: UUID)
    case confirmFailed(message: String)
    case saveForLater
    case discard
    case dismiss
    /// Reopens a persisted capture. `stage` is the capture's CURRENT store
    /// stage; `savedForLater` and terminal stages are rejected here — the
    /// controller resolves `savedForLater` through the store first.
    case reopen(StudyFlowContext, stage: PendingStudyCaptureStage)
}

public enum StudyFlowViewStateError: Error, Equatable, Sendable {
    /// The reducer refuses to emit a state that has no legal store
    /// transition, so the controller can never drive the store into
    /// `PendingStudyCaptureError.illegalTransition`.
    case illegalTransition(event: StudyFlowEvent, state: StudyFlowViewState)
}

public enum StudyFlowReducer {
    /// Maps an event to the next view state, or throws `illegalTransition`
    /// when the event has no legal `PendingStudyCaptureStore` counterpart.
    /// Events that leave the store stage unchanged (`checkDraftAttached`,
    /// `answersSubmitted`) keep the current state.
    public static func reduce(
        state: StudyFlowViewState,
        event: StudyFlowEvent
    ) throws -> StudyFlowViewState {
        switch (state, event) {
        case let (.idle, .begin(context)):
            return .active(context)

        case let (.active(context), .pause):
            return .paused(context)
        case let (.paused(context), .resume):
            return .active(context)
        case let (.active(context), .end), let (.paused(context), .end):
            return .awaitingCheck(context)

        case let (.awaitingCheck(context), .checkDraftAttached):
            return .awaitingCheck(context)
        case let (.awaitingCheck(context), .answersSubmitted):
            return .awaitingCheck(context)
        case let (.awaitingRecordConfirmation(context), .answersSubmitted):
            return .awaitingRecordConfirmation(context)
        case let (.awaitingCheck(context), .recordDraftAttached):
            return .awaitingRecordConfirmation(context)
        case let (.awaitingRecordConfirmation(context), .recordDraftAttached):
            return .awaitingRecordConfirmation(context)
        case let (.awaitingRecordConfirmation(context), .backToCheck):
            return .awaitingCheck(context)

        case let (.awaitingRecordConfirmation, .confirmSucceeded(sessionID)):
            return .completed(sessionID: sessionID)
        case let (.awaitingRecordConfirmation(context), .confirmFailed(message)):
            return .failed(message: message, returnTo: .awaitingRecordConfirmation(context))

        case (.awaitingCheck, .saveForLater), (.awaitingRecordConfirmation, .saveForLater):
            return .idle
        case (.active, .discard), (.paused, .discard),
             (.awaitingCheck, .discard), (.awaitingRecordConfirmation, .discard):
            return .idle
        case (_, .dismiss):
            return .idle

        case let (.idle, .reopen(context, stage)):
            switch stage {
            case .awaitingCheck:
                return .awaitingCheck(context)
            case .awaitingRecordConfirmation:
                return .awaitingRecordConfirmation(context)
            case .paused:
                return .paused(context)
            case .active, .recovered:
                return .active(context)
            case .savedForLater, .confirmed, .discarded:
                throw StudyFlowViewStateError.illegalTransition(event: event, state: state)
            }

        default:
            throw StudyFlowViewStateError.illegalTransition(event: event, state: state)
        }
    }
}

/// Text labels for the study flow. Progress, understanding, draft-source, and
/// status labels are always real text so VoiceOver reads them and color is
/// never the only signal (spec 16).
public enum StudyFlowCopy {
    public static func progressTitle(_ progress: CompletionProgress) -> String {
        switch progress {
        case .notStarted: String(localized: "study_flow.progress.not_started")
        case .partial: String(localized: "study_flow.progress.partial")
        case .mostlyCompleted: String(localized: "study_flow.progress.mostly_completed")
        case .completed: String(localized: "study_flow.progress.completed")
        }
    }

    public static func understandingTitle(_ level: UnderstandingLevel) -> String {
        switch level {
        case .unclear: String(localized: "study_flow.understanding.unclear")
        case .needsReview: String(localized: "study_flow.understanding.needs_review")
        case .mostlyUnderstood: String(localized: "study_flow.understanding.mostly_understood")
        case .canExplainOrApply: String(localized: "study_flow.understanding.can_explain_or_apply")
        }
    }

    public static func draftSourceTitle(_ source: DraftSource) -> String {
        switch source {
        case .ai: String(localized: "study_flow.source.ai")
        case .ruleBased: String(localized: "study_flow.source.rule_based")
        }
    }

    public static func adjustmentSignalTitle(_ signal: LearningRecordAdjustmentSignal) -> String {
        switch signal {
        case .none: String(localized: "study_flow.signal.none")
        case .ordinary: String(localized: "study_flow.signal.ordinary")
        case .structural: String(localized: "study_flow.signal.structural")
        }
    }

    public static var confirmedStatusTitle: String {
        String(localized: "study_flow.status.confirmed")
    }

    public static var amendedStatusTitle: String {
        String(localized: "study_flow.status.amended")
    }

    public static func pendingStageTitle(_ stage: PendingStudyCaptureStage) -> String {
        switch stage {
        case .active, .paused, .recovered:
            String(localized: "study_flow.stage.timer")
        case .awaitingCheck:
            String(localized: "study_flow.stage.awaiting_check")
        case .awaitingRecordConfirmation:
            String(localized: "study_flow.stage.awaiting_record")
        case .savedForLater:
            String(localized: "study_flow.stage.saved_for_later")
        case .confirmed, .discarded:
            stage.rawValue
        }
    }
}
