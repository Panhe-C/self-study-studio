# Practice Timer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an iHour-inspired recurring practice timer to Today, with local crash-safe timing, optional project linking, synced completed sessions, and calendar-aware statistics.

**Architecture:** `PracticeRoutine` and `PracticeSession` are first-class journal entities carried through snapshots, repository transactions, SwiftData, CloudKit, merge, and export. `PracticeService` owns validated mutations and `PracticeStatistics` derives display values from saved sessions; a separate `PracticeTimerRuntime` persists only the currently active timer in local device storage and never sends it to CloudKit. SwiftUI reads presentation models from `JournalViewModel`, while timer and routine-management sheets remain focused view components.

**Tech Stack:** Swift 6, SwiftUI, Combine, Foundation `Calendar`, SwiftData, CloudKit, XCTest, iOS 17+

## Global Constraints

- Practice routines remain independent from learning projects; project linking is optional and never changes course-plan progress.
- Target duration is `1...1_440` minutes and weekdays use `Calendar` values `1...7`.
- Today shows only active routines scheduled for the current weekday.
- The timer counts upward; crossing the target gives feedback once and never stops the timer.
- Only one practice timer may be active on a device at a time.
- Active timer state is local-only; only completed practice sessions sync.
- Multiple sessions on the same local calendar day combine toward target completion.
- Cards use an 8-point maximum corner radius, system typography, SF Symbols, explicit accessibility labels, and no color-only state.
- Do not add reminders, social sharing, achievements, streak penalties, custom themes, ambient audio, focus blocking, widgets, or Apple Watch support.
- Every task follows red-green-refactor and leaves the full test suite buildable.

---

## File Map

- `Sources/PersonalLearningJournal/Practice/PracticeDomain.swift`: routine/session entities, semantic color, validation errors.
- `Sources/PersonalLearningJournal/Practice/PracticeService.swift`: validated create, update, archive, and completed-session transactions.
- `Sources/PersonalLearningJournal/Practice/PracticeStatistics.swift`: calendar-aware Today/week/all-time aggregates.
- `Sources/PersonalLearningJournal/Practice/PracticeTimerRuntime.swift`: local active-timer state machine and persistence abstraction.
- `Sources/PersonalLearningJournal/Views/PracticeTimerView.swift`: focused timer and finish confirmation flow.
- `Sources/PersonalLearningJournal/Views/PracticeManagerView.swift`: active/archive list and routine editor.
- Existing snapshot, repository, sync, export, application-session, presentation, ViewModel, Today, and Xcode project files receive narrow integration changes.

### Task 1: Practice Domain And Legacy Snapshot Compatibility

**Files:**
- Create: `Sources/PersonalLearningJournal/Practice/PracticeDomain.swift`
- Modify: `Sources/PersonalLearningJournal/JournalStore.swift`
- Create: `Tests/PersonalLearningJournalTests/PracticeDomainTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/DomainTests.swift`

**Interfaces:**
- Produces: `PracticeRoutine`, `PracticeSession`, `PracticeSemanticColor`, `PracticeValidationError`.
- Produces: `JournalSnapshot.practiceRoutines: [PracticeRoutine]` and `JournalSnapshot.practiceSessions: [PracticeSession]` with legacy empty-array decoding.

- [ ] **Step 1: Add failing domain validation and legacy decoding tests**

```swift
import XCTest
@testable import PersonalLearningJournal

final class PracticeDomainTests: XCTestCase {
    func testRoutineRequiresNameTargetAndWeekday() throws {
        let valid = PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2, 4, 6])
        XCTAssertNoThrow(try valid.validated())
        XCTAssertThrowsError(try PracticeRoutine(name: " ", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2]).validated())
        XCTAssertThrowsError(try PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 0, weekdays: [2]).validated())
        XCTAssertThrowsError(try PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: []).validated())
        XCTAssertThrowsError(try PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [8]).validated())
    }

    func testSessionRejectsImpossibleDuration() {
        let session = PracticeSession(routineId: UUID(), startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 90), activeDurationSeconds: 20)
        XCTAssertThrowsError(try session.validated())
    }
}

func testLegacySnapshotDecodesEmptyPracticeCollections() throws {
    let data = Data(#"{"projects":[],"sessions":[],"proofs":[],"reviews":[],"trailEvents":[]}"#.utf8)
    let snapshot = try JSONDecoder().decode(JournalSnapshot.self, from: data)
    XCTAssertEqual(snapshot.practiceRoutines, [])
    XCTAssertEqual(snapshot.practiceSessions, [])
}
```

- [ ] **Step 2: Run the focused tests and verify the compile failure**

Run: `swift test --filter 'PracticeDomainTests|DomainTests.testLegacySnapshotDecodesEmptyPracticeCollections'`

Expected: FAIL because the practice types and snapshot properties do not exist.

- [ ] **Step 3: Implement the domain and snapshot fields**

