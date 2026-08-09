# Personal Learning Journal

Personal Learning Journal is a SwiftUI-first, evidence-first learning system. A Project becomes active only with a Goal, one canonical Next Step, and an Evidence Contract; progress is established through qualifying Proof and explicit Review Decisions.

## Product Documentation

- [产品功能演示页（单文件 HTML）](docs/product-guide/self-study-studio-product-tour.html)
- [产品功能手册](docs/PRODUCT_GUIDE.md)
- [Web Workspace MVP 产品规格](docs/web-workspace-mvp-spec.md)
- [跨端迁移路线图](docs/cross-surface-migration-roadmap.md)
- [领域语言与实现状态](CONTEXT.md)
- [Canva 可导入演示稿](docs/product-guide/self-study-studio-product-deck.pptx)
- [Canva 可导入 A4 手册](docs/product-guide/self-study-studio-product-guide-a4.pdf)
- [产品功能说明图](diagrams/PRODUCT_FUNCTION_DIAGRAMS.md)
- [产品功能手册设计](docs/superpowers/specs/2026-07-12-product-guide-design.md)

When user-visible behavior changes, update the affected diagram source and regenerate its SVG and PNG exports.

The current implementation focuses on the first product loop:

```text
Continue today -> record in 30 seconds -> attach Proof -> review the week
```

## What Is Implemented

The list below describes the shipped iPhone model and the current Web Workspace boundary. Today
Agenda, Carryover, immutable plan revisions, Practice Blocks, Planning Window, Stage Review
readiness, and Qualifying Proof are implemented in the package and surfaced from Today/Project
flows. The Web Workspace has explicit Demo and Real modes plus typed C2 guarded writes, conflict
review, and recoverable drafts. Local tests and mappings pass; live CloudKit and device convergence
remain separate D1 release gates.

- Two-step onboarding for 1-3 current projects with `name`, `area`, `goal`, one `Next Step`, and a required first Session before Today opens
- Project creation after onboarding, plus edit and status changes
- Today continue cards for active projects with a clear next step, latest Session, and latest Proof context
- Deterministic Today Agenda combining due/overdue planned sessions, recurring practice, and one Next Step per active Project
- Carryover cards that show the original planning window and offer Do Today, individual Reschedule, Skip, or Revise Plan
- Individual carryover rescheduling updates only the selected PlannedSession, records a schedule-change Trail event, and keeps Revise Plan as the structural revision flow
- Review prompts for active projects that have gone quiet for 7 days or when recent evidence is ready to review
- Quick Log sessions with project defaults, presets, custom duration stepping, and first-onboarding completion
- Timer sessions with pause, resume, end, discard, and a live active-duration display
- Recurring practice routines with weekday schedules, upward timing, local crash recovery, optional project association, synced completed sessions, and Today/week/all-time totals; Practice Blocks remain separate from Learning Plan completion
- Proof creation with a required "What does this prove?" statement
- Proof entry points from Project, Session, Quick Log, Timer, and Library
- Photo Proof from camera or photo library, audio recording, file import, and links
- Proof detail screens: image preview, local audio playback, Quick Look file preview, and link opening
- Project Learning Trail events for sessions, Proofs, Next Step changes, status changes, and reviews
- Project-scoped Stage Review readiness and explicit draft-to-published decisions anchored to a Plan Phase
- Qualifying Proof acceptance linked to an Evidence Contract, Proof Revision, Review Decision, and phase transition
- Stage Review `extendPhase`/`revisePhase` decisions create guarded Plan Revision Drafts; missing Proof blocks phase advancement
- Project lifecycle transitions: `idea`, `active`, `paused`, `completed`, `abandoned`, with separate archive/Trash recovery and permanent deletion actions
- Project detail actions for Start, Quick Log, Proof, Learning Trail, and historical Reviews
- Async Weekly Review through an `AIReviewProvider` abstraction
- OpenAI-compatible Chat Completions provider configurable in the app; endpoint/model live in preferences and API keys live in Keychain
- Rule-based review fallback that outputs Facts, Patterns, Decisions, and Next Steps when no provider is configured or available
- Editable Review results with source references under generated insights and explicit actions to apply suggested project status or Next Step
- Manual and AI-assisted course planning from a Project, with course outline, goal, expected outcome, dates, weekly budget, phases, expected Proof, and concrete study sessions
- An editable four-step plan draft flow: AI output is validated locally and stays a draft until the user explicitly activates it; revisions preserve prior plans as history
- Active-plan sessions appear in Today when due or overdue; Start and Quick Log carry planned-session context so the resulting learning record atomically completes the planned session, while Proof stays linked to the actual record
- Weekly Review includes active-plan revision, phase, completion, missed-deadline, and expected-Proof summaries with plan/phase/session source references
- AI course planning uses the existing endpoint/model/key configuration; it sends only the course input and summarized learning context, never Calendar event content, contacts, or location data
- Four primary tabs: Today, Projects, Calendar, and Library
- Day, Week, and Month study calendars with fixed timeline geometry, workload totals, deadlines, unscheduled work, and conflict markers
- Deterministic study scheduling from availability, preferred duration, daily limit, minimum gap, weekend policy, deadlines, pinned sessions, and privacy-stripped busy intervals
- Editable schedule drafts with pin, move, resize, remove, conflict, and unscheduled states before any system Calendar write
- EventKit integration behind an explicit permission action and target-calendar selection; the app never requests Calendar access at launch
- Exact create/update/delete previews and a second explicit confirmation before EventKit writes, with per-item failure and retry handling
- External Calendar edit/delete reconciliation with Adopt, Overwrite/Recreate, and Detach decisions
- Calendar event identifiers and last-written snapshots remain local-only; synced availability never contains event titles, notes, attendees, locations, URLs, or raw events
- Normalized SwiftData runtime store for Projects, Sessions, Proofs, Reviews, Trail events, and onboarding state; one-time import from legacy `journal.json`
- JSON export plus attachment directory export from Library
- SwiftUI screens for onboarding, Today, Projects, Learning Plan, Stage Review, Library, Quick Log, Timer, Review, Proof detail, and AI Review settings
- Private personal iCloud sync with account-scoped journal stores, local-first attachments, a retryable outbox, conflict review, automatic upload after local edits, foreground refresh, and a visible iCloud status surface
- Evidence-first Project activation, accepted Proof revisions, explicit Review Decisions, deterministic Today recommendations, and measurable Product Health
- Password-protected AES.GCM archive export/import with SHA-256 integrity checks, stable-ID preview, recoverable Trash, 30-day retention candidates, and explicit purge impact
- Account-space transfer previews with Copy, Move, and Keep Local choices; account switching never automatically merges or deletes another space
- Optional device-owner App Lock with a foreground unlock gate and background privacy cover
- English and Simplified Chinese resources for the core evidence loop

