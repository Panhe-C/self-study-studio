import Foundation

/// What a learning adjustment suggestion proposes (spec 4.7). Ordinary kinds
/// execute through existing safe commands (canonical Next Step, Today
/// override, planned-session reschedule, temporary duration); structural
/// ones always go through a new plan revision draft.
public enum LearningAdjustmentKind: String, Codable, CaseIterable, Sendable {
    case nextStep
    case dailyOrder
    case reschedule
    case temporaryDuration
    case structuralRevision
}

/// Suggestion lifecycle (spec 5.3): pending → adopted / modified / ignored.
public enum SuggestionDecision: String, Codable, CaseIterable, Sendable {
    case pending
    case adopted
    case modified
    case ignored
}

/// Machine-readable plan edits proposed by a structural adjustment provider.
///
/// `proposedValue` remains a display string, but structural planning never
/// parses that string. Every optional field is a concrete, reviewable edit.
/// Older persisted suggestions may decode with `nil`; those suggestions stay
/// pending and must be refreshed with a structured payload before a revision
/// draft can be prepared.
public struct LearningAdjustmentStructuralChange: Codable, Equatable, Sendable {
    public var deadline: Date?
    public var weeklyBudgetMinutes: Int?
    public var phaseID: UUID?
    public var phaseTargetEnd: Date?
    public var phaseObjective: String?
    public var sessionID: UUID?
    public var sessionDurationMinutes: Int?

    public init(
        deadline: Date? = nil,
        weeklyBudgetMinutes: Int? = nil,
        phaseID: UUID? = nil,
        phaseTargetEnd: Date? = nil,
        phaseObjective: String? = nil,
        sessionID: UUID? = nil,
        sessionDurationMinutes: Int? = nil
    ) {
        self.deadline = deadline
        self.weeklyBudgetMinutes = weeklyBudgetMinutes
        self.phaseID = phaseID
        self.phaseTargetEnd = phaseTargetEnd
        self.phaseObjective = phaseObjective
        self.sessionID = sessionID
        self.sessionDurationMinutes = sessionDurationMinutes
    }

    public var isEmpty: Bool {
        deadline == nil
            && weeklyBudgetMinutes == nil
            && phaseID == nil
            && phaseTargetEnd == nil
            && phaseObjective == nil
            && sessionID == nil
            && sessionDurationMinutes == nil
    }
}

/// A reviewable adjustment suggestion (spec 4.7). Suggestions sync but carry
/// no authority: `decision == .adopted` never by itself mutates any other
/// object — adoption is committed in the same transaction as the target
/// change by `LearningAdjustmentService`.
///
/// `deletedAt` mirrors the `LearningRecordRevision` plumbing pattern: every
/// journaled entity needs a deletion marker so repository tombstones,
/// `JournalEntity.isDeleted`, and sync merges behave uniformly.
public struct LearningAdjustmentSuggestion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: UUID
    /// Confirmed learning records that motivated the suggestion.
    public var sourceSessionIDs: [UUID]
    public var kind: LearningAdjustmentKind
    public var title: String
    public var rationale: String
    /// Human-readable proposal. Machine routing never parses this string;
    /// adoption of reschedule/duration kinds takes typed target parameters.
    public var proposedValue: String
    /// Structured fields used only by `.structuralRevision`. This is optional
    /// for backwards-compatible archives and legacy provider responses.
    public var structuralChange: LearningAdjustmentStructuralChange?
    public var decision: SuggestionDecision
    /// Set once a structural suggestion produced a plan revision draft. The
    /// decision stays `.pending` until the user activates that draft.
    public var planRevisionDraftID: UUID?
    /// Captured when the structural draft is prepared. Keeping the base
    /// expectation with the suggestion makes activation guarded across app
    /// restarts instead of silently recapturing a newer base revision.
    public var revisionGuardExpectation: RevisionGuardExpectation?
    /// The validated typed command chosen for an adopted/modified ordinary
    /// suggestion. This keeps local-only commands (Today order and temporary
    /// duration) replayable after restart without adding mutually-exclusive
    /// target optionals to the domain model.
    public var appliedCommand: LearningAdjustmentCommand?
    public var createdAt: Date
    public var decidedAt: Date?
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sourceSessionIDs: [UUID] = [],
        kind: LearningAdjustmentKind,
        title: String,
        rationale: String,
        proposedValue: String,
        structuralChange: LearningAdjustmentStructuralChange? = nil,
        decision: SuggestionDecision = .pending,
        planRevisionDraftID: UUID? = nil,
        revisionGuardExpectation: RevisionGuardExpectation? = nil,
        appliedCommand: LearningAdjustmentCommand? = nil,
        createdAt: Date = Date(),
        decidedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceSessionIDs = sourceSessionIDs
        self.kind = kind
        self.title = title
        self.rationale = rationale
        self.proposedValue = proposedValue
        self.structuralChange = structuralChange
        self.decision = decision
        self.planRevisionDraftID = planRevisionDraftID
        self.revisionGuardExpectation = revisionGuardExpectation
        self.appliedCommand = appliedCommand
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.deletedAt = deletedAt
    }

    public var reference: JournalEntityReference {
        JournalEntityReference(.learningAdjustmentSuggestion, id)
    }
}