Define `PracticeRoutine` with stable IDs/timestamps, `isArchived`, `schemaVersion = 1`, trimmed-name validation, `1...1_440` target validation, weekday-subset validation, and optional `PracticeReminderTime` validation for hour `0...23` and minute `0...59`. Keep `reminderTime` nil in this release because there is no reminder UI or scheduling. Define `PracticeSession` with required routine ID, optional `linkedProjectId`, start/end/active seconds/note, timestamps, soft deletion, and validation that dates and duration are nonnegative and active duration does not exceed wall-clock duration by more than one second.

```swift
public enum PracticeSemanticColor: String, Codable, CaseIterable, Sendable {
    case coral, teal, yellow, blue, green, pink
}

public enum PracticeValidationError: Error, Equatable, Sendable {
    case blankName
    case invalidTargetMinutes
    case invalidWeekdays
    case invalidReminderTime
    case invalidSessionTiming
}

public struct PracticeReminderTime: Codable, Equatable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

public struct PracticeRoutine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var color: PracticeSemanticColor
    public var targetMinutes: Int
    public var weekdays: Set<Int>
    public var reminderTime: PracticeReminderTime?
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public func validated() throws -> PracticeRoutine
}

public struct PracticeSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var routineId: UUID
    public var linkedProjectId: UUID?
    public var startedAt: Date
    public var endedAt: Date
    public var activeDurationSeconds: Int
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var schemaVersion: Int

    public func validated() throws -> PracticeSession
}
```

Add both arrays to the memberwise initializer, `CodingKeys`, and custom decoder in `JournalSnapshot`, using `decodeIfPresent(...) ?? []`.

- [ ] **Step 4: Run the focused tests and full Swift suite**

Run: `swift test --filter 'PracticeDomainTests|DomainTests.testLegacySnapshotDecodesEmptyPracticeCollections'`

Expected: PASS.

Run: `swift test`

Expected: all existing and new tests PASS.

- [ ] **Step 5: Commit the domain increment**

```bash
git add Sources/PersonalLearningJournal/Practice/PracticeDomain.swift Sources/PersonalLearningJournal/JournalStore.swift Tests/PersonalLearningJournalTests/PracticeDomainTests.swift Tests/PersonalLearningJournalTests/DomainTests.swift
git commit -m "feat: add practice timer domain"
```

### Task 2: Repository And SwiftData Persistence

**Files:**
- Modify: `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/JournalRepository.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`
- Modify: `Tests/PersonalLearningJournalTests/JournalRepositoryTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift`

**Interfaces:**
- Consumes: `PracticeRoutine`, `PracticeSession`, and the two snapshot arrays from Task 1.
- Produces: `JournalEntity.practiceRoutine`, `JournalEntity.practiceSession`, matching entity kinds, transaction persistence, tombstones, and outbox entries.

- [ ] **Step 1: Add failing in-memory and restart tests**

```swift
func testPracticeEntitiesRoundTripAndEnqueueMutations() throws {
    let repository = InMemoryJournalRepository()
    let routine = PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2])
    let session = PracticeSession(routineId: routine.id, startedAt: .now, endedAt: .now.addingTimeInterval(60), activeDurationSeconds: 60)
    try repository.commit(JournalTransaction(upserts: [.practiceRoutine(routine), .practiceSession(session)], origin: .user))
    XCTAssertEqual(try repository.snapshot().practiceRoutines, [routine])
    XCTAssertEqual(try repository.snapshot().practiceSessions, [session])
    XCTAssertEqual(try repository.pendingMutations(limit: 10).count, 2)
}

func testPracticeEntitiesSurviveSwiftDataRestartAndSoftDeletion() throws {
    let url = temporaryDirectory.appendingPathComponent("practice.store")
    let routine = PracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2])
    try SwiftDataJournalRepository(url: url).commit(JournalTransaction(upserts: [.practiceRoutine(routine)], origin: .user))
    let reopened = try SwiftDataJournalRepository(url: url)
    XCTAssertEqual(try reopened.snapshot().practiceRoutines, [routine])
    try reopened.commit(JournalTransaction(deletions: [.init(.practiceRoutine, routine.id)], origin: .user))
    XCTAssertTrue(try reopened.snapshot().practiceRoutines.isEmpty)
    XCTAssertNotNil(try reopened.entity(for: .init(.practiceRoutine, routine.id)))
}
```

- [ ] **Step 2: Run repository tests and verify exhaustive-switch failures**

Run: `swift test --filter 'JournalRepositoryTests|SwiftDataJournalRepositoryTests'`

Expected: FAIL because the new entity cases and SwiftData models are absent.

- [ ] **Step 3: Thread both entities through the repository layer**

Add `.practiceRoutine` and `.practiceSession` to `JournalEntityKind` and `JournalEntity`, then cover `reference`, `isDeleted`, and `deleting(at:)`. Include both arrays in `InMemoryJournalRepository.init(snapshot:)` and `snapshot()`.

