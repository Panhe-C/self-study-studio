# Study Calendar and EventKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a personal day/week/month learning calendar that deterministically schedules course-plan sessions around user availability and existing Calendar events, then creates, updates, or deletes EventKit events only after explicit confirmation.

**Architecture:** A pure `StudySchedulingEngine` turns unscheduled or movable `PlannedSession` values, availability, preferences, pinned sessions, and privacy-stripped busy intervals into an editable `ScheduleDraft`. EventKit access is isolated behind `CalendarClient`; `CalendarSyncService` converts confirmed draft changes into a retryable change set and reconciles external edits through local-only `CalendarBinding` values. SwiftUI renders the internal calendar from repository data whether Calendar permission is granted or denied.

**Tech Stack:** Swift 6, SwiftUI, EventKit, Foundation Calendar/TimeZone, SwiftData repository, CloudKit private sync for personal scheduling rules, XCTest, iOS 17, macOS 14 package-test compatibility.

## Global Constraints

- Complete `2026-07-10-personal-cloud-sync.md` and `2026-07-10-course-planning-ai.md` first.
- The internal learning calendar must remain usable without EventKit access.
- Request EventKit full access only when the user enables busy-time analysis or direct synchronization.
- Never send Calendar event titles, notes, attendees, locations, URLs, or raw events to AI or CloudKit.
- Never create, update, or delete EventKit events before the user confirms the exact change set.
- Store EventKit calendar/event identifiers and last-written snapshots locally only.
- Treat availability as private personal CloudKit data; do not add collaboration.
- Represent planned study sessions as concrete events, not one EventKit recurring series.
- Detect external changes before overwriting or deleting linked events.

---

## File Structure

- `Sources/PersonalLearningJournal/Calendar/CalendarDomain.swift`: availability, preferences, busy intervals, placements, conflicts, drafts, bindings, and change sets.
- `Sources/PersonalLearningJournal/Calendar/StudySchedulingEngine.swift`: deterministic scheduling algorithm.
- `Sources/PersonalLearningJournal/Calendar/CalendarClient.swift`: authorization and EventKit-independent protocol.
- `Sources/PersonalLearningJournal/Calendar/EventKitCalendarClient.swift`: production EventKit adapter.
- `Sources/PersonalLearningJournal/Calendar/CalendarSyncService.swift`: previews, confirmed writes, retries, and reconciliation.
- `Sources/PersonalLearningJournal/Calendar/CalendarViewModel.swift`: calendar range, mode, scheduling draft, permissions, and write state.
- `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`: availability/preferences entity cases.
- `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`: synced schedule settings and local-only binding records.
- `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`: availability/preferences private CloudKit records; no binding records.
- `Sources/PersonalLearningJournal/Views/StudyCalendarView.swift`: day/week/month shell.
- `Sources/PersonalLearningJournal/Views/DayCalendarView.swift`: hourly timeline.
- `Sources/PersonalLearningJournal/Views/WeekCalendarView.swift`: stable multi-day timeline and drag/resize.
- `Sources/PersonalLearningJournal/Views/MonthCalendarView.swift`: workload density, deadlines, and unscheduled counts.
- `Sources/PersonalLearningJournal/Views/ScheduleDraftView.swift`: candidate placements, conflicts, unscheduled items, and confirmation.
- `Sources/PersonalLearningJournal/Views/CalendarSettingsView.swift`: permission, target calendar, availability, and limits.
- `Sources/PersonalLearningJournal/Views/CalendarReconciliationView.swift`: external edit/delete decisions.
- `Sources/PersonalLearningJournal/Views/RootView.swift`: Calendar tab.
- `Sources/PersonalLearningJournal/Views/TodayView.swift`: conflicts and pending calendar changes.
- `Sources/PersonalLearningJournal/Views/CoursePlanWizardView.swift`: schedule after plan draft editing.
- `Sources/PersonalLearningJournal/JournalViewModel.swift`: shared plan/session commands.
- `App/SelfStudyStudioApp.swift`: calendar composition.
- `SelfStudyStudio.xcodeproj/project.pbxproj`: source registration and Calendar usage description.
- `Tests/PersonalLearningJournalTests/*Tests.swift`: domain, scheduler, EventKit adapter boundary, sync, layout, view-model, and end-to-end coverage.

