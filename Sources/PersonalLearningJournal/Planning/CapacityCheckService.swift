import Foundation

public struct CapacityProjectLoad: Codable, Equatable, Identifiable, Sendable {
    public let projectID: UUID
    public let plannedMinutes: Int
    public let practiceMinutes: Int

    public var id: UUID { projectID }
    public var totalMinutes: Int { plannedMinutes + practiceMinutes }

    public init(projectID: UUID, plannedMinutes: Int = 0, practiceMinutes: Int = 0) {
        self.projectID = projectID
        self.plannedMinutes = plannedMinutes
        self.practiceMinutes = practiceMinutes
    }
}

public struct CapacityWeek: Codable, Equatable, Identifiable, Sendable {
    public let weekStart: Date
    public let weekEnd: Date
    public let availableMinutes: Int
    public let plannedMinutes: Int
    public let practiceMinutes: Int
    public let projectLoads: [CapacityProjectLoad]

    public var id: Date { weekStart }
    public var totalMinutes: Int { plannedMinutes + practiceMinutes }
    public var overageMinutes: Int { max(0, totalMinutes - availableMinutes) }
    public var isOverCapacity: Bool { overageMinutes > 0 }

    public init(
        weekStart: Date,
        weekEnd: Date,
        availableMinutes: Int,
        plannedMinutes: Int,
        practiceMinutes: Int,
        projectLoads: [CapacityProjectLoad]
    ) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.availableMinutes = max(0, availableMinutes)
        self.plannedMinutes = max(0, plannedMinutes)
        self.practiceMinutes = max(0, practiceMinutes)
        self.projectLoads = projectLoads.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
    }
}

public struct CapacityWarning: Codable, Equatable, Identifiable, Sendable {
    public let weekStart: Date
    public let overageMinutes: Int
    public let projectIDs: [UUID]
    public let message: String

    public var id: Date { weekStart }
    public var requiresAcknowledgement: Bool { true }

    public init(
        weekStart: Date,
        overageMinutes: Int,
        projectIDs: [UUID],
        message: String
    ) {
        self.weekStart = weekStart
        self.overageMinutes = overageMinutes
        self.projectIDs = projectIDs.sorted { $0.uuidString < $1.uuidString }
        self.message = message
    }
}

public struct CapacityCheckResult: Codable, Equatable, Sendable {
    public let weeks: [CapacityWeek]
    public let warnings: [CapacityWarning]

    public var isOverCapacity: Bool { !warnings.isEmpty }
    public var requiresAcknowledgement: Bool { isOverCapacity }
    public var firstWarning: CapacityWarning? { warnings.first }

    public init(weeks: [CapacityWeek] = [], warnings: [CapacityWarning] = []) {
        self.weeks = weeks.sorted { $0.weekStart < $1.weekStart }
        self.warnings = warnings.sorted { $0.weekStart < $1.weekStart }
    }
}