In `SwiftDataJournalRepository`, add payload-backed models consistent with the existing V2 records:

```swift
@Model
final class StoredPracticeRoutineV2: StoredJournalEntityV2 {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, payload: Data, deletedAt: Date?) { self.id = id; self.payload = payload; self.deletedAt = deletedAt }
}

@Model
final class StoredPracticeSessionV2: StoredJournalEntityV2 {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var deletedAt: Date?
    init(id: UUID, payload: Data, deletedAt: Date?) { self.id = id; self.payload = payload; self.deletedAt = deletedAt }
}
```

Register both models in `makeContainer`, decode them in `snapshot()`, and add both cases to `entity(for:)`, `upsert(_:)`, and `markDeleted(_:)`. Preserve the existing user-origin outbox rules.

- [ ] **Step 4: Verify repository behavior and the whole suite**

Run: `swift test --filter 'JournalRepositoryTests|SwiftDataJournalRepositoryTests'`

Expected: PASS, including restart, tombstone, and two-outbox-entry assertions.

Run: `swift test`

Expected: all tests PASS.

- [ ] **Step 5: Commit repository support**

```bash
git add Sources/PersonalLearningJournal/Persistence/JournalEntity.swift Sources/PersonalLearningJournal/Persistence/JournalRepository.swift Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift Tests/PersonalLearningJournalTests/JournalRepositoryTests.swift Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift
git commit -m "feat: persist practice routines and sessions"
```

### Task 3: CloudKit, Merge, Export, And Migration Coverage

**Files:**
- Modify: `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/SyncMergeService.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/CloudAccountCoordinator.swift`
- Modify: `Sources/PersonalLearningJournal/ExportService.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/RepositoryMigration.swift`
- Modify: `Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/CloudAccountCoordinatorTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/CloudSyncEndToEndTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/RepositoryMigrationTests.swift`

**Interfaces:**
- Consumes: repository entity cases from Task 2.
- Produces: Cloud record types `PracticeRoutine` and `PracticeSession`; deterministic merge/export/migration behavior for both entities.

- [ ] **Step 1: Add failing round-trip, merge, export, and migration tests**

```swift
func testPracticeSessionCloudRoundTripKeepsOptionalProjectLink() throws {
    let mapper = CloudRecordMapper()
    let projectID = UUID()
    let session = PracticeSession(routineId: UUID(), linkedProjectId: projectID, startedAt: .now, endedAt: .now.addingTimeInterval(120), activeDurationSeconds: 120, note: "Chord changes")
    let record = try mapper.record(for: .practiceSession(session), metadata: nil)
    XCTAssertEqual(record.recordType, "PracticeSession")
    XCTAssertEqual(try mapper.entity(from: record), .practiceSession(session))
}

func testPracticeEntitiesUploadDownloadAndDeleteThroughCoordinator() async throws {
    let fixture = makeCloudSyncFixture()
    let routine = makePracticeRoutine()
    try fixture.local.commit(JournalTransaction(upserts: [.practiceRoutine(routine)], origin: .user))
    try await fixture.coordinator.sync()
    XCTAssertEqual(fixture.client.savedRecordTypes, ["PracticeRoutine"])
    fixture.client.queueRemoteDeletion(recordName: routine.id.uuidString)
    try await fixture.coordinator.sync()
    XCTAssertTrue(try fixture.local.snapshot().practiceRoutines.isEmpty)
}

func testRemotePracticeDeletionWinsOverOlderLocalValue() throws {
    let outcome = try makeMergeOutcome(kind: .practiceRoutine, localUpdatedAt: 100, remoteDeletedAt: 200)
    XCTAssertTrue(outcome.transaction.deletions.contains(outcome.reference))
}

func testExportAndMigrationIncludePracticeData() throws {
    let snapshot = makeSnapshotWithOnePracticeRoutineAndSession()
    let data = try ExportService().jsonData(for: snapshot)
    let decoded = try JSONDecoder.journal.decode(JournalSnapshot.self, from: data)
    XCTAssertEqual(decoded.practiceRoutines.count, 1)
    XCTAssertEqual(decoded.practiceSessions.count, 1)
}
```

- [ ] **Step 2: Run focused integration tests and verify failure**

Run: `swift test --filter 'CloudRecordMapperTests|CloudSyncEndToEndTests|SyncMergeServiceTests|CloudAccountCoordinatorTests|ExportServiceTests|RepositoryMigrationTests'`

Expected: FAIL on unmapped entity kinds or missing snapshot conversion.

- [ ] **Step 3: Implement all integration switches**

Map each entity as a CloudKit record containing a versioned JSON payload plus existing common metadata; do not write derived statistics or active timer state. Add both cases to mapper record-type lookup, decoding, merge timestamps/deletion logic, account snapshot-to-entity conversion, repository migration entity conversion, and export bundle JSON.

