# Personal Learning Journal PRD v0.1 Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining Personal Learning Journal v0.1 PRD gaps: first-use completion, usable Proof viewing, actionable and configurable weekly review, structured SwiftData persistence, and end-to-end verification.

**Architecture:** Keep the existing value-type domain and `JournalService` API as the boundary used by tests and SwiftUI. Add a SwiftData-backed `JournalStore` that maps each domain entity to an independent model record, keep JSON only for export and one-time legacy import, and make review providers asynchronous so network AI never blocks the main actor. SwiftUI adds focused screens for first capture, Proof detail, and AI configuration rather than expanding the daily logging flow.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (iOS 17/macOS 14), Foundation, AVFoundation, QuickLook, Security, XCTest.

## Global Constraints

- Platform: iOS native app; iOS 17 minimum, with macOS 14 package-test compatibility.
- Product scope: record loop plus review loop only; no course planning, CloudKit, accounts, social features, rankings, calendar scheduler, search, desktop, or web app.
- Local-first: project/session/proof capture and local Proof attachments work without a network connection.
- AI scope: weekly review only; OpenAI-compatible endpoint is optional, asynchronously invoked, and falls back to a local evidence-based review when unavailable.
- AI outputs: Facts, Patterns, Decisions, Next Steps; no more than three generated suggestions; recommendations never change project status until the user applies them.
- UX: daily recording requires one sentence, Proof requires “What does this prove?”, each active project has one Next Step, and no streak or pressure copy.
- Persistence: SwiftData stores each structured entity; attachment data remains in `LearningJournal/Attachments/<project>/<session-or-project>/<proof>.<ext>`.

---

## File Structure

- `Sources/PersonalLearningJournal/JournalStore.swift`: preserve test-memory and legacy JSON stores; add independent SwiftData record models, store conversion, and one-time JSON import.
- `Sources/PersonalLearningJournal/Domain.swift`: add Codable onboarding progress with backward-compatible snapshot decoding.
- `Sources/PersonalLearningJournal/JournalService.swift`: add atomic onboarding creation/completion and validation.
- `Sources/PersonalLearningJournal/JournalViewModel.swift`: expose onboarding completion and async review commands.
- `Sources/PersonalLearningJournal/ReviewService.swift`: add async OpenAI-compatible provider, structured response parsing, source references, and fallback behavior.
- `Sources/PersonalLearningJournal/AIReviewSettings.swift`: persist endpoint/model in `UserDefaults`, API key in Keychain, and provide an adaptive review provider.
- `Sources/PersonalLearningJournal/Views/ProofDetailView.swift`: preview images, play local audio, open files through Quick Look, and open links.
- `Sources/PersonalLearningJournal/Views/AIReviewSettingsView.swift`: configure the optional endpoint/model/key without exposing secrets in normal preferences.
- `Sources/PersonalLearningJournal/Views/{OnboardingView,QuickLogView,LibraryView,ProjectsView,ReviewView,TimerSessionView,TodayView}.swift`: wire first capture, viewer navigation, review applications, timer refresh, and richer Continue context.
- `App/SelfStudyStudioApp.swift` and `Views/PersonalLearningJournalApp.swift`: use SwiftData store and adaptive AI settings at app startup.
- `Tests/PersonalLearningJournalTests/{JournalStoreTests,JournalServiceTests,JournalViewModelTests,ReviewServiceTests,ProofPreviewTests}.swift`: TDD coverage for all new behavior.

## Task 1: Complete First-Use Capture Atomically

