# Evidence-First Product Health Validation

Last updated: 2026-07-15

This record audits the convergence design against implementation evidence. Automated and Simulator evidence is complete. Signed physical-device and second-device evidence remains a separate release gate and is not inferred from Simulator success.

## Current gate status

| Gate | Result | Evidence |
|---|---|---|
| Complete automated suite | Pass | `swift test`: 260 tests, 0 failures |
| Package build | Pass | `swift build` |
| Unsigned iOS Simulator build | Pass | `xcodebuild ... -sdk iphonesimulator ... CODE_SIGNING_ALLOWED=NO build`; `BUILD SUCCEEDED` |
| Clean install and launch | Pass | App data uninstalled, current app installed and launched on iPhone 16 Pro Simulator; onboarding rendered after initial store startup |
| End-to-end evidence loop | Pass | `ProductConvergenceAcceptanceTests`: Idea → Contract → Session → accepted Text Proof → Review Decision → Trash restore → encrypted archive restore → Product Health with no silent miss |
| Signed physical device | Pending | Requires the Task 14 capability matrix below |
| Second-space iCloud recovery | Pending | Requires a second Apple device or clean signed reinstall |

## Requirement audit

| Design requirement | Implementation | Automated or Simulator evidence |
|---|---|---|
| Product contract and canonical language | `Domain.swift`, `Projects/ProjectCommitment.swift`, evidence-first entities | `EvidenceFirstDomainTests`, acceptance test |
| Project lifecycle and attention budget | `JournalService`, commitment and migration services | `JournalServiceTests`, `ProductConvergenceMigrationTests` |
| Qualifying Proof semantics | `Evidence/ProofEvidence.swift`, `AddProofView`, `ProofPreview` | `ProofAttachmentDraftTests`, `ProofPreviewTests` |
| Text, Link, attachment, and revision behavior | `JournalService.reviseProof`, `ProofDetailView`, local attachment store | proof and attachment suites; revision assertions in `JournalServiceTests` |
| Default Library qualification and local search | `Search/ProofSearchIndex.swift`, `LibraryView` | `ProofSearchIndexTests` |
| Today prioritization and canonical Next Step | `Recommendations/TodayRecommendationService.swift`, `TodayView` | `TodayRecommendationServiceTests`, `StudioPresentationTests` |
| One-sentence Session capture | `QuickLogView`, `TimerSessionView`, `JournalService` | `QuickLogViewTests`, `JournalServiceTests` |
| Practice remains Project-bound | `PracticeDomain`, `PracticeService` | practice domain/service/end-to-end suites |
| Explicit Review Decision and Product Health | `ReviewDecision`, `ReviewView`, `ProductHealthService` | review tests, health tests, acceptance test |
| AI request authorization boundary | `AI/StructuredAIClient.swift`, provider request previews | `StructuredAIClientTests`; unselected artifacts and Calendar data excluded |
| Plans propose rather than silently replace Next Step | `CoursePlanningService`, `CoursePlanDetailView` | planning service and end-to-end suites |
| Dedicated Calendar and explicit writes | Calendar services and settings views | Calendar client/sync/view-model/end-to-end suites |
| Generic lock-screen notifications | `Notifications/LearningNotificationPolicy.swift` | `LearningNotificationPolicyTests` |
| Local-first persistence and retryable private sync | repository, mapper, coordinator, merge service | repository, CloudKit mapper, merge, and offline sync suites |
| Account-space isolation | `CloudAccountCoordinator` transfer preview and explicit choices | `CloudAccountCoordinatorTests`; no write before choice |
| Optional App Lock and privacy cover | `Security/AppLockController.swift`, app scene overlay | `AppLockControllerTests`; device-owner UI requires physical acceptance |
| Encrypted round-trip archive | `Archive/JournalArchiveService.swift`, `ExportService` | archive/export tests cover AES.GCM, SHA-256, wrong password, tamper, stable IDs |
| Recoverable Trash and explicit purge | `TrashView`, purge impact and tombstones | archive tests and ViewModel lifecycle regression |
| Safe migration with backup and ambiguity review | `Migration/ProductConvergenceMigration.swift`, `MigrationReviewView` | migration and repository migration suites |
| Bilingual core loop | `Resources/en.lproj`, `Resources/zh-Hans.lproj`, localized core views | `LocalizationTests`; both resources copied by Xcode build |
| Architecture and failure boundaries | domain modules, repository transactions, local fallbacks | full 260-test suite and successful package/App builds |

## Simulator acceptance evidence

- Device: iPhone 16 Pro Simulator, iOS 18.3.
- Bundle: `com.local.selfstudystudio` from `build/Debug-iphonesimulator/SelfStudyStudio.app`.
- Clean-state procedure: uninstall bundle, install current build, launch, wait for store initialization, capture onboarding.
- Idea creation, activation, Session, Text Proof acceptance, Review Decision, Trash restore, archive restore, and Product Health are covered together by `ProductConvergenceAcceptanceTests`.
- Conditional Calendar-tab behavior is covered by `StudioPresentationTests.testCalendarTabAppearsOnlyWhenSchedulingIsEnabled`.
- Migration review behavior is covered by migration service tests and the compiled `MigrationReviewView`.

The Simulator does not establish camera, microphone, notification delivery, signed entitlement, Face ID, real Calendar, or real iCloud behavior.

## Four-week validation checklist

Start only after the signed physical-device and second-space gates pass.

- [ ] Record start date and the exact app commit.
- [ ] Record active Projects and one current Evidence Contract per Project.
- [ ] Capture baseline canonical-Next-Step coverage, resolved Contract periods, silent misses, incomplete Reviews, and Proof sequences.
- [ ] Each week, confirm every elapsed Contract period is accepted or explicitly resolved.
- [ ] Confirm no status, Next Step, Calendar write, account transfer, or AI artifact upload occurs silently.
- [ ] Verify all accepted Proof remains openable and its revision history remains intact.
- [ ] Log recovery drills: Trash restore, encrypted archive preview/restore, and one offline-to-online sync recovery.
- [ ] At week four, compare Product Health to baseline; do not substitute usage time or feature count for the evidence criteria.

## Physical-device capability matrix

- [ ] Signed install with configured Developer Team and private CloudKit container.
- [ ] Camera and photo import.
- [ ] File import.
- [ ] Audio record and playback.
- [ ] Generic lock-screen notifications with no learning content.
- [ ] Dedicated Calendar disclosure, preview, write, retry, and reconciliation.
- [ ] Airplane-mode Session and Proof writes followed by queued recovery.
- [ ] Account-space Copy, Move, and Keep Local without automatic merge or deletion.
- [ ] Face ID / device-owner App Lock and background privacy cover.
- [ ] Password-protected export, wrong-password rejection, clean import, and attachment opening.
- [ ] Same-account second-device or clean-reinstall restoration.