/// Provider-facing suggestion draft (spec 12.4). It deliberately has NO
/// decision or activation fields: provider output is always persisted as
/// `.pending`, and structural requests become drafts only through
/// `CoursePlanningService.revise`.
public struct LearningAdjustmentSuggestionDraft: Codable, Equatable, Sendable {
    public var kind: LearningAdjustmentKind
    public var title: String
    public var rationale: String
    public var proposedValue: String
    /// Structured plan edits for structural suggestions; never inferred by
    /// parsing `proposedValue`.
    public var structuralChange: LearningAdjustmentStructuralChange?
    public var sourceSessionIDs: [UUID]

    public init(
        kind: LearningAdjustmentKind,
        title: String,
        rationale: String,
        proposedValue: String,
        sourceSessionIDs: [UUID] = [],
        structuralChange: LearningAdjustmentStructuralChange? = nil
    ) {
        self.kind = kind
        self.title = title
        self.rationale = rationale
        self.proposedValue = proposedValue
        self.sourceSessionIDs = sourceSessionIDs
        self.structuralChange = structuralChange
    }
}

// MARK: - Plan revision diff

/// Field-level diff between a base plan revision and a candidate revision
/// (spec 11.3). Pure value type computed by `PlanRevisionDiffEngine`; the
/// view only renders it.
public struct PlanRevisionDiff: Equatable, Sendable {
    public enum ChildChangeKind: String, Equatable, Sendable {
        case added
        case removed
        case changed
    }

    public struct FieldChange: Equatable, Sendable {
        public var field: String
        public var base: String?
        public var candidate: String?

        public init(field: String, base: String?, candidate: String?) {
            self.field = field
            self.base = base
            self.candidate = candidate
        }
    }

    public struct PhaseChange: Equatable, Identifiable, Sendable {
        public var id: String
        public var ordinal: Int
        public var title: String
        public var kind: ChildChangeKind
        public var fieldChanges: [FieldChange]

        public init(
            ordinal: Int,
            title: String,
            kind: ChildChangeKind,
            fieldChanges: [FieldChange] = []
        ) {
            self.id = "\(kind.rawValue)-\(ordinal)-\(title)"
            self.ordinal = ordinal
            self.title = title
            self.kind = kind
            self.fieldChanges = fieldChanges
        }
    }

    public struct SessionChange: Equatable, Identifiable, Sendable {
        public var id: String
        public var phaseOrdinal: Int
        public var title: String
        public var kind: ChildChangeKind
        public var fieldChanges: [FieldChange]

        public init(
            phaseOrdinal: Int,
            title: String,
            kind: ChildChangeKind,
            fieldChanges: [FieldChange] = []
        ) {
            self.id = "\(kind.rawValue)-\(phaseOrdinal)-\(title)"
            self.phaseOrdinal = phaseOrdinal
            self.title = title
            self.kind = kind
            self.fieldChanges = fieldChanges
        }
    }

    public var planFieldChanges: [FieldChange]
    public var phaseChanges: [PhaseChange]
    public var sessionChanges: [SessionChange]

    public init(
        planFieldChanges: [FieldChange] = [],
        phaseChanges: [PhaseChange] = [],
        sessionChanges: [SessionChange] = []
    ) {
        self.planFieldChanges = planFieldChanges
        self.phaseChanges = phaseChanges
        self.sessionChanges = sessionChanges
    }

    public var isEmpty: Bool {
        planFieldChanges.isEmpty && phaseChanges.isEmpty && sessionChanges.isEmpty
    }
}

/// Computes the reviewable field-level diff between two plan revisions.
///
/// Revision drafts mint fresh child IDs (every revision is an immutable
/// snapshot), so identity matching uses structure instead: phases match by
/// ordinal, sessions match by (phase ordinal, normalized title). That is the
/// same granularity the review UI reasons about; a renamed title shows up as
/// removed + added, which reads honestly in the diff.
public enum PlanRevisionDiffEngine {
    public static func compute(base: PlanRevision, candidate: PlanRevision) -> PlanRevisionDiff {
        PlanRevisionDiff(
            planFieldChanges: planChanges(base: base.plan, candidate: candidate.plan),
            phaseChanges: childChanges(
                base: base.phases, candidate: candidate.phases,
                key: { $0.ordinal },
                title: \.title,
                ordinal: { $0.ordinal },
                fields: phaseFields
            ),
            sessionChanges: sessionChanges(base: base, candidate: candidate)
        )
    }

    private static func planChanges(base: LearningPlan, candidate: LearningPlan) -> [PlanRevisionDiff.FieldChange] {
        var changes: [PlanRevisionDiff.FieldChange] = []
        func compare(_ field: String, _ baseValue: String?, _ candidateValue: String?) {
            if baseValue != candidateValue {
                changes.append(.init(field: field, base: baseValue, candidate: candidateValue))
            }
        }
        compare("courseTitle", base.courseTitle, candidate.courseTitle)
        compare("goal", base.goal, candidate.goal)
        compare("expectedOutcome", base.expectedOutcome, candidate.expectedOutcome)
        compare("summary", base.summary, candidate.summary)
        compare("startsOn", dateString(base.startsOn), dateString(candidate.startsOn))
        compare("deadline", base.deadline.map(dateString), candidate.deadline.map(dateString))
        compare(
            "weeklyBudgetMinutes",
            String(base.weeklyBudgetMinutes),
            String(candidate.weeklyBudgetMinutes)
        )
        return changes
    }

