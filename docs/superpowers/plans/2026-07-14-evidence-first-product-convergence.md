# Evidence-First Product Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Converge the existing Self Study Studio app on the approved evidence-first Project → Session → Proof → Review → Decision model without losing existing user data or weakening offline, sync, Calendar, planning, and media behavior.

**Architecture:** Add small domain modules for commitments, evidence, review decisions, health, migration, and archive behavior. Persist every syncable semantic type through the existing `JournalEntity` + SwiftData JSON-payload record pattern, then expose behavior through `JournalService` and focused projection services instead of growing `JournalViewModel` with domain logic. External services remain downstream of local repository commits.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit, EventKit, CryptoKit, LocalAuthentication, XCTest via Swift Testing, iOS 17+, macOS 14+ package tests.

## Global Constraints

- Platform is iPhone-first on iOS 17+; iPad-specific, macOS product, Web, and Android surfaces are out of scope.
- Core navigation is Today, Projects, Library; Calendar is a primary tab only after scheduling is enabled.
- A committed Project has exactly one canonical Next Step and one active Evidence Contract.
- A Proof is an inspectable artifact plus a separate non-empty proof statement.
- Session capture remains local and does not require Proof.
- AI, Calendar, iCloud, notifications, and network failures may not block local Project, Session, Proof, Contract, Review, or lifecycle mutations.
- AI is BYOK, device-to-provider, explicitly invoked, and draft-only.
- Private iCloud sync starts automatically when an Apple Account is available; secrets and device-bound data never sync.
- Trash retains synchronized deletions for 30 days unless immediate permanent deletion is explicitly confirmed.
- Simplified Chinese and English localization follow system language; user content is never translated automatically.
- Dedicated accessibility verification is not a first-validation release gate; standard SwiftUI controls and semantics remain preferred.
- Preserve unrelated working-tree changes, including the existing `.gitignore` and `diagrams/` changes.

---

## File Structure

New focused files:

- `Sources/PersonalLearningJournal/Projects/ProjectCommitment.swift`: lifecycle activation, attention budget, canonical-step rules.
- `Sources/PersonalLearningJournal/Contracts/EvidenceContract.swift`: contract cadence, periods, criteria, acceptance and resolution.
- `Sources/PersonalLearningJournal/Evidence/ProofEvidence.swift`: artifact qualification, link metadata, integrity state.
- `Sources/PersonalLearningJournal/Evidence/ProofRevision.swift`: immutable referenced-Proof snapshots and revisions.
- `Sources/PersonalLearningJournal/Reviews/ReviewDecision.swift`: explicit review decisions and completion rules.
- `Sources/PersonalLearningJournal/ProductHealth/ProductHealthService.swift`: deterministic local health report.
- `Sources/PersonalLearningJournal/Recommendations/TodayRecommendationService.swift`: deterministic one-primary/two-alternative ranking.
- `Sources/PersonalLearningJournal/Migration/ProductConvergenceMigration.swift`: dry run, ambiguity issues, execution and validation.
- `Sources/PersonalLearningJournal/Archive/JournalArchiveService.swift`: manifest, checksums, round-trip restore and encrypted envelope.
- `Sources/PersonalLearningJournal/Security/AppLockController.swift`: optional LocalAuthentication gate and background privacy state.
- `Sources/PersonalLearningJournal/Search/ProofSearchIndex.swift`: local-only Proof search projection.
- `Sources/PersonalLearningJournal/Notifications/LearningNotificationPolicy.swift`: generic notification content and category policy.
- `Sources/PersonalLearningJournal/Views/ProjectCommitmentView.swift`: idea activation and Contract editing.
- `Sources/PersonalLearningJournal/Views/MigrationReviewView.swift`: explicit migration ambiguity resolution.
- `Sources/PersonalLearningJournal/Views/ProductHealthView.swift`: local health facts.
- `Sources/PersonalLearningJournal/Views/TrashView.swift`: restore and permanent-delete confirmation.
- `Sources/PersonalLearningJournal/Resources/en.lproj/Localizable.strings`: English core-loop strings.
- `Sources/PersonalLearningJournal/Resources/zh-Hans.lproj/Localizable.strings`: Simplified Chinese core-loop strings.

Existing files retain their current responsibilities and receive integration changes only.

---

### Task 1: Add commitment, contract, evidence, and decision domain types

**Files:**
- Create: `Sources/PersonalLearningJournal/Projects/ProjectCommitment.swift`
- Create: `Sources/PersonalLearningJournal/Contracts/EvidenceContract.swift`
- Create: `Sources/PersonalLearningJournal/Evidence/ProofEvidence.swift`
- Create: `Sources/PersonalLearningJournal/Evidence/ProofRevision.swift`
- Create: `Sources/PersonalLearningJournal/Reviews/ReviewDecision.swift`
- Modify: `Sources/PersonalLearningJournal/Domain.swift`
- Test: `Tests/PersonalLearningJournalTests/EvidenceFirstDomainTests.swift`

**Interfaces:**
- Produces: `ProjectCommitmentState`, `EvidenceContract`, `EvidenceContractTrigger`, `EvidenceAcceptance`, `ProofArtifact`, `ProofIntegrity`, `ProofRevision`, `ReviewDecision`, `ReviewDecisionKind`.
- Changes: `Project.status` uses the expanded lifecycle values; `Project.commitmentState` distinguishes `ready` and transitional `needsSetup`; `Proof` contains artifact/integrity/revision fields; `Review` contains explicit decisions and referenced snapshots.