/// Deterministic weekly capacity derivation. It consumes planning windows,
/// estimated Planned Session duration, operational Practice Cadence load, and
/// explicit availability. It never creates completions, calendar events, or
/// any other Journal record.
public struct CapacityCheckService: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func check(
        draft: CoursePlanDraft,
        input: CoursePlanningInput,
        practiceRoutines: [PracticeRoutine] = [],
        availabilityRules: [AvailabilityRule] = []
    ) -> CapacityCheckResult {
        let phases = Dictionary(uniqueKeysWithValues: draft.phases.map { ($0.id, $0) })
        let planned = draft.sessions.compactMap { session -> PlannedLoad? in
            guard let phase = phases[session.phaseID] else { return nil }
            let window = session.planningWindow
                ?? (try? PlanningWindow(
                    start: phase.targetStart,
                    end: phase.targetEnd,
                    granularity: .dateRange
                ))
            let assignmentDate = session.deadline
                ?? session.planningWindow?.start
                ?? phase.targetStart
            return PlannedLoad(
                id: session.id,
                projectID: input.projectId,
                minutes: max(0, session.durationMinutes),
                assignmentDate: assignmentDate,
                window: window
            )
        }
        return derive(
            planned: planned,
            practiceRoutines: practiceRoutines,
            availabilityRules: availabilityRules,
            availableMinutesByWeekday: input.availableMinutesByWeekday,
            fallbackStart: input.startsOn,
            fallbackEnd: input.deadline
        )
    }

    /// Capacity for an already persisted plan/revision. Existing phase ranges
    /// are treated as Planning Windows, while an explicit session deadline is
    /// used as its due-date assignment when present.
    public func check(
        plan: LearningPlan,
        phases: [PlanPhase],
        sessions: [PlannedSession],
        practiceRoutines: [PracticeRoutine] = [],
        availabilityRules: [AvailabilityRule] = []
    ) -> CapacityCheckResult {
        let phaseByID = Dictionary(uniqueKeysWithValues: phases.map { ($0.id, $0) })
        let planned = sessions.compactMap { session -> PlannedLoad? in
            guard let phase = phaseByID[session.phaseId],
                  session.status != .completed,
                  session.status != .skipped,
                  session.status != .cancelled,
                  session.deletedAt == nil else { return nil }
            let window = session.planningWindow ?? (try? PlanningWindow(
                start: phase.targetStart,
                end: session.deadline ?? phase.targetEnd,
                granularity: .dateRange
            ))
            return PlannedLoad(
                id: session.id.uuidString,
                projectID: session.projectId,
                minutes: max(0, session.durationMinutes),
                assignmentDate: session.deadline
                    ?? session.planningWindow?.start
                    ?? phase.targetStart,
                window: window
            )
        }
        return derive(
            planned: planned,
            practiceRoutines: practiceRoutines,
            availabilityRules: availabilityRules,
            availableMinutesByWeekday: [:],
            fallbackStart: plan.startsOn,
            fallbackEnd: plan.deadline
        )
    }

    public func check(
        snapshot: JournalSnapshot,
        planID: UUID,
        availabilityRules: [AvailabilityRule]? = nil
    ) -> CapacityCheckResult {
        guard let plan = snapshot.coursePlans.first(where: { $0.id == planID }) else {
            return CapacityCheckResult()
        }
        return check(
            plan: plan,
            phases: snapshot.planPhases.filter { $0.planId == planID },
            sessions: snapshot.plannedSessions.filter { $0.planId == planID },
            practiceRoutines: snapshot.operationalPracticeRoutines,
            availabilityRules: availabilityRules ?? snapshot.availabilityRules.filter { $0.deletedAt == nil }
        )
    }

    private func derive(
        planned: [PlannedLoad],
        practiceRoutines: [PracticeRoutine],
        availabilityRules: [AvailabilityRule],
        availableMinutesByWeekday: [Int: Int],
        fallbackStart: Date,
        fallbackEnd: Date?
    ) -> CapacityCheckResult {
        let dates = planned.map(\.assignmentDate)
            + [fallbackStart]
            + (fallbackEnd.map { [$0] } ?? [])
        let startDate = dates.min() ?? fallbackStart
        let endDate = dates.max() ?? fallbackStart
        let firstWeek = weekInterval(containing: startDate)
        let lastWeek = weekInterval(containing: max(endDate, startDate))
        var weekStarts: [Date] = []
        var cursor = firstWeek.start
        while cursor <= lastWeek.start {
            weekStarts.append(cursor)
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor) else { break }
            if next == cursor { break }
            cursor = next
        }

        var weeks: [CapacityWeek] = []
        var warnings: [CapacityWarning] = []
        let hasStatedAvailability = !availabilityRules.isEmpty || !availableMinutesByWeekday.isEmpty
        for weekStart in weekStarts {
            let week = weekInterval(containing: weekStart)
            let plannedForWeek = planned.filter { week.contains($0.assignmentDate) }
            let routineLoads = practiceLoads(
                routines: practiceRoutines,
                in: week
            )
            let available = availableMinutes(
                in: week,
                rules: availabilityRules,
                fallbackByWeekday: availableMinutesByWeekday
            )
            var projectMinutes: [UUID: (planned: Int, practice: Int)] = [:]
            for item in plannedForWeek {
                projectMinutes[item.projectID, default: (0, 0)].planned += item.minutes
            }
            for (projectID, minutes) in routineLoads {
                projectMinutes[projectID, default: (0, 0)].practice += minutes
            }
            let loads = projectMinutes.map { projectID, value in
                CapacityProjectLoad(
                    projectID: projectID,
                    plannedMinutes: value.planned,
                    practiceMinutes: value.practice
                )
            }
            let weekValue = CapacityWeek(
                weekStart: week.start,
                weekEnd: week.end,
                availableMinutes: available,
                plannedMinutes: plannedForWeek.reduce(0) { $0 + $1.minutes },
                practiceMinutes: routineLoads.values.reduce(0, +),
                projectLoads: loads
            )
            weeks.append(weekValue)
            if hasStatedAvailability && weekValue.isOverCapacity {
                warnings.append(
                    CapacityWarning(
                        weekStart: weekValue.weekStart,
                        overageMinutes: weekValue.overageMinutes,
                        projectIDs: loads.filter { $0.totalMinutes > 0 }.map(\.projectID),
                        message: "Week \(weekValue.weekStart.ISO8601Format()) exceeds available capacity by \(weekValue.overageMinutes) min."
                    )
                )
            }
        }
        return CapacityCheckResult(weeks: weeks, warnings: warnings)
    }

    private func weekInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(
                start: calendar.startOfDay(for: date),
                duration: 7 * 86_400
            )
    }

    private func availableMinutes(
        in week: DateInterval,
        rules: [AvailabilityRule],
        fallbackByWeekday: [Int: Int]
    ) -> Int {
        if rules.isEmpty {
            guard !fallbackByWeekday.isEmpty else { return 0 }
            return days(in: week).reduce(0) { total, day in
                total + max(0, fallbackByWeekday[calendar.component(.weekday, from: day)] ?? 0)
            }
        }
        return days(in: week).reduce(0) { total, day in
            total + rules.reduce(0) { ruleTotal, rule in
                guard rule.enabled,
                      rule.validFrom.map({ day >= calendar.startOfDay(for: $0) }) ?? true,
                      rule.validThrough.map({ day <= calendar.startOfDay(for: $0) }) ?? true,
                      let ruleTimeZone = TimeZone(identifier: rule.timeZoneIdentifier)
                else { return ruleTotal }
                var ruleCalendar = calendar
                ruleCalendar.timeZone = ruleTimeZone
                guard ruleCalendar.component(.weekday, from: day) == rule.weekday,
                      let start = ruleCalendar.date(
                          from: DateComponents(
                              calendar: ruleCalendar,
                              timeZone: ruleTimeZone,
                              year: ruleCalendar.component(.year, from: day),
                              month: ruleCalendar.component(.month, from: day),
                              day: ruleCalendar.component(.day, from: day),
                              hour: rule.startMinute / 60,
                              minute: rule.startMinute % 60
                          )
                      ),
                      let end = ruleCalendar.date(
                          from: DateComponents(
                              calendar: ruleCalendar,
                              timeZone: ruleTimeZone,
                              year: ruleCalendar.component(.year, from: day),
                              month: ruleCalendar.component(.month, from: day),
                              day: ruleCalendar.component(.day, from: day),
                              hour: rule.endMinute / 60,
                              minute: rule.endMinute % 60
                          )
                      ),
                      let intersection = DateInterval(start: start, end: end).intersection(with: week)
                else { return ruleTotal }
                return ruleTotal + Int(intersection.duration / 60)
            }
        }
    }

    private func practiceLoads(
        routines: [PracticeRoutine],
        in week: DateInterval
    ) -> [UUID: Int] {
        var loads: [UUID: Int] = [:]
        for routine in routines where !routine.isArchived && routine.deletedAt == nil {
            guard let projectID = routine.projectId else { continue }
            for day in days(in: week) {
                guard routine.weekdays.contains(calendar.component(.weekday, from: day)),
                      routine.createdAt < calendar.date(byAdding: .day, value: 1, to: day)!
                else { continue }
                loads[projectID, default: 0] += max(0, routine.targetMinutes)
            }
        }
        return loads
    }

    private func days(in interval: DateInterval) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            if next == day { break }
            day = next
        }
        return result
    }

    private struct PlannedLoad {
        let id: String
        let projectID: UUID
        let minutes: Int
        let assignmentDate: Date
        let window: PlanningWindow?
    }
}
