import Foundation

public struct CoursePlanValidationResult: Equatable, Sendable {
    public var errors: [CoursePlanningValidationError]
    public var warnings: [String]

    public init(
        errors: [CoursePlanningValidationError] = [],
        warnings: [String] = []
    ) {
        self.errors = errors
        self.warnings = warnings
    }

    public var isValid: Bool { errors.isEmpty }
}

public struct CoursePlanValidator {
    public init() {}

    public func validate(
        _ draft: CoursePlanDraft,
        input: CoursePlanningInput
    ) -> CoursePlanValidationResult {
        var errors: [CoursePlanningValidationError] = []
        var warnings: [String] = []

        if draft.title.trimmedForJournal.isEmpty || input.courseTitle.trimmedForJournal.isEmpty {
            errors.append(.emptyTitle)
        }
        if input.goal.trimmedForJournal.isEmpty {
            errors.append(.emptyGoal)
        }
        if input.weeklyBudgetMinutes <= 0 {
            errors.append(.invalidWeeklyBudget)
        }
        if input.preferredSessionMinutes <= 0 {
            errors.append(.invalidDuration)
        }
        if let deadline = input.deadline, deadline < input.startsOn {
            errors.append(.invalidDateRange)
        }
        if draft.phases.isEmpty {
            errors.append(.emptyTitle)
        }

        var identifiers = Set<String>()
        let phaseIdentifiers = Set(draft.phases.map(\.id))
        for phase in draft.phases {
            if phase.id.isEmpty || !identifiers.insert(phase.id).inserted {
                errors.append(.duplicateDraftID(phase.id))
            }
            if phase.title.trimmedForJournal.isEmpty {
                errors.append(.emptyTitle)
            }
            if phase.objective.trimmedForJournal.isEmpty {
                errors.append(.emptyGoal)
            }
            if phase.targetEnd < phase.targetStart {
                errors.append(.invalidDateRange)
            }
            if phase.targetStart < input.startsOn
                || input.deadline.map({ phase.targetEnd > $0 }) == true {
                errors.append(.phaseOutsidePlan(phase.id))
            }
        }

        for session in draft.sessions {
            if session.id.isEmpty || !identifiers.insert(session.id).inserted {
                errors.append(.duplicateDraftID(session.id))
            }
            if !phaseIdentifiers.contains(session.phaseID) {
                errors.append(.unknownPhaseReference(session.phaseID))
            }
            if session.title.trimmedForJournal.isEmpty {
                errors.append(.emptyTitle)
            }
            if session.durationMinutes <= 0 {
                errors.append(.invalidDuration)
            }
            if let deadline = session.deadline,
               deadline < input.startsOn || input.deadline.map({ deadline > $0 }) == true {
                errors.append(.invalidDateRange)
            }
        }

        let availableMinutes = input.availableMinutesByWeekday.values.reduce(0, +)
        if availableMinutes > 0 && input.weeklyBudgetMinutes > availableMinutes {
            warnings.append("Weekly budget exceeds the available minutes you supplied.")
        }
        return CoursePlanValidationResult(errors: errors, warnings: warnings)
    }
}
