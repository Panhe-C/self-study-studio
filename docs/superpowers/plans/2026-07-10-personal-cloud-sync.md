# Personal Cloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace snapshot-wide persistence with an incremental local repository and synchronize the personal journal through the current Apple Account's private CloudKit database while preserving offline behavior, attachments, conflicts, migration, and export.

**Architecture:** SwiftData remains the immediate local source of truth. `JournalRepository` commits entity-level transactions and an outbox atomically; `CloudSyncCoordinator` uses one `CKSyncEngine` for the private database and applies remote changes through a deterministic three-way merge. Account-scoped stores isolate Apple Accounts, and all CloudKit APIs sit behind protocols so package tests run without iCloud.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit, CKSyncEngine, Foundation, XCTest, iOS 17, macOS 14 package-test compatibility.

## Global Constraints

- Keep core recording, Proof, Review, Trail, attachment, and export behavior working throughout the migration.
- Store all cloud records in the current user's private CloudKit database; do not add `CKShare`, People, roles, invitations, or shared-database code.
- Commit local data before attempting network work.
- Never silently discard a same-field local or remote edit.
- Keep API keys, CloudKit account identifiers, sync metadata, and local paths out of exports and logs.
- Use one private record zone named `LearningJournalZone`.
- Use `ICLOUD_CONTAINER_IDENTIFIER`, defaulting to `iCloud.com.local.selfstudystudio` for the current bundle identifier.
- Real CloudKit acceptance requires an Apple Developer Team and provisioned container; fake-adapter and simulator checks do not replace it.

---

## File Structure

- `Sources/PersonalLearningJournal/Domain.swift`: backward-compatible soft-delete and schema-version fields.
- `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`: typed entity envelope and references.
- `Sources/PersonalLearningJournal/Persistence/JournalRepository.swift`: incremental transaction protocol and in-memory test implementation.
- `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`: version-2 SwiftData records, outbox, remote apply, and snapshot reads.
- `Sources/PersonalLearningJournal/Persistence/RepositoryMigration.swift`: legacy snapshot backup and one-time import into the version-2 store.
- `Sources/PersonalLearningJournal/Sync/SyncDomain.swift`: account, outbox, metadata, remote change, conflict, and status values.
- `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`: `JournalEntity` and `CKRecord` conversion plus `CKAsset` staging.
- `Sources/PersonalLearningJournal/Sync/SyncMergeService.swift`: pure three-way merge.
- `Sources/PersonalLearningJournal/Sync/CloudSyncCoordinator.swift`: protocol-driven sync orchestration and CKSyncEngine adapter.
- `Sources/PersonalLearningJournal/Sync/CloudAccountCoordinator.swift`: account status and account-scoped repository selection.
- `Sources/PersonalLearningJournal/Views/SyncSettingsView.swift`: account, queue, error, conflict, and retry UI.
- `SelfStudyStudio/SelfStudyStudio.entitlements`: iCloud and remote-notification entitlements.
- `Sources/PersonalLearningJournal/JournalService.swift`: entity-level transactions instead of snapshot writes.
- `Sources/PersonalLearningJournal/JournalViewModel.swift`: observed repository/sync state.
- `App/SelfStudyStudioApp.swift`: production repository, account, and sync composition.
- `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`: package/demo composition.
- `SelfStudyStudio.xcodeproj/project.pbxproj`: new files, entitlements, container setting, and background mode.
- `Tests/PersonalLearningJournalTests/*Tests.swift`: migration, repository, mapping, merge, sync, account, and UI-state coverage.

### Task 1: Make Existing Domain Records Sync-Safe

**Files:**
- Modify: `Sources/PersonalLearningJournal/Domain.swift`
- Modify: `Sources/PersonalLearningJournal/ExportService.swift`
- Test: `Tests/PersonalLearningJournalTests/DomainTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`

**Interfaces:**
- Produces: `JournalSchema.currentVersion`, `deletedAt`, `schemaVersion`, and new `TrailEventType` values used by repository and CloudKit tasks.