**Files:**
- Modify: `Sources/PersonalLearningJournal/Domain.swift`
- Modify: `Sources/PersonalLearningJournal/JournalService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Modify: `Sources/PersonalLearningJournal/Views/OnboardingView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/QuickLogView.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`

**Interfaces:**
- Produces `JournalSnapshot.hasCompletedOnboarding: Bool`, `pendingFirstRecordProjectId: UUID?`, `JournalService.createOnboardingProjects(_:)`, and `JournalService.completeOnboarding()`.
- `JournalViewModel` exposes `pendingFirstRecordProject` and calls `completeOnboarding()` after its first saved session.

- [ ] **Step 1: Write failing tests**

```swift
func testOnboardingIsNotCompleteUntilFirstSessionIsRecorded() throws {
    let service = JournalService(store: InMemoryJournalStore())
    let project = try service.createOnboardingProjects([
        ProjectOnboardingDraft(name: "CS336", area: "AI", goal: "复现课程", nextStep: "整理 loss")
    ]).first!

    XCTAssertFalse(service.snapshot().hasCompletedOnboarding)
    XCTAssertEqual(service.snapshot().pendingFirstRecordProjectId, project.id)

    _ = try service.quickLog(projectId: project.id, durationMinutes: 20, note: "复现了第一段")
    try service.completeOnboarding()

    XCTAssertTrue(service.snapshot().hasCompletedOnboarding)
    XCTAssertNil(service.snapshot().pendingFirstRecordProjectId)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter JournalServiceTests/testOnboardingIsNotCompleteUntilFirstSessionIsRecorded`

Expected: compile failure because `createOnboardingProjects` and onboarding state do not exist.

- [ ] **Step 3: Implement the minimal domain and service behavior**

Add backward-compatible snapshot decoding: old persisted snapshots containing projects infer completed onboarding, while a newly created empty snapshot begins incomplete. Validate every onboarding draft before adding any project, create at most three projects as one transaction, store the first ID as pending, and only allow `completeOnboarding()` after a session or Proof exists for that project.

- [ ] **Step 4: Connect the first-capture screen**

After project forms save, keep Root on onboarding and present `QuickLogView` for the pending project. Add an optional `onSaved` closure to `QuickLogView`; onboarding calls `completeOnboarding()` in that closure. Preserve existing Quick Log behavior when the closure is absent.

- [ ] **Step 5: Run focused tests and full tests**

Run: `swift test --filter JournalServiceTests && swift test --filter JournalViewModelTests && swift test`

Expected: all onboarding, existing session, and view-model tests pass.

## Task 2: Make Proofs Viewable

**Files:**
- Create: `Sources/PersonalLearningJournal/ProofPreview.swift`
- Create: `Sources/PersonalLearningJournal/Views/ProofDetailView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/LibraryView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Test: `Tests/PersonalLearningJournalTests/ProofPreviewTests.swift`

**Interfaces:**
- Produces `ProofPreviewKind` and `ProofPreviewDescriptor(proof:)` for pure selection logic.
- `ProofDetailView(proof:projectName:sessionSummary:)` provides image preview, audio playback, Quick Look file preview, and `Link` destination for URL Proofs.

- [ ] **Step 1: Write failing descriptor tests**

```swift
func testLocalAudioProofProducesAudioPreview() throws {
    let proof = try Proof(
        projectId: UUID(), type: .audio, title: "练习", statement: "能完整弹完第一段",
        localPath: "/tmp/practice.m4a", mimeType: "audio/m4a"
    )

    XCTAssertEqual(ProofPreviewDescriptor(proof: proof).kind, .audio)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter ProofPreviewTests/testLocalAudioProofProducesAudioPreview`

Expected: compile failure because preview types do not exist.

- [ ] **Step 3: Implement descriptor and detail screen**

Map image/audio/file/link Proofs to their render mode. Use `Image(uiImage:)` on iOS for images, `AVAudioPlayer` for local audio, `QLPreviewController` through a UIKit representable for files, and `Link` for URLs. Use guarded platform fallbacks so the Swift package compiles on macOS.

- [ ] **Step 4: Add navigation from all Proof lists**

Make Library rows and Project/Session Proof rows navigate to `ProofDetailView`, preserving title, statement, project, session, and creation time.

- [ ] **Step 5: Run tests and simulator build**

Run: `swift test --filter ProofPreviewTests && swift test && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: tests and iOS build pass.

## Task 3: Make Weekly Review Actionable and Non-Blocking

**Files:**
- Modify: `Sources/PersonalLearningJournal/Domain.swift`
- Modify: `Sources/PersonalLearningJournal/ReviewService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ReviewView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Test: `Tests/PersonalLearningJournalTests/ReviewServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`

**Interfaces:**
- Produces asynchronous `AIReviewProvider.makeReview(snapshot:periodStart:periodEnd:)`.
- `Review` and `ReviewDraft` gain `sourceReferences: [String: [String]]` keyed by generated insight text.
- `JournalViewModel.applyReviewRecommendation(reviewId:projectId:)` changes status only after an explicit button tap.

- [ ] **Step 1: Write failing review tests**

```swift
func testGeneratedDecisionCarriesEvidenceAndRequiresExplicitStatusApplication() async throws {
    let project = try service.createProject(name: "CS336", area: "AI", goal: "复现", nextStep: "写 notebook")
    let review = try await reviewService.createWeeklyReview(periodStart: start, periodEnd: end)

    XCTAssertFalse(review.sourceReferences[review.decisions[0], default: []].isEmpty)
    XCTAssertEqual(service.project(id: project.id)?.status, .active)

    try service.applyReviewRecommendation(reviewId: review.id, projectId: project.id)
    XCTAssertEqual(service.project(id: project.id)?.status, review.projectRecommendations[project.id])
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter ReviewServiceTests/testGeneratedDecisionCarriesEvidenceAndRequiresExplicitStatusApplication`

Expected: compile failure because source references and recommendation application do not exist.

- [ ] **Step 3: Convert review APIs to async**

Change providers and service/view-model creation methods to `async throws`; update views to run them in `Task` and expose a progress state. Rule-based fallback remains deterministic and returns immediately. Ensure every generated fact/pattern/decision gets at least one session or Proof source when evidence exists, preserve references while editing unchanged text, and cap generated lists to three.

- [ ] **Step 4: Surface and apply recommendations**

Show each recommendation in Review with its source chips, an explicit “Apply status” action, and an explicit “Use as Next Step” action. Status and Next Step remain unchanged until their respective user action is tapped. Add a weekly prompt after seven days even without three new evidence items.

- [ ] **Step 5: Run review and full tests**

Run: `swift test --filter ReviewServiceTests && swift test --filter JournalViewModelTests && swift test`

Expected: asynchronous review, edits, fallback, recommendations, and existing tests pass.

## Task 4: Add Configurable OpenAI-Compatible Review

**Files:**
- Create: `Sources/PersonalLearningJournal/AIReviewSettings.swift`
- Create: `Sources/PersonalLearningJournal/Views/AIReviewSettingsView.swift`
- Modify: `Sources/PersonalLearningJournal/ReviewService.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Modify: `App/SelfStudyStudioApp.swift`
- Modify: `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`
- Test: `Tests/PersonalLearningJournalTests/ReviewServiceTests.swift`

**Interfaces:**
- Produces `AIReviewSettings(endpoint:model:)`, `AIReviewSettingsStore`, `KeychainSecretStore`, and `AdaptiveAIReviewProvider`.
- `OpenAICompatibleReviewProvider` sends `model` plus system/user chat messages and decodes a JSON-object response into `ReviewDraft`.

- [ ] **Step 1: Write failing provider tests**

```swift
func testOpenAICompatibleProviderParsesJSONContentFromChatCompletion() async throws {
    let provider = OpenAICompatibleReviewProvider(
        settings: AIReviewSettings(endpoint: URL(string: "https://example.test/v1")!, model: "test-model"),
        apiKey: "test-key", transport: StubReviewTransport(responseData: completionData)
    )

    let draft = try await provider.makeReview(snapshot: JournalSnapshot(), periodStart: start, periodEnd: end)

    XCTAssertEqual(draft.facts, ["CS336: 1 session."])
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter ReviewServiceTests/testOpenAICompatibleProviderParsesJSONContentFromChatCompletion`

Expected: compile failure because provider and transport do not exist.

- [ ] **Step 3: Implement settings and provider**

Store endpoint/model in a dedicated `UserDefaults` suite and API key through the Security Keychain. Use an injected `ReviewHTTPTransport` for tests; production uses `URLSession.data(for:)`. If settings/key are absent, invalid, or the request fails, adaptive provider selects the existing local rule provider.

- [ ] **Step 4: Add the configuration UI**

Present a sheet from review entry points with Endpoint, Model, and API Key fields. Save clears the key only when the user explicitly clears it; normal reloads never render the secret. Indicate whether the current review will use the configured provider or local fallback.

- [ ] **Step 5: Run tests and iOS build**

Run: `swift test --filter ReviewServiceTests && swift test && xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: provider parsing, local fallback, review logic, and the app build pass.

## Task 5: Replace Runtime JSON Persistence with SwiftData

**Files:**
- Modify: `Sources/PersonalLearningJournal/JournalStore.swift`
- Modify: `App/SelfStudyStudioApp.swift`
- Modify: `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalStoreTests.swift`
- Test: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`

**Interfaces:**
- Produces `SwiftDataJournalStore(container:)`, `SwiftDataJournalStore.inMemory()`, and `JournalStoreFactory.makeDefault(documentsDirectory:)`.
- Store maps Project, Session, Proof, Review, and TrailEvent to independent SwiftData records and rebuilds a `JournalSnapshot` on load.

- [ ] **Step 1: Write failing persistence tests**

```swift
func testSwiftDataStoreRoundTripsEachJournalEntity() throws {
    let store = try SwiftDataJournalStore.inMemory()
    let snapshot = JournalSnapshot(projects: [project], sessions: [session], proofs: [proof], reviews: [review], trailEvents: [event])

    try store.save(snapshot)

    XCTAssertEqual(try store.load(), snapshot)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter JournalStoreTests/testSwiftDataStoreRoundTripsEachJournalEntity`

Expected: compile failure because `SwiftDataJournalStore` does not exist.

- [ ] **Step 3: Implement normalized SwiftData records**

Create one `@Model` record per PRD entity. Persist IDs, scalar fields, and dates as typed properties; encode the few collection/dictionary review fields as JSON data scoped to the Review record. On save, replace records within a SwiftData transaction and save once. On load, decode every record to domain values sorted by timestamps.

- [ ] **Step 4: Add legacy JSON migration and wire the app**

If a SwiftData store is empty and `LearningJournal/journal.json` exists, import it once, save SwiftData, and leave the legacy file untouched for recovery. App entry points create SwiftData through the factory; `JSONJournalStore` remains available only for legacy import and tests.

- [ ] **Step 5: Run persistence/export regression suite**

Run: `swift test --filter JournalStoreTests && swift test --filter ExportServiceTests && swift test`

Expected: entity round trip, JSON export, attachment export, and the full suite pass.

## Task 6: Finish UX and PRD Acceptance Verification

**Files:**
- Modify: `Sources/PersonalLearningJournal/Views/TimerSessionView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TodayView.swift`
- Modify: `README.md`
- Modify: `personal-learning-journal-design.md`
- Test: `Tests/PersonalLearningJournalTests/JournalViewModelTests.swift`

**Interfaces:**
- Produces live timer display, Today card last-activity context, and a current PRD implementation/acceptance note.

- [ ] **Step 1: Write failing behavior tests where behavior is non-visual**

```swift
func testTodayContinueProjectOrderingUsesMostRecentSessionThenProof() throws {
    XCTAssertEqual(service.todayContinueProjects().map(\.id), [recentProject.id, olderProject.id])
}
```

- [ ] **Step 2: Run focused test and verify RED when a service change is required**

Run: `swift test --filter JournalServiceTests/testTodayContinueProjectOrderingUsesMostRecentSessionThenProof`

Expected: failure until Proof dates are included in ordering.

- [ ] **Step 3: Implement UX refinements**

Use `TimelineView` for a live elapsed timer. Show latest Session/Proof context in Today cards. Keep review prompts based on either seven-day cadence, sufficient new evidence, or a seven-day idle project. Preserve all existing one-handed sheet entry points.

- [ ] **Step 4: Execute the complete verification matrix**

Run: `swift test`, `swift build`, and `xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`.

Install and launch the iOS Simulator app, then manually verify: onboarding to first session, Quick Log with 20 minutes, timer pause/resume/save, image/audio/file/link Proof detail, Trail entries, Review source/recommendation application, export generation, and offline local capture.

- [ ] **Step 5: Update PRD/README status and audit every requirement**

Mark only verified implementation details as complete in README and add an acceptance matrix to the PRD. Do not claim CloudKit, accounts, course planning, search, desktop, or web support.
