# Course Planning AI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add editable, revisioned course plans that connect project goals to phases, expected Proof, and concrete planned study sessions, with optional OpenAI-compatible draft generation that never mutates active data without confirmation.

**Architecture:** Course planning is a domain service above the incremental `JournalRepository` from the personal-cloud plan. A reusable structured AI client powers both existing weekly Review and the new `CoursePlanningProvider`; provider output is decoded into a draft, validated locally, edited by the user, then activated as a repository transaction. Scheduling and EventKit remain outside this plan and consume unscheduled `PlannedSession` records in the calendar plan.

**Tech Stack:** Swift 6, SwiftUI, Foundation, URLSession, Security Keychain, SwiftData repository, XCTest, iOS 17, macOS 14 package-test compatibility.

## Global Constraints

- Complete `2026-07-10-personal-cloud-sync.md` first.
- Keep daily Quick Log and Timer flows unchanged.
- Do not crawl course pages; inputs are the URL and course structure supplied by the user.
- Do not send Calendar event content to AI.
- AI output is always a draft and cannot activate a plan, change Next Step, or create Calendar events.
- API keys remain in Keychain and out of SwiftData, CloudKit, exports, and logs.
- Manual course planning must work without AI or network access.
- Plans remain personal private CloudKit records; do not add People or collaboration.

---

## File Structure

- `Sources/PersonalLearningJournal/Planning/CoursePlanningDomain.swift`: plans, phases, planned sessions, inputs, and drafts.
- `Sources/PersonalLearningJournal/Planning/CoursePlanValidator.swift`: pure validation and time-budget warnings.
- `Sources/PersonalLearningJournal/Planning/CoursePlanningService.swift`: draft persistence, activation, completion, and revision behavior.
- `Sources/PersonalLearningJournal/AI/StructuredAIClient.swift`: reusable OpenAI-compatible JSON client.
- `Sources/PersonalLearningJournal/Planning/CoursePlanningProvider.swift`: prompt/input mapping and structured plan decoding.
- `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`: planning entity cases.
- `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`: planning records.
- `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`: planning CloudKit record schemas.
- `Sources/PersonalLearningJournal/Domain.swift`: project active-plan reference and plan Trail events.
- `Sources/PersonalLearningJournal/JournalService.swift`: plan-aware project/session behavior.
- `Sources/PersonalLearningJournal/JournalViewModel.swift`: observable plan state and commands.
- `Sources/PersonalLearningJournal/ExportService.swift`: export plan entities.
- `Sources/PersonalLearningJournal/Views/CoursePlanWizardView.swift`: input, generation, edit, and activation flow.
- `Sources/PersonalLearningJournal/Views/CoursePlanDetailView.swift`: active plan, phases, progress, and revision history.
- `Sources/PersonalLearningJournal/Views/ProjectsView.swift`: Plan section and entry actions.
- `Sources/PersonalLearningJournal/Views/TodayView.swift`: due/overdue planned sessions.
- `SelfStudyStudio.xcodeproj/project.pbxproj`: source registration.
- `Tests/PersonalLearningJournalTests/*Tests.swift`: domain, validation, AI, service, repository, mapper, export, and view-model coverage.

### Task 1: Add Course Plan Domain and Backward-Compatible Export

**Files:**
- Create: `Sources/PersonalLearningJournal/Planning/CoursePlanningDomain.swift`
- Modify: `Sources/PersonalLearningJournal/Domain.swift`
- Modify: `Sources/PersonalLearningJournal/JournalStore.swift`
- Modify: `Sources/PersonalLearningJournal/ExportService.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningDomainTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `CoursePlan`, `PlanPhase`, `PlannedSession`, `CoursePlanningInput`, `CoursePlanDraft`, and planning arrays in `JournalSnapshot`/`JournalExport`.

- [ ] **Step 1: Write model validation and legacy snapshot tests**

```swift
func testCoursePlanRequiresPositiveWeeklyBudget() throws {
    XCTAssertThrowsError(try CoursePlan(
        projectId: UUID(), revision: 1, status: .draft,
        courseURL: nil, courseTitle: "CS336", courseOutline: "",
        goal: "Implement a language model", expectedOutcome: "Working notebook",
        startsOn: Date(), deadline: nil, weeklyBudgetMinutes: 0, summary: ""
    )) { error in
        XCTAssertEqual(error as? CoursePlanningValidationError, .invalidWeeklyBudget)
    }
}

