# Cross-Surface Migration Roadmap

Status: B5 iOS slice complete; B6 is next

Product decisions: `docs/adr/0001` through `docs/adr/0033`
Target domain language: `CONTEXT.md`
Target product spec: `docs/web-workspace-mvp-spec.md`

## Why this document exists

The product decisions for the iPhone + Web personal learning system are accepted, but the
code has not followed all of them yet. The iOS app now uses the canonical Learning Plan
domain (with a compatibility `CoursePlan` alias), while it still has the pre-decision model
(flat `PracticeRoutine`, seven `ProjectStatus` values, a Primary/Alternatives
recommendation split, Weekly-Review-only reflection). The Web Workspace renders the target
information architecture from two hardcoded demo Projects and reads CloudKit only for
diagnostics.

None of the twelve acceptance scenarios in `docs/web-workspace-mvp-spec.md` §12 can pass
today, because the two surfaces do not yet share one domain model. This roadmap splits that
gap into milestones that can each be verified on their own, so the app stays usable
throughout and no milestone depends on a later one to be meaningful.

## Sequencing principles

1. **Never break the shipped loop.** Every milestone ends with `swift test`, the unsigned iOS
   Simulator build, and `npm test` in `WebWorkspace` all green, and with the iPhone app still
   fully usable. No milestone may leave the app in a half-migrated state across a release.
2. **Migrate data before renaming behavior.** Records already exist in CloudKit and in local
   stores. Each model change reuses the established `ProductConvergenceMigration` pattern:
   dry run, explicit resolution of ambiguity, backup, execute, validate. Never silently pick
   a value on the learner's behalf.
3. **One shared contract before any second writer.** The Web Workspace must not write
   canonical records until one versioned record contract and fixture suite is enforced on both
   the Swift and TypeScript sides.
4. **iOS leads, Web follows.** Web reads real records only after the model it expects exists in
   the Journal; Web writes only after conflict and revision guards exist.
5. **Cheapest disambiguation first.** Milestones that mostly remove confusion (documentation,
   status collapse) come before milestones that add structure (Practice Blocks, Stage Review).

## Milestone overview

| # | Milestone | Surface | Size | Depends on |
| --- | --- | --- | --- | --- |
| A1 | Align documentation with reality | Docs | S | — |
| A2 | Versioned record contract and shared fixtures | Both | M | A1 |
| B1 | Collapse Project Status to four values | iOS | M | A2 |
| B2 | Learning Plan rename and explicit Plan Revisions | iOS | L | A2 |
| B3 | Practice Blocks, Focus, and Segments | iOS | L | A2 |
| B4 | Today Agenda, Carryover, and Daily Override | iOS | M | B2, B3 |
| B5 | Planning Windows and Capacity Check | iOS | M | B2 |
| B6 | Stage Review and Qualifying Proof | iOS | L | B1, B2 |
| C1 | Web reads the real Journal | Web | M | A2, B1–B3 |
| C2 | Web writes with revision guards and a conflict workspace | Web | L | C1, B2, B6 |
| D1 | Cross-surface acceptance suite and device gate | Both | M | C2, B4, B5 |

Sizes are relative effort, not calendar estimates.

---

## Phase A — Foundations

### A1. Align documentation with reality

**Problem.** The documents now contradict each other and the code, which makes every later
decision more expensive to reason about.

- `README.md` lists "Desktop or web app" under "Not In v0.1" while `WebWorkspace` exists and
  passes 39 tests.
- `docs/PRODUCT_GUIDE.md` (v1.0, last checked 2026-07-13) says the app has three main entries
  and that Calendar is not in navigation, but `Sources/PersonalLearningJournal/Views/RootView.swift`
  mounts four tabs including Calendar. Its verification baseline (49 of 50 tests) is far behind
  the 260-test baseline recorded in `README.md`.
- `CONTEXT.md` defines target language with no indication of what is implemented, so its terms
  read as if they already exist in code.