- [ ] **Step 1: Write backward-decoding and export tests**

Add tests that decode a pre-sync `Project` without new keys and verify local-only metadata never enters exports:

```swift
func testLegacyProjectDecodesWithCurrentSchemaAndNoDeletion() throws {
    let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"CS336","area":"AI","goal":"Finish","status":"active","currentNextStep":"Lecture 1","lastActionType":"course","defaultDurationMinutes":30,"createdAt":"2001-01-01T00:00:00Z","updatedAt":"2001-01-01T00:00:00Z"}"#.utf8)
    let project = try JSONDecoder.journal.decode(Project.self, from: data)

    XCTAssertNil(project.deletedAt)
    XCTAssertEqual(project.schemaVersion, JournalSchema.currentVersion)
}
```

```swift
func testExportContainsDomainDeletionStateButNoSyncMetadata() throws {
    let project = Project(name: "CS336", area: "AI", goal: "Finish", currentNextStep: "Lecture 1")
    let data = try ExportService().exportJSON(snapshot: JournalSnapshot(projects: [project]))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(json.contains("schemaVersion"))
    XCTAssertFalse(json.contains("recordChangeTag"))
    XCTAssertFalse(json.contains("accountRecordName"))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter DomainTests/testLegacyProjectDecodesWithCurrentSchemaAndNoDeletion`

Expected: compile failure because `deletedAt`, `schemaVersion`, and `JournalSchema` do not exist.

- [ ] **Step 3: Add schema and deletion fields with backward-compatible decoding**

Add this public schema constant and fields to all five existing domain structs:

```swift
public enum JournalSchema {
    public static let currentVersion = 2
}

// Add to Project, LearningSession, Proof, Review, and TrailEvent.
public var deletedAt: Date?
public var schemaVersion: Int
```

Each custom `init(from:)` must use this exact fallback:

```swift
deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
    ?? JournalSchema.currentVersion
```

Add these cases without changing existing raw values:

```swift
case planActivated
case planRevised
case scheduleChanged
case calendarSynced
```

- [ ] **Step 4: Run focused and full domain/export tests**

Run: `swift test --filter DomainTests && swift test --filter ExportServiceTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Domain.swift Sources/PersonalLearningJournal/ExportService.swift Tests/PersonalLearningJournalTests/DomainTests.swift Tests/PersonalLearningJournalTests/ExportServiceTests.swift
git commit -m "feat: make journal entities sync safe"
```

### Task 2: Define Entity-Level Repository Transactions

**Files:**
- Create: `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`
- Create: `Sources/PersonalLearningJournal/Persistence/JournalRepository.swift`
- Create: `Sources/PersonalLearningJournal/Sync/SyncDomain.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalRepositoryTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: existing domain entities with stable UUIDs.
- Produces: `JournalEntity`, `JournalEntityReference`, `JournalTransaction`, `MutationOrigin`, `PendingMutation`, `SyncRecordMetadata`, `SyncConflict`, and `JournalRepository`.

- [ ] **Step 1: Write transaction and idempotency tests**

```swift
func testUserTransactionPersistsEntityAndOutboxAtomically() throws {
    let repository = InMemoryJournalRepository()
    let project = Project(name: "CS336", area: "AI", goal: "Finish", currentNextStep: "Lecture 1")

    try repository.commit(JournalTransaction(upserts: [.project(project)], origin: .user))

    XCTAssertEqual(try repository.snapshot().projects, [project])
    XCTAssertEqual(try repository.pendingMutations(limit: 10).map(\.entity), [.init(.project, project.id)])
}

