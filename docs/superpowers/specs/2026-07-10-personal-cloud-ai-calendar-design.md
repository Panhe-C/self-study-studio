# Self Study Studio Personal Cloud, AI Planning, and Calendar Design

## 1. Purpose

Extend Self Study Studio from a local personal learning journal into a personal,
multi-device learning system with three connected capabilities:

1. Private iCloud/CloudKit synchronization across devices using the same Apple
   Account.
2. AI-assisted course planning that produces an editable draft before changing
   project data.
3. A full personal learning calendar that schedules around existing Calendar
   events and writes changes only after explicit confirmation.

The product remains centered on self-study. It does not add social identity,
project members, invitations, shared projects, or collaboration.

## 2. Product Principles

- Local first: recording, reviewing, planning, and viewing the internal calendar
  remain usable without a network connection.
- Personal by default: all CloudKit records live in the current user's private
  database.
- Continue learning first: planning and calendar features must make the next
  useful study action clearer, not turn the app into a generic task manager.
- Draft before mutation: AI output and calendar changes are previews until the
  user confirms them.
- Evidence over completion percentage: plans define expected Proof, and actual
  learning remains grounded in Sessions and Proofs.
- Private calendar boundary: Calendar event titles, attendees, notes, and URLs
  never leave the device or enter an AI request.
- Recoverable synchronization: a local edit is durable before upload and is
  never silently discarded by a cloud conflict.

## 3. Scope

### 3.1 Included

- iCloud account status and private CloudKit synchronization.
- Offline mutation queue, incremental sync, deletion tombstones, retry, and
  three-way conflict handling.
- CloudKit attachment upload and download with local caching.
- Account-scoped local stores and safe Apple Account switching.
- Course plan creation from a course link plus user-provided course structure,
  target, deadline, and time budget.
- Structured AI plan generation through the existing OpenAI-compatible settings.
- Editable plan drafts, activation, replanning, and plan history.
- Plan phases, milestones, expected Proof, and concrete planned study sessions.
- Personal availability rules, daily limits, preferred session length, and time
  zone handling.
- Internal day, week, and month calendar views.
- EventKit full-access integration for busy-time analysis and confirmed event
  creation, update, and deletion.
- Calendar conflict detection, drag-to-reschedule, repeated availability rules,
  external event change detection, and permission degradation.
- Today integration for scheduled and overdue learning sessions.

### 3.2 Excluded

- People, members, invitations, roles, project sharing, `CKShare`, and the
  CloudKit shared database.
- Custom accounts, passwords, email login, Sign in with Apple UI, or a custom
  backend.
- Automatic crawling or scraping of course pages.
- AI actions that directly activate a plan, alter a project, or write Calendar
  events without confirmation.
- Sharing a user's availability or Calendar contents.
- Cross-platform web or desktop clients.
- General-purpose team calendars, meetings, attendees, or room booking.

## 4. Navigation and User Experience

The primary tabs become:

1. **Today**: continue cards, today's planned sessions, overdue work, schedule
   conflicts, and pending plan/calendar confirmations.
2. **Projects**: project list and project detail, including the active course
   plan, phases, milestones, actual Sessions, Proofs, and Reviews.
3. **Calendar**: day, week, and month views for personal learning sessions,
   availability, conflicts, and rescheduling.
4. **Library**: Proof browsing, attachment preview, and export.

Settings remains a toolbar destination rather than a tab. It contains:

- iCloud account and synchronization status.
- Last successful sync, queued mutation count, conflict count, and retry action.
- Calendar permission and target calendar selection.
- Availability rules and scheduling preferences.
- OpenAI-compatible endpoint, model, and API key controls.

Project detail gains a **Plan** section. It does not gain a People section.

### 4.1 Course Planning Flow

1. The user enters a course URL, optional pasted outline, learning goal,
   deadline, expected outcome, and weekly time budget.
2. The user selects or edits personal availability, preferred session length,
   maximum study minutes per day, and minimum gap between sessions.
3. The AI returns a structured `CoursePlanDraft` containing phases,
   milestones, expected Proof, and unscheduled session requirements.
4. The user edits, removes, or adds phases and sessions.
5. The local scheduler combines the edited draft with availability and EventKit
   busy intervals to create a `ScheduleDraft`.