- [ ] **Step 1: Write failing lifecycle and activation tests**

```swift
@Test func ideaDoesNotRequireCommitmentFields() {
    let project = Project(name: "Shaders", area: "Graphics", goal: "", status: .idea, currentNextStep: "")
    #expect(project.activationIssues(contract: nil) == [.missingGoal, .missingNextStep, .missingContract])
    #expect(project.countsTowardAttentionBudget == false)
}

@Test func activeProjectRequiresAValidContract() throws {
    let contract = try EvidenceContract.weekly(
        projectId: UUID(),
        expectedArtifact: .text,
        acceptanceCriteria: "Explains the technique with a runnable example",
        startsAt: Date(timeIntervalSince1970: 0)
    )
    #expect(contract.acceptanceCriteria == "Explains the technique with a runnable example")
}
```

- [ ] **Step 2: Run tests and confirm RED**

Run: `swift test --filter EvidenceFirstDomainTests`  
Expected: compilation fails because evidence-first domain types do not exist.

- [ ] **Step 3: Implement the focused domain types and backward-compatible decoding**

```swift
public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case idea, active
    case lowFrequency = "low-frequency"
    case paused, archived, completed, trash
}

public enum ProjectCommitmentState: String, Codable, Sendable {
    case ready
    case needsSetup
}

public enum EvidenceContractTrigger: Codable, Equatable, Sendable {
    case interval(days: Int)
    case milestone(String)
}

public struct EvidenceContract: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var trigger: EvidenceContractTrigger
    public var expectedArtifact: ProofType
    public var acceptanceCriteria: String
    public var startsAt: Date
    public var endedAt: Date?
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public static func weekly(
        projectId: UUID,
        expectedArtifact: ProofType,
        acceptanceCriteria: String,
        startsAt: Date
    ) throws -> EvidenceContract {
        try EvidenceContract(
            projectId: projectId,
            trigger: .interval(days: 7),
            expectedArtifact: expectedArtifact,
            acceptanceCriteria: acceptanceCriteria,
            startsAt: startsAt
        ).validated()
    }
}

public enum ProofIntegrity: String, Codable, Sendable {
    case qualifying
    case needsEvidence
    case changedLink
    case brokenLink
}

public enum ProofArtifact: Codable, Equatable, Sendable {
    case attachment(localPath: String, mimeType: String?, fileSize: Int?)
    case link(url: URL, title: String?, site: String?, retrievedAt: Date?, fingerprint: String?, snapshotPath: String?)
    case text(markdown: String)
}

public struct EvidenceAcceptance: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var contractId: UUID
    public var proofId: UUID
    public var acceptedCriteria: [String]
    public var acceptedAt: Date
    public var deletedAt: Date?
}

public struct ProofRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var proofId: UUID
    public var revision: Int
    public var title: String
    public var statement: String
    public var artifactChecksum: String
    public var createdAt: Date
    public var deletedAt: Date?
}

public enum ReviewDecisionKind: String, Codable, Sendable {
    case continueUnchanged, changeNextStep, reviseContract, changeFrequency
    case pause, archive, complete
}

public struct ReviewDecision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var reviewId: UUID
    public var projectId: UUID
    public var kind: ReviewDecisionKind
    public var nextStep: String?
    public var contractId: UUID?
    public var capstoneProofId: UUID?
    public var decidedAt: Date
    public var deletedAt: Date?
}
```

`Project` decoding defaults old active/low-frequency projects to `.needsSetup`; newly created ideas default to `.ready`. `Proof` decoding maps existing attachment-backed records to a qualifying artifact and statement-only records to `.needsEvidence` without inventing content.

- [ ] **Step 4: Add validation tests for Text Proof, Link Proof, revision snapshots, and completed Projects**

```swift
@Test func statementOnlyProofNeedsEvidence() throws {
    let proof = try Proof(projectId: UUID(), type: .image, title: "Old", statement: "Understood")
    #expect(proof.integrity == .needsEvidence)
    #expect(proof.qualifies == false)
}

@Test func textProofSeparatesArtifactAndClaim() throws {
    let proof = try Proof.text(projectId: UUID(), title: "Derivation", artifactBody: "# Result\n42", statement: "I can derive the result")
    #expect(proof.qualifies)
    #expect(proof.artifactBody == "# Result\n42")
}
```

- [ ] **Step 5: Run focused and full domain tests**

Run: `swift test --filter EvidenceFirstDomainTests`  
Expected: all new tests pass.  
Run: `swift test --filter DomainTests`  
Expected: existing domain tests pass after compatibility updates.

- [ ] **Step 6: Commit**

```bash
git add Sources/PersonalLearningJournal/Projects Sources/PersonalLearningJournal/Contracts Sources/PersonalLearningJournal/Evidence Sources/PersonalLearningJournal/Reviews Sources/PersonalLearningJournal/Domain.swift Tests/PersonalLearningJournalTests/EvidenceFirstDomainTests.swift Tests/PersonalLearningJournalTests/DomainTests.swift
git commit -m "feat: add evidence-first domain model"
```

---

### Task 2: Persist and synchronize new semantic entities

