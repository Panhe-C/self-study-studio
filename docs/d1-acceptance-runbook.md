# D1 Cross-Surface Acceptance and Release Gate

This runbook separates deterministic package evidence from Apple and human gates. It does not
turn Simulator, fake CloudKit, static checks, or browser-independent Node tests into physical
device, live CloudKit, EventKit, visual, or VoiceOver acceptance.

## One copy-safe command

From the repository root:

```bash
node scripts/d1-release-check.mjs --report /tmp/self-study-studio-d1-report.json
```

The command runs Swift tests/build, the unsigned iOS Simulator build, Web build/tests, lint,
TypeScript checking, `git diff --check`, and source manifests for the canonical contract,
migrations, CloudKit mapper, Web reader/projector/writer, recoverable drafts, and conflict
resolution seams. The Swift source manifest also compares every Package production Swift file
with the app target and fails if a test file enters the app target. It writes a versioned JSON
report without recording environment credentials.

Use `--json` for JSON on stdout. `--allow-blocked` is useful when collecting a report in an
environment that cannot run a manual gate; it does not change any gate from `BLOCKED` or
`NOT_RUN` to `PASS`.

The process exits non-zero when an automated check fails or a release gate remains blocked.
Known baseline TypeScript ambient errors (`worker/index.ts` missing `Fetcher` and `D1Database`)
are reported as `PASS_KNOWN_BASELINE`, not hidden.

## Scenario map

| # | Deterministic automated evidence | Live/manual gate |
|---:|---|---|
| 1 | `CoursePlanningEndToEndTests`; Web atomic plan-activation writer test | Signed iPhone/Web against one provisioned CloudKit zone |
| 2 | `TodayAgendaServiceTests`; `PracticeBlocksTests` | Physical Today Agenda with same-owner records |
| 3 | `PracticeTimerEndToEndTests`; `PracticeTimerRuntimeTests` | Physical Guided Routine Player, pause/skip/reorder/revisit and relaunch |
| 4 | Swift `CloudRecordMapperTests`; Web reader/projector test | Real Practice Summary/Proof and asset download in Web Project Workspace |
| 5 | `TodayAgendaServiceTests.testMissedPlannedSessionBecomesCarryoverWithoutMovingItsWindow` | Physical carryover actions and cross-surface refresh |
| 6 | `PlanningWindowCapacityServiceTests`; plan activation tests | Real availability/time zone and acknowledged activation |
| 7 | `StageReviewServiceTests`; `EvidenceFirstDomainTests` | Authenticated same-owner Review/Proof flow |
| 8 | Stage Review atomic/idempotency and Trail tests | Live guarded publication and one cross-surface decision |
| 9 | Swift `SyncMergeServiceTests`; Web merge/conflict tests | Two live writers, conflict UI choose/combine, no silent overwrite |
| 10 | Plan lifecycle guards, stale Review guard, Web stale-write test | Real CloudKit change tags and stale replay |
| 11 | Project status migration, archive/restore, convergence migration tests | Legacy production records, signed app, attachment restore |
| 12 | Product convergence acceptance and local-review-without-AI tests | Human manual loop with Support Service and all AI disabled |

The JSON report repeats this map with `PASS_LOCAL_AUTOMATED`, `BLOCKED`, or `NOT_RUN` statuses,
required inputs, and explicit caveats.

## Manual/live gates required before release

- A signed physical iPhone/iPad install with a selected Developer Team, iCloud/CloudKit and Push
  entitlements, and a trusted device.
- A provisioned development/production CloudKit schema and private zone, a Web API token, allowed
  Web origins, and the same Journal Owner on iPhone and Web.
- Two signed same-account devices (or a clean reinstall) for airplane-mode recovery, attachment
  download, and convergence.
- Full Calendar Access and a writable target calendar for EventKit preview/write/reconciliation.
- An interactive browser session for responsive visual inspection and VoiceOver/assistive
  technology checks.
- A human run with Support Service and every AI capability disabled.