6. The app shows proposed additions, moves, conflicts, and unscheduled work.
7. The user confirms plan activation separately from Calendar writeback.
8. Confirmed plan entities are saved locally and queued for CloudKit sync.
9. Calendar events are created or updated only after a second explicit Calendar
   confirmation.

### 4.2 Replanning Flow

- Completed Sessions and Proofs are historical facts and are never rewritten.
- Missed, skipped, or externally moved planned sessions can trigger a replan
  suggestion.
- Replanning produces a new draft and a visible change set.
- Activating the new plan archives the previous plan revision and preserves its
  relationship to completed learning records.
- Calendar changes again require explicit confirmation.

## 5. Domain Model

Existing `Project`, `LearningSession`, `Proof`, `Review`, and `TrailEvent`
remain the foundation. Their UUIDs become stable CloudKit record names.

### 5.1 Existing Entity Changes

`Project` gains:

- `activeCoursePlanId: UUID?`
- `deletedAt: Date?`
- `schemaVersion: Int`

`LearningSession` gains:

- `plannedSessionId: UUID?`
- `deletedAt: Date?`
- `schemaVersion: Int`

`Proof`, `Review`, and `TrailEvent` gain:

- `deletedAt: Date?`
- `schemaVersion: Int`

`TrailEventType` gains plan activation, plan revision, schedule change, and
calendar synchronization cases.

### 5.2 CoursePlan

- `id: UUID`
- `projectId: UUID`
- `revision: Int`
- `status: draft | active | archived | completed`
- `courseURL: URL?`
- `courseTitle: String`
- `courseOutline: String`
- `goal: String`
- `expectedOutcome: String`
- `startsOn: Date`
- `deadline: Date?`
- `weeklyBudgetMinutes: Int`
- `summary: String`
- `createdAt: Date`
- `updatedAt: Date`
- `activatedAt: Date?`
- `deletedAt: Date?`
- `schemaVersion: Int`

### 5.3 PlanPhase

- `id: UUID`
- `coursePlanId: UUID`
- `title: String`
- `objective: String`
- `expectedProof: String`
- `ordinal: Int`
- `targetStart: Date`
- `targetEnd: Date`
- `createdAt: Date`
- `updatedAt: Date`
- `deletedAt: Date?`

### 5.4 PlannedSession

- `id: UUID`
- `projectId: UUID`
- `coursePlanId: UUID`
- `phaseId: UUID`
- `title: String`
- `actionType: ActionType`
- `expectedProof: String?`
- `durationMinutes: Int`
- `scheduledStart: Date?`
- `scheduledEnd: Date?`
- `deadline: Date?`
- `status: unscheduled | scheduled | completed | skipped | cancelled`
- `completedSessionId: UUID?`
- `createdAt: Date`
- `updatedAt: Date`
- `deletedAt: Date?`

Plans contain concrete `PlannedSession` instances. Repeated availability rules
generate concrete sessions rather than a recurring EventKit series, allowing one
session to move without changing the rest of the plan.

### 5.5 AvailabilityRule

- `id: UUID`
- `weekday: Int`
- `startMinute: Int`
- `endMinute: Int`
- `timeZoneIdentifier: String`
- `validFrom: Date?`
- `validThrough: Date?`
- `minimumSessionMinutes: Int`
- `enabled: Bool`
- `createdAt: Date`
- `updatedAt: Date`

Availability is personal private data. It synchronizes through the user's
private CloudKit database but is never supplied to other services in raw form.

### 5.6 SchedulingPreferences

- `preferredSessionMinutes: Int`
- `maximumDailyMinutes: Int`
- `minimumGapMinutes: Int`
- `allowWeekends: Bool`
- `targetCalendarIdentifier: String?`
- `eventTitleStyle: project | session | private`

The target Calendar identifier is local-only because EventKit identifiers are
device-specific. Other preferences may sync privately.

### 5.7 CalendarBinding

`CalendarBinding` is local-only and never uploaded:

- `plannedSessionId: UUID`
- `eventIdentifier: String`
- `calendarIdentifier: String`
- `lastWrittenTitle: String`
- `lastWrittenStart: Date`
- `lastWrittenEnd: Date`
- `lastObservedAt: Date`
- `state: linked | externallyModified | externallyDeleted | detached`

### 5.8 Sync Metadata

`SyncRecordMetadata` is local-only:

- entity type and entity UUID
- CloudKit record ID and zone ID
- record change tag
- last-synced encoded payload for three-way merge
- local and server modification timestamps
- sync state and last error

