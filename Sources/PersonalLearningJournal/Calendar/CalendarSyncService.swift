import Foundation

public struct CalendarApplyResult: Equatable, Sendable {
    public var succeeded: [UUID]
    public var failed: [CalendarChangeFailure]

    public init(succeeded: [UUID] = [], failed: [CalendarChangeFailure] = []) {
        self.succeeded = succeeded
        self.failed = failed
    }
}

public struct CalendarChangeFailure: Equatable, Sendable {
    public var changeID: UUID
    public var message: String
    public var isRetryable: Bool

    public init(changeID: UUID, message: String, isRetryable: Bool) {
        self.changeID = changeID
        self.message = message
        self.isRetryable = isRetryable
    }
}

public enum CalendarReconciliationAction: Equatable, Sendable {
    case adoptExternal
    case overwriteExternal
    case recreateDeleted
    case detach
}

public struct CalendarReconciliationItem: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var plannedSessionID: UUID
    public var binding: CalendarBinding
    public var externalEvent: CalendarEventSnapshot?
    public var state: CalendarBindingState

    public init(
        id: UUID = UUID(),
        plannedSessionID: UUID,
        binding: CalendarBinding,
        externalEvent: CalendarEventSnapshot?,
        state: CalendarBindingState
    ) {
        self.id = id
        self.plannedSessionID = plannedSessionID
        self.binding = binding
        self.externalEvent = externalEvent
        self.state = state
    }
}

@MainActor
public final class CalendarSyncService: Sendable {
    public static let dedicatedCalendarTitle = "Self Study Studio"
    private let repository: any JournalRepository
    private let calendarClient: any CalendarClient
    private let now: () -> Date

    public init(
        repository: any JournalRepository,
        calendarClient: any CalendarClient,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.calendarClient = calendarClient
        self.now = now
    }

    @discardableResult
    public func configureDedicatedCalendar(
        sharedCalendarConfirmed: Bool
    ) async throws -> CalendarDescriptor {
        let calendars = try await calendarClient.writableCalendars()
        let existing = calendars.first(where: {
            $0.title == Self.dedicatedCalendarTitle && $0.allowsContentModifications
        })
        let calendar: CalendarDescriptor
        if let existing {
            calendar = existing
        } else {
            calendar = try await calendarClient.createCalendar(named: Self.dedicatedCalendarTitle)
        }
        guard !calendar.isShared || sharedCalendarConfirmed else {
            throw CalendarClientError.sharedCalendarConfirmationRequired
        }
        try repository.saveTargetCalendarIdentifier(calendar.id)
        return calendar
    }

    public func previewChanges(for draft: ScheduleDraft) async throws -> CalendarChangeSet {
        guard let targetCalendarIdentifier = try repository.targetCalendarIdentifier() else {
            throw CalendarClientError.calendarUnavailable
        }

        let snapshot = try repository.snapshot()
        let placementIDs = Set(draft.placements.map(\.sessionID))
        var changes: [CalendarChange] = []

        for placement in draft.placements.sorted(by: Self.sortPlacements) {
            let after = CalendarEventDraft(
                identifier: try repository.calendarBinding(for: placement.sessionID)?.eventIdentifier,
                calendarIdentifier: targetCalendarIdentifier,
                title: eventTitle(for: placement.sessionID, snapshot: snapshot),
                details: eventDetails(for: placement.sessionID, snapshot: snapshot),
                start: placement.start,
                end: placement.end
            )

            guard let binding = try repository.calendarBinding(for: placement.sessionID) else {
                changes.append(
                    CalendarChange(
                        plannedSessionID: placement.sessionID,
                        operation: .create,
                        after: after
                    )
                )
                continue
            }

            let externalEvent = try await calendarClient.event(identifier: binding.eventIdentifier)
            guard let externalEvent, eventMatchesBinding(externalEvent, binding: binding) else {
                continue
            }
            changes.append(
                CalendarChange(
                    plannedSessionID: placement.sessionID,
                    operation: .update,
                    before: externalEvent,
                    after: after
                )
            )
        }

        for binding in try repository.calendarBindings() where !placementIDs.contains(binding.plannedSessionId) {
            guard let externalEvent = try await calendarClient.event(identifier: binding.eventIdentifier),
                  eventMatchesBinding(externalEvent, binding: binding)
            else {
                continue
            }
            changes.append(
                CalendarChange(
                    plannedSessionID: binding.plannedSessionId,
                    operation: .delete,
                    before: externalEvent
                )
            )
        }

        return CalendarChangeSet(items: changes, createdAt: now())
    }

