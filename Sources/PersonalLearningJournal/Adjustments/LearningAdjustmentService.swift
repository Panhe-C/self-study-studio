import Foundation

public enum LearningAdjustmentError: Error, Equatable, Sendable {
    case missingSuggestion
    case missingProject
    case alreadyDecided
    case emptyProposedValue
    case notStructuralSuggestion
    case structuralRevisionRequiresDraftActivation
    case revisionNotActivated
    case missingActivePlan
    case planningUnavailable
    case invalidStructuralChange
    case commandKindMismatch(expected: LearningAdjustmentKind, actual: LearningAdjustmentKind)
    case invalidCommandTarget
}

extension LearningAdjustmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingSuggestion:
            return String(localized: "adjustment.error.missing_suggestion")
        case .missingProject:
            return String(localized: "adjustment.error.missing_project")
        case .alreadyDecided:
            return String(localized: "adjustment.error.already_decided")
        case .emptyProposedValue:
            return String(localized: "adjustment.error.empty_proposed_value")
        case .notStructuralSuggestion:
            return String(localized: "adjustment.error.not_structural")
        case .structuralRevisionRequiresDraftActivation:
            return String(localized: "adjustment.error.requires_activation")
        case .revisionNotActivated:
            return String(localized: "adjustment.error.revision_not_activated")
        case .missingActivePlan:
            return String(localized: "adjustment.error.missing_active_plan")
        case .planningUnavailable:
            return String(localized: "adjustment.error.planning_unavailable")
        case .invalidStructuralChange:
            return String(localized: "adjustment.error.invalid_structural")
        case let .commandKindMismatch(expected, actual):
            return String(
                format: String(localized: "adjustment.error.command_kind_mismatch"),
                expected.rawValue,
                actual.rawValue
            )
        case .invalidCommandTarget:
            return String(localized: "adjustment.error.invalid_command_target")
        }
    }
}

/// Typed adoption targets. `proposedValue` stays human-readable; machine
/// routing never parses it. The UI supplies the concrete target the user
/// picked, and the service applies it through the canonical command in the
/// same transaction as the decision.
public struct RescheduleAdoptionTarget: Codable, Equatable, Sendable {
    public var plannedSessionID: UUID
    public var newDeadline: Date
    public var capacityAcknowledged: Bool

    public init(plannedSessionID: UUID, newDeadline: Date, capacityAcknowledged: Bool = false) {
        self.plannedSessionID = plannedSessionID
        self.newDeadline = newDeadline
        self.capacityAcknowledged = capacityAcknowledged
    }
}

public struct TemporaryDurationAdoptionTarget: Codable, Equatable, Sendable {
    public var plannedSessionID: UUID
    public var minutes: Int

    public init(plannedSessionID: UUID, minutes: Int) {
        self.plannedSessionID = plannedSessionID
        self.minutes = minutes
    }
}

/// Concrete target supplied by the user when adopting a day-scoped ordering
/// suggestion. Today overrides remain local-only, but the decision itself is
/// journaled only after this complete target has been validated.
public struct DailyOrderAdoptionTarget: Codable, Equatable, Sendable {
    public var day: Date
    public var source: TodayAgendaSource
    public var sourceID: UUID
    public var position: TodayAgendaPosition

    public init(
        day: Date,
        source: TodayAgendaSource,
        sourceID: UUID,
        position: TodayAgendaPosition
    ) {
        self.day = day
        self.source = source
        self.sourceID = sourceID
        self.position = position
    }

    public var overrideValue: TodayAgendaOverride {
        TodayAgendaOverride(day: day, source: source, sourceID: sourceID, position: position)
    }
}

/// The only commands accepted by ordinary adjustment adoption. Associated
/// values make it impossible to accidentally pass a reschedule target for a
/// duration suggestion (or silently omit the required day/session/minutes).
public enum LearningAdjustmentCommand: Codable, Equatable, Sendable {
    case nextStep(value: String)
    case dailyOrder(target: DailyOrderAdoptionTarget)
    case reschedule(target: RescheduleAdoptionTarget)
    case temporaryDuration(target: TemporaryDurationAdoptionTarget)
    /// Structural suggestions are prepared and activated through the revision
    /// flow, never through ordinary adoption. The case documents that boundary
    /// for callers without giving it a direct mutation path.
    case structuralRevision(draftID: UUID)

    public var kind: LearningAdjustmentKind {
        switch self {
        case .nextStep: return .nextStep
        case .dailyOrder: return .dailyOrder
        case .reschedule: return .reschedule
        case .temporaryDuration: return .temporaryDuration
        case .structuralRevision: return .structuralRevision
        }
    }

    fileprivate var proposedValue: String? {
        switch self {
        case let .nextStep(value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .dailyOrder(target):
            return "\(target.position.rawValue) on \(JournalISO8601Codec.string(from: target.day))"
        case let .reschedule(target):
            return "Reschedule \(target.plannedSessionID.uuidString) to \(JournalISO8601Codec.string(from: target.newDeadline))"
        case let .temporaryDuration(target):
            return "Use \(target.minutes) minutes for \(target.plannedSessionID.uuidString)"
        case let .structuralRevision(draftID):
            return "Plan revision draft \(draftID.uuidString)"
        }
    }
}

/// Reviewable learning adjustments (spec 11, 12.4).
///
/// Detection is rule-based, explicit, and reads ONLY confirmed records
/// (sessions with an `assessment`, not deleted). It never runs automatically
/// on confirm; callers trigger it from a user request (spec 11.1).
/// `recordConfirmedAndDetect` is a thin convenience for the post-confirm
/// "check for adjustments" request.
///
/// Decision routing:
/// - `.nextStep` — canonical Next Step command semantics (mirrors
///   `JournalService`: project update + `.nextStepChange` trail), one commit.
/// - `.dailyOrder` — day-scoped Today overrides are intentionally not journal
///   records, so the caller (JournalViewModel) applies the in-memory override
///   FIRST and the adoption transaction persists only the decision.
/// - `.reschedule` — requires a typed `RescheduleAdoptionTarget`; applied via
///   `CoursePlanningService.reschedule`, which folds the decided suggestion
///   into its single transaction.
/// - `.temporaryDuration` — requires a typed `TemporaryDurationAdoptionTarget`.
///   The selected minutes are persisted as an execution-only command; the
///   active plan's structurally locked duration remains unchanged.
/// - `.structuralRevision` — adoption is impossible without activation.
///   `prepareStructuralDraft` goes through `CoursePlanningService.revise`
///   (base stays active, decision stays `.pending`); after the user activates
///   the revision through the existing activation path, the UI calls
///   `markAdoptedAfterActivation`.
public final class LearningAdjustmentService {
    /// Rule thresholds, kept as named constants so detection stays auditable.
    public static let minimumRepeats = 2
    public static let phaseWindowRiskDays = 3
    /// A phase window shortfall is structural when MORE than half of the
    /// phase's sessions are still incomplete.
    public static let structuralShortfallRatio = 0.5