`PendingMutation` is local-only:

- mutation UUID
- entity type and UUID
- operation: save or delete
- enqueue time, retry count, and last error

`SyncConflict` is local-only:

- entity type and UUID
- base, local, server, and proposed merged payloads
- conflicting field names
- creation and resolution timestamps

## 6. Persistence Architecture

The current `JournalStore.save(snapshot:)` implementation deletes and recreates
all rows. That behavior must not remain on the synchronization path.

Introduce an entity-level `JournalRepository` that supports:

- fetch and observation by entity type and project
- transactional insert, update, soft delete, and restore
- atomic insertion of a domain change plus `PendingMutation`
- application of remote batches without generating outbound mutations
- account-scoped store opening and closing
- versioned schema migration

`JournalService` remains the domain behavior boundary used by SwiftUI, but it
delegates persistence to `JournalRepository`. Snapshot construction remains
available for review, export, and backward-compatible tests; it is no longer the
write protocol.

The first launch after upgrade performs these steps:

1. Create a local backup export.
2. Migrate existing SwiftData records to the versioned repository schema.
3. Preserve the legacy JSON import path for users who have not migrated yet.
4. Ask whether existing local data should enable iCloud synchronization.
5. On approval, enqueue the existing entities as initial CloudKit saves.

## 7. iCloud and CloudKit Synchronization

### 7.1 Configuration

- Minimum platform remains iOS 17.
- Add iCloud/CloudKit and remote notification capabilities.
- Use one private custom record zone named `LearningJournalZone`.
- Use `CKSyncEngine` against the private database.
- Use a configurable `ICLOUD_CONTAINER_IDENTIFIER` build setting. Its default
  for the current bundle identifier is `iCloud.com.local.selfstudystudio`.
- The final container must be associated with the user's Apple Developer Team
  and promoted from development to production before release.

### 7.2 Account Isolation

CloudKit's account record ID selects an account-scoped local store. A hash of
the record name may be used in the local directory name; raw account identifiers
must not appear in UI or logs.

- First run without iCloud uses a `local` store.
- Enabling iCloud offers to migrate the local store into the current account's
  store and upload it.
- Temporary sign-out preserves the last account cache and queues local changes.
- Signing in with a different Apple Account closes the old store before opening
  the new account store.
- Data from two account stores is never merged automatically.

### 7.3 Record Mapping

CloudKit record types mirror domain entities. UUID strings are record names.
Relationships use UUID fields, not server-generated identifiers. Proof files use
`CKAsset`; the record retains MIME type, file size, and content hash.

On download, a `CKAsset` temporary file is copied atomically into the existing
attachment store before the CloudKit callback completes.

### 7.4 Mutation and Sync Flow

1. A user action validates through the domain service.
2. The repository atomically commits the entity and a `PendingMutation`.
3. SwiftUI observes the local commit immediately.
4. The sync coordinator schedules the CloudKit record-zone change.
5. `CKSyncEngine` asks for records to send; the coordinator builds records from
   current local entities.
6. Successful sends update change tags and remove matching mutations.
7. Retryable errors retain mutations with bounded exponential backoff.
8. Remote changes apply in one local transaction and refresh observers.

### 7.5 Conflict Policy

- UUIDs make all saves and downloads idempotent.
- Newly created Sessions, Proofs, and TrailEvents are append-oriented and merge
  independently.
- For mutable entities, the last-synced payload is the base of a three-way merge.
- Fields changed only locally keep the local value.
- Fields changed only remotely take the server value.
- Identical changes collapse.
- Different changes to the same field create `SyncConflict`; neither version is
  silently discarded.
- Resolving a conflict creates a new local mutation with the selected or edited
  result.

### 7.6 Deletion

Domain entities first receive `deletedAt`. The tombstone synchronizes like any
other change. After CloudKit confirms the delete and no pending dependent records
remain, the local row and attachment may be physically removed. This prevents an
offline device from resurrecting deleted data.

## 8. AI Course Planning

Refactor the existing OpenAI-compatible review transport into a reusable
structured AI client while preserving current settings and Keychain behavior.

Introduce:

- `CoursePlanningProvider`
- `OpenAICompatibleCoursePlanningProvider`
- `CoursePlanDraftValidator`
- `CoursePlanningService`

The AI request includes only:

- user-entered course URL and pasted outline
- project goal and current Next Step
- deadline and time budget
- desired session length and aggregate available minutes by weekday
- relevant Session and Proof summaries when replanning