    public func applyConfirmed(_ changeSet: CalendarChangeSet) async -> CalendarApplyResult {
        var succeeded: [UUID] = []
        var failed: [CalendarChangeFailure] = []

        for change in changeSet.items {
            do {
                switch change.operation {
                case .create, .update:
                    guard let after = change.after else {
                        throw CalendarClientError.eventUnavailable
                    }
                    let savedEvent = try await calendarClient.save(after)
                    try repository.saveCalendarBinding(binding(for: change.plannedSessionID, event: savedEvent))
                    try recordScheduleState(
                        for: change.plannedSessionID,
                        status: .scheduled,
                        occurredAt: now()
                    )
                case .delete:
                    guard let before = change.before else {
                        throw CalendarClientError.eventUnavailable
                    }
                    try await calendarClient.delete(identifier: before.identifier)
                    try repository.removeCalendarBinding(for: change.plannedSessionID)
                    try recordScheduleState(
                        for: change.plannedSessionID,
                        status: .unscheduled,
                        occurredAt: now()
                    )
                }
                succeeded.append(change.plannedSessionID)
            } catch {
                failed.append(
                    CalendarChangeFailure(
                        changeID: change.id,
                        message: String(describing: error),
                        isRetryable: isRetryable(error)
                    )
                )
            }
        }

        return CalendarApplyResult(succeeded: succeeded, failed: failed)
    }

    public func reconcileBindings() async throws -> [CalendarReconciliationItem] {
        var reconciliations: [CalendarReconciliationItem] = []

        for binding in try repository.calendarBindings() {
            let externalEvent = try await calendarClient.event(identifier: binding.eventIdentifier)
            let state: CalendarBindingState
            if let externalEvent {
                state = eventMatchesBinding(externalEvent, binding: binding) ? .linked : .externallyModified
            } else {
                state = .externallyDeleted
            }

            guard state != .linked else {
                if binding.state != .linked {
                    var relinkedBinding = binding
                    relinkedBinding.state = .linked
                    relinkedBinding.lastObservedAt = now()
                    try repository.saveCalendarBinding(relinkedBinding)
                }
                continue
            }

            var updatedBinding = binding
            updatedBinding.state = state
            updatedBinding.lastObservedAt = now()
            try repository.saveCalendarBinding(updatedBinding)
            reconciliations.append(
                CalendarReconciliationItem(
                    plannedSessionID: binding.plannedSessionId,
                    binding: updatedBinding,
                    externalEvent: externalEvent,
                    state: state
                )
            )
        }

        return reconciliations
    }

    public func resolve(
        _ item: CalendarReconciliationItem,
        action: CalendarReconciliationAction
    ) async throws {
        switch action {
        case .adoptExternal:
            guard let externalEvent = item.externalEvent else {
                throw CalendarClientError.eventUnavailable
            }
            try repository.saveCalendarBinding(binding(for: item.plannedSessionID, event: externalEvent))
            try recordScheduleState(
                for: item.plannedSessionID,
                status: .scheduled,
                occurredAt: now()
            )
        case .overwriteExternal:
            guard let externalEvent = item.externalEvent else {
                throw CalendarClientError.eventUnavailable
            }
            let savedEvent = try await calendarClient.save(
                CalendarEventDraft(
                    identifier: externalEvent.identifier,
                    calendarIdentifier: item.binding.calendarIdentifier,
                    title: item.binding.lastWrittenTitle,
                    details: item.binding.lastWrittenDetails,
                    start: item.binding.lastWrittenStart,
                    end: item.binding.lastWrittenEnd
                )
            )
            try repository.saveCalendarBinding(binding(for: item.plannedSessionID, event: savedEvent))
        case .recreateDeleted:
            guard item.state == .externallyDeleted else {
                throw CalendarClientError.eventUnavailable
            }
            let savedEvent = try await calendarClient.save(
                CalendarEventDraft(
                    calendarIdentifier: item.binding.calendarIdentifier,
                    title: item.binding.lastWrittenTitle,
                    details: item.binding.lastWrittenDetails,
                    start: item.binding.lastWrittenStart,
                    end: item.binding.lastWrittenEnd
                )
            )
            try repository.saveCalendarBinding(binding(for: item.plannedSessionID, event: savedEvent))
            try recordScheduleState(
                for: item.plannedSessionID,
                status: .scheduled,
                occurredAt: now()
            )
        case .detach:
            try repository.removeCalendarBinding(for: item.plannedSessionID)
        }
    }