func testRemoteApplyDoesNotCreateOutboundMutation() throws {
    let repository = InMemoryJournalRepository()
    let project = Project(name: "CS336", area: "AI", goal: "Finish", currentNextStep: "Lecture 1")

    try repository.commit(JournalTransaction(upserts: [.project(project)], origin: .remote))

    XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter JournalRepositoryTests`

Expected: compile failure because repository types do not exist.

- [ ] **Step 3: Add exact entity and transaction types**

```swift
public enum JournalEntityKind: String, Codable, CaseIterable, Sendable {
    case project, session, proof, review, trailEvent
}

public struct JournalEntityReference: Codable, Equatable, Hashable, Sendable {
    public var kind: JournalEntityKind
    public var id: UUID
    public init(_ kind: JournalEntityKind, _ id: UUID) { self.kind = kind; self.id = id }
}

public enum JournalEntity: Codable, Equatable, Sendable {
    case project(Project)
    case session(LearningSession)
    case proof(Proof)
    case review(Review)
    case trailEvent(TrailEvent)
}

public enum MutationOrigin: Sendable { case user, migration, remote }

public struct JournalTransaction: Sendable {
    public var upserts: [JournalEntity]
    public var deletions: [JournalEntityReference]
    public var origin: MutationOrigin

    public init(
        upserts: [JournalEntity] = [],
        deletions: [JournalEntityReference] = [],
        origin: MutationOrigin
    ) {
        self.upserts = upserts
        self.deletions = deletions
        self.origin = origin
    }
}

public extension JournalEntity {
    var reference: JournalEntityReference {
        switch self {
        case let .project(value): .init(.project, value.id)
        case let .session(value): .init(.session, value.id)
        case let .proof(value): .init(.proof, value.id)
        case let .review(value): .init(.review, value.id)
        case let .trailEvent(value): .init(.trailEvent, value.id)
        }
    }
}

public enum SyncOperation: String, Codable, Sendable { case save, delete }
public enum SyncDatabaseScope: String, Codable, Sendable { case privateDatabase }
public enum SyncState: String, Codable, Sendable { case pending, syncing, synced, failed, conflict }

public struct PendingMutation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entity: JournalEntityReference
    public var operation: SyncOperation
    public var enqueuedAt: Date
    public var retryCount: Int
    public var lastError: String?
}

public struct SyncRecordMetadata: Codable, Equatable, Sendable {
    public var entity: JournalEntityReference
    public var zoneName: String
    public var recordName: String
    public var recordChangeTag: String?
    public var lastSyncedPayload: Data?
    public var lastSyncedAt: Date?
    public var state: SyncState
    public var lastError: String?
}

public struct SyncConflict: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entity: JournalEntityReference
    public var basePayload: Data
    public var localPayload: Data
    public var serverPayload: Data
    public var proposedPayload: Data
    public var conflictingFields: [String]
    public var createdAt: Date
    public var resolvedAt: Date?
}
```

- [ ] **Step 4: Add repository protocol and in-memory implementation**

```swift
public protocol JournalRepository: AnyObject {
    func snapshot() throws -> JournalSnapshot
    func commit(_ transaction: JournalTransaction) throws
    func pendingMutations(limit: Int) throws -> [PendingMutation]
    func acknowledge(_ mutationIDs: Set<UUID>, metadata: [SyncRecordMetadata]) throws
    func conflicts() throws -> [SyncConflict]
    func resolveConflict(id: UUID, with entity: JournalEntity) throws
}
```

`InMemoryJournalRepository.commit` must replace by `(kind,id)`, mark deletions
locally, and append one `PendingMutation` per user upsert/deletion in the same
critical section. Migration and remote origins create no outbox entries.

- [ ] **Step 5: Register new files and run tests**

Add both source files to the Xcode app target's Sources group and build phase.

Run: `swift test --filter JournalRepositoryTests && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: repository tests pass and the app target builds.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Persistence Sources/PersonalLearningJournal/Sync/SyncDomain.swift Tests/PersonalLearningJournalTests/JournalRepositoryTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: add incremental journal repository"
```

### Task 3: Persist Transactions, Outbox, and Sync Metadata in SwiftData

**Files:**
- Create: `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`
- Modify: `Sources/PersonalLearningJournal/JournalStore.swift`
- Test: `Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `JournalRepository`, `JournalTransaction`, and `JournalEntity`.
- Produces: `SwiftDataJournalRepository` and `RepositoryFactory`, persisting the sync types from Task 2.