**Work.** Correct the two stale claims in `README.md` and `docs/PRODUCT_GUIDE.md`. Add an
implementation-status marker to every `CONTEXT.md` term (shipped / partial / planned). Commit
the currently untracked `docs/adr/`, `docs/web-workspace-mvp-spec.md`, `CONTEXT.md`, and app
icon assets. Push the 17 unpushed commits.

**Independent verification.** A reader can determine, from `CONTEXT.md` alone, which terms
exist in code today. No document states a navigation structure, scope boundary, or test
baseline that contradicts the repository.

**Risk.** None to runtime behavior.

**Status.** Completed 2026-08-08. The stale claims in `README.md` and `docs/PRODUCT_GUIDE.md`
were corrected, every `CONTEXT.md` term carries a `[shipped]` / `[partial]` / `[planned]`
marker, and `docs/adr/`, `docs/web-workspace-mvp-spec.md`, `CONTEXT.md`, and the app icon
assets (`App/Assets.xcassets`, `docs/assets/self-study-studio-icon-1024.png`, and
`scripts/generate-app-icon.py`) are now tracked, with the AppIcon asset catalog wired into
`SelfStudyStudio.xcodeproj`. Verification on the A1 commit: `swift test` 261 tests / 0
failures, `npm test` in `WebWorkspace` 39 tests / 0 failures, the unsigned iOS Simulator
build succeeded, and `git diff --check` is clean. The 17 commits that predate A1 were pushed
on 2026-08-08; A2 remains the next milestone and is not completed by this roadmap update.

### A2. Versioned record contract and shared fixtures

**Problem.** `docs/web-workspace-mvp-spec.md` §9 requires canonical record contracts and
validation rules to stay equivalent between Swift and TypeScript. Today the Swift side owns
validation inside each domain type's `validated()`, and the Web side has an unrelated demo
shape in `WebWorkspace/lib/journal.ts`. There is no way to detect divergence.

**Work.** Define one versioned contract per record kind covering field names, optionality,
enum values, and validation rules, plus a fixture suite of valid and invalid payloads. Enforce
it from Swift tests against `JournalEntity` encoding and from Node tests against the Web
decoders. Keep `JournalRecordKind` as the enumeration of record kinds so CloudKit record types
stay stable.

**Independent verification.** The same fixture files produce the same accept/reject outcome and
the same normalized values in both languages. Adding a field on one side without updating the
contract fails a test.

**Risk.** Low. Additive; no stored-data change. This milestone pays for itself immediately
because every later model change lands in one place and is checked on both sides.

**Status.** Completed 2026-08-08. The versioned shared Journal record contract is enforced
strictly on both surfaces, with 269 Swift tests / 0 failures and 48 Web tests / 0 failures;
the Swift contract fixtures, Web decoders, and Xcode wiring are tracked and validated. The
unsigned iOS Simulator build and `git diff --check` are clean. A2 is complete; execution now
starts at B1.

---

## Phase B — Converge the iOS domain model

Each Phase B milestone follows the same shape: extend the contract from A2, write a migration
with a dry run and explicit resolution of ambiguity, update the domain types and services,
then update the SwiftUI surfaces.

### B1. Collapse Project Status to four values

**Current.** `ProjectStatus` has seven cases: `idea`, `active`, `lowFrequency`, `paused`,
`archived`, `completed`, `trash`. The committed lifecycle is exactly `Active`, `Paused`,
`Completed`, `Abandoned`, with a Project Archive view and Permanent Deletion as a separate
destructive flow (`docs/adr/0030`).

**Accepted mapping.**

| Existing value | Target | Basis |
| --- | --- | --- |
| `idea` | stays `idea` | `docs/adr/0032`: pre-commitment is a real state outside the committed lifecycle |
| `active` | `Active` | direct |
| `lowFrequency` | `Active` | `docs/adr/0033`: low frequency becomes cadence and Review Decisions |
| `paused` | `Paused` | direct |
| `completed` | `Completed` | direct |
| `archived` | `Paused` / `Completed` / `Abandoned` | ambiguous; resolved per record by the learner |
| `trash` | not a lifecycle value | already carries `previousStatusBeforeTrash`; belongs to deletion |

