import Foundation

public enum TodayAgendaSource: String, Codable, CaseIterable, Hashable, Sendable {
    case plannedSession
    case practiceRoutine
    case nextStep
}

public enum TodayAgendaPosition: String, Codable, CaseIterable, Sendable {
    case upNext
    case laterToday
    case optional
    case skipToday
}

public enum TodayCarryoverReason: String, Codable, CaseIterable, Sendable {
    case planningWindowPassed
}

public enum TodayCarryoverResolution: String, Codable, CaseIterable, Sendable {
    case doToday
    case reschedule
    case skip
    case revisePlan
}

/// A local, day-scoped presentation choice. It is deliberately not a Journal
/// record: applying it never changes a Plan, Routine, completion state, or
/// Learning Trail event.
public struct TodayAgendaOverride: Codable, Equatable, Hashable, Sendable {
    public let day: Date
    public let source: TodayAgendaSource
    public let sourceID: UUID
    public let position: TodayAgendaPosition

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
}

public struct TodayCarryover: Codable, Equatable, Sendable {
    public let reason: TodayCarryoverReason
    public let originalWindowStart: Date?
    public let originalWindowEnd: Date?
    public let originalDeadline: Date?
    public let resolutions: [TodayCarryoverResolution]

    public init(
        reason: TodayCarryoverReason,
        originalWindowStart: Date?,
        originalWindowEnd: Date?,
        originalDeadline: Date?,
        resolutions: [TodayCarryoverResolution] = TodayCarryoverResolution.allCases
    ) {
        self.reason = reason
        self.originalWindowStart = originalWindowStart
        self.originalWindowEnd = originalWindowEnd
        self.originalDeadline = originalDeadline
        self.resolutions = resolutions
    }
}

public struct TodayCadenceSignal: Codable, Equatable, Identifiable, Sendable {
    public let routineID: UUID
    public let projectID: UUID
    public let occurrenceDate: Date
    public let title: String
    public let isMissed: Bool

    public var id: UUID { routineID }

    public init(
        routineID: UUID,
        projectID: UUID,
        occurrenceDate: Date,
        title: String,
        isMissed: Bool = true
    ) {
        self.routineID = routineID
        self.projectID = projectID
        self.occurrenceDate = occurrenceDate
        self.title = title
        self.isMissed = isMissed
    }
}

public struct TodayAgendaItem: Codable, Equatable, Identifiable, Sendable {
    public let source: TodayAgendaSource
    public let sourceID: UUID
    public let projectID: UUID
    public let title: String
    public let detail: String
    public let durationMinutes: Int?
    public let originalDeadline: Date?
    public let windowStart: Date?
    public let windowEnd: Date?
    public let position: TodayAgendaPosition
    public let carryover: TodayCarryover?

    public var id: String { "\(source.rawValue):\(sourceID.uuidString)" }

    public init(
        source: TodayAgendaSource,
        sourceID: UUID,
        projectID: UUID,
        title: String,
        detail: String,
        durationMinutes: Int?,
        originalDeadline: Date? = nil,
        windowStart: Date? = nil,
        windowEnd: Date? = nil,
        position: TodayAgendaPosition,
        carryover: TodayCarryover? = nil
    ) {
        self.source = source
        self.sourceID = sourceID
        self.projectID = projectID
        self.title = title
        self.detail = detail
        self.durationMinutes = durationMinutes
        self.originalDeadline = originalDeadline
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.position = position
        self.carryover = carryover
    }

    fileprivate func positioned(_ position: TodayAgendaPosition) -> TodayAgendaItem {
        TodayAgendaItem(
            source: source,
            sourceID: sourceID,
            projectID: projectID,
            title: title,
            detail: detail,
            durationMinutes: durationMinutes,
            originalDeadline: originalDeadline,
            windowStart: windowStart,
            windowEnd: windowEnd,
            position: position,
            carryover: carryover
        )
    }
}

public struct TodayAgenda: Codable, Equatable, Sendable {
    public let day: Date
    public let items: [TodayAgendaItem]
    public let cadenceSignals: [TodayCadenceSignal]

    public var isEmpty: Bool { items.isEmpty && cadenceSignals.isEmpty }

    public init(
        day: Date,
        items: [TodayAgendaItem],
        cadenceSignals: [TodayCadenceSignal] = []
    ) {
        self.day = day
        self.items = items
        self.cadenceSignals = cadenceSignals
    }
}