- [ ] **Step 1: Write SwiftData atomicity and restart tests**

```swift
func testSwiftDataRepositoryRoundTripsEntityAndOutboxAcrossInstances() throws {
    let url = temporaryDirectory.appendingPathComponent("journal-v2.store")
    let first = try SwiftDataJournalRepository(url: url)
    let project = Project(name: "CS336", area: "AI", goal: "Finish", currentNextStep: "Lecture 1")
    try first.commit(JournalTransaction(upserts: [.project(project)], origin: .user))

    let second = try SwiftDataJournalRepository(url: url)
    XCTAssertEqual(try second.snapshot().projects.map(\.id), [project.id])
    XCTAssertEqual(try second.pendingMutations(limit: 10).count, 1)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter SwiftDataJournalRepositoryTests`

Expected: compile failure because the SwiftData repository implementation does not exist.

- [ ] **Step 3: Implement the version-2 SwiftData repository**

Create separate `@Model` records for each domain entity, outbox item, metadata,
conflict, and repository metadata. `commit` must use one `ModelContext.save()`
after applying entity changes and creating outbox records. Fetches exclude rows
whose `deletedAt` is non-nil from ordinary snapshots.

Use this factory signature:

```swift
public enum RepositoryFactory {
    public static func makeDefault(storeURL: URL) throws -> SwiftDataJournalRepository
}
```

- [ ] **Step 4: Run repository and legacy-store regression tests**

Run: `swift test --filter SwiftDataJournalRepositoryTests && swift test --filter JournalStoreTests`

Expected: all selected tests pass; existing `SwiftDataJournalStore` tests remain green until migration removes runtime use.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Sync/SyncDomain.swift Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift Sources/PersonalLearningJournal/JournalStore.swift Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: persist journal outbox transactions"
```

### Task 4: Migrate Legacy Stores and Refactor JournalService Writes

**Files:**
- Create: `Sources/PersonalLearningJournal/Persistence/RepositoryMigration.swift`
- Modify: `Sources/PersonalLearningJournal/JournalService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Modify: `App/SelfStudyStudioApp.swift`
- Modify: `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`
- Test: `Tests/PersonalLearningJournalTests/RepositoryMigrationTests.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `JournalRepository` and legacy `JournalStore`.
- Produces: `RepositoryMigration.migrateIfNeeded(...)`; `JournalService.init(repository:now:)`.

- [ ] **Step 1: Write migration and precise-mutation tests**

```swift
func testMigrationImportsLegacySnapshotOnceWithoutCreatingOutbox() throws {
    let legacy = InMemoryJournalStore(snapshot: JournalSnapshot(projects: [project]))
    let repository = InMemoryJournalRepository()

    try RepositoryMigration().migrateIfNeeded(from: legacy, to: repository)
    try RepositoryMigration().migrateIfNeeded(from: legacy, to: repository)

    XCTAssertEqual(try repository.snapshot().projects.map(\.id), [project.id])
    XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
}
```

Add a `JournalServiceTests` spy repository assertion that `quickLog` upserts only
the changed Project, new Session, and generated TrailEvents rather than replacing
the whole snapshot.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter RepositoryMigrationTests && swift test --filter JournalServiceTests/testQuickLogCommitsOnlyChangedEntities`

Expected: compile failure because migration and repository-based service initialization do not exist.

- [ ] **Step 3: Implement one-time backup and migration**

Use this API:

```swift
public struct RepositoryMigration {
    public func migrateIfNeeded(
        from legacyStore: any JournalStore,
        to repository: any JournalRepository,
        backupDirectory: URL? = nil
    ) throws
}
```

The migration writes `journal-v1-backup.json` before import, commits all legacy
entities with `.migration`, and records a durable migration marker so a second
launch is a no-op.

- [ ] **Step 4: Change JournalService to entity-level commits**

Replace `JournalService.init(store:now:)` runtime use with:

```swift
public init(repository: any JournalRepository, now: @escaping () -> Date = Date.init) {
    self.repository = repository
    self.now = now
    self.state = (try? repository.snapshot()) ?? JournalSnapshot()
}
```

Every mutating method must construct a `JournalTransaction` containing only its
changed entities and generated TrailEvents. Remove `replaceSnapshot` from public
runtime behavior; keep a test-only import helper in `RepositoryMigration`.

- [ ] **Step 5: Update composition and tests**

Construct `SwiftDataJournalRepository` at `LearningJournal/<account-scope>/journal-v2.store`, run migration, and inject the repository into `JournalService`.

Run: `swift test --filter RepositoryMigrationTests && swift test --filter JournalServiceTests && swift test --filter JournalViewModelTests && swift test`

Expected: all tests pass, including prior recording and review behavior.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Persistence/RepositoryMigration.swift Sources/PersonalLearningJournal/JournalService.swift Sources/PersonalLearningJournal/JournalViewModel.swift App/SelfStudyStudioApp.swift Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift Tests/PersonalLearningJournalTests SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "refactor: persist journal changes incrementally"
```

### Task 5: Map Domain Entities and Attachments to CloudKit

**Files:**
- Create: `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`
- Modify: `Sources/PersonalLearningJournal/AttachmentStore.swift`
- Test: `Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `JournalEntity`, `SyncRecordMetadata`, and attachment paths.
- Produces: `CloudRecordMapper.record(for:zoneID:)`, `entity(from:)`, and asset import.

- [ ] **Step 1: Write record round-trip and asset tests**

```swift
func testProjectMapsToStablePrivateZoneRecord() throws {
    let project = Project(id: fixedID, name: "CS336", area: "AI", goal: "Finish", currentNextStep: "Lecture 1")
    let record = try mapper.record(for: .project(project), zoneID: zoneID)

    XCTAssertEqual(record.recordID.recordName, fixedID.uuidString)
    XCTAssertEqual(record.recordType, "Project")
    XCTAssertEqual(record["name"] as? String, "CS336")
    XCTAssertEqual(try mapper.entity(from: record), .project(project))
}
```

```swift
func testDownloadedProofAssetIsCopiedBeforeTemporaryFileDisappears() throws {
    let destination = try mapper.importAsset(at: temporaryAssetURL, proofID: fixedID)
    try FileManager.default.removeItem(at: temporaryAssetURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CloudRecordMapperTests`

Expected: compile failure because `CloudRecordMapper` does not exist.

- [ ] **Step 3: Implement explicit record schemas**

Use `CKRecord.ID(recordName: entity.id.uuidString, zoneID: zoneID)`. Encode every
domain field as a named CKRecord field, never as one opaque snapshot blob. Store
relationships as UUID strings. Proof records use `CKAsset(fileURL:)`, MIME type,
file size, and SHA-256 content hash. Decoder validation must reject mismatched
record type, missing UUID, invalid enum raw value, or invalid duration.

- [ ] **Step 4: Run mapping tests and package build**

Run: `swift test --filter CloudRecordMapperTests && swift build`

Expected: mapping and attachment tests pass; package builds on macOS 14.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift Sources/PersonalLearningJournal/AttachmentStore.swift Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: map journal records to cloudkit"
```

### Task 6: Implement Three-Way Merge and Conflict Resolution

**Files:**
- Create: `Sources/PersonalLearningJournal/Sync/SyncMergeService.swift`
- Test: `Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: base, local, and server encoded `JournalEntity` payloads.
- Produces: `SyncMergeResult.merged(JournalEntity)` or `.conflict(SyncConflict)`.

- [ ] **Step 1: Write disjoint and same-field merge tests**

