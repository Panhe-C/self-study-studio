@preconcurrency import EventKit
import Foundation

@MainActor
public final class EventKitCalendarClient: CalendarClient {
    private let eventStore: EKEventStore

    public init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    public func authorizationState() async -> CalendarAuthorizationState {
        mapAuthorization(EKEventStore.authorizationStatus(for: .event))
    }

    public func requestFullAccess() async throws -> CalendarAuthorizationState {
        if #available(iOS 17.0, macOS 14.0, *) {
            _ = try await eventStore.requestFullAccessToEvents()
        } else {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            guard granted else { return .denied }
        }
        return mapAuthorization(EKEventStore.authorizationStatus(for: .event))
    }

    public func writableCalendars() async throws -> [CalendarDescriptor] {
        try requireFullAccess()
        let defaultIdentifier = eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        return eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map {
                CalendarDescriptor(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    allowsContentModifications: $0.allowsContentModifications,
                    isDefault: $0.calendarIdentifier == defaultIdentifier
                )
            }
            .sorted { ($0.isDefault ? 0 : 1, $0.title) < ($1.isDefault ? 0 : 1, $1.title) }
    }

    public func busyIntervals(in range: DateInterval) async throws -> [BusyInterval] {
        try requireFullAccess()
        let predicate = eventStore.predicateForEvents(
            withStart: range.start,
            end: range.end,
            calendars: nil
        )
        let intervals = eventStore.events(matching: predicate)
            .map { BusyInterval(start: $0.startDate, end: $0.endDate) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        return merge(intervals)
    }

    public func event(identifier: String) async throws -> CalendarEventSnapshot? {
        try requireFullAccess()
        return eventStore.event(withIdentifier: identifier).map(snapshot)
    }

    public func save(_ event: CalendarEventDraft) async throws -> CalendarEventSnapshot {
        try requireFullAccess()
        guard let calendar = eventStore.calendar(withIdentifier: event.calendarIdentifier),
              calendar.allowsContentModifications else {
            throw CalendarClientError.calendarUnavailable
        }
        let stored = event.identifier.flatMap { eventStore.event(withIdentifier: $0) } ?? EKEvent(eventStore: eventStore)
        stored.calendar = calendar
        stored.title = event.title
        stored.startDate = event.start
        stored.endDate = event.end
        try eventStore.save(stored, span: .thisEvent, commit: true)
        return snapshot(stored)
    }

    public func delete(identifier: String) async throws {
        try requireFullAccess()
        guard let stored = eventStore.event(withIdentifier: identifier) else {
            throw CalendarClientError.eventUnavailable
        }
        try eventStore.remove(stored, span: .thisEvent, commit: true)
    }

    private func requireFullAccess() throws {
        guard mapAuthorization(EKEventStore.authorizationStatus(for: .event)) == .fullAccess else {
            throw CalendarClientError.accessDenied
        }
    }

    private func snapshot(_ event: EKEvent) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            identifier: event.eventIdentifier,
            calendarIdentifier: event.calendar.calendarIdentifier,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            lastModifiedAt: event.lastModifiedDate
        )
    }

    private func mapAuthorization(_ status: EKAuthorizationStatus) -> CalendarAuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .authorized, .fullAccess: return .fullAccess
        case .denied, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    private func merge(_ intervals: [BusyInterval]) -> [BusyInterval] {
        intervals.reduce(into: []) { merged, next in
            guard let last = merged.last else {
                merged.append(next)
                return
            }
            if next.start <= last.end {
                merged[merged.count - 1] = BusyInterval(start: last.start, end: max(last.end, next.end))
            } else {
                merged.append(next)
            }
        }
    }
}