Use these stable record type names in the mapper's existing exhaustive switches:

```swift
case .practiceRoutine: return "PracticeRoutine"
case .practiceSession: return "PracticeSession"
```

- [ ] **Step 4: Run integration tests and full suite**

Run: `swift test --filter 'CloudRecordMapperTests|CloudSyncEndToEndTests|SyncMergeServiceTests|CloudAccountCoordinatorTests|ExportServiceTests|RepositoryMigrationTests'`

Expected: PASS for save round-trip, optional nil/non-nil project IDs, remote deletion, snapshot export, and legacy migration.

Run: `swift test`

Expected: all tests PASS.

- [ ] **Step 5: Commit sync and export support**

```bash
git add Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift Sources/PersonalLearningJournal/Sync/SyncMergeService.swift Sources/PersonalLearningJournal/Sync/CloudAccountCoordinator.swift Sources/PersonalLearningJournal/ExportService.swift Sources/PersonalLearningJournal/Persistence/RepositoryMigration.swift Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift Tests/PersonalLearningJournalTests/CloudSyncEndToEndTests.swift Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift Tests/PersonalLearningJournalTests/CloudAccountCoordinatorTests.swift Tests/PersonalLearningJournalTests/ExportServiceTests.swift Tests/PersonalLearningJournalTests/RepositoryMigrationTests.swift
git commit -m "feat: sync and export practice data"
```

### Task 4: Practice Service And Calendar-Aware Statistics

**Files:**
- Create: `Sources/PersonalLearningJournal/Practice/PracticeService.swift`
- Create: `Sources/PersonalLearningJournal/Practice/PracticeStatistics.swift`
- Create: `Tests/PersonalLearningJournalTests/PracticeServiceTests.swift`
- Create: `Tests/PersonalLearningJournalTests/PracticeStatisticsTests.swift`

**Interfaces:**
- Consumes: `JournalRepository`, `PracticeRoutine`, `PracticeSession`.
- Produces: `PracticeService.createRoutine`, `updateRoutine`, `archiveRoutine`, `saveSession`.
- Produces: `PracticeRoutineStatistics` and `PracticeStatistics.calculate(routine:sessions:now:calendar:)`.

- [ ] **Step 1: Add failing service tests**

```swift
func testServiceValidatesAndCommitsRoutine() throws {
    let repository = InMemoryJournalRepository()
    let service = PracticeService(repository: repository, now: { Date(timeIntervalSince1970: 1_000) })
    let routine = try service.createRoutine(name: " Guitar ", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2, 4, 6])
    XCTAssertEqual(routine.name, "Guitar")
    XCTAssertEqual(try repository.snapshot().practiceRoutines, [routine])
}

func testServiceRejectsDuplicateActiveNameCaseInsensitively() throws {
    let repository = InMemoryJournalRepository()
    let service = PracticeService(repository: repository)
    _ = try service.createRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2])
    XCTAssertThrowsError(try service.createRoutine(name: " guitar ", symbolName: "music.note", color: .blue, targetMinutes: 20, weekdays: [3]))
}

func testDeletedLinkedProjectFallsBackToNil() throws {
    let repository = InMemoryJournalRepository()
    let service = PracticeService(repository: repository)
    let result = try service.saveSession(routineId: UUID(), linkedProjectId: UUID(), startedAt: .now, endedAt: .now.addingTimeInterval(60), activeDurationSeconds: 60, note: nil)
    XCTAssertNil(result.session.linkedProjectId)
    XCTAssertTrue(result.didDropMissingProjectLink)
}
```

Represent the fallback as a result rather than a stored model field:

```swift
public struct PracticeSessionSaveResult: Equatable, Sendable {
    public let session: PracticeSession
    public let didDropMissingProjectLink: Bool
}
```

- [ ] **Step 2: Add failing aggregate tests**

```swift
func testSameDaySessionsCombineToCompleteTarget() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
    let routine = makeRoutine(targetMinutes: 30)
    let sessions = [makeSession(routine.id, "2026-07-13T00:30:00Z", 1_200), makeSession(routine.id, "2026-07-13T10:00:00Z", 600)]
    let result = PracticeStatistics.calculate(routine: routine, sessions: sessions, now: isoDate("2026-07-13T12:00:00Z"), calendar: calendar)
    XCTAssertEqual(result.todayActiveSeconds, 1_800)
    XCTAssertEqual(result.weekCompletionCount, 1)
    XCTAssertEqual(result.weekActiveSeconds, 1_800)
    XCTAssertEqual(result.allTimeActiveSeconds, 1_800)
}

func testWeekAndTimeZoneUseInjectedCalendar() {
    let result = calculateAcrossSundayBoundaryAndShanghaiMidnight()
    XCTAssertEqual(result.weekCompletionCount, 1)
    XCTAssertEqual(result.todayActiveSeconds, 900)
}
```