**Work.** Extend the committed lifecycle to the four accepted values while keeping `idea`
outside it, and update `Project.commitmentState`, `ProductHealthService`, and
`ProductConvergenceMigration` where they currently pair `.active` with `.lowFrequency`. Change
`ReviewService`, which today recommends `.lowFrequency` as an outcome, to recommend reducing
cadence or planned load instead. Route every `archived` record through the existing
`MigrationReviewView` for an explicit per-record decision; never infer Completed from evidence
automatically. Move `trash` out of `ProjectStatus` into the deletion flow, preserving the
existing restore-to-previous-status behavior. Add the Archive view and separate Permanent
Deletion with dependency disclosure, confirmation, and an export opportunity.

**Independent verification.** A store containing all seven old values migrates with zero
records losing their historical meaning, and every `archived` record required an explicit
learner decision. An `idea` Project still never reaches the Today Agenda or the attention
budget. A previously `lowFrequency` Project remains visible as Active. Restoring from Trash
still returns the Project to its prior status. Archived Projects retain Plans, Practice, Proof,
Trail, and Reviews. Permanent Deletion is unreachable without passing through impact
disclosure.

**Risk.** Medium — this is the first milestone that rewrites existing user records. The
`archived` split cannot be automated, so migration is interactive by design.

**Status.** Completed 2026-08-09. Canonical Project lifecycle values, legacy decoding,
explicit archived-status resolution, Trash markers, startup migration gating, Archive and
Permanent Deletion flows, cadence-based Review outcomes, Product Health eligibility, CloudKit
mapping, and the shared v1 contract/fixtures are implemented. The review hardening also adds
atomic migration markers and first-backup preservation, fail-closed startup retry, observable
project-scoped Trash export, retryable local attachment cleanup with legacy-queue recovery,
explicitly confirmed orphan cleanup, corrupt/unsafe-legacy queue quarantine with shareable recovery artifacts,
strict canonical transport rejection, and dependency-safe permanent deletion. Unencrypted Trash
exports require an explicit trusted-location confirmation. B1 baseline verification: `swift test`
330 tests / 0 failures, `npm test` in `WebWorkspace` 48 tests / 0 failures, `npm run lint`, `swift build`,
unsigned iOS Simulator build, and `git diff --check` all pass. B2 is implemented below.

### B2. Learning Plan rename and explicit Plan Revisions

**Status.** Completed 2026-08-09. `LearningPlan` is canonical in the domain and UI while
`CoursePlan`/`coursePlan`/`CoursePlan` CloudKit records remain read/write compatibility aliases.
`PlanRevision` and `PlanRevisionDraft` now preserve immutable structural snapshots, stable
series/revision identities, and queryable superseded history. `RevisionGuard` validates the
base revision and caller-supplied CloudKit change tag before activation. The adjustment UI
captures that expectation when it opens, pending mutations freeze it with their transaction,
and grouped stale writes become terminal without blocking unrelated transactions. Terminal
mutations are persisted for manual recovery and excluded from automatic retries; same-record
draft/activation writes coalesce to the latest payload before grouping.

**Implemented.** User-visible plan language is Learning Plan across Wizard, Detail, Today,
Projects, Review/Calendar consumers, with an explicit `Adjust Plan` entry. Structural edits
create a draft linked by `baseRevisionID`/`supersedesID`; completing or rescheduling a planned
session remains a direct execution update. Cloud pushes use conditional writes with atomic
custom-zone batches, preserve server change tags on pull, and map stale writes without LWW.
The idempotent migration performs dry-run, backup, stable-series mapping, active-revision
validation, and rollback-safe persistence. Ambiguous multiple-active projects stop at an
explicit survivor-selection review; unresolved choices never execute. Published plan/phase
structure is immutable in sync merges while planned-session execution fields remain mergeable,
and historical revisions open with their phases, planned sessions, and linked proof.
Revision-scoped Practice Routine snapshots carry the same series/revision identity and lock on
activation; legacy project-owned routines are bound to the surviving published revision during
migration, while B3 still owns Blocks and cadence redesign.