### Task 1: Add Calendar, Availability, and Local Binding Domain

**Files:**
- Create: `Sources/PersonalLearningJournal/Calendar/CalendarDomain.swift`
- Modify: `Sources/PersonalLearningJournal/JournalStore.swift`
- Modify: `Sources/PersonalLearningJournal/ExportService.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`
- Test: `Tests/PersonalLearningJournalTests/CalendarDomainTests.swift`
- Test: `Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `AvailabilityRule`, `SchedulingPreferences`, `BusyInterval`, `ScheduledPlacement`, `ScheduleConflict`, `ScheduleDraft`, `CalendarBinding`, and `CalendarChangeSet`.

- [ ] **Step 1: Write validation, persistence, and privacy tests**

```swift
func testAvailabilityRejectsEndBeforeStart() {
    XCTAssertThrowsError(try AvailabilityRule(
        weekday: 2, startMinute: 18 * 60, endMinute: 17 * 60,
        timeZoneIdentifier: "Asia/Shanghai", minimumSessionMinutes: 30
    )) { error in
        XCTAssertEqual(error as? CalendarValidationError, .invalidAvailabilityRange)
    }
}

func testCalendarBindingPersistsLocallyButNeverExportsOrEntersCloudMapper() throws {
    try repository.saveCalendarBinding(binding)
    XCTAssertEqual(try repository.calendarBinding(for: plannedSession.id), binding)
    let export = try ExportService().exportJSON(snapshot: repository.snapshot())
    XCTAssertFalse(String(decoding: export, as: UTF8.self).contains(binding.eventIdentifier))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CalendarDomainTests`

Expected: compile failure because calendar domain types do not exist.

- [ ] **Step 3: Define exact scheduling domain values**

```swift
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
}

public struct SchedulingPreferences: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var preferredSessionMinutes: Int
    public var maximumDailyMinutes: Int
    public var minimumGapMinutes: Int
    public var allowWeekends: Bool
    public var eventTitleStyle: CalendarEventTitleStyle
    public var updatedAt: Date
}

public enum CalendarEventTitleStyle: String, Codable, CaseIterable, Sendable {
    case project, session, `private`
}

public enum CalendarValidationError: Error, Equatable, Sendable {
    case invalidAvailabilityRange
    case invalidWeekday
    case invalidDuration
    case invalidTimeZone
}

public struct BusyInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
}
```

`BusyInterval` deliberately has no title, notes, calendar, location, attendees,
or URL fields.

- [ ] **Step 4: Define draft, conflict, binding, and change values**

```swift
public struct ScheduleDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var range: DateInterval
    public var placements: [ScheduledPlacement]
    public var unscheduledSessionIDs: [UUID]
    public var conflicts: [ScheduleConflict]
    public var generatedAt: Date
}

public enum CalendarBindingState: String, Codable, Sendable {
    case linked, externallyModified, externallyDeleted, detached
}

public enum CalendarChangeOperation: String, Codable, Sendable {
    case create, update, delete
}

public enum ScheduleConflictReason: String, Codable, Sendable {
    case outsideAvailability
    case overlapsBusyTime
    case exceedsDailyLimit
    case violatesMinimumGap
    case insufficientCapacityBeforeDeadline
    case invalidTimeZone
}

public struct CalendarEventSnapshot: Codable, Equatable, Sendable {
    public var identifier: String
    public var calendarIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var lastModifiedAt: Date?
}

public struct CalendarEventDraft: Codable, Equatable, Sendable {
    public var identifier: String?
    public var calendarIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
}

public struct ScheduledPlacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var start: Date
    public var end: Date
    public var isPinned: Bool
}

public struct ScheduleConflict: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var reason: ScheduleConflictReason
    public var detail: String
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
}