**Files:**
- Modify: `Sources/PersonalLearningJournal/JournalStore.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/SyncMergeService.swift`
- Test: `Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift`
- Test: `Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 domain types.
- Produces: `JournalSnapshot.evidenceContracts`, `.evidenceAcceptances`, `.proofRevisions`, `.reviewDecisions`; matching `JournalEntityKind` and `JournalEntity` cases.

- [ ] **Step 1: Write failing repository round-trip tests**

```swift
@Test func repositoryRoundTripsEvidenceFirstEntities() throws {
    let repository = try SwiftDataJournalRepository.inMemory()
    try repository.commit(.init(upserts: [.evidenceContract(contract), .reviewDecision(decision)], origin: .user))
    let snapshot = try repository.snapshot()
    #expect(snapshot.evidenceContracts == [contract])
    #expect(snapshot.reviewDecisions == [decision])
}
```

- [ ] **Step 2: Run focused repository test and confirm RED**

Run: `swift test --filter SwiftDataJournalRepositoryTests.repositoryRoundTripsEvidenceFirstEntities`  
Expected: compilation fails on missing entity cases.

- [ ] **Step 3: Add snapshot/entity cases and generic SwiftData payload records**

Add one `StoredEntityV2` model per new syncable type to `makeContainer`, `snapshot`, `upsert`, `entity(for:)`, and deletion switches. All new arrays decode with `decodeIfPresent(... ) ?? []` so old JSON exports remain readable.

```swift
case evidenceContract(EvidenceContract)
case evidenceAcceptance(EvidenceAcceptance)
case proofRevision(ProofRevision)
case reviewDecision(ReviewDecision)
```

- [ ] **Step 4: Add CloudKit mapping tests and implementation**

Each new record uses its UUID as the stable record name and JSON-compatible scalar fields. `ProofRevision` stores checksums and snapshots, not device paths. Add round-trip tests for all new record types.

- [ ] **Step 5: Preserve both sides of commitment conflicts**

Write tests proving conflicts on Project Goal/Next Step/status, active Contract, and plan revision produce `SyncConflict`, while independent append-only acceptances/decisions merge.

- [ ] **Step 6: Run persistence and sync suites**

Run: `swift test --filter SwiftDataJournalRepositoryTests`  
Run: `swift test --filter CloudRecordMapperTests`  
Run: `swift test --filter SyncMergeServiceTests`  
Expected: all selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/PersonalLearningJournal/JournalStore.swift Sources/PersonalLearningJournal/Persistence Sources/PersonalLearningJournal/Sync Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift
git commit -m "feat: persist evidence-first records"
```

---

### Task 3: Enforce activation, canonical Next Step, Proof, and Review decisions in services

**Files:**
- Modify: `Sources/PersonalLearningJournal/JournalService.swift`
- Modify: `Sources/PersonalLearningJournal/ReviewService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ReviewServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`

**Interfaces:**
- Produces: `createIdea`, `activateProject`, `reviseContract`, `acceptProof`, `completeReview`, `completeProject`, `moveToTrash`, `restoreFromTrash`.

- [ ] **Step 1: Write failing service behavior tests**

```swift
@Test func activatingIdeaRequiresGoalNextStepAndContract() throws {
    let project = try service.createIdea(name: "Guitar", area: "Music")
    #expect(throws: JournalValidationError.missingEvidenceContract) {
        try service.activateProject(projectId: project.id, goal: "Play one song", nextStep: "Practice verse", contract: nil)
    }
}

@Test func reviewCannotCompleteWithoutExplicitDecision() throws {
    #expect(throws: JournalValidationError.missingReviewDecision) {
        try service.completeReview(reviewId: review.id, decision: nil)
    }
}

@Test func fourthActiveProjectRequiresExplicitBudgetOverride() throws {
    #expect(throws: JournalValidationError.attentionBudgetExceeded) {
        try service.activateProject(projectId: fourth.id, goal: "Goal", nextStep: "Next", contract: contract, allowAttentionBudgetOverride: false)
    }
}

@Test func twoUnresolvedContractPeriodsRequireDecision() {
    let state = service.contractState(projectId: project.id, referenceDate: endOfSecondPeriod)
    #expect(state == .decisionRequired(unresolvedPeriods: 2))
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --filter JournalServiceTests`  
Expected: new tests fail because APIs and validation cases do not exist.

- [ ] **Step 3: Implement transactional service mutations**

Every method constructs a new snapshot, validates it, commits all changed entities in one `JournalTransaction`, then publishes state. `activateProject` upserts Project and Contract together. `acceptProof` creates `EvidenceAcceptance` and a `ProofRevision` snapshot. `completeProject` requires a `.complete` decision referencing a qualifying Capstone Proof.

- [ ] **Step 4: Remove first-record onboarding gate**

`createOnboardingProjects` is replaced by idea creation plus activation. `shouldShowMainTabs` becomes true after any non-trash Project exists. Existing `pendingFirstRecordProjectId` remains decode-compatible but is cleared by convergence migration and no longer blocks navigation.

- [ ] **Step 5: Make review generation sourced but decision-free**

Rule-based and AI providers return facts/patterns/recommendations only. Persisted `ReviewDecision` is created solely from explicit user confirmation. Existing string `decisions` remain decode-compatible and are migrated as source text, not confirmed decisions.

- [ ] **Step 6: Run service/view-model tests**