It never includes Calendar event titles, notes, URLs, locations, attendees, or
raw event objects.

The provider must return a JSON object containing:

- title and summary
- ordered phases with objective, target range, and expected Proof
- session requirements with phase reference, action type, duration, and deadline
- assumptions and warnings

Validation rejects unknown phase references, nonpositive durations, dates outside
the plan range, empty objectives, and plans exceeding the user's time budget
without an explicit warning.

AI output is stored as a draft. It cannot change `Project.currentNextStep`,
activate a plan, or create EventKit events. Those changes require separate user
actions.

If the provider is unavailable, the user can create and schedule a manual plan.
Review generation continues to use its existing rule-based fallback.

## 9. Scheduling and EventKit

### 9.1 Calendar Access

The app requests iOS 17 EventKit full access only when the user enables busy-time
analysis. The target Info.plist contains
`NSCalendarsFullAccessUsageDescription`.

Authorization states are presented as:

- not requested
- full access
- denied or restricted
- changed in Settings

Denied access does not disable the internal learning calendar. It only disables
busy-time reads and direct system Calendar synchronization.

### 9.2 Scheduling Engine

The scheduling engine is a pure, deterministic component. Its inputs are:

- unscheduled or movable `PlannedSession` values
- availability rules
- scheduling preferences
- EventKit busy intervals stripped of private event content
- current time zone and plan deadline
- pinned sessions that the user does not want moved

It prioritizes:

1. hard deadlines and prerequisite phase order
2. pinned sessions
3. avoiding Calendar conflicts
4. maximum daily minutes and minimum gaps
5. preferred session length
6. an even weekly workload

The output is a `ScheduleDraft` with proposed placements, unscheduled sessions,
conflicts, and reasons. The scheduler never writes EventKit directly.

### 9.3 EventKit Writeback

After confirmation, `CalendarSyncService` creates or updates one EventKit event
per concrete planned session and stores a local `CalendarBinding`.

Before changing or deleting an existing event, it compares the current event to
the last-written snapshot:

- unchanged event: apply the requested update
- externally modified event: ask whether to adopt, overwrite, or detach
- externally deleted event: ask whether to recreate or detach

Calendar operations report partial success. A successful event is not rolled
back because another event failed; failed items remain in a retryable change set.

### 9.4 Calendar Interaction

- Day view shows an hourly timeline and conflicts.
- Week view supports drag-to-reschedule and duration changes.
- Month view shows workload density, deadlines, and unscheduled counts.
- Moving a planned session updates the internal plan first and then presents the
  system Calendar change for confirmation.
- Starting or completing a planned session links the resulting LearningSession
  and updates Today, Calendar, phase progress, and Review inputs.

## 10. Error Handling and Recovery

### 10.1 CloudKit

- No account or restricted account: local mode remains available.
- Network or service failure: retain outbox and expose retry.
- Quota exceeded: stop attachment uploads, keep local files, and explain which
  records remain unsynced.
- Missing asset: show Proof metadata and a retryable download state.
- Account change: isolate stores before showing new data.
- Conflict: expose Conflict Review with base, local, remote, and editable result.

### 10.2 AI

- Preserve all form input and the latest valid draft on request failure.
- Display validation failures against the relevant phase or session.
- Allow retry, provider reconfiguration, and manual plan creation.
- Never discard or rewrite an active plan because generation failed.

### 10.3 Calendar

- Permission denial falls back to the internal calendar.
- Revoked access marks bindings unavailable without deleting planned sessions.
- External edits require a user decision before overwrite.
- Partial write failure leaves a retryable change set.
- Time zone changes re-render local times and offer a schedule preview; they do
  not silently move confirmed events.

## 11. Privacy and Security

- CloudKit data uses the user's private database and Apple Account access model.
- AI API keys remain in Keychain and never enter SwiftData, CloudKit, export, or
  logs.
- Calendar event content remains on device. Only busy intervals and aggregate
  availability reach the local scheduler.
- AI requests contain no Calendar event metadata beyond aggregate available
  minutes.
- Logs redact CloudKit account IDs, record payloads, course content, API keys,
  URLs with query strings, and local attachment paths.
- JSON export includes plan entities but excludes sync metadata, account state,
  Calendar bindings, and API credentials.

## 12. Components and Interfaces

New modules:

- `JournalRepository`: incremental, transactional domain persistence.
- `AccountStoreCoordinator`: account status and account-scoped local stores.
- `CloudRecordMapper`: domain-to-CKRecord mapping.
- `CloudSyncCoordinator`: CKSyncEngine delegate, outbox, download, and retry.
- `SyncMergeService`: deterministic three-way merge and conflict creation.
- `CoursePlanningService`: provider input, validation, draft persistence, and
  activation.
- `StudySchedulingEngine`: pure schedule generation.
- `CalendarAuthorizationService`: EventKit authorization state.
- `CalendarSyncService`: EventKit read/write and binding reconciliation.

All external frameworks sit behind protocols so domain tests do not require an
iCloud account, network model, or Calendar permission.

## 13. Testing Strategy

### 13.1 Unit Tests

- Versioned domain decoding and migration.
- Entity repository transactions and outbox atomicity.
- CKRecord mapping for every entity and Proof asset metadata.
- Three-way merge, idempotency, tombstones, and conflict resolution.
- Account-store isolation and local-to-iCloud migration.
- AI request privacy, response decoding, validation, and draft-only behavior.
- Scheduling across deadlines, availability, daily limits, gaps, time zones,
  pinned sessions, busy intervals, and impossible schedules.
- Event comparison and external modification classification.
- View-model permissions and confirmation gates.

### 13.2 Integration Tests

- Fake CloudKit adapter sends and receives incremental record batches.
- Retryable and terminal CloudKit errors preserve correct outbox state.
- Fake EventKit store handles authorization, partial writes, external edits, and
  deletions.
- Stub AI transport verifies structured plan generation and malformed output.
- Existing journal export/import includes plans while excluding local-only data.

### 13.3 UI and Runtime Tests

- Course planning wizard through editable draft and activation.
- Calendar permission grant, denial, and fallback states.
- Day/week/month navigation and schedule confirmation.
- Offline local edit and visible queued-sync state.
- Conflict Review resolution.
- Today integration for scheduled, overdue, and completed work.

### 13.4 Real-Environment Acceptance

- Same Apple Account on two devices synchronizes all structured entities.
- Offline edits upload after connectivity returns.
- Concurrent edits produce the documented merge or Conflict Review.
- Image, audio, and file Proof attachments download on the second device.
- Account switching never mixes local stores.
- EventKit full access reads busy intervals and confirmed changes appear in the
  selected system Calendar.
- External Calendar edits and deletions produce reconciliation choices.
- AI plan generation, editing, activation, scheduling, writeback, completion,
  and replanning work end to end.

Real CloudKit acceptance requires an Apple Developer Team, a provisioned iCloud
container, and physical devices signed into iCloud. Simulator and fake-adapter
tests do not replace this gate.

## 14. Delivery Sequence

1. Versioned domain and incremental repository migration.
2. CloudKit private sync, account isolation, attachments, conflicts, and status
   UI.
3. Course plan domain, manual plan editing, and project/Today integration.
4. Reusable structured AI client and course planning provider.
5. Availability and deterministic scheduling engine.
6. Calendar day/week/month UI and EventKit adapter.
7. Confirmed Calendar writeback and reconciliation.
8. Cross-feature migration, export, UI tests, simulator verification, and real
   device acceptance.

Each stage must keep existing Session, Proof, Trail, Review, and export behavior
working.

## 15. Acceptance Criteria

The feature set is complete only when all of the following are true:

- Existing user data migrates without loss and can still be exported.
- Core recording remains usable while offline or signed out of iCloud.
- Same-account devices converge after independent offline edits.
- No People, role, invitation, `CKShare`, or shared-database UI or runtime path
  is present.
- CloudKit conflicts never silently discard a local or remote same-field edit.
- AI creates only editable drafts and never performs unconfirmed mutations.
- Course plans connect phases, planned sessions, completed Sessions, Proofs, and
  Reviews.
- The scheduler respects availability, Calendar busy intervals, time zones,
  deadlines, pinned sessions, and daily limits.
- EventKit is not changed until the user confirms the exact change set.
- Calendar permission denial leaves a usable internal calendar.
- Calendar external edits and deletes are detected and recoverable.
- Existing automated tests plus new repository, sync, planning, scheduling,
  EventKit, migration, and UI tests pass.
- The app builds and launches on an iOS simulator.
- CloudKit and EventKit real-device acceptance passes using the configured Apple
  Developer environment.