    private func eventTitle(for plannedSessionID: UUID, snapshot: JournalSnapshot) -> String {
        let titleStyle = snapshot.schedulingPreferences
            .filter { $0.deletedAt == nil }
            .max { $0.updatedAt < $1.updatedAt }?
            .eventTitleStyle ?? .private
        guard let session = snapshot.plannedSessions.first(where: { $0.id == plannedSessionID }) else {
            return "Study"
        }

        let projectName = snapshot.projects.first(where: { $0.id == session.projectId })?.name
        if let projectName {
            return "\(projectName) · \(session.title)"
        }
        switch titleStyle {
        case .private:
            return "Study"
        case .session:
            return session.title
        case .project:
            return snapshot.projects.first(where: { $0.id == session.projectId })?.name ?? session.title
        }
    }

    private func eventDetails(for plannedSessionID: UUID, snapshot: JournalSnapshot) -> String? {
        guard let session = snapshot.plannedSessions.first(where: { $0.id == plannedSessionID }) else {
            return nil
        }
        let project = snapshot.projects.first(where: { $0.id == session.projectId })
        var lines: [String] = []
        if let goal = project?.goal.trimmedForJournal, !goal.isEmpty {
            lines.append("Goal: \(goal)")
        }
        if let expectedProof = session.expectedProof?.trimmedForJournal, !expectedProof.isEmpty {
            lines.append("Expected Proof: \(expectedProof)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func binding(for plannedSessionID: UUID, event: CalendarEventSnapshot) -> CalendarBinding {
        CalendarBinding(
            plannedSessionId: plannedSessionID,
            eventIdentifier: event.identifier,
            calendarIdentifier: event.calendarIdentifier,
            lastWrittenTitle: event.title,
            lastWrittenDetails: event.details,
            lastWrittenStart: event.start,
            lastWrittenEnd: event.end,
            lastObservedAt: now(),
            state: .linked
        )
    }

    private func recordScheduleState(
        for plannedSessionID: UUID,
        status: PlannedSessionStatus,
        occurredAt: Date
    ) throws {
        let snapshot = try repository.snapshot()
        guard var session = snapshot.plannedSessions.first(where: { $0.id == plannedSessionID }) else {
            return
        }

        session.status = status
        session.updatedAt = occurredAt
        let detail = status == .scheduled ? "Scheduled a study session in the selected calendar." : "Removed a study session from the selected calendar."
        let event = TrailEvent(
            projectId: session.projectId,
            type: .calendarSynced,
            sourceId: session.id,
            occurredAt: occurredAt,
            title: "Calendar updated",
            detail: detail
        )
        try repository.commit(
            JournalTransaction(
                upserts: [.plannedSession(session), .trailEvent(event)],
                origin: .user
            )
        )
    }

    private func eventMatchesBinding(
        _ event: CalendarEventSnapshot,
        binding: CalendarBinding
    ) -> Bool {
        event.identifier == binding.eventIdentifier
            && event.calendarIdentifier == binding.calendarIdentifier
            && event.title == binding.lastWrittenTitle
            && event.details == binding.lastWrittenDetails
            && event.start == binding.lastWrittenStart
            && event.end == binding.lastWrittenEnd
    }

    private func isRetryable(_ error: Error) -> Bool {
        guard let calendarError = error as? CalendarClientError else { return true }
        switch calendarError {
        case .accessDenied, .sharedCalendarConfirmationRequired:
            return false
        case .calendarUnavailable, .eventUnavailable:
            return true
        }
    }

    private nonisolated static func sortPlacements(_ left: ScheduledPlacement, _ right: ScheduledPlacement) -> Bool {
        if left.start != right.start { return left.start < right.start }
        return left.sessionID.uuidString < right.sessionID.uuidString
    }
}
