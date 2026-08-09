import Foundation

/// The temporal shape of a learning commitment before an exact calendar
/// appointment is chosen.
public enum PlanningWindowGranularity: String, Codable, CaseIterable, Hashable, Sendable {
    case day
    case week
    case dateRange

    public var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .dateRange: "Date range"
        }
    }
}

/// Compatibility spelling for callers that describe the field as a unit.
public typealias PlanningWindowUnit = PlanningWindowGranularity

public enum PlanningWindowValidationError: Error, Equatable, Sendable {
    case invalidRange
}

/// A flexible, calendar-independent target range. It is deliberately not an
/// EventKit commitment: converting it into an exact placement happens only in
/// a schedule draft and still requires the existing preview/confirmation flow.
public struct PlanningWindow: Codable, Equatable, Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let granularity: PlanningWindowGranularity

    public init(
        start: Date,
        end: Date,
        granularity: PlanningWindowGranularity
    ) throws {
        guard end >= start else {
            throw PlanningWindowValidationError.invalidRange
        }
        self.start = start
        self.end = end
        self.granularity = granularity
    }

    public var interval: DateInterval {
        DateInterval(start: start, end: end)
    }

    public func contains(_ date: Date) -> Bool {
        interval.contains(date)
    }

    public static func day(
        containing date: Date,
        calendar: Calendar = .current
    ) throws -> PlanningWindow {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return try PlanningWindow(start: start, end: end, granularity: .day)
    }

    public static func week(
        containing date: Date,
        calendar: Calendar = .current
    ) throws -> PlanningWindow {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86_400)
        return try PlanningWindow(start: interval.start, end: interval.end, granularity: .week)
    }
}