**Independent verification.** Existing `coursePlan` records load and display under the new
language with no data loss. Activating a draft built from stale state fails and does not
overwrite the newer revision. Superseded revisions remain readable and explain historical
decisions.

Verification: `swift test` (357 tests / 0 failures), `swift build`, Web `npm test` (48 tests / 0
failures), `npm run lint`, and `git diff --check` pass. The unsigned iOS simulator build reaches
asset compilation but this machine has no available simulator runtime; local and fake-client
Revision Guard paths are verified, while real CloudKit conditional-write behavior and
physical-device acceptance remain outside this local verification.

**Risk.** Medium-high. Touches planning, scheduling, and the Calendar draft pipeline. Keep the
existing EventKit preview and confirmation boundary untouched.

### B3. Practice Blocks, Focus, and Segments

**Status (2026-08-09, complete for the iOS slice).** The domain/contract and migration layers now
carry ordered Practice Blocks, optional Focus and Next Focus candidates, per-Block Segments and
Summaries, and a dry-run/backup/idempotent explicit merge-or-archive migration. The Guided Routine
Player, durable runtime recovery, one-operational-Routine service guard, authoring UI, and B1/B2/B3
startup gate are wired.

**Current.** PracticeTimerRuntime persists the ordered blocks, current Block, active segments,
skip state, and a recoverable pending completion. Pause time is excluded; direct selection, skip,
extension, and revisits remain attributable to one session. Finish writes the base Practice Session,
segments, observed Block/Focus snapshot, and summary in one repository transaction before optional
reflection. Note and Attention Marker are guarded updates to that same session; leaving reflection
only clears the local draft. Existing flat timers recover as one stable Block with recovered active
time; corrupt or impossible state fails closed.
Published plan revisions keep their routine structure locked and require a new revision. Web
remains history/configuration only for practice timing.

**Remaining work.** Proof attachment is an explicit follow-up and is not part of the finish flow.
Physical-device and real CloudKit acceptance remain separate release checks; Web timing/write parity
is intentionally out of B3.

**Independent verification.** Runtime tests cover pause/skip/revisit/relaunch, switch-boundary
accounting, and legacy active-time recovery. Service tests cover atomic save and the one-operational-
Routine guard; migration-gate tests cover backup/resolution sequencing and a clean flat-routine
startup. No Block rating is required to save. Full-suite, unsigned-simulator, physical-device, and
real CloudKit checks remain release evidence rather than being inferred from these static/runtime
tests.

**Risk.** High — the largest single model change, and the one the Web Practice view already
assumes. Local crash recovery must keep working for in-progress sessions across the migration.

### B4. Today Agenda, Carryover, and Daily Override

**Status (2026-08-09, complete for the iOS slice).** `TodayAgendaService` now derives a
deterministic projection from the canonical Journal snapshot. JournalViewModel and TodayView use
that projection as the single Today surface; Web remains a later read/write milestone.

**Current.** The Agenda combines executable Planned Sessions, scheduled operational Practice
Routine occurrences, and one selected Next Step per active Project. It marks the first item `Up
Next`, then `Later Today` or `Optional`, and exposes a local, day-scoped Daily Override without
persisting computed Agenda records. `TodayRecommendationService` remains available for older
callers but is no longer the Today presentation source.

**Delivered.** The three-section presentation is replaced by a derived Agenda whose Items are
presentations of existing Planned Sessions, Practice Routine occurrences, and selected Next
Steps, preserving each source's completion semantics. Daily Override (Up Next / Later Today /
Skip Today) changes only the in-memory day projection and stays out of the Learning Trail.
Carryover preserves the original timing and offers `Do Today`, `Reschedule`, `Skip`, or `Revise
Plan`; the latter two source actions use the existing Journal/Plan flows. Missed Practice
occurrences remain cadence signals and never become overdue task records. Overrides are currently
local to the running iOS process; durable preferences and Web parity are intentionally deferred
until their owning surface/storage contract is specified.

