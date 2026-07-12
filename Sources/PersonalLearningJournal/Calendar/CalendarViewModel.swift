import Combine
import Foundation

public enum StudyCalendarMode: String, CaseIterable, Sendable {
    case day
    case week
    case month
}

public struct CalendarStudyItem: Equatable, Identifiable, Sendable {
    public var id: UUID { plannedSessionID }
    public var plannedSessionID: UUID
    public var projectID: UUID
    public var title: String
    public var projectTitle: String
    public var durationMinutes: Int
    public var status: PlannedSessionStatus
    public var start: Date?
    public var end: Date?
    public var deadline: Date?
    public var bindingState: CalendarBindingState?

    public init(
        plannedSessionID: UUID,
        projectID: UUID,
        title: String,
        projectTitle: String,
        durationMinutes: Int,
        status: PlannedSessionStatus,
        start: Date?,
        end: Date?,
        deadline: Date?,
        bindingState: CalendarBindingState?
    ) {
        self.plannedSessionID = plannedSessionID
        self.projectID = projectID
        self.title = title
        self.projectTitle = projectTitle
        self.durationMinutes = durationMinutes
        self.status = status
        self.start = start
        self.end = end
        self.deadline = deadline
        self.bindingState = bindingState
    }
}

public struct CalendarSchedulingConfiguration: Sendable {
    public var preferences: SchedulingPreferences
    public var availabilityRules: [AvailabilityRule]
    public var targetCalendarIdentifier: String?

    public init(
        preferences: SchedulingPreferences,
        availabilityRules: [AvailabilityRule],
        targetCalendarIdentifier: String?
    ) {
        self.preferences = preferences
        self.availabilityRules = availabilityRules
        self.targetCalendarIdentifier = targetCalendarIdentifier
    }
}

@MainActor
public final class CalendarViewModel: ObservableObject {
    @Published public private(set) var mode: StudyCalendarMode
    @Published public private(set) var focusedDate: Date
    @Published public private(set) var scheduleDraft: ScheduleDraft?
    @Published public private(set) var pendingChangeSet: CalendarChangeSet?
    @Published public private(set) var authorization: CalendarAuthorizationState
    @Published public private(set) var items: [CalendarStudyItem]
    @Published public private(set) var lastApplyResult: CalendarApplyResult?
    @Published public private(set) var reconciliationItems: [CalendarReconciliationItem]
    @Published public private(set) var writableCalendars: [CalendarDescriptor]
    @Published public private(set) var lastErrorMessage: String?

    private let repository: any JournalRepository
    private let calendarClient: any CalendarClient
    private let scheduler: StudySchedulingEngine
    private let syncService: CalendarSyncService
    private var calendar: Calendar
    private var timeZoneIdentifier: String

    public init(
        repository: any JournalRepository,
        calendarClient: any CalendarClient,
        scheduler: StudySchedulingEngine = StudySchedulingEngine(),
        syncService: CalendarSyncService? = nil,
        calendar: Calendar = .current,
        mode: StudyCalendarMode = .week,
        focusedDate: Date = Date(),
        timeZoneIdentifier: String? = nil
    ) {
        self.repository = repository
        self.calendarClient = calendarClient
        self.scheduler = scheduler
        self.syncService = syncService ?? CalendarSyncService(
            repository: repository,
            calendarClient: calendarClient
        )
        self.calendar = calendar
        self.timeZoneIdentifier = timeZoneIdentifier ?? calendar.timeZone.identifier
        self.mode = mode
        self.focusedDate = focusedDate
        self.scheduleDraft = nil
        self.pendingChangeSet = nil
        self.authorization = .notDetermined
        self.items = []
        self.lastApplyResult = nil
        self.reconciliationItems = []
        self.writableCalendars = []
        self.lastErrorMessage = nil
        loadInternalItems()
    }