## Current Shape

This repository provides both a Swift Package and a minimal iOS app project:

- Library target: `PersonalLearningJournal`
- Test target: `PersonalLearningJournalTests`
- iOS app project: `SelfStudyStudio.xcodeproj`
- iOS app target: `SelfStudyStudio`

The Xcode app target compiles the same SwiftUI app core and includes generated Info.plist permission strings for camera, photo library, microphone, Calendar full access, and document sharing.

Learning Plan activation and Calendar writing have separate confirmation boundaries. Activating a
Learning Plan creates only internal planned sessions. Scheduling creates only an editable
`ScheduleDraft`. Reviewing changes still performs no EventKit writes. The app writes only after
`Confirm Calendar Changes` is tapped.

The internal Calendar remains usable without iCloud, AI configuration, network access, or Calendar permission. CloudKit keeps retryable local mutations queued; AI failures fall back to local/manual planning or review paths; denied Calendar access disables busy-time reading and EventKit writes without blocking local scheduling and learning records.

## Verify

Run the test suite:

```bash
swift test
```

Build the package:

```bash
swift build
```

Run the cross-surface D1 release gate and write a machine-readable report:

```bash
node scripts/d1-release-check.mjs --report /tmp/self-study-studio-d1-report.json
```

The report maps all twelve Web Workspace MVP acceptance scenarios to deterministic Swift/Web
evidence and keeps physical-device, live CloudKit schema/token/origin, EventKit, browser visual,
and VoiceOver gates explicitly `BLOCKED` or `NOT_RUN`. See
[`docs/d1-acceptance-runbook.md`](docs/d1-acceptance-runbook.md).

Build the iOS Simulator app target:

```bash
xcodebuild -project SelfStudyStudio.xcodeproj -target SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Current verification status:

- 2026-08-09: `swift test` completed 446 tests with 0 failures, and `swift build` completed successfully. Stage Review readiness/publication, Qualifying Proof linkage, guarded Plan Revision Drafts, and shared Web contract fixtures are covered by targeted tests; the day-scoped agenda-position override is intentionally in-memory/local-only and is not synced.
- 2026-08-09: The package build and tests do not establish iPhone Dynamic Type/layout, physical-device behavior, or live CloudKit/iCloud convergence. Those remain separate device and Cloud acceptance gates.
- 2026-07-15: evidence-first convergence completed `swift test` with 260 tests and 0 failures; `swift build` and the unsigned iOS Simulator build succeeded. A clean iPhone 16 Pro Simulator install launched into onboarding. See `docs/product-health-validation.md` for the requirement audit and the separate physical-device gate.
- 2026-07-10: `swift test` completed 49 tests with 0 failures.
- 2026-07-10: `swift build` completed successfully.
- 2026-07-10: `xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build` completed successfully.
- 2026-07-10: the app installed and launched on an iPhone 16 Pro Simulator. Existing `journal.json` data appeared in Today after startup, while `journal.store` and its SQLite sidecars were created alongside the untouched legacy JSON file.
- 2026-07-12: `swift test` completed 105 tests with 0 failures, and the iOS Simulator build completed successfully after adding course planning.
- 2026-07-12: `swift test` completed 132 tests with 0 failures after adding deterministic scheduling, EventKit confirmation/reconciliation, Calendar views, settings, and the full course-to-review integration test.
- 2026-07-12: `swift build` and the iOS Simulator app build completed successfully with the Calendar module integrated.
- 2026-07-13: `swift test` completed 199 tests with 0 failures, and a clean iPhone 16 Pro Simulator build installed and launched successfully after adding recurring practice routines and the recoverable practice timer.
- 2026-07-14: `swift test` completed 207 tests with 0 failures; `swift build` and the unsigned iOS Simulator build also succeeded after adding automatic post-mutation sync, foreground refresh, and concurrent-sync coalescing.

## iCloud Device Acceptance

Before testing on devices, select an Apple Developer Team for `SelfStudyStudio`, create and associate the `iCloud.com.local.selfstudystudio` container, then enable iCloud/CloudKit and Push Notifications for the app identifier. Promote the development CloudKit schema before distributing a release build.

For a two-device test, sign both devices into the same Apple Account, install signed development builds, and create a learning record on each device. Verify that records made while airplane mode is enabled remain queued, upload once connectivity returns, and become visible on the other device. Attach one image, audio file, and document, then verify every downloaded attachment opens after synchronization. Finally, sign out of iCloud or switch accounts on one device and confirm the app keeps the accounts in separate local stores; exports must continue to omit account identifiers, CloudKit metadata, queued mutations, conflicts, and Calendar bindings.

For Calendar acceptance, grant Full Access only from Calendar Settings, select a writable target calendar, and confirm that busy-time scheduling uses only interval boundaries. Review the exact change list before confirming writes. Then move and delete linked events in Apple Calendar and verify the app offers Adopt, Overwrite/Recreate, or Detach without acting automatically. Change the scheduling time zone and confirm it creates a new draft while existing EventKit events remain unchanged until the normal preview and confirmation flow.

The final device matrix should cover same-account two-device convergence, attachment download, airplane-mode recovery, confirmed EventKit create/update/delete, partial write retry, external edits and deletion, denied permission, time-zone changes, AI-assisted planning, and AI fallback. Physical-device results depend on a provisioned Developer Team, iCloud container, CloudKit schema, Push Notifications entitlement, signed installation, network access, and a writable device Calendar; simulator success does not prove those device-only capabilities.

## Not In v0.1

Per the PRD, these are intentionally not implemented yet:

- Social features
- Rankings or streak pressure
- Course marketplace
- Complete Pomodoro system
- Full autonomous learning agent
- Search
- Desktop app

The Web Workspace is no longer excluded. `WebWorkspace/` contains a Next.js implementation of
the Dashboard, Project Workspace, Plan, Practice, Proof, Learning Trail, Review Inbox, and
CloudKit-backed Real Journal projection with typed guarded writes, Sync & Conflicts, and
recoverable drafts; Demo mode remains explicit and no Real-mode read silently falls back to
fixtures. See
[跨端迁移路线图](docs/cross-surface-migration-roadmap.md) for the accepted sequence that connects
it to the real Journal.