Until these inputs exist, the release gate is intentionally `BLOCKED`; no report should claim
physical-device, live CloudKit, EventKit, browser visual, or VoiceOver acceptance.

## vNext acceptance (spec 2026-08-10, section 17)

The vNext guided-learning loop has deterministic, service-level automated evidence plus a
separate set of REQUIRED MANUAL gates. The automated evidence composes the real services
(`CoursePlanningService`, `CoursePlanDraftEditingService`, `PendingStudyCaptureStore`,
rule-based and adaptive providers, `LearningRecordService`, `LearningAdjustmentService`,
`TodayAgendaService`, `VNextTodayProjector`) over `InMemoryJournalRepository` and temp-dir
capture stores — no network, no CloudKit, no UI.

| # | Deterministic automated evidence | Manual gate (not covered by automation) |
|---|---|---|
| A | `VNextEndToEndTests.testScenarioANewCourseDraftHiddenFromTodayUntilActivatedThenExactlyOneUpNext` — draft invisible in Today; edit + single-phase regeneration leaves other phases untouched; activation yields exactly one Up Next | iPhone plan wizard walkthrough (edit, regenerate, activate) |
| B | `VNextEndToEndTests.testScenarioBConfirmPublishesSessionAssessmentPlannedCompletionAndTrailInOneCommit` — ending the timer writes nothing; the check has no preselected answers; confirm publishes Session + assessment + planned completion + Trail in ONE commit | Physical-device guided study flow with a real timer |
| C | `VNextEndToEndTests.testScenarioCSaveForLaterSurvivesStoreRecreationAndStaysOutOfJournalUntilConfirm` — a fresh store instance recovers the saved-for-later capture; Today recovery card surfaces it; no journal session before confirm | System kill (jetsam/swipe-away) recovery of a pending capture on a physical device |
| D | `VNextEndToEndTests.testScenarioDAmendBumpsRevisionKeepsSnapshotAndLeavesPlanUntouched` — amend produces revision 2, keeps an immutable revision-1 snapshot, and never rewrites plan revisions | iPhone record-detail correction flow |
| E | `VNextEndToEndTests.testScenarioEDetectAdoptNextStepAndStructuralRevisionLifecycle` — repeated-partial detection, one-commit adopt, structural v2 draft with v1 active, archived v1 still readable after activation | iPhone adjustment suggestion UI (adopt / modify / ignore) |
| F | `VNextEndToEndTests.testScenarioFUnconfiguredAIStillCompletesLoopAndManualPlanAppearsInToday` — unconfigured adaptive providers fall back to rule-based drafts and complete the loop; a fully manual plan activates and appears in Today | Device run with AI unconfigured AND against a failing provider endpoint; airplane-mode confirm |
| Legacy | `VNextEndToEndTests.testLegacySnapshotDecodesLosslesslyWithoutFabricatedAssessments` — legacy Sessions/Plans/Phases/PlannedSessions decode losslessly; no assessment is fabricated | Import of a real pre-vNext `journal.json` on device |

### vNext manual gates required before release

None of the following is covered by automation; each must be run and recorded separately:

- A signed physical iPhone install running the full CS336 flow (plan, study, confirm, amend, adjust).
- Live CloudKit two-device convergence of confirmed records, record revisions, and adjustment
  suggestions.
- Pending-capture recovery after a real system kill on a physical device.
- Local notification delivery for pending captures and the deep link into the pending
  confirmation.
- Image, audio, and file attachments staged in the guided flow, including download and preview
  after sync.
- Maximum Dynamic Type pass over Today, the study flow, and the record draft screens.
- VoiceOver pass over Today, the completion check, the record draft, and plan review.
- AI-unconfigured and provider-failure runs on device, including airplane mode.

The JSON report carries these as `vnext.scenarios` and `vnext.manualGates` with `BLOCKED` /
`NOT_RUN` statuses. Simulator runs and unit tests must never be presented as device or CloudKit
acceptance.