```swift
func testDisjointProjectEditsMergeWithoutConflict() throws {
    let result = try merger.merge(base: base, local: localGoalEdit, server: serverNextStepEdit)
    guard case let .merged(.project(project)) = result else { return XCTFail("Expected merged project") }
    XCTAssertEqual(project.goal, "New goal")
    XCTAssertEqual(project.currentNextStep, "New next")
}

func testSameFieldProjectEditsCreateConflictWithoutDroppingEitherValue() throws {
    let result = try merger.merge(base: base, local: localGoalEdit, server: serverGoalEdit)
    guard case let .conflict(conflict) = result else { return XCTFail("Expected conflict") }
    XCTAssertEqual(conflict.conflictingFields, ["goal"])
    XCTAssertFalse(conflict.localPayload.isEmpty)
    XCTAssertFalse(conflict.serverPayload.isEmpty)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter SyncMergeServiceTests`

Expected: compile failure because merge types do not exist.

- [ ] **Step 3: Implement field-level three-way merge**

```swift
public enum SyncMergeResult: Equatable, Sendable {
    case merged(JournalEntity)
    case conflict(SyncConflict)
}

public struct SyncMergeService {
    public func merge(
        base: JournalEntity,
        local: JournalEntity,
        server: JournalEntity,
        now: Date = Date()
    ) throws -> SyncMergeResult
}
```

Compare typed fields by entity kind. Keep local-only changes, take server-only
changes, collapse identical changes, and create a conflict when both sides changed
the same field differently. Never use whole-record last-write-wins.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SyncMergeServiceTests`

Expected: all merge and conflict tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PersonalLearningJournal/Sync/SyncMergeService.swift Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: merge cloud journal changes safely"
```

### Task 7: Orchestrate Private Cloud Synchronization

**Files:**
- Create: `Sources/PersonalLearningJournal/Sync/CloudSyncCoordinator.swift`
- Test: `Tests/PersonalLearningJournalTests/CloudSyncCoordinatorTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: repository outbox, mapper, merger, and `CloudDatabaseClient`.
- Produces: `CloudSyncCoordinator.start()`, `syncNow()`, `status`, and remote batch application.

- [ ] **Step 1: Write push, retry, pull, and delete tests with a fake client**

```swift
func testSuccessfulPushAcknowledgesOnlySavedMutations() async throws {
    let coordinator = makeCoordinator(client: FakeCloudDatabaseClient(saveResult: .success))
    try await coordinator.syncNow()
    XCTAssertTrue(try repository.pendingMutations(limit: 10).isEmpty)
}

func testRetryableFailureKeepsMutationAndIncrementsRetryCount() async throws {
    let coordinator = makeCoordinator(client: FakeCloudDatabaseClient(saveResult: .retryableFailure))
    try await coordinator.syncNow()
    XCTAssertEqual(try repository.pendingMutations(limit: 10).first?.retryCount, 1)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CloudSyncCoordinatorTests`

Expected: compile failure because coordinator and cloud client protocol do not exist.

- [ ] **Step 3: Define the injectable cloud boundary**

```swift
public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing(pending: Int)
    case synced(lastSuccess: Date)
    case failed(pending: Int, conflicts: Int, message: String)
}

public enum CloudMutation: Sendable {
    case save(mutationID: UUID, entity: JournalEntity)
    case delete(mutationID: UUID, entity: JournalEntityReference)
}

public struct CloudSendResult: Sendable {
    public var acknowledgedMutationIDs: Set<UUID>
    public var metadata: [SyncRecordMetadata]
    public var retryableErrors: [UUID: String]
    public var terminalErrors: [UUID: String]
}

public enum CloudRemoteChange: Sendable {
    case save(CKRecord)
    case delete(CKRecord.ID)
}

public struct CloudChangeBatch: Sendable {
    public var changes: [CloudRemoteChange]
    public var tokenData: Data?
    public var moreComing: Bool
}

public protocol CloudDatabaseClient: Sendable {
    func ensureZone(named: String) async throws
    func send(_ mutations: [CloudMutation]) async throws -> CloudSendResult
    func fetchChanges(after tokenData: Data?) async throws -> CloudChangeBatch
}