public struct CalendarChange: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var plannedSessionID: UUID
    public var operation: CalendarChangeOperation
    public var before: CalendarEventSnapshot?
    public var after: CalendarEventDraft?
}

public struct CalendarChangeSet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var items: [CalendarChange]
    public var createdAt: Date
}
```

Define `CalendarBinding` with the approved local-only fields and
`CalendarChangeSet` as an identified list of exact before/after changes plus
per-item status.

- [ ] **Step 5: Persist synced settings and local-only bindings separately**

Add `.availabilityRule` and `.schedulingPreferences` to `JournalEntity` and
CloudKit mapping. Add planning arrays to `JournalSnapshot`. Store bindings and
target-calendar identifier in dedicated local SwiftData records that are omitted
from snapshots, CloudKit mapping, merge, and export.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --filter CalendarDomainTests && swift test --filter SwiftDataJournalRepositoryTests && swift test --filter ExportServiceTests`

Expected: all selected tests pass.

```bash
git add Sources/PersonalLearningJournal/Calendar/CalendarDomain.swift Sources/PersonalLearningJournal/JournalStore.swift Sources/PersonalLearningJournal/ExportService.swift Sources/PersonalLearningJournal/Persistence Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift Tests/PersonalLearningJournalTests SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: add personal calendar domain"
```

### Task 2: Schedule Sessions Deterministically