func testLegacySnapshotDecodesWithEmptyPlanningCollections() throws {
    let data = Data(#"{"projects":[],"sessions":[],"proofs":[],"reviews":[],"trailEvents":[]}"#.utf8)
    let snapshot = try JSONDecoder.journal.decode(JournalSnapshot.self, from: data)
    XCTAssertTrue(snapshot.coursePlans.isEmpty)
    XCTAssertTrue(snapshot.planPhases.isEmpty)
    XCTAssertTrue(snapshot.plannedSessions.isEmpty)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CoursePlanningDomainTests`

Expected: compile failure because planning domain types do not exist.

- [ ] **Step 3: Add exact planning status and value types**

```swift
public enum CoursePlanStatus: String, Codable, CaseIterable, Sendable {
    case draft, active, archived, completed
}

public enum PlannedSessionStatus: String, Codable, CaseIterable, Sendable {
    case unscheduled, scheduled, completed, skipped, cancelled
}

public enum CoursePlanningValidationError: Error, Equatable, Sendable {
    case emptyTitle
    case emptyGoal
    case invalidWeeklyBudget
    case invalidDateRange
    case unknownPhaseReference(String)
    case invalidDuration
    case duplicateDraftID(String)
    case phaseOutsidePlan(String)
}

public struct CoursePlan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var revision: Int
    public var status: CoursePlanStatus
    public var courseURL: URL?
    public var courseTitle: String
    public var courseOutline: String
    public var goal: String
    public var expectedOutcome: String
    public var startsOn: Date
    public var deadline: Date?
    public var weeklyBudgetMinutes: Int
    public var summary: String
    public var createdAt: Date
    public var updatedAt: Date
    public var activatedAt: Date?
    public var deletedAt: Date?
    public var schemaVersion: Int
}
```

Define `PlanPhase` and `PlannedSession` with the exact fields from the approved
design. Initializers reject empty titles/objectives, nonpositive revisions,
nonpositive durations, reversed date ranges, and project/plan mismatches.

Add this backward-compatible project link:

```swift
// Project
public var activeCoursePlanId: UUID?

// Project.init(from:)
activeCoursePlanId = try container.decodeIfPresent(UUID.self, forKey: .activeCoursePlanId)
```

- [ ] **Step 4: Define draft and input types**

```swift
public struct CoursePlanningInput: Codable, Equatable, Sendable {
    public var projectId: UUID
    public var courseURL: URL?
    public var courseTitle: String
    public var courseOutline: String
    public var goal: String
    public var expectedOutcome: String
    public var startsOn: Date
    public var deadline: Date?
    public var weeklyBudgetMinutes: Int
    public var preferredSessionMinutes: Int
    public var availableMinutesByWeekday: [Int: Int]
}

public struct CoursePlanDraft: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var phases: [CoursePlanDraftPhase]
    public var sessions: [CoursePlanDraftSession]
    public var assumptions: [String]
    public var warnings: [String]
}

public struct CoursePlanDraftPhase: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var objective: String
    public var expectedProof: String
    public var ordinal: Int
    public var targetStart: Date
    public var targetEnd: Date
}