**Independent verification.** This is spec §12.5: a missed Planned Session becomes Carryover
with its original window unchanged. Applying a Daily Override produces no change to any source
record and no Trail event. Missed Practice is emitted as a cadence signal only, never as an
overdue task or fabricated completion. The Agenda stores nothing; deriving it twice from the same
Journal gives the same result. Targeted service tests cover deterministic composition, Carryover,
Daily Override immutability, cadence signals, and the explicit empty state. Full-suite, simulator,
physical-device, and real CloudKit checks remain separate release evidence.

**Risk.** Medium. Mostly a projection change, but it is the most visible daily surface, so
regressions are immediately felt.

### B5. Planning Windows and Capacity Check

**Current.** Deterministic scheduling from availability already exists, along with EventKit
confirmation and reconciliation. The iOS slice now persists an explicit `PlanningWindow`
(day, week, or date range) on draft and Planned Session records, while exact Calendar
Commitment remains an opt-in boundary (`docs/adr/0026`).

**Work completed (iOS).** `CapacityCheckService` compares estimated Planned Session and
operational Practice Cadence load against configured weekly `AvailabilityRule`s. It returns
stable week/project breakdowns, counts real calendar duration across DST transitions, and
does not warn when no availability has been stated. The wizard shows the warning and requires
an explicit acknowledgement; activation and reschedule remain deliberate and non-blocking,
with no automatic reductions, deferrals, completions, or Trail records. The planning window
is carried through the Swift Codable contract, CloudRecordMapper, and shared Swift/Web
contract fixtures; legacy payloads safely decode with a missing window.

**Independent verification.** Targeted `PlanningWindowCapacityServiceTests` (including a
spring-forward DST week), `CoursePlanningServiceTests` (acknowledged activation and
reschedule), Cloud/current+legacy round trips, shared-contract fixtures, full `swift test`,
and `WebWorkspace/npm test` cover the deterministic and non-blocking path. Calendar preview
still performs no EventKit write; only the existing second confirmation applies the change
set, and denied access or a missing target calendar remains recoverable.

**Release caveat.** These are source, unit, and unsigned-build checks. Physical iPhone
EventKit authorization, real calendar writes/reconciliation, and cross-surface CloudKit
convergence still require the D1 device/CloudKit acceptance gate.

**Risk.** Low-medium. Preserve the existing EventKit preview and second-confirmation boundary
exactly.

### B6. Stage Review and Qualifying Proof

**Current.** Only Weekly Review exists, with AI plus a rule-based fallback.
`EvidenceContract`, `EvidenceAcceptance`, `ProofRevision`, and `ReviewDecision` already provide
much of the foundation. Missing are the project-scoped, phase-anchored Stage Review
(`docs/adr/0003`), readiness detection that prompts but never auto-publishes
(`docs/adr/0009`), and the requirement that a Phase cannot complete without Qualifying Proof
(`docs/adr/0010`).

**Work.** Add Stage Review anchored to an ending Plan Phase, opened with deterministic
source-linked Review Facts (`docs/adr/0008`) and no AI in the manual path. Add Stage Review
Readiness detection. Make Qualifying Proof an explicit acceptance required to complete or
advance a Phase; without it, offer only extend, revise, pause, or abandon. Make `Publish
Review` pass the Revision Guard from B2 and atomically record the Review with its accepted
decisions, turning any structural Plan change into a Plan Revision Draft rather than an
in-place overwrite.

**Independent verification.** This is spec §12.7 and §12.8: a Stage Review cannot advance a
Phase without Qualifying Proof, and publishing with accepted Proof advances or revises the
Project exactly once while creating meaningful Trail events. Readiness never publishes on its
own. The whole flow completes with every AI capability disabled.

**Risk.** Medium-high. Atomicity matters: a partially applied publication would corrupt the
Trail's meaning.

---

## Phase C — Connect the Web Workspace

### C1. Web reads the real Journal

**Current.** `WebWorkspace/lib/journal.ts` exports two hardcoded demos (`guitarDemo`,
`cs336Demo`); `lib/dashboard.ts` derives the whole portfolio view from them. `lib/cloudkit.ts`
is deliberately read-only and only verifies authentication, private custom-zone access, record
types, and change tags.