/// Derives one deterministic Today projection from canonical Journal records.
/// The projection is intentionally ephemeral; only explicit source actions
/// (complete, skip, reschedule, or revise) may mutate Journal records.
public struct TodayAgendaService: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func agenda(
        snapshot: JournalSnapshot,
        day: Date = Date(),
        now: Date? = nil,
        overrides: [TodayAgendaOverride] = []
    ) -> TodayAgenda {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let referenceNow = now ?? day
        let todayStart = calendar.startOfDay(for: referenceNow)
        let projects = snapshot.projects.filter {
            $0.deletedAt == nil && !$0.isTrashed && $0.canContinue
        }
        let projectByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let activePlanIDs: Set<UUID> = Set(projects.compactMap { project in
            guard let planID = project.activeCoursePlanId,
                  let plan = snapshot.coursePlans.first(where: { $0.id == planID }),
                  plan.status == .active,
                  plan.deletedAt == nil else { return nil }
            return planID
        })
        let phaseByID = Dictionary(uniqueKeysWithValues: snapshot.planPhases.map { ($0.id, $0) })

        var baseItems: [BaseAgendaItem] = []

        for session in snapshot.plannedSessions where isExecutable(session) {
            guard activePlanIDs.contains(session.planId),
                  let project = projectByID[session.projectId] else { continue }
            let phase = phaseByID[session.phaseId]
            let windowStart = phase?.targetStart ?? session.createdAt
            let windowEnd = session.deadline ?? phase?.targetEnd ?? session.createdAt
            let isCarryover = windowEnd < dayStart
            let isInToday = windowStart < dayEnd && windowEnd >= dayStart
            guard isCarryover || isInToday else { continue }

            let detail = [project.name, phase?.title].compactMap { $0 }.joined(separator: " · ")
            let carryover = isCarryover
                ? TodayCarryover(
                    reason: .planningWindowPassed,
                    originalWindowStart: windowStart,
                    originalWindowEnd: windowEnd,
                    originalDeadline: session.deadline
                )
                : nil
            baseItems.append(
                BaseAgendaItem(
                    item: TodayAgendaItem(
                        source: .plannedSession,
                        sourceID: session.id,
                        projectID: project.id,
                        title: session.title,
                        detail: detail,
                        durationMinutes: session.durationMinutes,
                        originalDeadline: session.deadline,
                        windowStart: windowStart,
                        windowEnd: windowEnd,
                        position: .laterToday,
                        carryover: carryover
                    ),
                    defaultPosition: .laterToday,
                    kindRank: carryover == nil ? 1 : 0,
                    sortDate: windowEnd,
                    sortText: session.title
                )
            )
        }

        let weekday = calendar.component(.weekday, from: dayStart)
        for routine in snapshot.operationalPracticeRoutines where
            !routine.isArchived && routine.deletedAt == nil && routine.weekdays.contains(weekday) {
            guard let projectID = routine.projectId,
                  projectByID[projectID] != nil,
                  routine.createdAt < dayEnd else { continue }
            // A past date is history, not an overdue practice task. The
            // current date and future projections may show the occurrence.
            guard dayStart >= todayStart else { continue }
            baseItems.append(
                BaseAgendaItem(
                    item: TodayAgendaItem(
                        source: .practiceRoutine,
                        sourceID: routine.id,
                        projectID: projectID,
                        title: routine.name,
                        detail: "Practice cadence · \(routine.targetMinutes) min",
                        durationMinutes: routine.targetMinutes,
                        position: .optional
                    ),
                    defaultPosition: .optional,
                    kindRank: 2,
                    sortDate: dayStart,
                    sortText: routine.name
                )
            )
        }

        // Every executable Project contributes its one canonical Next Step to
        // Today, even when the same Project also has planned or practice work.
        for project in projects {
            baseItems.append(
                BaseAgendaItem(
                    item: TodayAgendaItem(
                        source: .nextStep,
                        sourceID: project.id,
                        projectID: project.id,
                        title: project.currentNextStep,
                        detail: project.name,
                        durationMinutes: project.defaultDurationMinutes,
                        position: .optional
                    ),
                    defaultPosition: .optional,
                    kindRank: 3,
                    sortDate: project.createdAt,
                    sortText: project.currentNextStep
                )
            )
        }

        let cadenceSignals = cadenceSignals(
            snapshot: snapshot,
            projects: projectByID,
            dayStart: dayStart,
            todayStart: todayStart,
            referenceNow: referenceNow
        )
        let applied = applyOverrides(
            baseItems,
            day: dayStart,
            overrides: overrides
        )
        return TodayAgenda(day: dayStart, items: applied, cadenceSignals: cadenceSignals)
    }

    private func isExecutable(_ session: PlannedSession) -> Bool {
        session.deletedAt == nil && (session.status == .scheduled || session.status == .unscheduled)
    }

    private func cadenceSignals(
        snapshot: JournalSnapshot,
        projects: [UUID: Project],
        dayStart: Date,
        todayStart: Date,
        referenceNow: Date
    ) -> [TodayCadenceSignal] {
        guard dayStart <= todayStart else { return [] }
        let routines = snapshot.operationalPracticeRoutines.filter {
            !$0.isArchived && $0.deletedAt == nil &&
            $0.projectId.flatMap { projects[$0] } != nil
        }
        let sessions = snapshot.practiceSessions.filter { $0.deletedAt == nil }
        return routines.compactMap { routine in
            guard let projectID = routine.projectId else { return nil }
            for offset in 1...7 {
                guard let occurrence = calendar.date(byAdding: .day, value: -offset, to: dayStart) else { continue }
                let occurrenceStart = calendar.startOfDay(for: occurrence)
                let occurrenceWeekday = calendar.component(.weekday, from: occurrenceStart)
                guard routine.weekdays.contains(occurrenceWeekday),
                      occurrenceStart >= calendar.startOfDay(for: routine.createdAt),
                      occurrenceStart <= calendar.startOfDay(for: referenceNow) else { continue }
                let hadSession = sessions.contains { session in
                    session.routineId == routine.id &&
                    calendar.isDate(session.startedAt, inSameDayAs: occurrenceStart)
                }
                guard !hadSession else { return nil }
                return TodayCadenceSignal(
                    routineID: routine.id,
                    projectID: projectID,
                    occurrenceDate: occurrenceStart,
                    title: routine.name
                )
            }
            return nil
        }
        .sorted { left, right in
            if left.occurrenceDate != right.occurrenceDate {
                return left.occurrenceDate < right.occurrenceDate
            }
            return left.routineID.uuidString < right.routineID.uuidString
        }
    }

    private func applyOverrides(
        _ baseItems: [BaseAgendaItem],
        day: Date,
        overrides: [TodayAgendaOverride]
    ) -> [TodayAgendaItem] {
        struct Key: Hashable {
            let source: TodayAgendaSource
            let sourceID: UUID
        }
        struct Applied {
            let item: BaseAgendaItem
            let requested: TodayAgendaPosition
            let overrideOrder: Int?
        }

        var overrideMap: [Key: (TodayAgendaPosition, Int)] = [:]
        for (index, override) in overrides.enumerated() where calendar.isDate(override.day, inSameDayAs: day) {
            overrideMap[Key(source: override.source, sourceID: override.sourceID)] = (override.position, index)
        }
        let sortedBaseItems = baseItems.sorted(by: isCanonicalBaseOrder)
        let applied = sortedBaseItems.map { item in
            let key = Key(source: item.item.source, sourceID: item.item.sourceID)
            let value = overrideMap[key]
            return Applied(
                item: item,
                requested: value?.0 ?? item.defaultPosition,
                overrideOrder: value?.1
            )
        }
        let explicitUpNext = applied
            .filter { $0.requested == .upNext }
            .max { left, right in
                let leftOrder = left.overrideOrder ?? .min
                let rightOrder = right.overrideOrder ?? .min
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return isCanonicalBaseOrder(left.item, right.item)
            }
        let selectedID = explicitUpNext?.item.item.id
            ?? applied.first(where: { $0.requested != .skipToday })?.item.item.id

        return applied
            .map { value in
                let position = resolvedPosition(
                    requested: value.requested,
                    defaultPosition: value.item.defaultPosition,
                    itemID: value.item.item.id,
                    selectedID: selectedID
                )
                return (value.item, position)
            }
            .sorted { left, right in
                let leftGroup = sortGroup(left.1)
                let rightGroup = sortGroup(right.1)
                if leftGroup != rightGroup { return leftGroup < rightGroup }
                return isCanonicalBaseOrder(left.0, right.0)
            }
            .map { value in
                value.0.item.positioned(value.1)
            }
    }

    private func resolvedPosition(
        requested: TodayAgendaPosition,
        defaultPosition: TodayAgendaPosition,
        itemID: String,
        selectedID: String?
    ) -> TodayAgendaPosition {
        if itemID == selectedID, requested != .skipToday {
            return .upNext
        }
        switch requested {
        case .skipToday:
            return .skipToday
        case .upNext:
            if itemID == selectedID { return .upNext }
            // A stale or older explicit Up Next is demoted to the item's
            // declared default instead of creating a second Up Next.
            return defaultPosition == .upNext ? .laterToday : defaultPosition
        case .laterToday:
            return .laterToday
        case .optional:
            return .optional
        }
    }

    private func sortGroup(_ position: TodayAgendaPosition) -> Int {
        switch position {
        case .upNext: return 0
        case .laterToday: return 1
        case .optional: return 2
        case .skipToday: return 3
        }
    }

    private func isCanonicalBaseOrder(_ left: BaseAgendaItem, _ right: BaseAgendaItem) -> Bool {
        if left.kindRank != right.kindRank { return left.kindRank < right.kindRank }
        if left.sortDate != right.sortDate { return left.sortDate < right.sortDate }
        let leftText = left.sortText.lowercased()
        let rightText = right.sortText.lowercased()
        if leftText != rightText { return leftText < rightText }
        return left.item.id < right.item.id
    }

    private struct BaseAgendaItem {
        let item: TodayAgendaItem
        let defaultPosition: TodayAgendaPosition
        let kindRank: Int
        let sortDate: Date
        let sortText: String
    }
}
