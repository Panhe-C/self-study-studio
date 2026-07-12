import Foundation

public struct SchedulingRequest: Sendable {
    public var sessions: [PlannedSession]
    public var availability: [AvailabilityRule]
    public var preferences: SchedulingPreferences
    public var busyIntervals: [BusyInterval]
    public var pinnedPlacements: [ScheduledPlacement]
    public var range: DateInterval
    public var timeZoneIdentifier: String
    public var now: Date

    public init(
        sessions: [PlannedSession],
        availability: [AvailabilityRule],
        preferences: SchedulingPreferences,
        busyIntervals: [BusyInterval],
        pinnedPlacements: [ScheduledPlacement],
        range: DateInterval,
        timeZoneIdentifier: String,
        now: Date
    ) {
        self.sessions = sessions
        self.availability = availability
        self.preferences = preferences
        self.busyIntervals = busyIntervals
        self.pinnedPlacements = pinnedPlacements
        self.range = range
        self.timeZoneIdentifier = timeZoneIdentifier
        self.now = now
    }
}

public struct StudySchedulingEngine {
    public init() {}

    public func makeDraft(_ request: SchedulingRequest) throws -> ScheduleDraft {
        guard let timeZone = TimeZone(identifier: request.timeZoneIdentifier) else {
            throw CalendarValidationError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let windows = availabilityWindows(for: request, calendar: calendar)
        var placements = request.pinnedPlacements.sorted { ($0.start, $0.sessionID.uuidString) < ($1.start, $1.sessionID.uuidString) }
        let pinnedIDs = Set(request.pinnedPlacements.map(\.sessionID))
        let candidates = request.sessions
            .filter {
                $0.status != .completed && $0.status != .skipped && $0.status != .cancelled && !pinnedIDs.contains($0.id)
            }
            .sorted {
                let leftDeadline = $0.deadline ?? .distantFuture
                let rightDeadline = $1.deadline ?? .distantFuture
                return leftDeadline == rightDeadline ? $0.id.uuidString < $1.id.uuidString : leftDeadline < rightDeadline
            }

        var unscheduled: [UUID] = []
        var conflicts: [ScheduleConflict] = []
        for session in candidates {
            let result = findPlacement(
                for: session,
                windows: windows,
                placements: placements,
                request: request,
                calendar: calendar
            )
            if let placement = result.placement {
                placements.append(placement)
                placements.sort { ($0.start, $0.sessionID.uuidString) < ($1.start, $1.sessionID.uuidString) }
            } else {
                unscheduled.append(session.id)
                conflicts.append(
                    ScheduleConflict(
                        sessionID: session.id,
                        reason: result.reason,
                        detail: result.detail
                    )
                )
            }
        }

        let uniqueConflicts = Dictionary(
            conflicts.map { ("\($0.sessionID.uuidString):\($0.reason.rawValue)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .sorted { ($0.sessionID.uuidString, $0.reason.rawValue) < ($1.sessionID.uuidString, $1.reason.rawValue) }

        return ScheduleDraft(
            range: request.range,
            placements: placements,
            unscheduledSessionIDs: unscheduled,
            conflicts: uniqueConflicts,
            generatedAt: request.now
        )
    }

    private func availabilityWindows(
        for request: SchedulingRequest,
        calendar: Calendar
    ) -> [DateInterval] {
        let rangeStart = calendar.startOfDay(for: request.range.start)
        let rangeEnd = request.range.end
        var day = rangeStart
        var windows: [DateInterval] = []
        while day < rangeEnd {
            let weekday = calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7
            for rule in request.availability where rule.enabled && (request.preferences.allowWeekends || !isWeekend) {
                guard rule.weekday == weekday,
                      rule.validFrom.map({ day >= calendar.startOfDay(for: $0) }) ?? true,
                      rule.validThrough.map({ day <= calendar.startOfDay(for: $0) }) ?? true,
                      let ruleTimeZone = TimeZone(identifier: rule.timeZoneIdentifier)
                else { continue }
                var ruleCalendar = calendar
                ruleCalendar.timeZone = ruleTimeZone
                guard let start = ruleCalendar.date(byAdding: .minute, value: rule.startMinute, to: ruleCalendar.startOfDay(for: day)),
                      let end = ruleCalendar.date(byAdding: .minute, value: rule.endMinute, to: ruleCalendar.startOfDay(for: day))
                else { continue }
                let interval = DateInterval(start: start, end: end).intersection(with: request.range)
                if let interval, interval.duration >= TimeInterval(rule.minimumSessionMinutes * 60) {
                    windows.append(interval)
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return windows.sorted { $0.start < $1.start }
    }

    private func findPlacement(
        for session: PlannedSession,
        windows: [DateInterval],
        placements: [ScheduledPlacement],
        request: SchedulingRequest,
        calendar: Calendar
    ) -> (placement: ScheduledPlacement?, reason: ScheduleConflictReason, detail: String) {
        let duration = TimeInterval(session.durationMinutes * 60)
        var foundDailyLimit = false
        var foundGapConflict = false
        var foundBusyOverlap = false
        let deadline = session.deadline

        for window in windows {
            var cursor = max(window.start, request.now)
            while cursor.addingTimeInterval(duration) <= window.end {
                let end = cursor.addingTimeInterval(duration)
                if let deadline, end > deadline {
                    break
                }
                let candidate = DateInterval(start: cursor, end: end)
                let blockers = request.busyIntervals.map { DateInterval(start: $0.start, end: $0.end) }
                if blockers.contains(where: { overlaps(candidate, $0) }) {
                    foundBusyOverlap = true
                    cursor = nextCursor(after: blockers, candidate: candidate, current: cursor)
                    continue
                }

                let placementIntervals = placements.map { DateInterval(start: $0.start, end: $0.end) }
                if placementIntervals.contains(where: { overlaps(candidate, $0) }) {
                    cursor = nextCursor(after: placementIntervals, candidate: candidate, current: cursor)
                    continue
                }

                if violatesMinimumGap(candidate, placements: placements, minimumGap: request.preferences.minimumGapMinutes) {
                    foundGapConflict = true
                    cursor = cursor.addingTimeInterval(60)
                    continue
                }

                let dailyLoad = dailyMinutes(on: cursor, placements: placements, calendar: calendar)
                if dailyLoad + session.durationMinutes > request.preferences.maximumDailyMinutes {
                    foundDailyLimit = true
                    break
                }

                return (
                    ScheduledPlacement(sessionID: session.id, start: cursor, end: end),
                    .outsideAvailability,
                    ""
                )
            }
        }

        if foundDailyLimit {
            return (nil, .exceedsDailyLimit, "Daily study limit leaves no slot for this session.")
        }
        if foundGapConflict {
            return (nil, .violatesMinimumGap, "Minimum gap between study sessions leaves no slot.")
        }
        if foundBusyOverlap {
            return (nil, .overlapsBusyTime, "Busy time overlaps every available slot.")
        }
        if deadline != nil {
            return (nil, .insufficientCapacityBeforeDeadline, "No available slot fits before the session deadline.")
        }
        return (nil, .outsideAvailability, "No enabled availability window can fit this session.")
    }

    private func nextCursor(after intervals: [DateInterval], candidate: DateInterval, current: Date) -> Date {
        let laterEnds = intervals.filter { overlaps(candidate, $0) }.map(\.end)
        return laterEnds.max() ?? current
    }

    private func dailyMinutes(on date: Date, placements: [ScheduledPlacement], calendar: Calendar) -> Int {
        let day = calendar.startOfDay(for: date)
        return placements.reduce(0) { total, placement in
            guard calendar.startOfDay(for: placement.start) == day else { return total }
            return total + Int(placement.end.timeIntervalSince(placement.start) / 60)
        }
    }

    private func violatesMinimumGap(
        _ candidate: DateInterval,
        placements: [ScheduledPlacement],
        minimumGap: Int
    ) -> Bool {
        guard minimumGap > 0 else { return false }
        let gap = TimeInterval(minimumGap * 60)
        return placements.contains {
            candidate.start < $0.end.addingTimeInterval(gap)
                && candidate.end > $0.start.addingTimeInterval(-gap)
        }
    }

    private func overlaps(_ left: DateInterval, _ right: DateInterval) -> Bool {
        left.start < right.end && right.start < left.end
    }
}