    public var visibleRange: DateInterval {
        switch mode {
        case .day:
            let start = calendar.startOfDay(for: focusedDate)
            return DateInterval(
                start: start,
                end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            )
        case .week:
            if let interval = calendar.dateInterval(of: .weekOfYear, for: focusedDate) {
                return interval
            }
            let start = calendar.startOfDay(for: focusedDate)
            return DateInterval(start: start, end: start.addingTimeInterval(7 * 86_400))
        case .month:
            if let interval = calendar.dateInterval(of: .month, for: focusedDate) {
                return interval
            }
            let start = calendar.startOfDay(for: focusedDate)
            return DateInterval(start: start, end: start.addingTimeInterval(30 * 86_400))
        }
    }

    public var canReadBusyTime: Bool {
        authorization == .fullAccess
    }

    public var currentTimeZoneIdentifier: String {
        timeZoneIdentifier
    }

    public var unscheduledItems: [CalendarStudyItem] {
        items.filter { $0.start == nil }
    }

    public func setMode(_ mode: StudyCalendarMode, focusedDate: Date? = nil) {
        self.mode = mode
        if let focusedDate {
            self.focusedDate = focusedDate
        }
    }

    public func navigatePrevious() {
        focusedDate = shiftedFocusedDate(by: -1)
    }

    public func navigateNext() {
        focusedDate = shiftedFocusedDate(by: 1)
    }

    public func goToToday(_ date: Date = Date()) {
        focusedDate = date
    }