Run: `swift test --filter JournalServiceTests`  
Run: `swift test --filter ReviewServiceTests`  
Run: `swift test --filter JournalViewModelTests`  
Expected: all selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/PersonalLearningJournal/JournalService.swift Sources/PersonalLearningJournal/ReviewService.swift Sources/PersonalLearningJournal/JournalViewModel.swift Tests/PersonalLearningJournalTests/JournalServiceTests.swift Tests/PersonalLearningJournalTests/ReviewServiceTests.swift Tests/PersonalLearningJournalTests/JournalViewModelTests.swift
git commit -m "feat: enforce evidence-first workflow"
```

---

### Task 4: Add deterministic Today recommendations and Product Health

**Files:**
- Create: `Sources/PersonalLearningJournal/Recommendations/TodayRecommendationService.swift`
- Create: `Sources/PersonalLearningJournal/ProductHealth/ProductHealthService.swift`
- Test: `Tests/PersonalLearningJournalTests/TodayRecommendationServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ProductHealthServiceTests.swift`

**Interfaces:**
- Produces: `TodayRecommendation`, `TodayRecommendationReason`, `ProductHealthReport`, `ProjectHealthFact`.

- [ ] **Step 1: Write failing ranking tests**

```swift
@Test func recommendationOrderIsPinnedThenContractThenScheduleThenStale() {
    let recommendations = service.recommendations(snapshot: snapshot, now: now, limit: 3)
    #expect(recommendations.map(\.reason) == [.userPinned, .contractBoundary, .confirmedSchedule])
    #expect(recommendations.count == 3)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter TodayRecommendationServiceTests`  
Expected: missing service types.

- [ ] **Step 3: Implement stable ranking with explicit tie-breakers**

Use reason priority, due date, last meaningful activity, then Project creation date and UUID. Return one primary and at most two alternatives. Do not call AI.

- [ ] **Step 4: Write health tests for satisfied, resolved, and silent periods**

```swift
@Test func deliberatePauseResolvesMissInsteadOfCountingAsFailure() {
    let report = service.report(snapshot: snapshotWithMissAndPause, now: now)
    #expect(report.silentMisses == 0)
    #expect(report.resolvedContractPeriods == 1)
}
```

- [ ] **Step 5: Implement deterministic local health report**

No combined score and no network dependency. Include canonical-step coverage, accepted periods, review-resolved periods, silent misses, incomplete Reviews, and Projects with Proof sequences.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --filter TodayRecommendationServiceTests`  
Run: `swift test --filter ProductHealthServiceTests`  
Expected: all tests pass.

```bash
git add Sources/PersonalLearningJournal/Recommendations Sources/PersonalLearningJournal/ProductHealth Tests/PersonalLearningJournalTests/TodayRecommendationServiceTests.swift Tests/PersonalLearningJournalTests/ProductHealthServiceTests.swift
git commit -m "feat: add recommendations and product health"
```

---

### Task 5: Build safe convergence migration

**Files:**
- Create: `Sources/PersonalLearningJournal/Migration/ProductConvergenceMigration.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/RepositoryMigration.swift`
- Test: `Tests/PersonalLearningJournalTests/ProductConvergenceMigrationTests.swift`
- Test: `Tests/PersonalLearningJournalTests/RepositoryMigrationTests.swift`

**Interfaces:**
- Produces: `MigrationDryRun`, `MigrationIssue`, `MigrationResolution`, `MigrationValidationReport`, `ProductConvergenceMigration.execute(...)`.

- [ ] **Step 1: Write failing dry-run classification tests**

```swift
@Test func dryRunClassifiesAllApprovedAmbiguities() throws {
    let report = migration.dryRun(snapshot: legacy)
    #expect(report.issues.contains(.proofNeedsEvidence(proofID)))
    #expect(report.issues.contains(.practiceNeedsProject(routineID)))
    #expect(report.issues.contains(.projectNeedsSetup(projectID)))
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter ProductConvergenceMigrationTests`  
Expected: missing migration types.

- [ ] **Step 3: Implement pure dry run and explicit resolutions**

Dry run never mutates. Execution requires a resolution for every proof/routine ambiguity, automatically marks old committed Projects `.needsSetup`, clears first-record gating, and never invents Contracts or accepted Proof.

- [ ] **Step 4: Implement backup, transaction, validation, and rollback boundary**

Before repository commit, write an atomic `JournalExport` backup. Validate entity counts, IDs, relationships, attachment existence/checksums, and repository re-read equality. On error, do not set the migration completion identifier and preserve the old store.

- [ ] **Step 5: Run migration suites and commit**

Run: `swift test --filter ProductConvergenceMigrationTests`  
Run: `swift test --filter RepositoryMigrationTests`  
Expected: all tests pass.

```bash
git add Sources/PersonalLearningJournal/Migration Sources/PersonalLearningJournal/Persistence/RepositoryMigration.swift Tests/PersonalLearningJournalTests/ProductConvergenceMigrationTests.swift Tests/PersonalLearningJournalTests/RepositoryMigrationTests.swift
git commit -m "feat: add safe product convergence migration"
```

---

### Task 6: Converge core SwiftUI flows and navigation

**Files:**
- Create: `Sources/PersonalLearningJournal/Views/ProjectCommitmentView.swift`
- Create: `Sources/PersonalLearningJournal/Views/MigrationReviewView.swift`
- Create: `Sources/PersonalLearningJournal/Views/ProductHealthView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/RootView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/OnboardingView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/QuickLogView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TimerSessionView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ReviewView.swift`
- Test: `Tests/PersonalLearningJournalTests/StudioPresentationTests.swift`
- Test: `Tests/PersonalLearningJournalTests/QuickLogViewTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5 view-model methods and projections.
- Produces: `StudioPresentation.primaryTabs(calendarEnabled:)` and migration/commitment/review presentation states.

- [ ] **Step 1: Write failing presentation tests**

```swift
@Test func calendarTabAppearsOnlyWhenSchedulingIsEnabled() {
    #expect(StudioPresentation.primaryTabs(calendarEnabled: false) == [.today, .projects, .library])
    #expect(StudioPresentation.primaryTabs(calendarEnabled: true) == [.today, .projects, .calendar, .library])
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter StudioPresentationTests`  
Expected: primary tab behavior does not match.

- [ ] **Step 3: Implement idea capture and commitment activation UI**

Creation asks only name and area. Activation requires Goal, Next Step, trigger, artifact type, and acceptance criteria in one focused flow. Existing `needsSetup` Projects show a non-blocking setup banner.

- [ ] **Step 4: Replace Today list with explained recommendations**

Render one primary card and at most two alternatives. Each card shows the deterministic reason. Preserve Start and Quick Log entry points.

- [ ] **Step 5: Require explicit Review decision UI**

Generated facts/patterns are read-only sources. The confirmation section offers continue, Next Step, Contract, frequency, pause, archive, or complete. Complete requires selecting a qualifying Capstone Proof.

- [ ] **Step 6: Keep Session capture at one sentence plus Next Step confirmation**

Quick Log and Timer must expose current canonical Next Step, default to unchanged, and permit a replacement. They do not require Proof.

- [ ] **Step 7: Run presentation tests and Simulator compile**

Run: `swift test --filter StudioPresentationTests`  
Run: `swift test --filter QuickLogViewTests`  
Run: `xcodebuild -project SelfStudyStudio.xcodeproj -target SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`  
Expected: tests pass and build exits 0.

- [ ] **Step 8: Commit**

```bash
git add Sources/PersonalLearningJournal/Views Tests/PersonalLearningJournalTests/StudioPresentationTests.swift Tests/PersonalLearningJournalTests/QuickLogViewTests.swift
git commit -m "feat: converge core evidence-first interface"
```

---

### Task 7: Complete Proof creation, revision, Library, and local search

**Files:**
- Create: `Sources/PersonalLearningJournal/Search/ProofSearchIndex.swift`
- Modify: `Sources/PersonalLearningJournal/Views/AddProofView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ProofDetailView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/LibraryView.swift`
- Modify: `Sources/PersonalLearningJournal/ProofPreview.swift`
- Test: `Tests/PersonalLearningJournalTests/ProofSearchIndexTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ProofPreviewTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ProofAttachmentDraftTests.swift`

**Interfaces:**
- Produces: `ProofSearchDocument`, `ProofSearchIndex.search(_:)`, Text Proof editor, `needsEvidence` repair actions, revision UI.

- [ ] **Step 1: Write failing qualification and search tests**

```swift
@Test func defaultLibraryExcludesNeedsEvidence() {
    let results = ProofSearchIndex(snapshot: snapshot).search("")
    #expect(results.allSatisfy(\.proof.qualifies))
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter ProofSearchIndexTests`  
Expected: missing search index.

- [ ] **Step 3: Implement Add Proof validation**

Image/audio/file require a readable local attachment. Link requires a syntactically valid HTTP(S) URL and stores optional retrieval metadata. Text requires non-empty artifact body. Every type requires statement.

- [ ] **Step 4: Implement revision and migration repair UI**

Referenced Proof edits call the revision service and show history. `needsEvidence` records stay out of default Library but appear in Migration Review with attach, convert-to-session-note, and Trash choices.

- [ ] **Step 5: Implement local-only index**

Index title, statement, Project name, Text body, and locally derived OCR/transcription text. Persist no index entity and expose a rebuild operation.

- [ ] **Step 6: Run proof suites and commit**

Run: `swift test --filter ProofSearchIndexTests`  
Run: `swift test --filter ProofPreviewTests`  
Run: `swift test --filter ProofAttachmentDraftTests`  
Expected: all tests pass.

```bash
git add Sources/PersonalLearningJournal/Search Sources/PersonalLearningJournal/Views/AddProofView.swift Sources/PersonalLearningJournal/Views/ProofDetailView.swift Sources/PersonalLearningJournal/Views/LibraryView.swift Sources/PersonalLearningJournal/ProofPreview.swift Tests/PersonalLearningJournalTests/ProofSearchIndexTests.swift Tests/PersonalLearningJournalTests/ProofPreviewTests.swift Tests/PersonalLearningJournalTests/ProofAttachmentDraftTests.swift
git commit -m "feat: qualify and search proof artifacts"
```

---

### Task 8: Bind Practice and course plans to the canonical Project model

**Files:**
- Modify: `Sources/PersonalLearningJournal/Practice/PracticeDomain.swift`
- Modify: `Sources/PersonalLearningJournal/Practice/PracticeService.swift`
- Modify: `Sources/PersonalLearningJournal/Views/PracticeManagerView.swift`
- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanningService.swift`
- Modify: `Sources/PersonalLearningJournal/Views/CoursePlanDetailView.swift`
- Test: `Tests/PersonalLearningJournalTests/PracticeServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningEndToEndTests.swift`

**Interfaces:**
- Changes: persistent `PracticeRoutine.projectId` is required after migration; plan activation proposes but does not silently replace canonical Next Step.

- [ ] **Step 1: Write failing Project-bound Practice tests**

```swift
@Test func persistentRoutineRequiresExistingProject() throws {
    #expect(throws: PracticeValidationError.missingProject) {
        try service.createRoutine(draftWithoutProject)
    }
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter PracticeServiceTests`  
Expected: standalone routines are currently accepted.

- [ ] **Step 3: Require Project association and emit normal learning history**

Routine completion preserves Practice timing records and creates/links one Project `LearningSession`; Review consumes the Project Session and avoids double-counting Practice duration.

- [ ] **Step 4: Align plan activation with canonical Next Step**

Activation returns a `CanonicalNextStepProposal`. The user confirms or edits it. Completing a Planned Session produces the next proposal but does not mutate Project until confirmation.

```swift
public struct CanonicalNextStepProposal: Equatable, Sendable {
    public var projectId: UUID
    public var plannedSessionId: UUID
    public var title: String
    public var reason: String
}
```

- [ ] **Step 5: Run practice/planning suites and commit**

Run: `swift test --filter PracticeServiceTests`  
Run: `swift test --filter CoursePlanningServiceTests`  
Run: `swift test --filter CoursePlanningEndToEndTests`  
Expected: all tests pass.

```bash
git add Sources/PersonalLearningJournal/Practice Sources/PersonalLearningJournal/Planning Sources/PersonalLearningJournal/Views/PracticeManagerView.swift Sources/PersonalLearningJournal/Views/CoursePlanDetailView.swift Tests/PersonalLearningJournalTests/PracticeServiceTests.swift Tests/PersonalLearningJournalTests/CoursePlanningServiceTests.swift Tests/PersonalLearningJournalTests/CoursePlanningEndToEndTests.swift
git commit -m "feat: align practice and plans with projects"
```

---

### Task 9: Enforce AI, Calendar, and notification privacy boundaries

**Files:**
- Modify: `Sources/PersonalLearningJournal/AI/StructuredAIClient.swift`
- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanningProvider.swift`
- Modify: `Sources/PersonalLearningJournal/ReviewService.swift`
- Modify: `Sources/PersonalLearningJournal/Calendar/CalendarSyncService.swift`
- Modify: `Sources/PersonalLearningJournal/Calendar/EventKitCalendarClient.swift`
- Create: `Sources/PersonalLearningJournal/Notifications/LearningNotificationPolicy.swift`
- Test: `Tests/PersonalLearningJournalTests/StructuredAIClientTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CalendarSyncServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/LearningNotificationPolicyTests.swift`

**Interfaces:**
- Produces: `AIRequestPackage` with one-request artifact authorization; detailed Calendar payload and shared-calendar warning; generic lock-screen notification payload.

- [ ] **Step 1: Write failing privacy-boundary tests**

```swift
@Test func aiPackageExcludesUnselectedArtifactsAndCalendarData() {
    let package = builder.makePackage(snapshot: snapshot, selectedProofIDs: [])
    #expect(package.artifacts.isEmpty)
    #expect(package.encodedText.contains("eventIdentifier") == false)
    #expect(package.encodedText.contains("attendees") == false)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter StructuredAIClientTests`  
Expected: request packaging lacks explicit authorization boundary.

- [ ] **Step 3: Implement explicit AI request preview/package**

The package contains metadata/statements by default, selected artifact bytes only for the current request, exact course text preview, model/source metadata, and no persistent raw request entity.

- [ ] **Step 4: Make dedicated Calendar and disclosure explicit**

The first enablement selects/creates `Self Study Studio`. Detailed event fields are Project name, Session title, Goal, and expected Proof. Shared target calendars require a second confirmation. Existing change-set and reconciliation boundaries remain.

- [ ] **Step 5: Implement generic notification policy**

Only confirmed study time, Contract boundary, and pending Review categories exist. Lock-screen title/body contain no Project or learning content.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --filter StructuredAIClientTests`  
Run: `swift test --filter CalendarSyncServiceTests`  
Run: `swift test --filter LearningNotificationPolicyTests`  
Expected: all tests pass.

```bash
git add Sources/PersonalLearningJournal/AI Sources/PersonalLearningJournal/Planning/CoursePlanningProvider.swift Sources/PersonalLearningJournal/ReviewService.swift Sources/PersonalLearningJournal/Calendar Sources/PersonalLearningJournal/Notifications Tests/PersonalLearningJournalTests/StructuredAIClientTests.swift Tests/PersonalLearningJournalTests/CalendarSyncServiceTests.swift Tests/PersonalLearningJournalTests/LearningNotificationPolicyTests.swift
git commit -m "feat: enforce assistant and calendar boundaries"
```

---

### Task 10: Add round-trip archive, Trash, and permanent deletion

**Files:**
- Create: `Sources/PersonalLearningJournal/Archive/JournalArchiveService.swift`
- Modify: `Sources/PersonalLearningJournal/ExportService.swift`
- Create: `Sources/PersonalLearningJournal/Views/TrashView.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalArchiveServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`

**Interfaces:**
- Produces: `JournalArchiveManifest`, `JournalArchivePreview`, `JournalArchiveEnvelope`, `JournalArchiveService.export/preview/restore`; Trash restore/purge impact APIs.

- [ ] **Step 1: Write failing round-trip and checksum tests**

```swift
@Test func archiveRoundTripRestoresRelationshipsAndAttachments() throws {
    let envelope = try service.export(snapshot: snapshot, attachments: attachments, password: "correct horse")
    let preview = try service.preview(envelope, password: "correct horse")
    #expect(preview.checksumsValid)
    #expect(try service.restore(preview).snapshot == snapshot)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter JournalArchiveServiceTests`  
Expected: archive service missing.

- [ ] **Step 3: Implement versioned manifest and encrypted envelope**

Use SHA-256 checksums and AES.GCM from CryptoKit. Derive a 256-bit key with a versioned, salted iterative SHA-256 derivation recorded in the envelope manifest. Default UI path requires a password; unencrypted export requires explicit warning confirmation.

```swift
public struct JournalArchiveManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var recordCounts: [String: Int]
    public var checksums: [String: String]
}

public struct JournalArchiveEnvelope: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var salt: Data?
    public var derivationRounds: Int?
    public var sealedPayload: Data
    public var encrypted: Bool
}

public struct JournalArchivePreview: Equatable, Sendable {
    public var manifest: JournalArchiveManifest
    public var snapshot: JournalSnapshot
    public var attachmentData: [String: Data]
    public var duplicateIDs: Set<UUID>
    public var checksumsValid: Bool
}
```

- [ ] **Step 4: Implement import preview, duplicate detection, and restoration transaction**

Validate manifest version, record counts, checksums, attachment paths, and relationships before any commit. Restore with stable IDs and avoid device-local paths in semantic records.

- [ ] **Step 5: Implement Trash retention and explicit purge impact**

Restore clears `deletedAt` and returns the previous lifecycle state stored in deletion metadata. Automatic purge considers `deletedAt + 30 days`; immediate purge enumerates related Sessions, Proof, revisions, plans, attachments, and sync tombstones before confirmation.

- [ ] **Step 6: Run export/archive tests and commit**

Run: `swift test --filter JournalArchiveServiceTests`  
Run: `swift test --filter ExportServiceTests`  
Expected: all tests pass.

```bash
git add Sources/PersonalLearningJournal/Archive Sources/PersonalLearningJournal/ExportService.swift Sources/PersonalLearningJournal/Views/TrashView.swift Tests/PersonalLearningJournalTests/JournalArchiveServiceTests.swift Tests/PersonalLearningJournalTests/ExportServiceTests.swift
git commit -m "feat: add recoverable archive and trash"
```

---

### Task 11: Add account-space transfer and optional App Lock

**Files:**
- Modify: `Sources/PersonalLearningJournal/Sync/CloudAccountCoordinator.swift`
- Modify: `Sources/PersonalLearningJournal/Views/SyncSettingsView.swift`
- Create: `Sources/PersonalLearningJournal/Security/AppLockController.swift`
- Modify: `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`
- Test: `Tests/PersonalLearningJournalTests/CloudAccountCoordinatorTests.swift`
- Test: `Tests/PersonalLearningJournalTests/AppLockControllerTests.swift`

**Interfaces:**
- Produces: `AccountSpaceTransferPreview`, `AccountSpaceTransferChoice`, `AppLockController.unlock()`.

- [ ] **Step 1: Write failing account-space and lock-state tests**

```swift
@Test func signingIntoAccountNeverAutoMergesLocalSpace() async throws {
    let transition = try await coordinator.transition(from: .local, to: .account("A"))
    #expect(transition.requiresTransferChoice)
    #expect(repository.commitCount == 0)
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter CloudAccountCoordinatorTests`  
Expected: no explicit transfer choice.

- [ ] **Step 3: Implement isolated transfer preview and choices**

Before move/copy, create archive, detect stable-ID duplicates, list counts, and require `move`, `copy`, or `keepLocal`. Account switching hides other stores but never deletes them automatically.

```swift
public enum AccountSpaceTransferChoice: Sendable {
    case move
    case copy
    case keepLocal
}

public struct AccountSpaceTransferPreview: Equatable, Sendable {
    public var sourceRecordCount: Int
    public var sourceAttachmentCount: Int
    public var duplicateIDs: Set<UUID>
    public var archiveURL: URL
}
```

- [ ] **Step 4: Implement optional LocalAuthentication App Lock**

Default disabled. When enabled, app activation requires successful device-owner authentication, protected screens remain unavailable until unlock, and scene backgrounding renders a privacy cover.

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter CloudAccountCoordinatorTests`  
Run: `swift test --filter AppLockControllerTests`  
Expected: all tests pass.

```bash
git add Sources/PersonalLearningJournal/Sync/CloudAccountCoordinator.swift Sources/PersonalLearningJournal/Views/SyncSettingsView.swift Sources/PersonalLearningJournal/Security Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift Tests/PersonalLearningJournalTests/CloudAccountCoordinatorTests.swift Tests/PersonalLearningJournalTests/AppLockControllerTests.swift
git commit -m "feat: isolate accounts and protect the app"
```

---

### Task 12: Establish bilingual core-loop localization

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PersonalLearningJournal/Resources/en.lproj/Localizable.strings`
- Create: `Sources/PersonalLearningJournal/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: core-loop views under `Sources/PersonalLearningJournal/Views/`
- Test: `Tests/PersonalLearningJournalTests/LocalizationTests.swift`

**Interfaces:**
- Produces: package resource bundle and matching keys for core navigation, lifecycle, Contract, Proof, Review, migration, Trash, Product Health, privacy disclosures, and validation errors.

- [ ] **Step 1: Write failing localization parity test**

```swift
@Test func englishAndChineseCoreKeysMatch() throws {
    let english = try LocalizedStringFile.keys(at: englishURL)
    let chinese = try LocalizedStringFile.keys(at: chineseURL)
    #expect(english == chinese)
    #expect(english.contains("review.decision.continue"))
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter LocalizationTests`  
Expected: resource files and helper missing.

- [ ] **Step 3: Add package resources and replace core hard-coded strings**

Set `defaultLocalization: "en"` and `.process("Resources")`. Use stable keys, parameter placeholders with matching types in both languages, and system-language selection. Do not translate user content.

Add the test-only parser in `LocalizationTests.swift` so the parity test is self-contained:

```swift
private enum LocalizedStringFile {
    static func keys(at url: URL) throws -> Set<String> {
        let source = try String(contentsOf: url, encoding: .utf8)
        let pattern = #"^\s*\"([^\"]+)\"\s*="#
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let range = NSRange(source.startIndex..., in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
    }
}
```

- [ ] **Step 4: Run localization and build verification**

Run: `swift test --filter LocalizationTests`  
Run: `swift build`  
Expected: localization parity passes and package builds.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/PersonalLearningJournal/Resources Sources/PersonalLearningJournal/Views Tests/PersonalLearningJournalTests/LocalizationTests.swift
git commit -m "feat: localize the evidence-first core"
```

---

### Task 13: Full automated and Simulator acceptance

**Files:**
- Modify: `README.md`
- Create: `docs/product-health-validation.md`
- Create: `Tests/PersonalLearningJournalTests/ProductConvergenceAcceptanceTests.swift`

**Interfaces:**
- Produces: current verification record and four-week validation checklist.

- [ ] **Step 1: Audit the design spec requirement by requirement**

For every requirement in `docs/superpowers/specs/2026-07-14-evidence-first-product-convergence-design.md`, record the implementing task/file and automated or device evidence in `docs/product-health-validation.md`. Add `ProductConvergenceAcceptanceTests.swift` with one end-to-end test that creates an idea, activates it with a Contract, logs a Session, saves and accepts Text Proof, completes a Review Decision, archives/restores through Trash, exports/restores an archive, and confirms the restored Product Health report contains no silent miss. Any missing evidence is an implementation gap, not a documentation note.

- [ ] **Step 2: Run the complete test suite**

Run: `swift test`  
Expected: 0 failures.

- [ ] **Step 3: Run package and unsigned Simulator builds**

Run: `swift build`  
Expected: exit 0.  
Run: `xcodebuild -project SelfStudyStudio.xcodeproj -target SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`  
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Install and launch a clean Simulator build**

Use `xcrun simctl` to boot an available iPhone simulator, install the built app, launch it, and capture evidence for idea creation, activation, Session, Text Proof, Review Decision, conditional Calendar tab, Trash restore, and migration review.

- [ ] **Step 5: Verify dirty-worktree scope**

Run: `git status --short` and `git diff --check`.  
Expected: only task-owned changes plus the preserved pre-existing `.gitignore` and `diagrams/` changes; no whitespace errors.

- [ ] **Step 6: Update README and commit automated acceptance**

```bash
git add README.md docs/product-health-validation.md Tests/PersonalLearningJournalTests/ProductConvergenceAcceptanceTests.swift
git commit -m "docs: verify evidence-first convergence"
```

---

### Task 14: Signed physical-device acceptance and four-week handoff

**Files:**
- Modify: `docs/product-health-validation.md`

**Interfaces:**
- Produces: device acceptance evidence and the start conditions for the four-week validation.

- [ ] **Step 1: Inspect current signing and device state**

Run `xcrun xctrace list devices`, inspect the selected Developer Team and iCloud container capability, and record which physical-device prerequisites are currently available.

- [ ] **Step 2: Build and install a signed physical-device app**

Use the configured team and connected iPhone destination. A Simulator-only result does not satisfy this step.

- [ ] **Step 3: Execute device capability matrix**

Verify camera, photo import, file import, audio recording/playback, generic lock-screen notifications, dedicated Calendar disclosure/write/reconciliation, airplane-mode Session/Proof writes, queued iCloud recovery, account-space isolation, Face ID cover, encrypted export/import, and clean restore.

- [ ] **Step 4: Verify second-space recovery**

Use a second Apple device or a clean reinstall to verify automatic private iCloud restoration and attachment opening without conflating it with Simulator-only evidence.

- [ ] **Step 5: Start the four-week validation**

Record the start date, active Projects, Contracts, and baseline Product Health. The validation succeeds only on the evidence-first criteria in the design spec, not on usage time or feature count.

- [ ] **Step 6: Commit device evidence when available**

```bash
git add docs/product-health-validation.md
git commit -m "docs: record physical device acceptance"
```
