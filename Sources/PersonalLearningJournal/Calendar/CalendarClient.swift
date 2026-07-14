import Foundation

public enum CalendarAuthorizationState: Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
    case restricted
}

public enum CalendarClientError: Error, Equatable, Sendable {
    case accessDenied
    case calendarUnavailable
    case eventUnavailable
}

public struct CalendarDescriptor: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var allowsContentModifications: Bool
    public var isDefault: Bool

    public init(id: String, title: String, allowsContentModifications: Bool, isDefault: Bool) {
        self.id = id
        self.title = title
        self.allowsContentModifications = allowsContentModifications
        self.isDefault = isDefault
    }
}

public protocol CalendarClient: Sendable {
    func authorizationState() async -> CalendarAuthorizationState
    func requestFullAccess() async throws -> CalendarAuthorizationState
    func writableCalendars() async throws -> [CalendarDescriptor]
    func busyIntervals(in range: DateInterval) async throws -> [BusyInterval]
    func event(identifier: String) async throws -> CalendarEventSnapshot?
    func save(_ event: CalendarEventDraft) async throws -> CalendarEventSnapshot
    func delete(identifier: String) async throws
}
