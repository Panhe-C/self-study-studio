import Foundation

public enum CalendarEventTitleStyle: String, Codable, CaseIterable, Sendable {
    case project
    case session
    case `private`
}

public enum CalendarValidationError: Error, Equatable, Sendable {
    case invalidAvailabilityRange
    case invalidWeekday
    case invalidDuration
    case invalidTimeZone
}

public struct AvailabilityRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var weekday: Int
    public var startMinute: Int
    public var endMinute: Int
    public var timeZoneIdentifier: String
    public var validFrom: Date?
    public var validThrough: Date?
    public var minimumSessionMinutes: Int
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        weekday: Int,
        startMinute: Int,
        endMinute: Int,
        timeZoneIdentifier: String,
        validFrom: Date? = nil,
        validThrough: Date? = nil,
        minimumSessionMinutes: Int,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
    ) throws {
        guard (1...7).contains(weekday) else { throw CalendarValidationError.invalidWeekday }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw CalendarValidationError.invalidTimeZone }
        guard startMinute >= 0, endMinute <= 24 * 60, endMinute > startMinute else {
            throw CalendarValidationError.invalidAvailabilityRange
        }
        guard minimumSessionMinutes > 0, endMinute - startMinute >= minimumSessionMinutes else {
            throw CalendarValidationError.invalidDuration
        }
        guard validFrom.map({ from in validThrough.map { from <= $0 } ?? true }) ?? true else {
            throw CalendarValidationError.invalidAvailabilityRange
        }
        self.id = id
        self.weekday = weekday
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.timeZoneIdentifier = timeZoneIdentifier
        self.validFrom = validFrom
        self.validThrough = validThrough
        self.minimumSessionMinutes = minimumSessionMinutes
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }
}

public struct SchedulingPreferences: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var preferredSessionMinutes: Int
    public var maximumDailyMinutes: Int
    public var minimumGapMinutes: Int
    public var allowWeekends: Bool
    public var eventTitleStyle: CalendarEventTitleStyle
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        preferredSessionMinutes: Int,
        maximumDailyMinutes: Int,
        minimumGapMinutes: Int,
        allowWeekends: Bool = true,
        eventTitleStyle: CalendarEventTitleStyle = .project,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        schemaVersion: Int = JournalSchema.currentVersion
    ) throws {
        guard preferredSessionMinutes > 0, maximumDailyMinutes > 0, minimumGapMinutes >= 0 else {
            throw CalendarValidationError.invalidDuration
        }
        self.id = id
        self.preferredSessionMinutes = preferredSessionMinutes
        self.maximumDailyMinutes = maximumDailyMinutes
        self.minimumGapMinutes = minimumGapMinutes
        self.allowWeekends = allowWeekends
        self.eventTitleStyle = eventTitleStyle
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
    }
}

public struct BusyInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public enum ScheduleConflictReason: String, Codable, Sendable {
    case outsideAvailability
    case overlapsBusyTime
    case exceedsDailyLimit
    case violatesMinimumGap
    case insufficientCapacityBeforeDeadline
    case invalidTimeZone
}

public struct ScheduledPlacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var start: Date
    public var end: Date
    public var isPinned: Bool

    public init(id: UUID = UUID(), sessionID: UUID, start: Date, end: Date, isPinned: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.start = start
        self.end = end
        self.isPinned = isPinned
    }
}

public struct ScheduleConflict: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var reason: ScheduleConflictReason
    public var detail: String

    public init(id: UUID = UUID(), sessionID: UUID, reason: ScheduleConflictReason, detail: String) {
        self.id = id
        self.sessionID = sessionID
        self.reason = reason
        self.detail = detail
    }
}

public struct ScheduleDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var range: DateInterval
    public var placements: [ScheduledPlacement]
    public var unscheduledSessionIDs: [UUID]
    public var conflicts: [ScheduleConflict]
    public var generatedAt: Date

    public init(
        id: UUID = UUID(),
        range: DateInterval,
        placements: [ScheduledPlacement],
        unscheduledSessionIDs: [UUID],
        conflicts: [ScheduleConflict],
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.range = range
        self.placements = placements
        self.unscheduledSessionIDs = unscheduledSessionIDs
        self.conflicts = conflicts
        self.generatedAt = generatedAt
    }
}

public enum CalendarBindingState: String, Codable, Sendable {
    case linked
    case externallyModified
    case externallyDeleted
    case detached
}

public enum CalendarChangeOperation: String, Codable, Sendable {
    case create
    case update
    case delete
}

public struct CalendarEventSnapshot: Codable, Equatable, Sendable {
    public var identifier: String
    public var calendarIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var lastModifiedAt: Date?

    public init(identifier: String, calendarIdentifier: String, title: String, start: Date, end: Date, lastModifiedAt: Date? = nil) {
        self.identifier = identifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.lastModifiedAt = lastModifiedAt
    }
}

public struct CalendarEventDraft: Codable, Equatable, Sendable {
    public var identifier: String?
    public var calendarIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date

    public init(identifier: String? = nil, calendarIdentifier: String, title: String, start: Date, end: Date) {
        self.identifier = identifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.start = start
        self.end = end
    }
}

public struct CalendarBinding: Codable, Equatable, Sendable {
    public var plannedSessionId: UUID
    public var eventIdentifier: String
    public var calendarIdentifier: String
    public var lastWrittenTitle: String
    public var lastWrittenStart: Date
    public var lastWrittenEnd: Date
    public var lastObservedAt: Date
    public var state: CalendarBindingState

    public init(
        plannedSessionId: UUID,
        eventIdentifier: String,
        calendarIdentifier: String,
        lastWrittenTitle: String,
        lastWrittenStart: Date,
        lastWrittenEnd: Date,
        lastObservedAt: Date,
        state: CalendarBindingState
    ) {
        self.plannedSessionId = plannedSessionId
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.lastWrittenTitle = lastWrittenTitle
        self.lastWrittenStart = lastWrittenStart
        self.lastWrittenEnd = lastWrittenEnd
        self.lastObservedAt = lastObservedAt
        self.state = state
    }
}

public struct CalendarChange: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var plannedSessionID: UUID
    public var operation: CalendarChangeOperation
    public var before: CalendarEventSnapshot?
    public var after: CalendarEventDraft?

    public init(id: UUID = UUID(), plannedSessionID: UUID, operation: CalendarChangeOperation, before: CalendarEventSnapshot? = nil, after: CalendarEventDraft? = nil) {
        self.id = id
        self.plannedSessionID = plannedSessionID
        self.operation = operation
        self.before = before
        self.after = after
    }
}

public struct CalendarChangeSet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var items: [CalendarChange]
    public var createdAt: Date

    public init(id: UUID = UUID(), items: [CalendarChange], createdAt: Date = Date()) {
        self.id = id
        self.items = items
        self.createdAt = createdAt
    }
}