public protocol CloudSyncCoordinating: AnyObject, Sendable {
    var status: SyncStatus { get async }
    func start() async
    func syncNow() async throws
}
```

Production `CKSyncEngineDatabaseClient` owns one engine configured for
`CKContainer(identifier: configuredIdentifier).privateCloudDatabase` and the
`LearningJournalZone` custom zone. It persists engine state/change tokens in the
account-scoped repository metadata.

- [ ] **Step 4: Implement coordinator behavior**

Push pending saves/deletes, acknowledge only per-record successes, retain
retryable failures, surface quota/account failures, fetch remote batches, run
three-way merge using stored base payloads, and apply merged entities/conflicts in
one repository transaction.

- [ ] **Step 5: Run sync and full tests**

Run: `swift test --filter CloudSyncCoordinatorTests && swift test`

Expected: all fake-cloud sync and existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Sync/CloudSyncCoordinator.swift Tests/PersonalLearningJournalTests/CloudSyncCoordinatorTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: synchronize private cloud journal"
```

### Task 8: Isolate Apple Accounts and Bootstrap Existing Data

**Files:**
- Create: `Sources/PersonalLearningJournal/Sync/CloudAccountCoordinator.swift`
- Test: `Tests/PersonalLearningJournalTests/CloudAccountCoordinatorTests.swift`
- Modify: `App/SelfStudyStudioApp.swift`
- Modify: `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CKAccountStatus`, account record name, and `RepositoryFactory`.
- Produces: `CloudAccountState`, account-scoped repository URLs, and local-to-iCloud bootstrap decision.

- [ ] **Step 1: Write account isolation tests**

```swift
func testDifferentAccountRecordNamesResolveDifferentStoreURLs() throws {
    let first = coordinator.storeURL(forAccountRecordName: "account-a")
    let second = coordinator.storeURL(forAccountRecordName: "account-b")
    XCTAssertNotEqual(first, second)
    XCTAssertFalse(first.path.contains("account-a"))
    XCTAssertFalse(second.path.contains("account-b"))
}
```

```swift
func testNoAccountKeepsLocalStoreAvailable() async throws {
    await coordinator.refresh(using: FakeAccountProvider(status: .noAccount))
    XCTAssertEqual(await coordinator.state.mode, .localOnly)
    XCTAssertNotNil(await coordinator.activeRepository)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CloudAccountCoordinatorTests`

Expected: compile failure because account coordinator types do not exist.

- [ ] **Step 3: Implement account hashing and state machine**

```swift
public protocol CloudAccountProviding: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func currentUserRecordName() async throws -> String?
}

public enum CloudAccountMode: Equatable, Sendable {
    case checking, localOnly, cloud(accountHash: String), restricted, unavailable
}

public struct CloudAccountState: Equatable, Sendable {
    public var mode: CloudAccountMode
    public var lastCheckedAt: Date?
    public var message: String?
}
```

Hash account record names with SHA-256, close the current repository before
opening another account's directory, and never log or display the raw record name.
Do not merge account stores automatically.

- [ ] **Step 4: Add explicit local-data bootstrap**

Expose `prepareExistingLocalDataForCloud()` as a preview count and
`confirmExistingLocalDataUpload()` as the user-confirmed action that enqueues all
current entities. Cancel leaves the local store untouched.

- [ ] **Step 5: Run account and startup tests**

Run: `swift test --filter CloudAccountCoordinatorTests && swift test`

Expected: account switching, local fallback, and existing app tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Sync/CloudAccountCoordinator.swift App/SelfStudyStudioApp.swift Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift Tests/PersonalLearningJournalTests/CloudAccountCoordinatorTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: isolate personal icloud accounts"
```

### Task 9: Add Sync Settings, Conflict Review, and Xcode Capabilities

**Files:**
- Create: `Sources/PersonalLearningJournal/Views/SyncSettingsView.swift`
- Create: `SelfStudyStudio/SelfStudyStudio.entitlements`
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`

**Interfaces:**
- Consumes: account state, `SyncStatus`, outbox, conflicts, and coordinator actions.
- Produces: visible Local Only/Syncing/Synced/Needs Attention states, retry, bootstrap confirmation, and conflict resolution UI.

- [ ] **Step 1: Write view-model state tests**