    private let repository: any JournalRepository
    private let planningService: CoursePlanningService?
    private let now: () -> Date

    public init(
        repository: any JournalRepository,
        planningService: CoursePlanningService? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.planningService = planningService
        self.now = now
    }

    // MARK: - Reading

    public func suggestions(for projectID: UUID) throws -> [LearningAdjustmentSuggestion] {
        try repository.snapshot().learningAdjustmentSuggestions
            .filter { $0.projectID == projectID && $0.deletedAt == nil }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    public func suggestion(id: UUID) throws -> LearningAdjustmentSuggestion {
        guard let suggestion = try repository.snapshot().learningAdjustmentSuggestions
            .first(where: { $0.id == id && $0.deletedAt == nil }) else {
            throw LearningAdjustmentError.missingSuggestion
        }
        return suggestion
    }

    // MARK: - Detection (spec 11.1, confirmed records only)

    /// Thin convenience for the post-confirm adjustment request. Detection
    /// stays callable standalone; nothing runs automatically on confirm.
    @discardableResult
    public func recordConfirmedAndDetect(projectID: UUID) throws -> [LearningAdjustmentSuggestion] {
        try detectSuggestions(projectID: projectID)
    }

    /// Runs the three deterministic detectors and persists newly found
    /// pending suggestions in one transaction. An equivalent pending
    /// suggestion (same project + kind + title) is never duplicated.
    @discardableResult
    public func detectSuggestions(projectID: UUID) throws -> [LearningAdjustmentSuggestion] {
        let snapshot = try repository.snapshot()
        let timestamp = now()
        let drafts = detectedDrafts(snapshot: snapshot, projectID: projectID, now: timestamp)
        // Keep rule-based and AI persistence on the same normalization and
        // batch-deduplication path. This prevents a detector refactor from
        // reintroducing a second, subtly different write implementation.
        return try persistSuggestions(drafts, projectID: projectID)
    }

    /// Pure detector seam used by the offline provider. Keeping detection
    /// separate from persistence ensures a provider fallback can be composed
    /// with `persistSuggestions` without writing the same batch twice or
    /// returning an empty result after the first write.
    private func detectedDrafts(
        snapshot: JournalSnapshot,
        projectID: UUID,
        now: Date
    ) -> [LearningAdjustmentSuggestionDraft] {
        var drafts = repeatedPartialDrafts(snapshot: snapshot, projectID: projectID)
            + repeatedBlockerDrafts(snapshot: snapshot, projectID: projectID)
        if let phaseRisk = phaseWindowRiskDraft(snapshot: snapshot, projectID: projectID, now: now) {
            drafts.append(phaseRisk)
        }
        return drafts
    }

    /// Rule (a): the same planned activity ends `.partial` in at least
    /// `minimumRepeats` consecutive confirmed records. Only records linked to
    /// a planned session (via `PlannedSession.completedSessionId`) carry an
    /// activity identity; manual records without that link never trigger this
    /// rule. Progress `.partial` only — a `.notStarted` record is a different
    /// signal and `.mostlyCompleted` is not a stall.
    private func repeatedPartialDrafts(
        snapshot: JournalSnapshot,
        projectID: UUID
    ) -> [LearningAdjustmentSuggestionDraft] {
        let confirmed = confirmedSessions(snapshot: snapshot, projectID: projectID)
        let plannedByCompletedSession = Dictionary(
            uniqueKeysWithValues: snapshot.plannedSessions
                .filter { $0.deletedAt == nil && $0.completedSessionId != nil }
                .map { ($0.completedSessionId!, $0) }
        )
        var sessionsByActivity: [String: [(title: String, session: LearningSession)]] = [:]
        for session in confirmed {
            guard let planned = plannedByCompletedSession[session.id] else { continue }
            let key = normalize(planned.title)
            sessionsByActivity[key, default: []].append((planned.title, session))
        }

        var drafts: [LearningAdjustmentSuggestionDraft] = []
        for (_, entries) in sessionsByActivity {
            let ordered = entries.sorted {
                ($0.session.assessment?.confirmedAt ?? .distantPast, $0.session.id.uuidString)
                    < ($1.session.assessment?.confirmedAt ?? .distantPast, $1.session.id.uuidString)
            }
            var trailing: [(title: String, session: LearningSession)] = []
            for entry in ordered.reversed() {
                guard entry.session.assessment?.progress == .partial else { break }
                trailing.append(entry)
            }
            guard trailing.count >= Self.minimumRepeats, let latest = trailing.first else { continue }
            let run = trailing.reversed()
            drafts.append(LearningAdjustmentSuggestionDraft(
                kind: .nextStep,
                title: "Repeated partial progress on \(latest.title)",
                rationale: "The last \(trailing.count) confirmed records for \"\(latest.title)\" ended partially.",
                proposedValue: "Review \"\(latest.title)\" and split it into a smaller checkpoint",
                sourceSessionIDs: run.map(\.session.id)
            ))
        }
        return drafts.sorted { $0.title < $1.title }
    }

    /// Rule (b): the trailing run of confirmed records shares the same
    /// trimmed, non-empty blocker (case-insensitive). Documented choice: this
    /// maps to `.nextStep` proposing a blocker-resolution step, because the
    /// canonical Next Step command is the safe executable action;
    /// `.temporaryDuration` remains available for user- or AI-initiated
    /// requests.
    private func repeatedBlockerDrafts(
        snapshot: JournalSnapshot,
        projectID: UUID
    ) -> [LearningAdjustmentSuggestionDraft] {
        let confirmed = confirmedSessions(snapshot: snapshot, projectID: projectID)
        var trailing: [(blocker: String, session: LearningSession)] = []
        for session in confirmed.reversed() {
            guard let blocker = session.assessment?.blocker?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !blocker.isEmpty else { break }
            if let last = trailing.last, last.blocker.lowercased() != blocker.lowercased() {
                break
            }
            trailing.append((blocker, session))
        }
        guard trailing.count >= Self.minimumRepeats, let latest = trailing.first else { return [] }
        return [LearningAdjustmentSuggestionDraft(
            kind: .nextStep,
            title: "Repeated blocker: \(latest.blocker)",
            rationale: "The last \(trailing.count) confirmed records hit the same blocker.",
            proposedValue: "Resolve blocker: \(latest.blocker)",
            sourceSessionIDs: trailing.reversed().map(\.session.id)
        )]
    }

    /// Rule (c): the current phase's target window ends within
    /// `phaseWindowRiskDays` (or already passed) with incomplete sessions
    /// remaining. More than half incomplete is a structural shortfall;
    /// otherwise a reschedule is enough.
    private func phaseWindowRiskDraft(
        snapshot: JournalSnapshot,
        projectID: UUID,
        now: Date
    ) -> LearningAdjustmentSuggestionDraft? {
        guard let activePlan = snapshot.coursePlans.first(where: {
            $0.projectId == projectID && $0.status == .active && $0.deletedAt == nil
        }) else { return nil }
        let phases = snapshot.planPhases
            .filter { $0.planId == activePlan.id && $0.deletedAt == nil }
            .sorted { $0.ordinal < $1.ordinal }
        guard let currentPhase = phases.first(where: { $0.progress == .active })
            ?? phases.first(where: { ![.completed, .abandoned].contains($0.progress) }) else {
            return nil
        }
        let riskHorizon = now.addingTimeInterval(TimeInterval(Self.phaseWindowRiskDays * 86_400))
        guard currentPhase.targetEnd <= riskHorizon else { return nil }

        let phaseSessions = snapshot.plannedSessions
            .filter { $0.phaseId == currentPhase.id && $0.deletedAt == nil }
        let incomplete = phaseSessions.filter {
            $0.status == .unscheduled || $0.status == .scheduled
        }
        guard !incomplete.isEmpty, !phaseSessions.isEmpty else { return nil }

        let isStructural = Double(incomplete.count) / Double(phaseSessions.count)
            > Self.structuralShortfallRatio
        let sourceIDs = confirmedSessions(snapshot: snapshot, projectID: projectID)
            .filter { session in
                phaseSessions.contains { $0.completedSessionId == session.id }
            }
            .suffix(3)
            .map(\.id)
        let deadlineText = JournalISO8601Codec.string(from: currentPhase.targetEnd)
        if isStructural {
            return LearningAdjustmentSuggestionDraft(
                kind: .structuralRevision,
                title: "Phase \"\(currentPhase.title)\" needs structural revision",
                rationale: "\(incomplete.count) of \(phaseSessions.count) sessions in \"\(currentPhase.title)\" are incomplete while its window closes.",
                proposedValue: "Revise the plan for \"\(currentPhase.title)\": \(incomplete.count) of \(phaseSessions.count) sessions remain as the phase window closes (\(deadlineText)).",
                sourceSessionIDs: sourceIDs,
                structuralChange: LearningAdjustmentStructuralChange(
                    weeklyBudgetMinutes: activePlan.weeklyBudgetMinutes + 15,
                    phaseID: currentPhase.id,
                    phaseObjective: "Add a recovery checkpoint to \(currentPhase.objective)"
                )
            )
        }
        return LearningAdjustmentSuggestionDraft(
            kind: .reschedule,
            title: "Phase \"\(currentPhase.title)\" window closes soon",
            rationale: "\(incomplete.count) session(s) in \"\(currentPhase.title)\" remain as its window closes.",
            proposedValue: "Reschedule the \(incomplete.count) remaining session(s) of \"\(currentPhase.title)\" beyond \(deadlineText).",
            sourceSessionIDs: sourceIDs
        )
    }

    /// Confirmed records only: assessed, not deleted, chronological.
    private func confirmedSessions(
        snapshot: JournalSnapshot,
        projectID: UUID
    ) -> [LearningSession] {
        snapshot.sessions
            .filter { $0.projectId == projectID && $0.deletedAt == nil && $0.assessment != nil }
            .sorted {
                ($0.assessment?.confirmedAt ?? .distantPast, $0.id.uuidString)
                    < ($1.assessment?.confirmedAt ?? .distantPast, $1.id.uuidString)
            }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func suggestionIdentity(
        kind: LearningAdjustmentKind,
        title: String
    ) -> String {
        let normalizedTitle = title
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        return "\(kind.rawValue)::\(normalizedTitle)"
    }

    // MARK: - Persisting provider drafts

    /// Persists provider drafts as pending suggestions. The decision is
    /// ALWAYS `.pending` — provider output can never arrive adopted or carry
    /// an activated plan. Equivalent pending suggestions are deduped.
    @discardableResult
    public func persistSuggestions(
        _ drafts: [LearningAdjustmentSuggestionDraft],
        projectID: UUID
    ) throws -> [LearningAdjustmentSuggestion] {
        let snapshot = try repository.snapshot()
        let pendingKeys = Set(snapshot.learningAdjustmentSuggestions
            .filter { $0.projectID == projectID && $0.deletedAt == nil && $0.decision == .pending }
            .map { suggestionIdentity(kind: $0.kind, title: $0.title) })
        var seenKeys = pendingKeys
        let timestamp = now()
        let created = drafts.compactMap { draft -> LearningAdjustmentSuggestion? in
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let rationale = draft.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            let proposedValue = draft.proposedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !proposedValue.isEmpty else { return nil }
            let key = suggestionIdentity(kind: draft.kind, title: title)
            guard seenKeys.insert(key).inserted else { return nil }

            var sourceSessionIDs: [UUID] = []
            var seenSourceIDs: Set<UUID> = []
            for sourceID in draft.sourceSessionIDs where seenSourceIDs.insert(sourceID).inserted {
                sourceSessionIDs.append(sourceID)
            }
            return LearningAdjustmentSuggestion(
                projectID: projectID,
                sourceSessionIDs: sourceSessionIDs,
                kind: draft.kind,
                title: title,
                rationale: rationale,
                proposedValue: proposedValue,
                structuralChange: draft.structuralChange,
                decision: .pending,
                createdAt: timestamp
            )
        }
        guard !created.isEmpty else { return [] }
        try repository.commit(
            JournalTransaction(
                upserts: created.map(JournalEntity.learningAdjustmentSuggestion),
                origin: .user
            )
        )
        return created
    }

    // MARK: - Decisions

    public func ignore(suggestionID: UUID) throws {
        var suggestion = try pendingSuggestion(suggestionID)
        suggestion.decision = .ignored
        suggestion.decidedAt = now()
        try repository.commit(
            JournalTransaction(
                upserts: [.learningAdjustmentSuggestion(suggestion)],
                origin: .user
            )
        )
    }

    /// Adopts a pending suggestion. The typed target change and the decision
    /// commit are one repository transaction. Structural suggestions throw —
    /// they take effect only through the revision activation path.
    public func adopt(
        suggestionID: UUID,
        command: LearningAdjustmentCommand
    ) throws {
        try applyDecision(suggestionID: suggestionID, decision: .adopted, command: command)
    }

    /// The user edited the proposal and supplied a complete typed command;
    /// the command is persisted with `.modified` in the same transaction.
    public func modify(
        suggestionID: UUID,
        command: LearningAdjustmentCommand
    ) throws {
        try applyDecision(suggestionID: suggestionID, decision: .modified, command: command)
    }

    private func applyDecision(
        suggestionID: UUID,
        decision: SuggestionDecision,
        command: LearningAdjustmentCommand
    ) throws {
        var suggestion = try pendingSuggestion(suggestionID)
        guard suggestion.kind == command.kind else {
            throw LearningAdjustmentError.commandKindMismatch(
                expected: suggestion.kind,
                actual: command.kind
            )
        }
        try validate(command: command, for: suggestion)
        if decision == .modified, let proposedValue = command.proposedValue, !proposedValue.isEmpty {
            suggestion.proposedValue = proposedValue
        }
        // Persist the exact typed choice with the decision. This is what
        // lets local-only commands be replayed after a restart without
        // parsing the display proposal or adding target optionals.
        suggestion.appliedCommand = command
        switch suggestion.kind {
        case .nextStep:
            guard case let .nextStep(value) = command else {
                throw LearningAdjustmentError.commandKindMismatch(expected: .nextStep, actual: command.kind)
            }
            try adoptNextStep(&suggestion, value: value, decision: decision)
        case .dailyOrder:
            // The day-scoped override is applied by JournalViewModel only
            // AFTER this commit succeeds. A failed decision write therefore
            // cannot leave a local override in a half-adopted state.
            suggestion.decision = decision
            suggestion.decidedAt = now()
            try repository.commit(
                JournalTransaction(
                    upserts: [.learningAdjustmentSuggestion(suggestion)],
                    origin: .user
                )
            )
        case .reschedule:
            guard case let .reschedule(target) = command else {
                throw LearningAdjustmentError.commandKindMismatch(expected: .reschedule, actual: command.kind)
            }
            try adoptReschedule(
                &suggestion,
                decision: decision,
                target: target
            )
        case .temporaryDuration:
            guard case .temporaryDuration = command else {
                throw LearningAdjustmentError.commandKindMismatch(expected: .temporaryDuration, actual: command.kind)
            }
            try adoptTemporaryDuration(&suggestion, decision: decision)
        case .structuralRevision:
            throw LearningAdjustmentError.structuralRevisionRequiresDraftActivation
        }
    }

    private func adoptNextStep(
        _ suggestion: inout LearningAdjustmentSuggestion,
        value: String,
        decision: SuggestionDecision
    ) throws {
        let snapshot = try repository.snapshot()
        guard let project = snapshot.projects.first(where: { $0.id == suggestion.projectID }) else {
            throw LearningAdjustmentError.missingProject
        }
        let nextStep = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextStep.isEmpty else { throw LearningAdjustmentError.emptyProposedValue }
        let timestamp = now()

        var updatedProject = project
        updatedProject.currentNextStep = nextStep
        updatedProject.updatedAt = timestamp
        // Mirror JournalService next-step semantics.
        let event = TrailEvent(
            projectId: project.id,
            type: .nextStepChange,
            sourceId: suggestion.id,
            occurredAt: timestamp,
            title: "Next Step updated",
            detail: "Next Step changed from \(project.currentNextStep) to \(nextStep)"
        )
        suggestion.decision = decision
        suggestion.decidedAt = timestamp
        try repository.commit(
            JournalTransaction(
                upserts: [
                    .project(updatedProject),
                    .trailEvent(event),
                    .learningAdjustmentSuggestion(suggestion)
                ],
                origin: .user
            )
        )
    }

    private func validate(
        command: LearningAdjustmentCommand,
        for suggestion: LearningAdjustmentSuggestion
    ) throws {
        let snapshot = try repository.snapshot()
        switch command {
        case let .nextStep(value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LearningAdjustmentError.emptyProposedValue
            }
        case let .dailyOrder(target):
            let validTarget: Bool
            switch target.source {
            case .plannedSession:
                validTarget = snapshot.plannedSessions.contains {
                    $0.id == target.sourceID && $0.projectId == suggestion.projectID && $0.deletedAt == nil
                }
            case .practiceRoutine:
                validTarget = snapshot.practiceRoutines.contains {
                    $0.id == target.sourceID && $0.projectId == suggestion.projectID && $0.deletedAt == nil
                }
            case .nextStep:
                validTarget = target.sourceID == suggestion.projectID
            }
            guard validTarget else { throw LearningAdjustmentError.invalidCommandTarget }
        case let .reschedule(target):
            guard target.newDeadline.timeIntervalSince1970.isFinite,
                  snapshot.plannedSessions.contains(where: {
                      $0.id == target.plannedSessionID
                          && $0.projectId == suggestion.projectID
                          && $0.deletedAt == nil
                  }) else {
                throw LearningAdjustmentError.invalidCommandTarget
            }
        case let .temporaryDuration(target):
            guard target.minutes > 0,
                  snapshot.plannedSessions.contains(where: {
                      $0.id == target.plannedSessionID
                          && $0.projectId == suggestion.projectID
                          && $0.deletedAt == nil
                  }) else {
                throw LearningAdjustmentError.invalidCommandTarget
            }
        case .structuralRevision:
            throw LearningAdjustmentError.structuralRevisionRequiresDraftActivation
        }
    }

    private func adoptReschedule(
        _ suggestion: inout LearningAdjustmentSuggestion,
        decision: SuggestionDecision,
        target: RescheduleAdoptionTarget
    ) throws {
        guard let planningService else { throw LearningAdjustmentError.planningUnavailable }
        suggestion.decision = decision
        suggestion.decidedAt = now()
        // The canonical reschedule command folds the decided suggestion into
        // its single transaction, so the journal never exposes a rescheduled
        // session without its decision (or vice versa).
        _ = try planningService.reschedule(
            plannedSessionID: target.plannedSessionID,
            newDeadline: target.newDeadline,
            capacityAcknowledged: target.capacityAcknowledged,
            additionalUpserts: [.learningAdjustmentSuggestion(suggestion)]
        )
    }

    private func adoptTemporaryDuration(
        _ suggestion: inout LearningAdjustmentSuggestion,
        decision: SuggestionDecision
    ) throws {
        // The target was validated against the same repository snapshot
        // before this call. Temporary duration is an execution-only local
        // override, not a mutation of the structurally locked active plan.
        // Persisting the typed command and decision together makes the
        // override replayable after restart.
        suggestion.decision = decision
        suggestion.decidedAt = now()
        try repository.commit(
            JournalTransaction(
                upserts: [.learningAdjustmentSuggestion(suggestion)],
                origin: .user
            )
        )
    }

    // MARK: - Structural suggestions (spec 11.3)

    /// Creates a plan revision DRAFT through `CoursePlanningService.revise`.
    /// The base revision stays active and the suggestion stays `.pending`
    /// with `planRevisionDraftID` set; only the existing activation path can
    /// make the change effective. Structural provider fields must describe a
    /// concrete, non-no-op edit. Human-readable `proposedValue` is never
    /// parsed or used to invent a revision.
    @discardableResult
    public func prepareStructuralDraft(suggestionID: UUID) throws -> PlanRevisionDraft {
        var suggestion = try pendingSuggestion(suggestionID)
        guard suggestion.kind == .structuralRevision else {
            throw LearningAdjustmentError.notStructuralSuggestion
        }
        guard let planningService else { throw LearningAdjustmentError.planningUnavailable }
        let snapshot = try repository.snapshot()
        guard let basePlan = snapshot.coursePlans.first(where: {
            $0.projectId == suggestion.projectID && $0.status == .active && $0.deletedAt == nil
        }) else {
            throw LearningAdjustmentError.missingActivePlan
        }

        let phases = snapshot.planPhases
            .filter { $0.planId == basePlan.id && $0.deletedAt == nil }
            .sorted { $0.ordinal < $1.ordinal }
        let sessions = snapshot.plannedSessions
            .filter { $0.planId == basePlan.id && $0.deletedAt == nil }
        guard let requestedChange = suggestion.structuralChange,
              !requestedChange.isEmpty else {
            throw LearningAdjustmentError.invalidStructuralChange
        }

        let candidateDeadline: Date?
        if let requestedDeadline = requestedChange.deadline {
            guard requestedDeadline >= basePlan.startsOn else {
                throw LearningAdjustmentError.invalidStructuralChange
            }
            candidateDeadline = requestedDeadline
        } else {
            candidateDeadline = basePlan.deadline
        }
        let candidateBudget: Int
        if let requestedBudget = requestedChange.weeklyBudgetMinutes {
            guard requestedBudget > 0 else {
                throw LearningAdjustmentError.invalidStructuralChange
            }
            candidateBudget = requestedBudget
        } else {
            candidateBudget = basePlan.weeklyBudgetMinutes
        }

        let selectedPhaseID = requestedChange.phaseID
        let selectedSessionID = requestedChange.sessionID
        let objectiveOverride = requestedChange.phaseObjective?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPhaseEdit = requestedChange.phaseTargetEnd != nil
            || requestedChange.phaseObjective != nil
        if (hasPhaseEdit && selectedPhaseID == nil)
            || (selectedPhaseID != nil && !hasPhaseEdit) {
            throw LearningAdjustmentError.invalidStructuralChange
        }
        let selectedPhase = selectedPhaseID.flatMap { phaseID in
            phases.first { $0.id == phaseID }
        }
        if hasPhaseEdit && selectedPhase == nil {
            throw LearningAdjustmentError.invalidStructuralChange
        }
        if let objectiveOverride,
           objectiveOverride.isEmpty {
            throw LearningAdjustmentError.invalidStructuralChange
        }
        if let requestedEnd = requestedChange.phaseTargetEnd,
           let selectedPhase,
           (requestedEnd < selectedPhase.targetStart
                || candidateDeadline.map({ requestedEnd > $0 }) == true) {
            throw LearningAdjustmentError.invalidStructuralChange
        }

        let hasSessionEdit = requestedChange.sessionDurationMinutes != nil
        if (hasSessionEdit && selectedSessionID == nil)
            || (selectedSessionID != nil && !hasSessionEdit) {
            throw LearningAdjustmentError.invalidStructuralChange
        }
        let selectedSession = selectedSessionID.flatMap { sessionID in
            sessions.first { $0.id == sessionID }
        }
        if hasSessionEdit && selectedSession == nil {
            throw LearningAdjustmentError.invalidStructuralChange
        }
        if let requestedDuration = requestedChange.sessionDurationMinutes,
           requestedDuration <= 0 {
            throw LearningAdjustmentError.invalidStructuralChange
        }

        var didApplyStructuredChange = false
        if candidateDeadline != basePlan.deadline
            || candidateBudget != basePlan.weeklyBudgetMinutes {
            didApplyStructuredChange = true
        }
        let candidatePhases = phases.map { phase -> CoursePlanDraftPhase in
            var objective = phase.objective
            var targetEnd = phase.targetEnd
            if phase.id == selectedPhaseID {
                if let objectiveOverride, !objectiveOverride.isEmpty,
                   objectiveOverride != objective {
                    objective = objectiveOverride
                    didApplyStructuredChange = true
                }
                if let requestedEnd = requestedChange.phaseTargetEnd,
                   requestedEnd != targetEnd {
                    targetEnd = requestedEnd
                    didApplyStructuredChange = true
                }
            }
            return CoursePlanDraftPhase(
                id: phase.id.uuidString,
                title: phase.title,
                objective: objective,
                expectedProof: phase.expectedProof,
                ordinal: phase.ordinal,
                targetStart: phase.targetStart,
                targetEnd: targetEnd
            )
        }
        if let selectedSession,
           let requestedDuration = requestedChange.sessionDurationMinutes,
           requestedDuration != selectedSession.durationMinutes {
            didApplyStructuredChange = true
        }
        let candidateSessions = sessions.map { session in
            CoursePlanDraftSession(
                id: session.id.uuidString,
                phaseID: session.phaseId.uuidString,
                title: session.title,
                actionType: session.actionType,
                expectedProof: session.expectedProof,
                durationMinutes: session.id == selectedSessionID
                    ? requestedChange.sessionDurationMinutes!
                    : session.durationMinutes,
                deadline: session.deadline,
                planningWindow: session.planningWindow,
                completionCriteria: session.completionCriteria,
                recommendationReason: session.recommendationReason
            )
        }
        if !didApplyStructuredChange {
            throw LearningAdjustmentError.invalidStructuralChange
        }

        let input = CoursePlanningInput(
            projectId: basePlan.projectId,
            courseURL: basePlan.courseURL,
            courseTitle: basePlan.courseTitle,
            courseOutline: basePlan.courseOutline,
            goal: basePlan.goal,
            expectedOutcome: basePlan.expectedOutcome,
            startsOn: basePlan.startsOn,
            deadline: candidateDeadline,
            weeklyBudgetMinutes: candidateBudget,
            preferredSessionMinutes: min(30, basePlan.weeklyBudgetMinutes)
        )
        let draft = CoursePlanDraft(
            title: basePlan.courseTitle,
            summary: basePlan.summary,
            phases: candidatePhases,
            sessions: candidateSessions
        )
        let revisionDraft = try planningService.saveRevisionDraft(
            planID: basePlan.id, input: input, draft: draft
        )

        suggestion.planRevisionDraftID = revisionDraft.plan.id
        suggestion.revisionGuardExpectation = revisionDraft.guardExpectation
        try repository.commit(
            JournalTransaction(
                upserts: [.learningAdjustmentSuggestion(suggestion)],
                origin: .user
            )
        )
        return revisionDraft
    }

    /// Called by the UI after the revision draft was activated through the
    /// existing activation path. Activation is the only way a structural
    /// suggestion becomes adopted.
    public func markAdoptedAfterActivation(suggestionID: UUID) throws {
        var suggestion = try suggestion(id: suggestionID)
        guard suggestion.kind == .structuralRevision else {
            throw LearningAdjustmentError.notStructuralSuggestion
        }
        if suggestion.decision == .adopted {
            return
        }
        guard suggestion.decision == .pending else {
            throw LearningAdjustmentError.alreadyDecided
        }
        guard let draftID = suggestion.planRevisionDraftID,
              let plan = try repository.snapshot().coursePlans.first(where: { $0.id == draftID }),
              plan.status == .active else {
            throw LearningAdjustmentError.revisionNotActivated
        }
        suggestion.decision = .adopted
        suggestion.decidedAt = now()
        try repository.commit(
            JournalTransaction(
                upserts: [.learningAdjustmentSuggestion(suggestion)],
                origin: .user
            )
        )
    }

    private func pendingSuggestion(_ id: UUID) throws -> LearningAdjustmentSuggestion {
        let suggestion = try suggestion(id: id)
        guard suggestion.decision == .pending else {
            throw LearningAdjustmentError.alreadyDecided
        }
        return suggestion
    }
}

// MARK: - Detection → provider bridge

/// Minimal surface the rule-based provider needs. `LearningAdjustmentService`
/// conforms; tests can stub it.
public protocol LearningAdjustmentRuleDetector: Sendable {
    func detectDrafts(projectID: UUID, now: Date) throws -> [LearningAdjustmentSuggestionDraft]
}

/// Repository implementations serialize their own state (NSLock / single
/// ModelContext), matching how `LearningRecordService` is shared across
/// actor boundaries from the view-model layer.
extension LearningAdjustmentService: @unchecked Sendable, LearningAdjustmentRuleDetector {
    public func detectDrafts(projectID: UUID, now: Date) throws -> [LearningAdjustmentSuggestionDraft] {
        detectedDrafts(
            snapshot: try repository.snapshot(),
            projectID: projectID,
            now: now
        )
    }
}

// MARK: - AI provider (spec 12.4)

public enum LearningAdjustmentProviderError: Error, Equatable, Sendable {
    /// The provider could not produce usable suggestions (configuration,
    /// transport, parse, or validation failure). Callers fall back to the
    /// rule-based provider.
    case providerUnavailable
}

/// Everything an adjustment provider may see (spec 12.4): the ACTIVE plan
/// revision summary, the current phase, the last ≤10 confirmed sessions of
/// THIS project (id/activity/progress/blocker/summary/dates), the unresolved
/// blocker digest, and the user's request. Nothing else may be sent — no
/// other projects, calendar, contacts, locations, or attachment content.
public struct LearningAdjustmentInput: Equatable, Sendable, Encodable {
    public struct PlanDigest: Equatable, Sendable, Encodable {
        public var revision: Int
        public var courseTitle: String
        public var goal: String
        public var expectedOutcome: String
        public var startsOn: Date
        public var deadline: Date?
        public var weeklyBudgetMinutes: Int
        public var summary: String
    }

    public struct PhaseDigest: Equatable, Sendable, Encodable {
        /// Optional for backwards-compatible provider callers; production
        /// input includes the stable phase id so structured revisions can
        /// target the exact phase without natural-language matching.
        public var id: UUID?
        public var title: String
        public var objective: String
        public var targetStart: Date
        public var targetEnd: Date

        public init(
            id: UUID? = nil,
            title: String,
            objective: String,
            targetStart: Date,
            targetEnd: Date
        ) {
            self.id = id
            self.title = title
            self.objective = objective
            self.targetStart = targetStart
            self.targetEnd = targetEnd
        }
    }

    public struct SessionDigest: Equatable, Sendable, Encodable {
        public var id: UUID
        public var activityTitle: String?
        public var progress: String
        public var blocker: String?
        public var summary: String
        public var confirmedAt: Date
    }

    public var projectID: UUID
    public var activePlan: PlanDigest?
    public var currentPhase: PhaseDigest?
    public var recentConfirmedSessions: [SessionDigest]
    public var unresolvedBlockers: [String]
    public var userRequest: String

    public init(
        projectID: UUID,
        activePlan: PlanDigest?,
        currentPhase: PhaseDigest?,
        recentConfirmedSessions: [SessionDigest],
        unresolvedBlockers: [String],
        userRequest: String
    ) {
        self.projectID = projectID
        self.activePlan = activePlan
        self.currentPhase = currentPhase
        self.recentConfirmedSessions = recentConfirmedSessions
        self.unresolvedBlockers = unresolvedBlockers
        self.userRequest = userRequest
    }

    public init(
        snapshot: JournalSnapshot,
        projectID: UUID,
        userRequest: String,
        maximumRecentSessions: Int = 10
    ) {
        let activePlan = snapshot.coursePlans.first {
            $0.projectId == projectID && $0.status == .active && $0.deletedAt == nil
        }
        let phases = snapshot.planPhases
            .filter { $0.planId == activePlan?.id && $0.deletedAt == nil }
            .sorted { $0.ordinal < $1.ordinal }
        let currentPhase = phases.first { $0.progress == .active }
            ?? phases.first { ![.completed, .abandoned].contains($0.progress) }

        let plannedByCompletedSession = Dictionary(
            uniqueKeysWithValues: snapshot.plannedSessions
                .filter { $0.deletedAt == nil && $0.completedSessionId != nil }
                .map { ($0.completedSessionId!, $0) }
        )
        let confirmed = snapshot.sessions
            .filter { $0.projectId == projectID && $0.deletedAt == nil && $0.assessment != nil }
            .sorted {
                ($0.assessment?.confirmedAt ?? .distantPast, $0.id.uuidString)
                    > ($1.assessment?.confirmedAt ?? .distantPast, $1.id.uuidString)
            }
            .prefix(max(0, maximumRecentSessions))
        let digests = confirmed.map { session -> SessionDigest in
            SessionDigest(
                id: session.id,
                activityTitle: plannedByCompletedSession[session.id]?.title,
                progress: session.assessment?.progress.rawValue ?? "",
                blocker: session.assessment?.blocker,
                summary: session.note,
                confirmedAt: session.assessment?.confirmedAt ?? session.updatedAt
            )
        }
        var seenBlockers: Set<String> = []
        var blockers: [String] = []
        for digest in digests {
            guard let blocker = digest.blocker?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !blocker.isEmpty else { continue }
            if seenBlockers.insert(blocker.lowercased()).inserted {
                blockers.append(blocker)
            }
        }

        self.init(
            projectID: projectID,
            activePlan: activePlan.map {
                PlanDigest(
                    revision: $0.revision,
                    courseTitle: $0.courseTitle,
                    goal: $0.goal,
                    expectedOutcome: $0.expectedOutcome,
                    startsOn: $0.startsOn,
                    deadline: $0.deadline,
                    weeklyBudgetMinutes: $0.weeklyBudgetMinutes,
                    summary: $0.summary
                )
            },
            currentPhase: currentPhase.map {
                PhaseDigest(
                    id: $0.id,
                    title: $0.title,
                    objective: $0.objective,
                    targetStart: $0.targetStart,
                    targetEnd: $0.targetEnd
                )
            },
            recentConfirmedSessions: digests,
            unresolvedBlockers: blockers,
            userRequest: userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public protocol LearningAdjustmentProvider: Sendable {
    func makeSuggestions(
        input: LearningAdjustmentInput
    ) async throws -> [LearningAdjustmentSuggestionDraft]
}

/// Deterministic fallback: wraps the rule-based detectors. Provider output
/// is always pending drafts; persistence and dedupe happen in the service.
public struct RuleBasedLearningAdjustmentProvider: LearningAdjustmentProvider {
    private let detector: any LearningAdjustmentRuleDetector
    private let now: @Sendable () -> Date

    public init(
        detector: any LearningAdjustmentRuleDetector,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.detector = detector
        self.now = now
    }

    public func makeSuggestions(
        input: LearningAdjustmentInput
    ) async throws -> [LearningAdjustmentSuggestionDraft] {
        try detector.detectDrafts(projectID: input.projectID, now: now())
    }
}

public struct OpenAICompatibleLearningAdjustmentProvider: LearningAdjustmentProvider {
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

    public func makeSuggestions(
        input: LearningAdjustmentInput
    ) async throws -> [LearningAdjustmentSuggestionDraft] {
        do {
            // Strict decoding: an unknown kind fails decoding and becomes
            // .providerUnavailable, so the adaptive provider falls back
            // instead of trusting the output. The response shape has no
            // decision or activation fields by design — hostile keys are
            // ignored and drafts are always persisted as pending.
            let response: LearningAdjustmentResponse = try await client.completeJSON(
                system: Self.systemPrompt,
                user: try Self.requestPreview(input: input, model: model).encodedText
            )
            let knownSessionIDs = Set(input.recentConfirmedSessions.map(\.id))
            return try response.suggestions.map { item in
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let proposedValue = item.proposedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !proposedValue.isEmpty else {
                    throw LearningAdjustmentProviderError.providerUnavailable
                }
                return LearningAdjustmentSuggestionDraft(
                    kind: item.kind,
                    title: title,
                    rationale: item.rationale?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    proposedValue: proposedValue,
                    sourceSessionIDs: (item.sourceSessionIDs ?? [])
                        .filter { knownSessionIDs.contains($0) },
                    structuralChange: item.structuralChange
                )
            }
        } catch let error as LearningAdjustmentProviderError {
            throw error
        } catch {
            throw LearningAdjustmentProviderError.providerUnavailable
        }
    }

    private static let systemPrompt = """
    You propose reviewable learning adjustments for one personal study course from the active plan summary, the current phase, the most recent confirmed learning records, unresolved blockers, and the learner's request. Return only a JSON object of the form {"suggestions": [{"kind": "nextStep" | "dailyOrder" | "reschedule" | "temporaryDuration" | "structuralRevision", "title": "...", "rationale": "...", "proposedValue": "...", "sourceSessionIDs": ["..."], "structuralChange": {"deadline": "ISO date or null", "weeklyBudgetMinutes": 0, "phaseID": "UUID or null", "phaseTargetEnd": "ISO date or null", "phaseObjective": "string or null", "sessionID": "UUID or null", "sessionDurationMinutes": 0} or null}]}. Each suggestion must cite only session ids from the request. Never output a decision, never activate or rewrite any plan, and never invent sessions. Use "structuralRevision" only when phases, completion criteria, the activity set, base durations, or the weekly budget must change; when using it, put concrete edits in structuralChange rather than encoding edits in proposedValue. Do not use or request calendar event content, contacts, location, attachment content, or any data beyond the request.
    """

    public static func requestPreview(
        input: LearningAdjustmentInput,
        model: String
    ) throws -> AIRequestPackage {
        AIRequestPackage(
            encodedText: String(decoding: try JSONEncoder.journal.encode(input), as: UTF8.self),
            artifacts: [],
            model: model,
            sourceMetadata: [
                "source": "learning-adjustment",
                "input": "active-plan-and-confirmed-records-only",
                "authorization": "one-request"
            ]
        )
    }
}

/// Prefers the AI provider when configured; on missing configuration or ANY
/// provider failure (transport, parse, invalid output) returns the
/// rule-based drafts. Never throws for provider failure.
public struct AdaptiveLearningAdjustmentProvider: LearningAdjustmentProvider {
    private let settingsStore: AIReviewSettingsStore
    private let transport: any AIHTTPTransport
    private let fallback: any LearningAdjustmentProvider

    public init(
        settingsStore: AIReviewSettingsStore = AIReviewSettingsStore(),
        transport: any AIHTTPTransport = URLSessionAIHTTPTransport(),
        fallback: any LearningAdjustmentProvider
    ) {
        self.settingsStore = settingsStore
        self.transport = transport
        self.fallback = fallback
    }

    public func makeSuggestions(
        input: LearningAdjustmentInput
    ) async throws -> [LearningAdjustmentSuggestionDraft] {
        guard let settings = settingsStore.settings(),
              let apiKey = settingsStore.apiKey(),
              !apiKey.isEmpty
        else {
            return try await fallback.makeSuggestions(input: input)
        }

        do {
            return try await OpenAICompatibleLearningAdjustmentProvider(
                settings: settings,
                apiKey: apiKey,
                transport: transport
            ).makeSuggestions(input: input)
        } catch {
            return try await fallback.makeSuggestions(input: input)
        }
    }
}

private struct LearningAdjustmentResponse: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var kind: LearningAdjustmentKind
        var title: String
        var rationale: String?
        var proposedValue: String
        var sourceSessionIDs: [UUID]?
        var structuralChange: LearningAdjustmentStructuralChange?
    }

    var suggestions: [Item]
}