- [ ] **Step 3: Run the focused tests and verify failure**

Run: `swift test --filter 'PracticeServiceTests|PracticeStatisticsTests'`

Expected: FAIL because the service and statistics types do not exist.

- [ ] **Step 4: Implement mutation and aggregate APIs**

`PracticeService` validates before committing, rejects duplicate active names after trimming and case folding, archives by setting `isArchived = true`, updates `updatedAt`, and saves a session with a nil project link when no live project matches. Add `deleteRoutineIfUnused(_:)`, which throws when any non-deleted practice session references the routine and otherwise commits a soft deletion. `PracticeStatistics` groups non-deleted sessions by `calendar.startOfDay(for:)`, obtains the week with `calendar.dateInterval(of: .weekOfYear, for:)`, and counts days whose accumulated seconds meet `targetMinutes * 60`.

```swift
public struct PracticeRoutineStatistics: Equatable, Sendable {
    public let todayActiveSeconds: Int
    public let weekCompletionCount: Int
    public let weekActiveSeconds: Int
    public let allTimeActiveSeconds: Int
}

public enum PracticeStatistics {
    public static func calculate(
        routine: PracticeRoutine,
        sessions: [PracticeSession],
        now: Date,
        calendar: Calendar
    ) -> PracticeRoutineStatistics
}
```

- [ ] **Step 5: Verify and commit the business layer**

Run: `swift test --filter 'PracticeServiceTests|PracticeStatisticsTests'`

Expected: PASS for validation, archive, link fallback, same-day accumulation, week boundaries, and time zones.

Run: `swift test`

Expected: all tests PASS.

```bash
git add Sources/PersonalLearningJournal/Practice/PracticeService.swift Sources/PersonalLearningJournal/Practice/PracticeStatistics.swift Tests/PersonalLearningJournalTests/PracticeServiceTests.swift Tests/PersonalLearningJournalTests/PracticeStatisticsTests.swift
git commit -m "feat: add practice service and statistics"
```

### Task 5: Local Active Timer Runtime

**Files:**
- Create: `Sources/PersonalLearningJournal/Practice/PracticeTimerRuntime.swift`
- Create: `Tests/PersonalLearningJournalTests/PracticeTimerRuntimeTests.swift`

**Interfaces:**
- Consumes: routine ID and target seconds; does not consume `JournalRepository` or sync APIs.
- Produces: `PracticeTimerStateStore`, `UserDefaultsPracticeTimerStateStore`, `PracticeTimerRuntime`, and `PracticeTimerSnapshot`.

- [ ] **Step 1: Add failing state-machine and recovery tests**

```swift
@MainActor
func testPauseResumeAndBackgroundTimeAreDerivedFromDates() throws {
    let clock = TestClock(now: Date(timeIntervalSince1970: 100))
    let store = InMemoryPracticeTimerStateStore()
    let runtime = PracticeTimerRuntime(store: store, now: clock.now)
    try runtime.start(routineId: UUID(), targetSeconds: 30)
    clock.advance(by: 20)
    runtime.pause()
    clock.advance(by: 100)
    XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 20)
    runtime.resume()
    clock.advance(by: 10)
    XCTAssertEqual(runtime.snapshot.activeElapsedSeconds, 30)
}

@MainActor
func testTargetCrossingFiresOnceAndRecoveryRejectsCorruption() throws {
    let store = InMemoryPracticeTimerStateStore()
    let runtime = PracticeTimerRuntime(store: store, now: fixedNow)
    try runtime.start(routineId: UUID(), targetSeconds: 10)
    advanceClock(by: 11)
    XCTAssertTrue(runtime.consumeTargetCrossing())
    XCTAssertFalse(runtime.consumeTargetCrossing())
    store.data = Data("not-json".utf8)
    XCTAssertNil(PracticeTimerRuntime(store: store, now: fixedNow).snapshot.activeRoutineId)
}
```

- [ ] **Step 2: Run timer tests and verify failure**

Run: `swift test --filter PracticeTimerRuntimeTests`

Expected: FAIL because the runtime types are absent.

- [ ] **Step 3: Implement date-derived local runtime state**

Persist a Codable state containing `routineId`, `startedAt`, accumulated active seconds before the current run, optional `resumedAt`, target seconds, and target-feedback-consumed flag. Calculate live elapsed as accumulated seconds plus `max(0, now - resumedAt)`. Reject decode failures, future timestamps, negative accumulated values, nonpositive targets, and elapsed values larger than wall time since `startedAt` plus one second.

