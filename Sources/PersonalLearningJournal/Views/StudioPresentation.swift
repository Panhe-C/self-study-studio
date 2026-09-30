import Foundation

public enum StudioPrimaryTab: String, Equatable, CaseIterable, Sendable {
    case today
    case trail
    case coach
    case projects
    case calendar
    case library
    /// vNext navigation collapses Projects/Calendar/Library into a single
    /// Courses tab. The legacy cases stay until RootView migrates.
    case courses
}

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
    public let plan: LearningPlan?
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
        plan: LearningPlan? = nil,
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

public struct StudioFocus: Equatable, Sendable {
    public let project: Project
    public let planned: PlannedSessionContext?
}

public struct StudioPracticeCard: Identifiable, Equatable, Sendable {
    public var id: UUID { routine.id }
    public let routine: PracticeRoutine
    public let statistics: PracticeRoutineStatistics
    public let isActiveTimer: Bool
    public let targetSeconds: Int

    public init(
        routine: PracticeRoutine,
        statistics: PracticeRoutineStatistics,
        isActiveTimer: Bool,
        targetSeconds: Int? = nil
    ) {
        self.routine = routine
        self.statistics = statistics
        self.isActiveTimer = isActiveTimer
        self.targetSeconds = targetSeconds ?? routine.targetMinutes * 60
    }
}

public enum StudioPresentation {
    public static func primaryTabs(calendarEnabled: Bool) -> [StudioPrimaryTab] {
        calendarEnabled
            ? [.today, .projects, .calendar, .library]
            : [.today, .projects, .library]
    }

    public static func projects(_ projects: [Project], status: ProjectStatus) -> [Project] {
        projects.filter { $0.status == status }
    }

    public static func focus(
        projects: [Project],
        planned: [PlannedSessionContext]
    ) -> StudioFocus? {
        if let context = planned.first {
            return StudioFocus(project: context.project, planned: context)
        }
        guard let project = projects.first(where: \.canContinue) else { return nil }
        return StudioFocus(project: project, planned: nil)
    }

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

    public static func practiceCards(
        routines: [PracticeRoutine],
        sessions: [PracticeSession],
        activeRoutineId: UUID?,
        now: Date,
        calendar: Calendar = .current,
        scheduledOnly: Bool = true
    ) -> [StudioPracticeCard] {
        let weekday = calendar.component(.weekday, from: now)
        return routines
            .filter {
                !$0.isArchived
                    && $0.deletedAt == nil
                    && (!scheduledOnly || $0.weekdays.contains(weekday))
            }
            .map { routine in
                StudioPracticeCard(
                    routine: routine,
                    statistics: PracticeStatistics.calculate(
                        routine: routine,
                        sessions: sessions,
                        now: now,
                        calendar: calendar
                    ),
                    isActiveTimer: routine.id == activeRoutineId
                )
            }
            .sorted { left, right in
                if left.isActiveTimer != right.isActiveTimer {
                    return left.isActiveTimer
                }
                if left.routine.createdAt != right.routine.createdAt {
                    return left.routine.createdAt < right.routine.createdAt
                }
                return left.routine.name.localizedCaseInsensitiveCompare(right.routine.name) == .orderedAscending
            }
    }
}

/// The vNext Today first screen: one Up Next card plus at most two
/// alternatives. Skipped items never appear.
public struct StudioFirstScreen: Equatable, Sendable {
    public let upNext: TodayAgendaItem?
    public let alternatives: [TodayAgendaItem]

    public init(upNext: TodayAgendaItem?, alternatives: [TodayAgendaItem]) {
        self.upNext = upNext
        self.alternatives = alternatives
    }
}

/// Non-regressible vNext product contract. Expresses only navigation shape
/// and first-screen count limits; domain behavior stays in
/// `TodayAgendaService`, whose deterministic ordering this type projects.
public enum StudioExperienceContract {
    /// vNext primary navigation: execution, projects, progress, and coaching.
    public static var vNextPrimaryTabs: [StudioPrimaryTab] { [.today, .courses, .trail, .coach] }

    public static let maximumAlternatives = 2

    /// Projects agenda items (already ordered by `TodayAgendaService`) into
    /// the Today first screen.
    public static func firstScreen(agenda items: [TodayAgendaItem]) -> StudioFirstScreen {
        let upNext = items.first { $0.position == .upNext }
        let alternatives = items
            .filter { $0.position != .upNext && $0.position != .skipToday }
            .prefix(maximumAlternatives)
        return StudioFirstScreen(upNext: upNext, alternatives: Array(alternatives))
    }
}