    public func changeTimeZone(to identifier: String, now: Date = Date()) async {
        guard let timeZone = TimeZone(identifier: identifier) else {
            lastErrorMessage = String(describing: CalendarValidationError.invalidTimeZone)
            return
        }
        timeZoneIdentifier = identifier
        calendar.timeZone = timeZone
        do {
            _ = try await generateSchedule(now: now)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    public func refresh() async {
        authorization = await calendarClient.authorizationState()
        loadInternalItems()
        do {
            reconciliationItems = try await syncService.reconcileBindings()
            loadInternalItems()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    @discardableResult
    public func requestCalendarAccess() async throws -> CalendarAuthorizationState {
        let state = try await calendarClient.requestFullAccess()
        authorization = state
        if state == .fullAccess {
            writableCalendars = try await calendarClient.writableCalendars()
        }
        return state
    }

    public func refreshWritableCalendars() async throws {
        guard authorization == .fullAccess else {
            writableCalendars = []
            return
        }
        writableCalendars = try await calendarClient.writableCalendars()
    }

    public func selectTargetCalendar(_ identifier: String?) throws {
        try repository.saveTargetCalendarIdentifier(identifier)
    }

    public func targetCalendarIdentifier() -> String? {
        try? repository.targetCalendarIdentifier()
    }

    public func schedulingConfiguration() throws -> CalendarSchedulingConfiguration {
        let snapshot = try repository.snapshot()
        let savedAvailability = configuredAvailability(from: snapshot)
        return CalendarSchedulingConfiguration(
            preferences: try currentPreferences(from: snapshot),
            availabilityRules: savedAvailability.isEmpty
                ? try currentAvailability(from: snapshot)
                : savedAvailability,
            targetCalendarIdentifier: try repository.targetCalendarIdentifier()
        )
    }

    public func saveSchedulingConfiguration(
        preferences: SchedulingPreferences,
        availabilityRules: [AvailabilityRule],
        targetCalendarIdentifier: String?
    ) throws {
        let snapshot = try repository.snapshot()
        let retainedPreferenceIDs = Set([preferences.id])
        let retainedRuleIDs = Set(availabilityRules.map(\.id))
        let deletions = snapshot.schedulingPreferences
            .filter { !retainedPreferenceIDs.contains($0.id) }
            .map { JournalEntityReference(.schedulingPreferences, $0.id) }
            + snapshot.availabilityRules
            .filter { !retainedRuleIDs.contains($0.id) }
            .map { JournalEntityReference(.availabilityRule, $0.id) }
        try repository.commit(
            JournalTransaction(
                upserts: availabilityRules.map(JournalEntity.availabilityRule)
                    + [.schedulingPreferences(preferences)],
                deletions: deletions,
                origin: .user
            )
        )
        try repository.saveTargetCalendarIdentifier(targetCalendarIdentifier)
    }

    @discardableResult
    public func generateSchedule(now: Date = Date()) async throws -> ScheduleDraft {
        let snapshot = try repository.snapshot()
        let busyIntervals: [BusyInterval]
        if authorization == .fullAccess {
            busyIntervals = try await calendarClient.busyIntervals(in: visibleRange)
        } else {
            busyIntervals = []
        }
        let preferences = try currentPreferences(from: snapshot)
        let availability = try currentAvailability(from: snapshot)
        let pinnedPlacements = try repository.calendarBindings().compactMap { binding -> ScheduledPlacement? in
            guard binding.state != .detached else { return nil }
            return ScheduledPlacement(
                sessionID: binding.plannedSessionId,
                start: binding.lastWrittenStart,
                end: binding.lastWrittenEnd,
                isPinned: true
            )
        }
        let draft = try scheduler.makeDraft(
            SchedulingRequest(
                sessions: snapshot.plannedSessions,
                availability: availability,
                preferences: preferences,
                busyIntervals: busyIntervals,
                pinnedPlacements: pinnedPlacements,
                range: visibleRange,
                timeZoneIdentifier: timeZoneIdentifier,
                now: now
            )
        )
        replaceScheduleDraft(draft)
        return draft
    }

    public func replaceScheduleDraft(_ draft: ScheduleDraft?) {
        scheduleDraft = draft
        pendingChangeSet = nil
        lastApplyResult = nil
    }

    public func movePlacement(_ sessionID: UUID, byMinutes minutes: Int) {
        updatePlacement(sessionID) { placement in
            let offset = TimeInterval(minutes * 60)
            placement.start = placement.start.addingTimeInterval(offset)
            placement.end = placement.end.addingTimeInterval(offset)
        }
    }

    public func resizePlacement(_ sessionID: UUID, toMinutes minutes: Int) {
        updatePlacement(sessionID) { placement in
            placement.end = placement.start.addingTimeInterval(TimeInterval(max(15, minutes) * 60))
        }
    }

    public func setPlacementPinned(_ sessionID: UUID, isPinned: Bool) {
        updatePlacement(sessionID) { $0.isPinned = isPinned }
    }

    public func removePlacement(_ sessionID: UUID) {
        guard var draft = scheduleDraft else { return }
        draft.placements.removeAll { $0.sessionID == sessionID }
        if !draft.unscheduledSessionIDs.contains(sessionID) {
            draft.unscheduledSessionIDs.append(sessionID)
        }
        scheduleDraft = draft
        pendingChangeSet = nil
    }

    @discardableResult
    public func previewCalendarChanges() async throws -> CalendarChangeSet {
        guard let scheduleDraft else {
            throw CalendarClientError.eventUnavailable
        }
        let changes = try await syncService.previewChanges(for: scheduleDraft)
        pendingChangeSet = changes
        return changes
    }

    @discardableResult
    public func confirmCalendarChanges() async -> CalendarApplyResult {
        guard let pendingChangeSet else {
            return CalendarApplyResult()
        }
        let result = await syncService.applyConfirmed(pendingChangeSet)
        lastApplyResult = result
        loadInternalItems()
        return result
    }

    @discardableResult
    public func retryFailedChanges() async -> CalendarApplyResult {
        guard let pendingChangeSet, let lastApplyResult else {
            return CalendarApplyResult()
        }
        let failedIDs = Set(lastApplyResult.failed.map(\.changeID))
        let retrySet = CalendarChangeSet(
            items: pendingChangeSet.items.filter { failedIDs.contains($0.id) }
        )
        let result = await syncService.applyConfirmed(retrySet)
        self.lastApplyResult = result
        loadInternalItems()
        return result
    }

    public func resolve(
        _ item: CalendarReconciliationItem,
        action: CalendarReconciliationAction
    ) async throws {
        try await syncService.resolve(item, action: action)
        reconciliationItems = try await syncService.reconcileBindings()
        loadInternalItems()
    }

    public func workloadMinutes(on day: Date) -> Int {
        presentedItems.reduce(0) { total, item in
            guard let start = item.start, calendar.isDate(start, inSameDayAs: day) else { return total }
            return total + item.durationMinutes
        }
    }

    public func deadlines(on day: Date) -> [CalendarStudyItem] {
        items.filter { item in
            item.deadline.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        }
    }

    public func items(in range: DateInterval) -> [CalendarStudyItem] {
        presentedItems.filter { item in
            guard let start = item.start, let end = item.end else { return false }
            return start < range.end && end > range.start
        }
    }

    private func shiftedFocusedDate(by amount: Int) -> Date {
        let component: Calendar.Component
        switch mode {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        return calendar.date(byAdding: component, value: amount, to: focusedDate) ?? focusedDate
    }

    private var presentedItems: [CalendarStudyItem] {
        guard let scheduleDraft else { return items }
        let placements = Dictionary(
            uniqueKeysWithValues: scheduleDraft.placements.map { ($0.sessionID, $0) }
        )
        return items.map { item in
            guard let placement = placements[item.plannedSessionID] else { return item }
            var presented = item
            presented.start = placement.start
            presented.end = placement.end
            return presented
        }
    }

    private func updatePlacement(
        _ sessionID: UUID,
        update: (inout ScheduledPlacement) -> Void
    ) {
        guard var draft = scheduleDraft,
              let index = draft.placements.firstIndex(where: { $0.sessionID == sessionID })
        else { return }
        update(&draft.placements[index])
        draft.placements.sort {
            ($0.start, $0.sessionID.uuidString) < ($1.start, $1.sessionID.uuidString)
        }
        scheduleDraft = draft
        pendingChangeSet = nil
    }

    private func loadInternalItems() {
        do {
            let snapshot = try repository.snapshot()
            let bindings = Dictionary(
                uniqueKeysWithValues: try repository.calendarBindings().map { ($0.plannedSessionId, $0) }
            )
            let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
            items = snapshot.plannedSessions
                .filter { $0.status != .completed && $0.status != .skipped && $0.status != .cancelled }
                .map { session in
                    let binding = bindings[session.id]
                    return CalendarStudyItem(
                        plannedSessionID: session.id,
                        projectID: session.projectId,
                        title: session.title,
                        projectTitle: projects[session.projectId] ?? "Study",
                        durationMinutes: session.durationMinutes,
                        status: session.status,
                        start: binding?.lastWrittenStart,
                        end: binding?.lastWrittenEnd,
                        deadline: session.deadline,
                        bindingState: binding?.state
                    )
                }
                .sorted(by: Self.sortItems)
        } catch {
            items = []
            lastErrorMessage = String(describing: error)
        }
    }

    private func currentPreferences(from snapshot: JournalSnapshot) throws -> SchedulingPreferences {
        if let preferences = snapshot.schedulingPreferences
            .filter({ $0.deletedAt == nil })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            return preferences
        }
        return try SchedulingPreferences(
            preferredSessionMinutes: 45,
            maximumDailyMinutes: 180,
            minimumGapMinutes: 15,
            eventTitleStyle: .private
        )
    }

    private func currentAvailability(from snapshot: JournalSnapshot) throws -> [AvailabilityRule] {
        let configured = configuredAvailability(from: snapshot)
        if !configured.isEmpty {
            return configured.filter(\.enabled)
        }
        return try (1...7).map { weekday in
            try AvailabilityRule(
                weekday: weekday,
                startMinute: 18 * 60,
                endMinute: 22 * 60,
                timeZoneIdentifier: timeZoneIdentifier,
                minimumSessionMinutes: 15
            )
        }
    }

    private func configuredAvailability(from snapshot: JournalSnapshot) -> [AvailabilityRule] {
        let saved = snapshot.availabilityRules.filter { $0.deletedAt == nil }
        return Dictionary(grouping: saved, by: \.weekday)
            .values
            .compactMap { $0.max(by: { $0.updatedAt < $1.updatedAt }) }
            .sorted { $0.weekday < $1.weekday }
    }

    private nonisolated static func sortItems(
        _ left: CalendarStudyItem,
        _ right: CalendarStudyItem
    ) -> Bool {
        switch (left.start, right.start) {
        case let (leftStart?, rightStart?) where leftStart != rightStart:
            return leftStart < rightStart
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return left.plannedSessionID.uuidString < right.plannedSessionID.uuidString
        }
    }
}