```swift
func testSyncSummaryShowsQueuedChangesAndConflictCount() async throws {
    let viewModel = makeViewModel(syncStatus: .failed(pending: 2, conflicts: 1, message: "Offline"))
    XCTAssertEqual(viewModel.syncSummary.title, "Needs Attention")
    XCTAssertEqual(viewModel.syncSummary.detail, "2 changes waiting, 1 conflict")
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter JournalViewModelTests/testSyncSummaryShowsQueuedChangesAndConflictCount`

Expected: compile failure because sync summary state is not exposed.

- [ ] **Step 3: Build sync settings and conflict UI**

The screen contains account mode, last success, pending count, retry button,
existing-data bootstrap confirmation, and a Conflict Review list. Conflict detail
shows base/local/server values per conflicting field and supports Local, Cloud, or
edited merged resolution. Do not add People or sharing controls.

- [ ] **Step 4: Add capabilities and generated Info.plist settings**

Create entitlements with:

```xml
<key>aps-environment</key>
<string>$(APS_ENVIRONMENT)</string>
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>$(ICLOUD_CONTAINER_IDENTIFIER)</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudKit</string></array>
```

Set `CODE_SIGN_ENTITLEMENTS`, `ICLOUD_CONTAINER_IDENTIFIER`, and the remote
notification background mode in both Debug and Release. Set `APS_ENVIRONMENT` to
`development` in Debug and `production` in Release. Keep `DEVELOPMENT_TEAM` empty
so the user's team is selected locally.

- [ ] **Step 5: Run tests and unsigned simulator build**

Run: `swift test && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: all tests pass and `** BUILD SUCCEEDED **` appears.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Views/SyncSettingsView.swift Sources/PersonalLearningJournal/Views/TodayView.swift Sources/PersonalLearningJournal/JournalViewModel.swift SelfStudyStudio/SelfStudyStudio.entitlements SelfStudyStudio.xcodeproj/project.pbxproj Tests/PersonalLearningJournalTests/JournalViewModelTests.swift
git commit -m "feat: expose personal cloud sync status"
```

### Task 10: Verify Migration, Offline Sync, Attachments, and Privacy

**Files:**
- Modify: `README.md`
- Modify: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`
- Create: `Tests/PersonalLearningJournalTests/CloudSyncEndToEndTests.swift`

**Interfaces:**
- Consumes: completed personal-cloud implementation.
- Produces: fake-cloud end-to-end proof and documented real-device checklist.

- [ ] **Step 1: Add end-to-end fake-cloud test**

```swift
func testOfflineEditSurvivesRestartUploadsAndAppearsOnSecondRepository() async throws {
    try firstRepository.commit(JournalTransaction(upserts: [.project(project)], origin: .user))
    let restarted = try SwiftDataJournalRepository(url: firstStoreURL)
    try await firstCoordinator(repository: restarted, cloud: cloud).syncNow()
    try await secondCoordinator(repository: secondRepository, cloud: cloud).syncNow()

    XCTAssertEqual(try secondRepository.snapshot().projects, [project])
    XCTAssertTrue(try restarted.pendingMutations(limit: 10).isEmpty)
}
```

- [ ] **Step 2: Add export privacy assertions**

Assert exported JSON contains domain records and excludes account hashes,
outbox errors, CloudKit identifiers, change tags, conflicts, and Calendar data.

- [ ] **Step 3: Run complete automated verification**

Run: `swift test && swift build && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: all tests pass, package builds, and simulator target reports `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Document real-device acceptance**

Add README steps for selecting the Apple Developer Team, associating the
container, signing two devices into the same Apple Account, creating records on
each device, testing airplane mode, downloading each attachment type, switching
accounts, and promoting the development schema before release.

- [ ] **Step 5: Commit**

```bash
git add README.md Tests/PersonalLearningJournalTests/ExportServiceTests.swift Tests/PersonalLearningJournalTests/CloudSyncEndToEndTests.swift
git commit -m "test: verify personal cloud sync end to end"
```