```swift
public protocol PracticeTimerStateStore: AnyObject {
    func load() -> Data?
    func save(_ data: Data?) throws
}

public struct PracticeTimerSnapshot: Equatable, Sendable {
    public let activeRoutineId: UUID?
    public let startedAt: Date?
    public let activeElapsedSeconds: Int
    public let isRunning: Bool
    public let targetSeconds: Int
}

public struct PracticeTimerCompletion: Equatable, Sendable {
    public let routineId: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let activeDurationSeconds: Int
}

@MainActor
public final class PracticeTimerRuntime: ObservableObject {
    @Published public private(set) var snapshot: PracticeTimerSnapshot
    public func start(routineId: UUID, targetSeconds: Int) throws
    public func pause()
    public func resume()
    public func refresh()
    public func consumeTargetCrossing() -> Bool
    public func finish() -> PracticeTimerCompletion?
    public func discard()
}
```

`finish()` returns immutable start/end/active-seconds data and clears local state only after the caller has captured it; saving failures are handled by retaining that completion in the UI until retry succeeds.

- [ ] **Step 4: Verify state behavior and commit**

Run: `swift test --filter PracticeTimerRuntimeTests`

Expected: PASS for one-active-timer enforcement, pause/resume, background elapsed time, target crossing once, finish, discard, relaunch recovery, and corrupt-state clearing.

Run: `swift test`

Expected: all tests PASS.

```bash
git add Sources/PersonalLearningJournal/Practice/PracticeTimerRuntime.swift Tests/PersonalLearningJournalTests/PracticeTimerRuntimeTests.swift
git commit -m "feat: add recoverable practice timer runtime"
```

### Task 6: ViewModel And Today Presentation Integration

**Files:**
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Modify: `Sources/PersonalLearningJournal/ReviewService.swift`
- Modify: `Sources/PersonalLearningJournal/Views/StudioPresentation.swift`
- Modify: `Sources/PersonalLearningJournal/Views/JournalApplicationSession.swift`
- Modify: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/ReviewServiceTests.swift`
- Modify: `Tests/PersonalLearningJournalTests/StudioPresentationTests.swift`

**Interfaces:**
- Consumes: `PracticeService`, `PracticeStatistics`, `PracticeTimerRuntime`.
- Produces: ViewModel practice collections/mutations and `StudioPracticeCard` values for Today.

- [ ] **Step 1: Add failing weekday-filter and save-refresh tests**

```swift
func testTodayPracticeCardsFilterWeekdayAndExposeActiveTimer() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let monday = isoDate("2026-07-13T10:00:00Z")
    let mondayRoutine = makeRoutine(name: "Guitar", weekdays: [2])
    let tuesdayRoutine = makeRoutine(name: "Voice", weekdays: [3])
    let cards = StudioPresentation.practiceCards(routines: [mondayRoutine, tuesdayRoutine], sessions: [], activeRoutineId: mondayRoutine.id, now: monday, calendar: calendar)
    XCTAssertEqual(cards.map(\.routine.id), [mondayRoutine.id])
    XCTAssertTrue(cards[0].isActiveTimer)
}

func testLinkedPracticeAppearsInProjectHistoryAndReviewSources() async throws {
    let fixture = makeReviewFixtureWithLinkedPractice(activeDurationSeconds: 1_800)
    XCTAssertEqual(fixture.viewModel.practiceSessionsForProject(fixture.project.id).count, 1)
    let review = try await fixture.reviewService.createWeeklyReview(periodStart: fixture.periodStart, periodEnd: fixture.periodEnd)
    XCTAssertTrue(review.aiSourceSummary.contains { $0.contains("practice") })
}