**Work.** Replace the demo source with real records fetched through CloudKit JS, decoded
against the A2 contract. Keep the derivation modules unchanged where possible so the existing
39 tests keep their value; the demos become fixtures rather than the product data source. Ship
the visible sync state surface and record-zone change fetching. Complete the outstanding
CloudKit JS validations from spec §13: a dedicated Web API token with allowed origins, and
verified change-tag and asset download behavior.

**Independent verification.** A record created on iPhone appears in the Web Dashboard and
Project Workspace for the same Journal Owner in the same CloudKit environment, with no
application database in the path. Demo mode remains explicitly labeled and separable.

**Risk.** Medium. This is the first real dependency on Apple infrastructure from the browser
and the first place where a contract mismatch becomes user-visible.

### C2. Web writes with revision guards and a conflict workspace

**Work.** Enable browser writes for the operations Web owns: Learning Plan authoring and
activation, Plan Revision Drafts, Practice Routine design, Proof acceptance as Qualifying
Proof, and Stage Review publication. Implement optimistic concurrency through CloudKit record
change tags and the Revision Guard from B2 and B6. Implement Sync Merge for independently
created records and edits to different fields, and surface same-field or structural collisions
as Sync Conflicts with both values, their surface and timestamp, and affected dependent
records (`docs/adr/0014`). Add the Sync & Conflicts workspace with retry, refresh, choose, and
combine — and no hidden last-write-wins behind automatic retry. Add Recoverable Drafts that
survive transient connection loss but cannot become canonical offline (`docs/adr/0016`).

**Independent verification.** This is spec §12.9 and §12.10: different-field Web and iPhone
edits merge, a same-field edit appears as a resolvable Sync Conflict, and a stale activation or
publication fails without overwriting the newer revision. Conflict resolution appears in the
Audit Log while only the resulting decisions enter the Learning Trail.

**Risk.** High. Two independent writers against one private database. Do not start before A2
is enforced and B2/B6 guards exist.

---

## Phase D — Acceptance

### D1. Cross-surface acceptance suite and device gate

**Work.** Turn all twelve scenarios in spec §12 into automated cross-surface tests where
possible, and into a documented manual device matrix where Apple infrastructure is required.
Extend the existing iCloud and Calendar device acceptance in `README.md` with the Web
Workspace, and verify production CloudKit schema promotion and same-account iPhone/Web
convergence.

**Independent verification.** All twelve scenarios pass against one Journal Owner in one
CloudKit environment, including scenario 12: the manual loop remains fully usable with the
Support Service and every AI capability disabled. Update `docs/product-health-validation.md`
with the result.

**Risk.** Depends on a provisioned Developer Team, iCloud container, CloudKit schema, Push
Notifications entitlement, and signed installation. Simulator success does not prove these.

---

## Deliberately out of scope

Per `docs/adr/0031` and spec §10, the following stay out until the manual cross-surface loop is
complete: AI plan generation and Review suggestions on Web, background AI analysis, Shared
Snapshots and enhanced exports, collaboration and roles, complete offline Web editing,
Web-based practice timing, advanced predictive analytics, and any automatic Plan activation,
Phase advancement, or Calendar write.

## Open decisions

Resolved: the B1 status mapping is settled by `docs/adr/0032`, `docs/adr/0033`, and the mapping
table above. These remain open and are due when their milestone starts, not before:

1. **B2 (resolved):** keep the `coursePlan` JournalEntity kind and `CoursePlan` CloudKit
   record type as compatibility aliases indefinitely; only domain/UI terminology and canonical
   revision fields use Learning Plan.
2. **B3:** whether a Project with several existing Routines defaults to a merge proposal or an
   archive proposal in the resolution UI.
3. **C1:** attachment size and browser preview limits, given that canonical assets must not
   move to a second store.
4. **C2:** Recoverable Draft storage location, expiration, encryption expectations, and cleanup.
