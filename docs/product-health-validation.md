# Evidence-First Product Health Validation

Last updated: 2026-08-09

This record audits the convergence design against implementation evidence. The D1 release runner
(`scripts/d1-release-check.mjs`) now maps all twelve Web Workspace MVP scenarios to deterministic
Swift/Web evidence and emits a machine-readable report. Signed physical-device, live CloudKit,
EventKit, browser visual, VoiceOver, and second-device evidence remains a separate release gate
and is not inferred from Simulator, fake CloudKit, static, or browser-independent tests.

## Current gate status

| Gate | Result | Evidence |
|---|---|---|
| Complete automated suite | Pass (D1) | `swift test`: 446 tests, 0 failures |
| Package build | Pass (D1) | `swift build` |
| Unsigned iOS Simulator build | Pass (D1) | `xcodebuild ... -sdk iphonesimulator ... CODE_SIGNING_ALLOWED=NO build`; `BUILD SUCCEEDED` after app-target source parity repair |
| Clean install and launch | Historical Pass; D1 not run | The 2026-07-15 Simulator snapshot remains historical evidence; D1 does not infer install/launch from a build |
| End-to-end evidence loop | Pass (D1 package) | `ProductConvergenceAcceptanceTests` and the 446-test Swift suite cover Idea → Contract → Session → accepted Text Proof → Review Decision → Trash restore → encrypted archive restore → Product Health with no silent miss |
| Signed physical device | Pending | Requires the Task 14 capability matrix below |
| Second-space iCloud recovery | Pending | Requires a second Apple device or clean signed reinstall |
| D1 deterministic scenario map | Pass with known baseline | `/tmp/self-study-studio-d1-report.json` at commit `52f141dc9eaef4c2353f4cd11f3af96130197557`; 12/12 local scenario mappings pass, TypeScript ambient errors remain known baseline |
| D1 live cross-surface/device gate | Blocked | Requires the inputs in `docs/d1-acceptance-runbook.md` |

## D1 local dry run — 2026-08-09

Command:

```bash
node scripts/d1-release-check.mjs --allow-blocked --report /tmp/self-study-studio-d1-report.json
```

The report is intentionally kept in `/tmp` and is not a repository artifact. It records commit
`52f141dc9eaef4c2353f4cd11f3af96130197557`, exact durations, sanitized command tails, the twelve
scenario mappings, and the live-gate matrix. Automated summary: 10 checks, 9 `PASS`, 1
`PASS_KNOWN_BASELINE` (Web `worker/index.ts` lacks `Fetcher` and `D1Database`), 0 environment
blocks, and 0 failures. Swift completed 446 tests with 0 failures; Web completed 63 tests with
63 passes and 0 failures; app-target source parity is 92/92 production Swift files with no Tests
sources in the app target; the unsigned Simulator build succeeded. The release gate remains
`BLOCKED` because physical-device, live CloudKit schema/token/origin, EventKit, cross-device
attachments, browser visual/VoiceOver, and no-AI human gates are explicitly not run.

## Physical-device readiness inspection — 2026-07-15

- `xcrun xctrace list devices` reported only the development Mac plus Simulators; no physical iPhone or iPad was connected.
- `xcrun devicectl list devices` returned `No devices found`.
- Xcode uses automatic signing, but `DEVELOPMENT_TEAM` is empty and the current Bundle ID is the local placeholder `com.local.selfstudystudio`.
- `SelfStudyStudio.entitlements` declares the CloudKit container and `aps-environment` through build-setting placeholders; those placeholders have not been backed by a provisioned App ID/container in this checkout.
- A Debug `iphoneos` build stopped at signing with: `Signing for "SelfStudyStudio" requires a development team.`

Therefore the signed install, device capability matrix, second-space recovery, and four-week start remain blocked. To resume: connect and trust an iPhone, select the intended Apple Developer Team, replace/confirm the App ID and private CloudKit container, enable Push Notifications, then rerun the matrix without changing the automated acceptance baseline.

## Requirement audit

| Design requirement | Implementation | Automated or Simulator evidence |
|---|---|---|
| Product contract and canonical language | `Domain.swift`, `Projects/ProjectCommitment.swift`, evidence-first entities | `EvidenceFirstDomainTests`, acceptance test |
| Project lifecycle and attention budget | `JournalService`, commitment and migration services | `JournalServiceTests`, `ProductConvergenceMigrationTests` |
| Qualifying Proof semantics | `Evidence/ProofEvidence.swift`, `AddProofView`, `ProofPreview` | `ProofAttachmentDraftTests`, `ProofPreviewTests` |
| Text, Link, attachment, and revision behavior | `JournalService.reviseProof`, `ProofDetailView`, local attachment store | proof and attachment suites; revision assertions in `JournalServiceTests` |
| Default Library qualification and local search | `Search/ProofSearchIndex.swift`, `LibraryView` | `ProofSearchIndexTests` |
| Today Agenda, canonical Next Step, and cadence signals | `Recommendations/TodayAgendaService.swift`, `TodayView`, `JournalViewModel` | `TodayAgendaServiceTests`, `TodayRecommendationServiceTests`, `StudioPresentationTests` |
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