public struct CoursePlanDraftSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var phaseID: String
    public var title: String
    public var actionType: ActionType
    public var expectedProof: String?
    public var durationMinutes: Int
    public var deadline: Date?
}
```

- [ ] **Step 5: Extend snapshot and export with decode defaults**

Add `coursePlans`, `planPhases`, and `plannedSessions` to `JournalSnapshot` and
`JournalExport`. Legacy decoding uses empty arrays. Increment export version to
`v0.2`; continue excluding sync metadata and local-only values.

- [ ] **Step 6: Run tests and build**

Run: `swift test --filter CoursePlanningDomainTests && swift test --filter ExportServiceTests && swift build`

Expected: selected tests pass and package builds.

- [ ] **Step 7: Commit**

```bash
git add Sources/PersonalLearningJournal/Planning/CoursePlanningDomain.swift Sources/PersonalLearningJournal/Domain.swift Sources/PersonalLearningJournal/JournalStore.swift Sources/PersonalLearningJournal/ExportService.swift Tests/PersonalLearningJournalTests/CoursePlanningDomainTests.swift Tests/PersonalLearningJournalTests/ExportServiceTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: add course planning domain"
```

### Task 2: Persist and Synchronize Planning Entities

**Files:**
- Modify: `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/SyncMergeService.swift`
- Test: `Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift`
- Test: `Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift`

**Interfaces:**
- Consumes: planning domain types and cloud repository foundation.
- Produces: `.coursePlan`, `.planPhase`, and `.plannedSession` entity kinds and CloudKit records.

- [ ] **Step 1: Add repository round-trip tests**

```swift
func testRepositoryRoundTripsPlanningGraph() throws {
    try repository.commit(JournalTransaction(
        upserts: [.coursePlan(plan), .planPhase(phase), .plannedSession(plannedSession)],
        origin: .user
    ))
    let snapshot = try repository.snapshot()
    XCTAssertEqual(snapshot.coursePlans, [plan])
    XCTAssertEqual(snapshot.planPhases, [phase])
    XCTAssertEqual(snapshot.plannedSessions, [plannedSession])
    XCTAssertEqual(try repository.pendingMutations(limit: 10).count, 3)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter SwiftDataJournalRepositoryTests/testRepositoryRoundTripsPlanningGraph`

Expected: compile failure because planning entity cases do not exist.

- [ ] **Step 3: Add planning entity cases and SwiftData records**

Extend `JournalEntityKind`, `JournalEntity`, entity reference helpers, repository
upsert/fetch/delete, and model container registration. Relationships remain UUID
strings in persistence records, not SwiftData object relationships, matching the
existing value-type domain boundary.

- [ ] **Step 4: Add CloudKit mapping and merge rules**

Use record types `CoursePlan`, `PlanPhase`, and `PlannedSession`; UUID strings are
record names and relationship fields. Three-way merge all mutable fields and
create `SyncConflict` for same-field divergence. Completed-session references are
never cleared automatically.

- [ ] **Step 5: Run persistence, mapper, merge, and sync tests**

Run: `swift test --filter SwiftDataJournalRepositoryTests && swift test --filter CloudRecordMapperTests && swift test --filter SyncMergeServiceTests && swift test --filter CloudSyncCoordinatorTests`

Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Persistence Sources/PersonalLearningJournal/Sync Tests/PersonalLearningJournalTests
git commit -m "feat: persist and sync course plans"
```

### Task 3: Implement Manual Plan Validation and Activation

**Files:**
- Create: `Sources/PersonalLearningJournal/Planning/CoursePlanValidator.swift`
- Create: `Sources/PersonalLearningJournal/Planning/CoursePlanningService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalService.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanValidatorTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningServiceTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CoursePlanningInput`, editable `CoursePlanDraft`, and `JournalRepository`.
- Produces: `CoursePlanValidationResult`, `CoursePlanningService.saveDraft(input:draft:)`, `activate(draftPlanID:)`, `revise(planID:input:draft:)`, `unschedule(plannedSessionID:)`, and `complete(plannedSessionID:with:)`.

- [ ] **Step 1: Write validator and confirmation-boundary tests**

```swift
func testDraftRejectsUnknownPhaseReference() {
    let result = validator.validate(draftWithUnknownPhase, input: input)
    XCTAssertEqual(result.errors, [.unknownPhaseReference("missing-phase")])
}

func testSavingDraftPersistsItWithoutActivatingProject() throws {
    let draftPlan = try service.saveDraft(input: input, draft: validDraft)
    XCTAssertEqual(draftPlan.status, .draft)
    XCTAssertNil(try repository.snapshot().projects.first?.activeCoursePlanId)
    XCTAssertEqual(try repository.snapshot().coursePlans.map(\.id), [draftPlan.id])
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CoursePlanValidatorTests && swift test --filter CoursePlanningServiceTests`

Expected: compile failure because validator and service do not exist.

- [ ] **Step 3: Implement deterministic validation**

```swift
public struct CoursePlanValidationResult: Equatable, Sendable {
    public var errors: [CoursePlanValidationError]
    public var warnings: [String]
    public var isValid: Bool { errors.isEmpty }
}

public struct CoursePlanValidator {
    public func validate(_ draft: CoursePlanDraft, input: CoursePlanningInput) -> CoursePlanValidationResult
}
```

Reject empty phases, unknown phase references, nonpositive duration, reversed
dates, phase ranges outside the plan, and duplicate draft IDs. Add a warning when
the requested weekly minutes exceed the supplied available minutes.

- [ ] **Step 4: Implement atomic activation**

```swift
public final class CoursePlanningService {
    public func saveDraft(input: CoursePlanningInput, draft: CoursePlanDraft) throws -> CoursePlan
    public func activate(draftPlanID: UUID) throws -> CoursePlan
    public func revise(planID: UUID, input: CoursePlanningInput, draft: CoursePlanDraft) throws -> CoursePlan
    public func unschedule(plannedSessionID: UUID) throws
    public func complete(plannedSessionID: UUID, with sessionID: UUID) throws
}
```

`saveDraft` commits a `.draft` Plan plus its Phases and unscheduled
PlannedSessions but does not alter the Project. Activation changes that persisted
draft to `.active`, updates Project `activeCoursePlanId`, sets Project Next Step
from the first planned session, archives the previously active revision, and adds
one `planActivated` TrailEvent in one repository transaction. Revision creates a
new persisted draft, preserves completed sessions, and records `planRevised` only
when the new draft is activated.

- [ ] **Step 5: Link completed LearningSessions**

Extend Quick Log and Timer save methods with optional `plannedSessionId`. When
present, mark the planned session completed and set its `completedSessionId` in
the same transaction as the LearningSession and TrailEvent.

- [ ] **Step 6: Run service and regression tests**

Run: `swift test --filter CoursePlanValidatorTests && swift test --filter CoursePlanningServiceTests && swift test --filter JournalServiceTests && swift test`

Expected: planning tests and all existing tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/PersonalLearningJournal/Planning Sources/PersonalLearningJournal/JournalService.swift Tests/PersonalLearningJournalTests SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: activate editable course plans"
```

### Task 4: Extract a Reusable Structured AI Client

**Files:**
- Create: `Sources/PersonalLearningJournal/AI/StructuredAIClient.swift`
- Modify: `Sources/PersonalLearningJournal/AIReviewSettings.swift`
- Modify: `Sources/PersonalLearningJournal/ReviewService.swift`
- Test: `Tests/PersonalLearningJournalTests/StructuredAIClientTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ReviewServiceTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: existing `AIReviewSettings`, `APIKeyStore`, and HTTP transport.
- Produces: `AIHTTPTransport`, `OpenAICompatibleStructuredClient.completeJSON(system:user:)`, with review behavior preserved.

- [ ] **Step 1: Write generic JSON and review-regression tests**

```swift
func testStructuredClientReturnsDecodedJSONContent() async throws {
    let client = OpenAICompatibleStructuredClient(settings: settings, apiKey: "key", transport: transport)
    let result: StubResult = try await client.completeJSON(system: "system", user: "user")
    XCTAssertEqual(result, StubResult(value: "ok"))
}
```

Retain the existing `testOpenAICompatibleProviderParsesJSONContentFromChatCompletion` unchanged.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter StructuredAIClientTests`

Expected: compile failure because the reusable client does not exist.

- [ ] **Step 3: Implement the generic client**

```swift
public protocol AIHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct OpenAICompatibleStructuredClient: Sendable {
    public func completeJSON<Response: Decodable & Sendable>(
        system: String,
        user: String,
        as type: Response.Type = Response.self
    ) async throws -> Response
}
```

Move request construction, authorization, status validation, Chat Completions
envelope decoding, and nested JSON content decoding into this client. Keep
`ReviewHTTPTransport` as a deprecated typealias for one release so existing tests
and callers migrate without a flag day.

- [ ] **Step 4: Refactor review provider to use the generic client**

`OpenAICompatibleReviewProvider.makeReview` builds only prompts and maps the
decoded review response into `ReviewDraft`. No weekly-review behavior or fallback
copy changes.

- [ ] **Step 5: Run AI and full tests**

Run: `swift test --filter StructuredAIClientTests && swift test --filter ReviewServiceTests && swift test`

Expected: generic client and all review tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/AI/StructuredAIClient.swift Sources/PersonalLearningJournal/AIReviewSettings.swift Sources/PersonalLearningJournal/ReviewService.swift Tests/PersonalLearningJournalTests/StructuredAIClientTests.swift Tests/PersonalLearningJournalTests/ReviewServiceTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "refactor: share structured ai transport"
```

### Task 5: Generate and Validate Course Plan Drafts with AI

**Files:**
- Create: `Sources/PersonalLearningJournal/Planning/CoursePlanningProvider.swift`
- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanningService.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningProviderTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningServiceTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `OpenAICompatibleStructuredClient`, input, aggregate availability, and optional Session/Proof summaries.
- Produces: `CoursePlanningProvider.makeDraft(input:context:)` and validated draft generation.

- [ ] **Step 1: Write privacy and decoding tests**

```swift
func testPlanningRequestContainsUserOutlineButNoCalendarEventContent() async throws {
    _ = try await provider.makeDraft(input: input, context: context)
    let body = try XCTUnwrap(transport.lastRequestBodyString)
    XCTAssertTrue(body.contains("Lecture 1: tokenization"))
    XCTAssertTrue(body.contains("availableMinutesByWeekday"))
    XCTAssertFalse(body.contains("Dentist appointment"))
    XCTAssertFalse(body.contains("calendarEvent"))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter CoursePlanningProviderTests`

Expected: compile failure because course planning provider does not exist.

- [ ] **Step 3: Define provider boundary and response schema**

```swift
public enum CoursePlanningError: Error, Equatable, Sendable {
    case configurationRequired
    case invalidDraft([CoursePlanningValidationError])
    case providerUnavailable
}

public protocol CoursePlanningProvider: Sendable {
    func makeDraft(
        input: CoursePlanningInput,
        context: CoursePlanningContext
    ) async throws -> CoursePlanDraft
}

public struct CoursePlanningContext: Codable, Equatable, Sendable {
    public var currentNextStep: String
    public var recentSessionSummaries: [String]
    public var recentProofSummaries: [String]
}
```

The system prompt demands JSON with title, summary, phases, sessions,
assumptions, and warnings. It explicitly forbids invented course-page content and
requires assumptions when the pasted outline is incomplete.

- [ ] **Step 4: Validate before returning a draft**

Decode into private response DTOs, map stable draft IDs locally, run
`CoursePlanValidator`, and throw `CoursePlanningError.invalidDraft(errors)` when
hard validation fails. Return budget warnings for UI display.

- [ ] **Step 5: Add adaptive provider behavior**

Add this exact service API:

```swift
public func generateDraft(
    input: CoursePlanningInput,
    context: CoursePlanningContext
) async throws -> CoursePlan
```

It asks the provider for `CoursePlanDraft`, validates it, then persists it through
`saveDraft`. When AI settings/key are absent it throws
`.configurationRequired` without changing stored data. Network/provider failure
preserves the user's input and previously persisted draft.

- [ ] **Step 6: Run planning and review regression tests**

Run: `swift test --filter CoursePlanningProviderTests && swift test --filter CoursePlanningServiceTests && swift test --filter ReviewServiceTests`

Expected: all selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/PersonalLearningJournal/Planning/CoursePlanningProvider.swift Sources/PersonalLearningJournal/Planning/CoursePlanningService.swift Tests/PersonalLearningJournalTests/CoursePlanningProviderTests.swift Tests/PersonalLearningJournalTests/CoursePlanningServiceTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: generate course plan drafts with ai"
```

### Task 6: Build Plan Wizard and Project Plan Detail

**Files:**
- Create: `Sources/PersonalLearningJournal/Views/CoursePlanWizardView.swift`
- Create: `Sources/PersonalLearningJournal/Views/CoursePlanDetailView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`
- Modify: `SelfStudyStudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: course planning service and repository-observed planning collections.
- Produces: manual/AI wizard, editable draft, activation confirmation, plan detail, and revision history.

- [ ] **Step 1: Write view-model confirmation tests**

```swift
func testGeneratedPlanRemainsDraftUntilActivateIsCalled() async throws {
    let draftPlan = try await viewModel.generateCoursePlan(input)
    XCTAssertEqual(viewModel.draftCoursePlan?.id, draftPlan.id)
    XCTAssertNil(viewModel.activeCoursePlan(for: project.id))

    try viewModel.activateCoursePlan(draftPlanID: draftPlan.id)
    XCTAssertNotNil(viewModel.activeCoursePlan(for: project.id))
}
```

- [ ] **Step 2: Run test and verify RED**

Run: `swift test --filter JournalViewModelTests/testGeneratedPlanRemainsDraftUntilActivateIsCalled`

Expected: compile failure because planning view-model APIs do not exist.

- [ ] **Step 3: Add observable planning state**

Expose project plans, phases, planned sessions, generation state, validation
errors, current draft, `generateCoursePlan`, `saveManualDraft`,
`activateCoursePlan(draftPlanID:)`, and `reviseCoursePlan`. Refresh from repository only after
confirmed activation/revision.

Use these exact mutation signatures:

```swift
public func generateCoursePlan(_ input: CoursePlanningInput) async throws -> CoursePlan
public func saveManualDraft(input: CoursePlanningInput, draft: CoursePlanDraft) throws -> CoursePlan
public func activateCoursePlan(draftPlanID: UUID) throws
```

- [ ] **Step 4: Build the four-step wizard**

Step 1 captures URL/title/outline/goal/deadline. Step 2 captures weekly budget
and preferred session length. Step 3 generates or manually creates an editable
draft with phase/session add, edit, reorder, and delete controls. Step 4 shows
assumptions, warnings, exact entities to create, and an Activate Plan button.
Closing the wizard preserves input and the last valid draft for the project.

- [ ] **Step 5: Build plan detail**

Show active revision, phase targets, expected Proof, session counts, completed
links, unscheduled work, archived revisions, and Revise Plan. Do not include
People, share, or member controls.

- [ ] **Step 6: Run tests and simulator build**

Run: `swift test --filter JournalViewModelTests && swift test && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: tests pass and app builds.

- [ ] **Step 7: Commit**

```bash
git add Sources/PersonalLearningJournal/Views/CoursePlanWizardView.swift Sources/PersonalLearningJournal/Views/CoursePlanDetailView.swift Sources/PersonalLearningJournal/Views/ProjectsView.swift Sources/PersonalLearningJournal/JournalViewModel.swift Tests/PersonalLearningJournalTests/JournalViewModelTests.swift SelfStudyStudio.xcodeproj/project.pbxproj
git commit -m "feat: add editable course planning flow"
```

### Task 7: Integrate Planned Work into Today and Learning Completion

**Files:**
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/QuickLogView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TimerSessionView.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Modify: `Sources/PersonalLearningJournal/ReviewService.swift`
- Modify: `README.md`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ReviewServiceTests.swift`
- Create: `Tests/PersonalLearningJournalTests/CoursePlanningEndToEndTests.swift`

**Interfaces:**
- Consumes: active plans and planned sessions.
- Produces: due/overdue Today sections and planned-to-actual completion loop.

- [ ] **Step 1: Write end-to-end completion test**

```swift
func testActivatePlanStartPlannedSessionAndRecordProofCompletesTheLoop() throws {
    let draftPlan = try planningService.saveDraft(input: input, draft: draft)
    let plan = try planningService.activate(draftPlanID: draftPlan.id)
    let planned = try XCTUnwrap(repository.snapshot().plannedSessions.first)
    let session = try journalService.quickLog(
        projectId: project.id,
        plannedSessionId: planned.id,
        durationMinutes: planned.durationMinutes,
        note: "Completed the tokenizer exercise"
    )
    _ = try journalService.addProof(
        projectId: project.id,
        sessionId: session.id,
        type: .link,
        title: "Tokenizer notebook",
        statement: "The tokenizer passes the course examples"
    )

    XCTAssertEqual(repository.snapshot().plannedSessions.first?.status, .completed)
    XCTAssertEqual(repository.snapshot().plannedSessions.first?.completedSessionId, session.id)
}

func testWeeklyReviewIncludesActivePlanProgressAsSources() async throws {
    let review = try await reviewService.createWeeklyReview(
        periodStart: weekStart,
        periodEnd: weekEnd
    )
    XCTAssertTrue(review.aiSourceSummary.contains { $0.contains("plan") })
    XCTAssertTrue(review.aiSourceSummary.contains { $0.contains("completed 1 of 3") })
}
```

- [ ] **Step 2: Run test and verify RED**

Run: `swift test --filter CoursePlanningEndToEndTests`

Expected: failure until Today and recording flows accept planned-session context.

- [ ] **Step 3: Add Today plan sections**

Show today's concrete sessions first, then overdue sessions, then existing
Continue cards. Each planned row shows project, phase, title, expected Proof,
duration, Start, Quick Log, Skip, and Make Unscheduled actions. Make Unscheduled
calls `CoursePlanningService.unschedule(plannedSessionID:)`; the calendar plan
later adds timed rescheduling. Unscheduled work appears as a count linking to
Plan detail.

- [ ] **Step 4: Carry planned session context through recording**

Quick Log and Timer receive optional `PlannedSession`; successful save invokes
the atomic completion path. Proof entry after save remains unchanged and links to
the actual LearningSession.

- [ ] **Step 5: Add plan progress to weekly Review context**

Include active plan revision, current phase, completed/scheduled/skipped counts,
missed deadlines, and expected Proof in rule-based and AI review inputs. Source
references use plan/phase/session UUID prefixes and never include Calendar event
content. Review recommendations still require explicit application.

- [ ] **Step 6: Run full verification**

Run: `swift test --filter CoursePlanningEndToEndTests && swift test --filter ReviewServiceTests && swift test && swift build && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: all tests pass and app target builds.

- [ ] **Step 7: Document course planning behavior**

Update README with manual planning, AI configuration, draft/activation boundary,
planned-to-actual completion, privacy exclusions, and the fact that Calendar
scheduling is delivered by the next plan.

- [ ] **Step 8: Commit**

```bash
git add Sources/PersonalLearningJournal/Views Sources/PersonalLearningJournal/JournalViewModel.swift Sources/PersonalLearningJournal/ReviewService.swift README.md Tests/PersonalLearningJournalTests
git commit -m "feat: connect plans to daily learning"
```