    private static func phaseFields(_ phase: PlanPhase) -> [(String, String?)] {
        [
            ("title", phase.title),
            ("objective", phase.objective),
            ("expectedProof", phase.expectedProof),
            ("targetStart", dateString(phase.targetStart)),
            ("targetEnd", dateString(phase.targetEnd))
        ]
    }

    private static func childChanges<Value>(
        base: [Value],
        candidate: [Value],
        key: (Value) -> Int,
        title: KeyPath<Value, String>,
        ordinal: (Value) -> Int,
        fields: (Value) -> [(String, String?)]
    ) -> [PlanRevisionDiff.PhaseChange] {
        let baseByKey = Dictionary(uniqueKeysWithValues: base.map { (key($0), $0) })
        let candidateByKey = Dictionary(uniqueKeysWithValues: candidate.map { (key($0), $0) })
        var changes: [PlanRevisionDiff.PhaseChange] = []
        for (phaseKey, candidateValue) in candidateByKey.sorted(by: { $0.key < $1.key }) {
            guard let baseValue = baseByKey[phaseKey] else {
                changes.append(.init(
                    ordinal: ordinal(candidateValue),
                    title: candidateValue[keyPath: title],
                    kind: .added
                ))
                continue
            }
            let fieldChanges = fieldChanges(fields(baseValue), fields(candidateValue))
            if !fieldChanges.isEmpty {
                changes.append(.init(
                    ordinal: ordinal(candidateValue),
                    title: candidateValue[keyPath: title],
                    kind: .changed,
                    fieldChanges: fieldChanges
                ))
            }
        }
        for (phaseKey, baseValue) in baseByKey.sorted(by: { $0.key < $1.key })
            where candidateByKey[phaseKey] == nil {
            changes.append(.init(
                ordinal: ordinal(baseValue),
                title: baseValue[keyPath: title],
                kind: .removed
            ))
        }
        return changes
    }

    private static func sessionChanges(
        base: PlanRevision,
        candidate: PlanRevision
    ) -> [PlanRevisionDiff.SessionChange] {
        func keyed(_ revision: PlanRevision) -> [String: PlannedSession] {
            let ordinals = Dictionary(uniqueKeysWithValues: revision.phases.map { ($0.id, $0.ordinal) })
            return Dictionary(uniqueKeysWithValues: revision.sessions.map { session in
                let phaseOrdinal = ordinals[session.phaseId] ?? .max
                return ("\(phaseOrdinal)::\(normalize(session.title))", session)
            })
        }
        func phaseOrdinal(of session: PlannedSession, in revision: PlanRevision) -> Int {
            revision.phases.first { $0.id == session.phaseId }?.ordinal ?? .max
        }
        func fields(_ session: PlannedSession) -> [(String, String?)] {
            [
                ("durationMinutes", String(session.durationMinutes)),
                ("completionCriteria", session.completionCriteria.joined(separator: "; ")),
                ("expectedProof", session.expectedProof),
                ("deadline", session.deadline.map(dateString))
            ]
        }

        let baseByKey = keyed(base)
        let candidateByKey = keyed(candidate)
        var changes: [PlanRevisionDiff.SessionChange] = []
        for (key, candidateSession) in candidateByKey.sorted(by: { $0.key < $1.key }) {
            guard let baseSession = baseByKey[key] else {
                changes.append(.init(
                    phaseOrdinal: phaseOrdinal(of: candidateSession, in: candidate),
                    title: candidateSession.title,
                    kind: .added
                ))
                continue
            }
            let sessionFieldChanges = fieldChanges(fields(baseSession), fields(candidateSession))
            if !sessionFieldChanges.isEmpty {
                changes.append(.init(
                    phaseOrdinal: phaseOrdinal(of: candidateSession, in: candidate),
                    title: candidateSession.title,
                    kind: .changed,
                    fieldChanges: sessionFieldChanges
                ))
            }
        }
        for (key, baseSession) in baseByKey.sorted(by: { $0.key < $1.key })
            where candidateByKey[key] == nil {
            changes.append(.init(
                phaseOrdinal: phaseOrdinal(of: baseSession, in: base),
                title: baseSession.title,
                kind: .removed
            ))
        }
        return changes
    }

    private static func fieldChanges(
        _ base: [(String, String?)],
        _ candidate: [(String, String?)]
    ) -> [PlanRevisionDiff.FieldChange] {
        zip(base, candidate).compactMap { baseField, candidateField in
            baseField.1 == candidateField.1
                ? nil
                : .init(field: baseField.0, base: baseField.1, candidate: candidateField.1)
        }
    }

    private static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func dateString(_ date: Date) -> String {
        JournalISO8601Codec.string(from: date)
    }
}