@MainActor
func testSavingCompletionRefreshesSnapshotAndReportsDroppedLink() throws {
    let fixture = makePracticeViewModelFixture()
    let result = try fixture.viewModel.savePracticeCompletion(fixture.completion, linkedProjectId: UUID(), note: "Scales")
    XCTAssertEqual(fixture.viewModel.practiceSessions.count, 1)
    XCTAssertTrue(result.didDropMissingProjectLink)
}
```

- [ ] **Step 2: Run presentation/ViewModel tests and verify failure**

Run: `swift test --filter 'StudioPresentationTests|JournalViewModelTests|ReviewServiceTests'`

Expected: FAIL because practice APIs are absent.

- [ ] **Step 3: Add presentation model and ViewModel facade**

```swift
public struct StudioPracticeCard: Identifiable, Equatable, Sendable {
    public var id: UUID { routine.id }
    public let routine: PracticeRoutine
    public let statistics: PracticeRoutineStatistics
    public let isActiveTimer: Bool
}
```

Add `StudioPresentation.practiceCards(...)` to filter `!isArchived`, `deletedAt == nil`, and current weekday membership, calculate statistics, sort active timer first then creation date/name, and expose `isActiveTimer`.

Inject one `PracticeService` and one shared `PracticeTimerRuntime` into `JournalViewModel`. Add `practiceRoutines`, `practiceSessions`, CRUD wrappers, `practiceCards(now:calendar:)`, `startPractice`, `savePracticeCompletion`, and `discardPractice`. Every successful repository mutation calls `refresh()`; `JournalApplicationSession` keeps the same runtime instance when rebuilding the ViewModel after account refresh so a running local timer is not lost.

Add `practiceSessionsForProject(_:)` to return non-deleted sessions whose optional link matches the project. Extend both `RuleBasedReviewProvider` and the structured HTTP review request with linked practice sessions in the requested period; include source lines in the stable form `practice <id-prefix>: <minutes> min - <note-or-routine-name>`. Treat this as related evidence only: do not add practice seconds to `LearningSession` minutes and do not mutate planned-session status.

- [ ] **Step 4: Verify and commit ViewModel integration**

Run: `swift test --filter 'StudioPresentationTests|JournalViewModelTests|ReviewServiceTests'`

Expected: PASS for weekday filtering, archived exclusion, active resume state, save refresh, and missing-project fallback.

Run: `swift test`

Expected: all tests PASS.

```bash
git add Sources/PersonalLearningJournal/JournalViewModel.swift Sources/PersonalLearningJournal/ReviewService.swift Sources/PersonalLearningJournal/Views/StudioPresentation.swift Sources/PersonalLearningJournal/Views/JournalApplicationSession.swift Tests/PersonalLearningJournalTests/JournalViewModelTests.swift Tests/PersonalLearningJournalTests/ReviewServiceTests.swift Tests/PersonalLearningJournalTests/StudioPresentationTests.swift
git commit -m "feat: expose practice timer in today presentation"
```

### Task 7: Practice Timer, Management, And Today UI

**Files:**
- Create: `Sources/PersonalLearningJournal/Views/PracticeTimerView.swift`
- Create: `Sources/PersonalLearningJournal/Views/PracticeManagerView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/StudioTheme.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`
- Create: `Tests/PersonalLearningJournalTests/PracticeTimerEndToEndTests.swift`

**Interfaces:**
- Consumes: `StudioPracticeCard` and ViewModel/runtime APIs from Task 6.
- Produces: routine cards, focused timer sheet, finish form, discard confirmation, and routine manager/editor.

- [ ] **Step 1: Add a failing end-to-end workflow test**

```swift
@MainActor
func testCreateStartPauseResumeAndSavePracticeWorkflow() throws {
    let fixture = makeEndToEndFixture(now: Date(timeIntervalSince1970: 1_000))
    let routine = try fixture.viewModel.createPracticeRoutine(name: "Guitar", symbolName: "guitars", color: .coral, targetMinutes: 30, weekdays: [2])
    try fixture.viewModel.startPractice(routine)
    fixture.clock.advance(by: 900)
    fixture.viewModel.practiceTimer.pause()
    fixture.viewModel.practiceTimer.resume()
    fixture.clock.advance(by: 900)
    let completion = try XCTUnwrap(fixture.viewModel.practiceTimer.finish())
    _ = try fixture.viewModel.savePracticeCompletion(completion, linkedProjectId: nil, note: "Chord changes")
    let card = try XCTUnwrap(fixture.viewModel.practiceCards(now: fixture.clock.now(), calendar: fixture.calendar).first)
    XCTAssertEqual(card.statistics.todayActiveSeconds, 1_800)
    XCTAssertEqual(card.statistics.weekCompletionCount, 1)
}
```

- [ ] **Step 2: Run the workflow test and verify failure**

Run: `swift test --filter PracticeTimerEndToEndTests`

Expected: FAIL until all public workflow APIs are connected.

- [ ] **Step 3: Build the Today practice section**

Place `practiceSection` immediately after `focusSection`. When cards are empty, show a compact `Add Practice` button. Each 8-point-radius card has fixed progress-ring dimensions, symbol/name, `today / target`, weekly completion count, weekly duration, all-time duration, and one Start/Resume command. Cap ring progress at `1.0` while leaving elapsed text uncapped. Add a section action that opens `PracticeManagerView`.

```swift
private var practiceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
        StudioSectionHeader(title: "Practice", actionTitle: "Manage") { showingPracticeManager = true }
        if practiceCards.isEmpty {
            Button { showingPracticeManager = true } label: {
                Label("Add Practice", systemImage: "plus")
            }
        } else {
            ForEach(practiceCards) { card in
                PracticeRoutineCard(card: card) { selectedPractice = card.routine }
            }
        }
    }
}
```

- [ ] **Step 4: Build timer and finish flow**

`PracticeTimerView` displays routine name, monospaced `HH:MM:SS`, target progress, pause/resume icon, finish icon, and discard icon with VoiceOver labels. Refresh display from a one-second `TimelineView`; elapsed remains date-derived from the runtime. Trigger `UINotificationFeedbackGenerator().notificationOccurred(.success)` only when `consumeTargetCrossing()` returns true. Finish reveals Save immediately plus optional note and project picker. On save error keep the finish view open with the user's values and a retryable alert; when a project vanished, save without it and show the fallback explanation. Confirm discard when elapsed is nonzero.

- [ ] **Step 5: Build routine management**

`PracticeManagerView` provides Active and Archived sections, add/edit sheets, a trimmed text field, SF Symbol menu, semantic-color swatches, `1...1_440` minute stepper/input, and seven weekday toggles. Disable Save for blank names, invalid targets, empty weekdays, or a duplicate active name compared case-insensitively. Archive routines that have history; allow permanent deletion only for routines with no sessions by using the existing soft-delete transaction path.

Add a `Related Practice` section to `ProjectDetailView` that reads `viewModel.practiceSessionsForProject(currentProject.id)` and shows routine name, date, active duration, and note. Keep it visually separate from learning Sessions so practice does not imply course-plan completion.

- [ ] **Step 6: Register source files and verify tests/build**

Add all four new Practice source files and both new view files to `SelfStudyStudio.xcodeproj/project.pbxproj` in the PersonalLearningJournal target, following the existing PBX file-reference/build-file conventions.

Run: `swift test --filter PracticeTimerEndToEndTests`

Expected: PASS.

Run: `swift test`

Expected: all tests PASS.

Run: `xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`

Expected: `** BUILD SUCCEEDED **` with no missing target-membership errors.

- [ ] **Step 7: Commit the UI workflow**

```bash
git add Sources/PersonalLearningJournal/Views/PracticeTimerView.swift Sources/PersonalLearningJournal/Views/PracticeManagerView.swift Sources/PersonalLearningJournal/Views/TodayView.swift Sources/PersonalLearningJournal/Views/ProjectsView.swift Sources/PersonalLearningJournal/Views/StudioTheme.swift SelfStudyStudio.xcodeproj/project.pbxproj Tests/PersonalLearningJournalTests/PracticeTimerEndToEndTests.swift
git commit -m "feat: add practice timer experience"
```

### Task 8: Full Verification, Simulator Walkthrough, And Documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the complete feature.
- Produces: verified package tests, simulator build, installed app, acceptance screenshots, and concise user-facing documentation.

- [ ] **Step 1: Document the completed feature and boundaries**

Add a `Practice timer` bullet to the README feature list describing recurring weekday routines, upward timing, local active-state recovery, optional project association, synced completions, and Today/week/all-time totals. State that practice does not complete course-plan sessions.

- [ ] **Step 2: Run the full automated verification**

Run: `swift test`

Expected: all tests PASS with zero failures.

Run: `xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Install and launch on iPhone 16 Pro**

