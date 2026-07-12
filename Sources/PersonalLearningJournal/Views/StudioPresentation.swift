import Foundation

public struct StudioWeekDay: Equatable, Identifiable, Sendable {
    public let date: Date
    public let minutes: Int

    public var id: Date { date }

    public init(date: Date, minutes: Int) {
        self.date = date
        self.minutes = minutes
    }
}

public struct StudioProjectProgress: Equatable, Identifiable, Sendable {
    public let project: Project
    public let plan: CoursePlan?
    public let phases: [PlanPhase]
    public let plannedSessions: [PlannedSession]

    public var id: UUID { project.id }

    public var completedSessionCount: Int {
        plannedSessions.count { $0.status == .completed }
    }

    public var progress: Double {
        StudioPresentation.progress(completed: completedSessionCount, total: plannedSessions.count)
    }

    public init(
        project: Project,
        plan: CoursePlan? = nil,
        phases: [PlanPhase] = [],
        plannedSessions: [PlannedSession] = []
    ) {
        self.project = project
        self.plan = plan
        self.phases = phases
        self.plannedSessions = plannedSessions
    }
}

public enum StudioLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case evidence
    case reviews
    case exports

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .evidence: "Evidence"
        case .reviews: "Reviews"
        case .exports: "Exports"
        }
    }
}

public enum StudioPresentation {
    public static func weekRhythm(
        sessions: [LearningSession],
        weekContaining date: Date,
        calendar: Calendar = .current
    ) -> [StudioWeekDay] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return []
        }

        let minutesByDay = Dictionary(grouping: sessions) { session in
            calendar.startOfDay(for: session.endedAt)
        }

        return (0 ..< 7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: week.start) ?? week.start
            let normalizedDay = calendar.startOfDay(for: day)
            let minutes = minutesByDay[normalizedDay, default: []]
                .reduce(0) { $0 + $1.durationMinutes }
            return StudioWeekDay(date: normalizedDay, minutes: minutes)
        }
    }

    public static func progress(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    public static func proofMatches(query: String, proof: Proof, projectName: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return [proof.title, proof.statement, proof.type.rawValue, projectName]
            .contains { $0.lowercased().contains(query) }
    }
}