**Files:**
- Create: `Sources/PersonalLearningJournal/Calendar/StudySchedulingEngine.swift`
- Test: `Tests/PersonalLearningJournalTests/StudySchedulingEngineTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: planned sessions, availability, preferences, busy intervals, pinned placements, range, time zone, and current date.
- Produces: `StudySchedulingEngine.makeDraft(_:) -> ScheduleDraft`.

- [ ] **Step 1: Write basic placement and privacy-independent tests**

```swift
func testSchedulerPlacesSessionInFirstAvailableWindowWithoutOverlappingBusyTime() throws {
    let draft = try scheduler.makeDraft(SchedulingRequest(
        sessions: [session], availability: [mondayEvening], preferences: preferences,
        busyIntervals: [busyFrom18To19], pinnedPlacements: [],
        range: mondayRange, timeZoneIdentifier: "Asia/Shanghai", now: mondayMorning
    ))
    XCTAssertEqual(draft.placements.first?.start, mondayAt19)
    XCTAssertEqual(draft.placements.first?.end, mondayAt19.addingTimeInterval(30 * 60))
}
```

```swift
func testSchedulerDoesNotMutatePlannedSessions() throws {
    let original = session
    _ = try scheduler.makeDraft(request)
    XCTAssertEqual(session, original)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter StudySchedulingEngineTests`

Expected: compile failure because scheduling engine and request do not exist.

- [ ] **Step 3: Define request and pure engine**

```swift
public struct SchedulingRequest: Sendable {
    public var sessions: [PlannedSession]
    public var availability: [AvailabilityRule]
    public var preferences: SchedulingPreferences
    public var busyIntervals: [BusyInterval]
    public var pinnedPlacements: [ScheduledPlacement]
    public var range: DateInterval
    public var timeZoneIdentifier: String
    public var now: Date
}

public struct StudySchedulingEngine {
    public func makeDraft(_ request: SchedulingRequest) throws -> ScheduleDraft
}
```

- [ ] **Step 4: Implement slot generation and scoring**

Expand enabled availability into concrete intervals using the named time zone,
subtract busy intervals and minimum gaps, split remaining windows by preferred
duration while respecting each session's duration, then score candidates by:
deadline urgency, phase order, pinned state, earliest fit, daily load, and even
weekly distribution. Stable sorting by session UUID makes equal-score output
deterministic.

- [ ] **Step 5: Run scheduler tests**

Run: `swift test --filter StudySchedulingEngineTests`

Expected: basic placement, overlap prevention, daily limit, gap, determinism, and unscheduled output tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Calendar/StudySchedulingEngine.swift Tests/PersonalLearningJournalTests/StudySchedulingEngineTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: schedule personal study sessions"
```

### Task 3: Handle Deadlines, Time Zones, Pinned Work, and Replanning

**Files:**
- Modify: `Sources/PersonalLearningJournal/Calendar/StudySchedulingEngine.swift`
- Modify: `Sources/PersonalLearningJournal/Calendar/CalendarDomain.swift`
- Test: `Tests/PersonalLearningJournalTests/StudySchedulingEngineTests.swift`

**Interfaces:**
- Consumes: engine from Task 2.
- Produces: explainable conflicts, deadline overflow, DST-safe placement, pinned-session preservation, and partial replanning.

- [ ] **Step 1: Add hard-case tests**

```swift
func testPinnedSessionIsNeverMovedWhenNewDeadlineWorkIsAdded() throws {
    let draft = try scheduler.makeDraft(requestWithPinnedAndUrgentSession)
    XCTAssertEqual(draft.placements.first(where: { $0.sessionID == pinned.id })?.start, pinnedStart)
}

func testSpringForwardDayUsesCalendarArithmeticWithoutInvalidLocalTime() throws {
    let draft = try scheduler.makeDraft(dstTransitionRequest)
    XCTAssertFalse(draft.placements.contains { localHour($0.start) == 2 })
}

func testImpossibleDeadlineReturnsUnscheduledReason() throws {
    let draft = try scheduler.makeDraft(overCapacityRequest)
    XCTAssertEqual(draft.unscheduledSessionIDs, [urgent.id])
    XCTAssertTrue(draft.conflicts.contains { $0.reason == .insufficientCapacityBeforeDeadline })
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter StudySchedulingEngineTests`

Expected: new deadline, DST, and pinned tests fail against the basic engine.

- [ ] **Step 3: Implement explainable conflict production**

Use the `ScheduleConflictReason` cases defined in Task 1 to report every rejected
placement and unscheduled deadline. A session may accumulate multiple reasons,
but duplicate `(sessionID, reason)` pairs collapse before returning the draft.

Use `Calendar(identifier: .gregorian)` with the request time zone for day and
minute arithmetic. Never add fixed 24-hour intervals to move between local days.

- [ ] **Step 4: Implement partial replanning**

Completed, cancelled, and pinned sessions are excluded from movement. Existing
scheduled sessions remain candidates at their current location with a stability
bonus. Only missed, skipped, unscheduled, explicitly movable, or conflict-causing
sessions are relocated.

- [ ] **Step 5: Run scheduler tests and commit**

Run: `swift test --filter StudySchedulingEngineTests`

Expected: all standard and hard-case scheduler tests pass.

```bash
git add Sources/PersonalLearningJournal/Calendar/StudySchedulingEngine.swift Sources/PersonalLearningJournal/Calendar/CalendarDomain.swift Tests/PersonalLearningJournalTests/StudySchedulingEngineTests.swift
git commit -m "feat: make study scheduling deadline aware"
```

### Task 4: Add EventKit Authorization and Privacy-Stripped Reads

**Files:**
- Create: `Sources/PersonalLearningJournal/Calendar/CalendarClient.swift`
- Create: `Sources/PersonalLearningJournal/Calendar/EventKitCalendarClient.swift`
- Test: `Tests/PersonalLearningJournalTests/CalendarClientTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `CalendarAuthorizationState`, `CalendarDescriptor`, `CalendarClient`, and production `EventKitCalendarClient`, using the event values from Task 1.

- [ ] **Step 1: Write authorization mapping and busy-interval tests**

```swift
func testDeniedAuthorizationReturnsNoEventsAndInternalCalendarCanContinue() async throws {
    let client = FakeCalendarClient(authorization: .denied)
    XCTAssertEqual(await client.authorizationState(), .denied)
    do {
        _ = try await client.busyIntervals(in: range)
        XCTFail("Expected access denied")
    } catch {
        XCTAssertEqual(error as? CalendarClientError, .accessDenied)
    }
}

func testBusyIntervalsExposeOnlyStartAndEnd() async throws {
    let intervals = try await client.busyIntervals(in: range)
    XCTAssertEqual(intervals, [BusyInterval(start: eventStart, end: eventEnd)])
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CalendarClientTests`

Expected: compile failure because Calendar client types do not exist.

- [ ] **Step 3: Define the framework-independent boundary**

```swift
public enum CalendarAuthorizationState: Equatable, Sendable {
    case notDetermined, fullAccess, denied, restricted
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
```

- [ ] **Step 4: Implement EventKit adapter**

Use one actor-owned `EKEventStore`. On iOS 17 call
`requestFullAccessToEvents()`. Map EventKit authorization to the public enum.
`busyIntervals` fetches events but returns only start/end values and merges
overlapping intervals. Event reads for reconciliation return only identifier,
calendar identifier, title, start, end, and last modified date; they never enter
CloudKit or AI inputs.

- [ ] **Step 5: Run tests and builds**

Run: `swift test --filter CalendarClientTests && swift build && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: tests pass and both package/app compile on supported platforms.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Calendar/CalendarClient.swift Sources/PersonalLearningJournal/Calendar/EventKitCalendarClient.swift Tests/PersonalLearningJournalTests/CalendarClientTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: read calendar availability privately"
```

### Task 5: Preview, Confirm, Write, and Reconcile Calendar Changes

**Files:**
- Create: `Sources/PersonalLearningJournal/Calendar/CalendarSyncService.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`
- Test: `Tests/PersonalLearningJournalTests/CalendarSyncServiceTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: confirmed `ScheduleDraft`, `CalendarClient`, repository, and local bindings.
- Produces: `previewChanges(for:)`, `applyConfirmed(_:)`, `reconcileBindings()`, and retryable per-item results.

- [ ] **Step 1: Write no-write-before-confirmation test**

```swift
func testPreviewDoesNotCallCalendarClientWrites() async throws {
    let changes = try await service.previewChanges(for: scheduleDraft)
    XCTAssertFalse(changes.items.isEmpty)
    XCTAssertEqual(calendarClient.saveCallCount, 0)
    XCTAssertEqual(calendarClient.deleteCallCount, 0)
}
```

- [ ] **Step 2: Write external edit/delete and partial success tests**

```swift
func testExternalEditRequiresDecisionBeforeOverwrite() async throws {
    calendarClient.events[binding.eventIdentifier] = externallyMovedEvent
    let result = try await service.reconcileBindings()
    XCTAssertEqual(result.first?.state, .externallyModified)
    XCTAssertEqual(calendarClient.saveCallCount, 0)
}

func testPartialFailurePersistsSuccessfulBindingAndRetryableFailure() async throws {
    let result = await service.applyConfirmed(changeSet)
    XCTAssertEqual(result.succeeded.count, 1)
    XCTAssertEqual(result.failed.count, 1)
    XCTAssertNotNil(try repository.calendarBinding(for: succeededSessionID))
}
```

- [ ] **Step 3: Run tests and verify RED**

Run: `swift test --filter CalendarSyncServiceTests`

Expected: compile failure because Calendar sync service does not exist.

- [ ] **Step 4: Implement preview and confirmed writes**

```swift
public struct CalendarApplyResult: Equatable, Sendable {
    public var succeeded: [UUID]
    public var failed: [CalendarChangeFailure]
}

public struct CalendarChangeFailure: Equatable, Sendable {
    public var changeID: UUID
    public var message: String
    public var isRetryable: Bool
}

public enum CalendarReconciliationAction: Equatable, Sendable {
    case adoptExternal, overwriteExternal, recreateDeleted, detach
}

public struct CalendarReconciliationItem: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var plannedSessionID: UUID
    public var binding: CalendarBinding
    public var externalEvent: CalendarEventSnapshot?
    public var state: CalendarBindingState
}

public final class CalendarSyncService: Sendable {
    public func previewChanges(for draft: ScheduleDraft) async throws -> CalendarChangeSet
    public func applyConfirmed(_ changeSet: CalendarChangeSet) async -> CalendarApplyResult
    public func reconcileBindings() async throws -> [CalendarReconciliationItem]
    public func resolve(_ item: CalendarReconciliationItem, action: CalendarReconciliationAction) async throws
}
```

Preview compares placements to local bindings and current events. Apply processes
items independently, updates PlannedSession times only for confirmed items,
persists each successful binding, leaves failed items retryable, and appends a
`calendarSynced` TrailEvent after at least one success.

- [ ] **Step 5: Implement external-change decisions**

Support `.adoptExternal`, `.overwriteExternal`, `.recreateDeleted`, and `.detach`.
Adopting updates internal planned times; overwrite/recreate writes only after the
user selects that action; detach removes the local binding without deleting the
external event.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --filter CalendarSyncServiceTests && swift test --filter JournalServiceTests`

Expected: confirmation, partial failure, binding, and reconciliation tests pass.

```bash
git add Sources/PersonalLearningJournal/Calendar/CalendarSyncService.swift Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift Tests/PersonalLearningJournalTests/CalendarSyncServiceTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: confirm and reconcile calendar writes"
```

### Task 6: Build Stable Day, Week, and Month Calendar Views

**Files:**
- Create: `Sources/PersonalLearningJournal/Calendar/CalendarViewModel.swift`
- Create: `Sources/PersonalLearningJournal/Views/StudyCalendarView.swift`
- Create: `Sources/PersonalLearningJournal/Views/DayCalendarView.swift`
- Create: `Sources/PersonalLearningJournal/Views/WeekCalendarView.swift`
- Create: `Sources/PersonalLearningJournal/Views/MonthCalendarView.swift`
- Create: `Sources/PersonalLearningJournal/Views/ScheduleDraftView.swift`
- Test: `Tests/PersonalLearningJournalTests/CalendarViewModelTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CalendarLayoutTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: repository sessions/plans, scheduler, Calendar client, and sync service.
- Produces: calendar mode/range navigation, stable timeline geometry, drag/resize draft changes, schedule preview, and write confirmation.

- [ ] **Step 1: Write range and geometry tests**

```swift
func testWeekModeRangeStartsAtUserCalendarWeekBoundary() {
    viewModel.setMode(.week, focusedDate: wednesday)
    XCTAssertEqual(viewModel.visibleRange.start, mondayMidnight)
    XCTAssertEqual(viewModel.visibleRange.end, nextMondayMidnight)
}

func testDraggingThirtyPointsMovesSessionThirtyMinutesWithoutChangingHeight() {
    let result = WeekTimelineLayout(pointsPerMinute: 1).move(frame, byY: 30)
    XCTAssertEqual(result.start, frame.start.addingTimeInterval(30 * 60))
    XCTAssertEqual(result.duration, frame.duration)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CalendarViewModelTests && swift test --filter CalendarLayoutTests`

Expected: compile failure because view model and layout values do not exist.

- [ ] **Step 3: Implement calendar view model**

```swift
public enum StudyCalendarMode: String, CaseIterable, Sendable { case day, week, month }

@MainActor
public final class CalendarViewModel: ObservableObject {
    @Published public private(set) var mode: StudyCalendarMode
    @Published public private(set) var focusedDate: Date
    @Published public private(set) var scheduleDraft: ScheduleDraft?
    @Published public private(set) var pendingChangeSet: CalendarChangeSet?
    @Published public private(set) var authorization: CalendarAuthorizationState
}
```

Expose previous/next/today navigation, visible range, internal planned-session
items, workload per day, generate draft, edit placement, preview writeback,
confirm, retry failed items, and reconciliation items.

- [ ] **Step 4: Build calendar shell and fixed geometry**

Use a segmented control for Day/Week/Month, icon buttons for previous/today/next,
and stable dimensions for hour rows, day columns, event blocks, and drag handles.
Day and Week use a scrollable hourly timeline; Month uses a seven-column grid
with workload minutes, deadlines, conflict marker, and unscheduled count. Dynamic
labels wrap or truncate without resizing timeline tracks.

- [ ] **Step 5: Build draft and confirmation UI**

`ScheduleDraftView` lists placements, conflicts with reasons, and unscheduled
sessions. Users may pin, move, or remove a placement before tapping Review
Calendar Changes. The next screen shows every create/update/delete and has one
explicit Confirm Calendar Changes button.

- [ ] **Step 6: Run tests and simulator build**

Run: `swift test --filter CalendarViewModelTests && swift test --filter CalendarLayoutTests && swift test && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: tests pass and app target builds.

- [ ] **Step 7: Commit**

```bash
git add Sources/PersonalLearningJournal/Calendar/CalendarViewModel.swift Sources/PersonalLearningJournal/Views/StudyCalendarView.swift Sources/PersonalLearningJournal/Views/DayCalendarView.swift Sources/PersonalLearningJournal/Views/WeekCalendarView.swift Sources/PersonalLearningJournal/Views/MonthCalendarView.swift Sources/PersonalLearningJournal/Views/ScheduleDraftView.swift Tests/PersonalLearningJournalTests/CalendarViewModelTests.swift Tests/PersonalLearningJournalTests/CalendarLayoutTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: add personal study calendar views"
```

### Task 7: Add Calendar Settings, Reconciliation, and App Integration

**Files:**
- Create: `Sources/PersonalLearningJournal/Views/CalendarSettingsView.swift`
- Create: `Sources/PersonalLearningJournal/Views/CalendarReconciliationView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/RootView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/CoursePlanWizardView.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Modify: `App/SelfStudyStudioApp.swift`
- Modify: `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`

**Interfaces:**
- Consumes: completed Calendar services and views.
- Produces: Calendar tab, permission/settings flow, post-plan schedule flow, Today alerts, and external-change resolution.

- [ ] **Step 1: Write integration-state tests**

```swift
func testDeniedCalendarPermissionStillShowsInternalCalendarItems() async throws {
    await calendarViewModel.refresh()
    XCTAssertEqual(calendarViewModel.authorization, .denied)
    XCTAssertEqual(calendarViewModel.items.map(\.plannedSessionID), [plannedSession.id])
    XCTAssertFalse(calendarViewModel.canReadBusyTime)
}

func testPlanActivationDoesNotWriteCalendarUntilSecondConfirmation() async throws {
    let draftPlan = try viewModel.saveManualDraft(input: input, draft: draft)
    try viewModel.activateCoursePlan(draftPlanID: draftPlan.id)
    _ = try await calendarViewModel.generateSchedule()
    XCTAssertEqual(calendarClient.saveCallCount, 0)
    _ = try await calendarViewModel.previewCalendarChanges()
    XCTAssertEqual(calendarClient.saveCallCount, 0)
}

func testTimeZoneChangeCreatesDraftWithoutMovingConfirmedEvents() async throws {
    await calendarViewModel.changeTimeZone(to: "America/Los_Angeles")
    XCTAssertNotNil(calendarViewModel.scheduleDraft)
    XCTAssertEqual(calendarClient.saveCallCount, 0)
    XCTAssertEqual(linkedEvent.start, originalEventStart)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter JournalViewModelTests/testDeniedCalendarPermissionStillShowsInternalCalendarItems`

Expected: failure until app composition exposes Calendar state.

- [ ] **Step 3: Add Calendar tab and settings**

Insert `StudyCalendarView` between Projects and Library with system image
`calendar`. Calendar settings edit availability, preferred duration, daily limit,
minimum gap, weekend policy, title style, permission, and writable target
calendar. Do not request permission on app launch.

Changing the scheduling time zone re-renders local times and generates a new
`ScheduleDraft`. It does not modify `PlannedSession` or EventKit values until the
normal preview and confirmation flow completes.

- [ ] **Step 4: Integrate planning and Today**

After course plan activation, offer Schedule Plan; generating a draft does not
write EventKit. Today shows conflicts, externally changed events, failed writes,
and overdue sessions above existing Continue cards.

- [ ] **Step 5: Add reconciliation UI**

For each externally modified/deleted binding, show the internal and external
start/end values and actions Adopt, Overwrite/Recreate, or Detach. Execute only
the tapped action.

- [ ] **Step 6: Add generated Info.plist usage description**

Set in Debug and Release:

```text
INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = "Learning Journal reads your busy times and writes only the study sessions you confirm.";
```

- [ ] **Step 7: Run full tests and app build**

Run: `swift test && swift build && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: all tests pass and app target builds.

- [ ] **Step 8: Commit**

```bash
git add Sources/PersonalLearningJournal/Views Sources/PersonalLearningJournal/JournalViewModel.swift App/SelfStudyStudioApp.swift Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift Tests/PersonalLearningJournalTests/JournalViewModelTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: integrate personal study calendar"
```

### Task 8: Verify the Full Self-Study Loop

**Files:**
- Create: `Tests/PersonalLearningJournalTests/StudyCalendarEndToEndTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: personal cloud, course planning, and calendar implementations.
- Produces: automated full-loop proof and real-device acceptance checklist.

- [ ] **Step 1: Add full-loop automated test**

```swift
func testCourseInputToPlanScheduleCalendarSessionProofAndReview() async throws {
    let draftPlan = try await planningService.generateDraft(input: input, context: context)
    let plan = try planningService.activate(draftPlanID: draftPlan.id)
    let schedule = try scheduler.makeDraft(request(for: plan))
    let changes = try await calendarSync.previewChanges(for: schedule)
    let applied = await calendarSync.applyConfirmed(changes)
    XCTAssertTrue(applied.failed.isEmpty)

    let planned = try XCTUnwrap(repository.snapshot().plannedSessions.first)
    let session = try journalService.quickLog(
        projectId: project.id, plannedSessionId: planned.id,
        durationMinutes: planned.durationMinutes, note: "Completed planned work"
    )
    _ = try journalService.addProof(
        projectId: project.id, sessionId: session.id, type: .link,
        title: "Notebook", statement: "The planned output now runs"
    )
    let review = try await reviewService.createWeeklyReview(periodStart: weekStart, periodEnd: weekEnd)

    XCTAssertEqual(repository.snapshot().plannedSessions.first?.status, .completed)
    XCTAssertTrue(review.aiSourceSummary.contains { $0.contains("Completed planned work") })
}
```

- [ ] **Step 2: Add degraded-mode tests**

Cover no iCloud, offline CloudKit, no AI configuration, AI failure, denied
Calendar permission, EventKit partial failure, and external event deletion. Each
case must preserve local recording and internal Calendar functionality.

- [ ] **Step 3: Run complete automated verification**

Run: `swift test && swift build && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: all tests pass and simulator build reports `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Launch and visually verify simulator UI**

Install and launch the built app. Capture screenshots at iPhone 16 Pro and a
compact iPhone viewport for Today, Project Plan, Calendar Day, Week, Month,
Schedule Draft, Calendar confirmation, denied permission, and reconciliation.
Verify no text overlap, stable timeline geometry, visible confirmation actions,
and a functional local-only path.

- [ ] **Step 5: Perform real-device acceptance**

With a provisioned iCloud container and Calendar permission, verify same-account
two-device CloudKit convergence, attachment download, airplane-mode recovery,
busy-time scheduling, confirmed EventKit writes, external modifications,
external deletions, time-zone changes, and AI-assisted replanning. Record any
environment-only prerequisites in README.

- [ ] **Step 6: Update product documentation and commit**

Document the four tabs, iCloud behavior, course planning draft boundary,
scheduler rules, Calendar permission, write confirmations, privacy guarantees,
degraded modes, and real-device setup.

```bash
git add README.md Tests/PersonalLearningJournalTests/StudyCalendarEndToEndTests.swift
git commit -m "test: verify self study planning loop"
```