Run: `xcrun simctl boot 'iPhone 16 Pro'`

Expected: simulator is booted, or command reports it is already booted.

Run: `open -a Simulator`

Expected: Simulator opens to iPhone 16 Pro.

Read `TARGET_BUILD_DIR`, `WRAPPER_NAME`, and `PRODUCT_BUNDLE_IDENTIFIER` from the successful build settings, then run:

```bash
xcrun simctl install booted "$TARGET_BUILD_DIR/$WRAPPER_NAME"
xcrun simctl launch booted "$PRODUCT_BUNDLE_IDENTIFIER"
```

Expected: launch returns the app process identifier.

- [ ] **Step 4: Perform the acceptance walkthrough**

In the simulator: create a Guitar routine for the current weekday with a one-minute target; start it; background and foreground the app; pause and resume; wait through target feedback and verify it keeps counting; finish; add a note and link a project; save; verify Today statistics update. Start a second short session and verify same-day totals combine. Edit and archive the routine, verify it leaves Today but remains in Archived, relaunch the app, and verify saved history remains. Repeat save with a project deleted before confirmation and verify the session saves without the link and explains why.

- [ ] **Step 5: Capture visual evidence and inspect accessibility/layout**

Run after each key screen is visible:

```bash
xcrun simctl io booted screenshot /tmp/practice-today.png
xcrun simctl io booted screenshot /tmp/practice-timer.png
xcrun simctl io booted screenshot /tmp/practice-finish.png
xcrun simctl io booted screenshot /tmp/practice-manager.png
```

Inspect the images at standard and accessibility text sizes. Confirm no overlap or truncation, progress ring dimensions do not shift, controls have readable VoiceOver labels, state is understandable without color, cards are at most 8-point radius, and no gradient/glass treatment was introduced.

- [ ] **Step 6: Commit documentation and any verification fixes**

Run: `git status --short`

Expected: only `README.md` is listed. If verification exposed a defect, return to the task that owns that behavior, add a failing regression test, fix it, rerun that task's focused command plus `swift test`, and commit the fix before continuing this task.

```bash
git add README.md
git commit -m "docs: verify practice timer workflow"
```

- [ ] **Step 7: Record final evidence**

Run: `git status --short`

Expected: no output.

Run: `git log -8 --oneline`

Expected: the practice domain, persistence, sync/export, service/statistics, runtime, presentation, UI, and verification commits appear in order.
