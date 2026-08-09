# Web Workspace MVP Product Specification

Status: product decisions accepted; C1 reads and the C2 typed guarded-write/conflict/draft slice are implemented in `WebWorkspace/`; real CloudKit/device acceptance remains a release gate.

Decision record: `docs/adr/0001` through `docs/adr/0031`

Domain language: `CONTEXT.md`

## 1. Product outcome

The Web Workspace is the deliberate planning and reflection surface for the same Personal Learning Journal used by the iPhone App. Together they support one complete loop:

```text
Define an outcome
  -> activate a Learning Plan
  -> execute Planned Sessions and Practice Routines on iPhone
  -> capture Proof and Practice Summaries
  -> inspect the Learning Trail
  -> publish a Stage Review
  -> continue, revise, pause, complete, or abandon the Project
```

The Web Workspace is not an administrator console, a second database, a team workspace, or a replacement for in-the-moment iPhone execution.

## 2. Product principles

1. **One Journal:** Web and iPhone operate on the same private CloudKit records owned by one learner.
2. **Evidence before activity:** outcomes and accepted Proof establish progress; time and frequency are supporting signals.
3. **Draft before authority:** generated or edited plans and Reviews change canonical intent only after explicit activation or publication.
4. **Flexible execution:** targets, windows, and cadence guide behavior without turning learning into rigid compliance.
5. **Meaningful history:** published decisions and learning evidence enter the Learning Trail; incidental edits do not.
6. **No silent loss:** compatible device edits merge, real conflicts surface, and stale publication fails safely.
7. **Useful without AI:** the complete first loop works manually.

## 3. Cross-surface responsibilities

| Capability | Web Workspace | iPhone App |
| --- | --- | --- |
| Project and outcome design | Primary | Quick edits and status access |
| Learning Plan authoring | Primary | View and execute |
| Capacity and phase analysis | Primary | Summary only |
| Practice Routine design | Primary | View and execute |
| Practice timing | History only | Guided Routine Player |
| Quick learning records | View/edit | Primary |
| Camera, audio, and file Proof | Browse and review | Primary capture surface |
| Learning Trail exploration | Primary | Project-level recent history |
| Stage Review | Primary | Read and lightweight follow-up |
| Weekly Review | Global Web entry point | Existing mobile fallback may remain |
| Exact EventKit changes | Prepare intent only | Preview and explicit confirmation |
| Conflict resolution | Full conflict workspace | Status and lightweight resolution |

## 4. Information architecture

```text
Web Workspace
├── Dashboard
├── Projects
│   ├── Active
│   ├── Archive
│   └── Project Workspace
│       ├── Overview
│       ├── Plan
│       ├── Practice
│       ├── Proof
│       ├── Learning Trail
│       └── Reviews
├── Review Inbox
└── Sync & Conflicts
```

Global navigation stays small. Plan, Practice, Proof, Trail, and Stage Review are not separate global management systems; they are views inside a Project Workspace.

## 5. Core domain shape

```text
Journal Owner
└── Personal Learning Journal
    └── Project
        ├── Project Status
        ├── Learning Plan
        │   └── Plan Revision [one active]
        │       └── Plan Phase
        │           ├── Planned Session
        │           └── expected Proof
        ├── Practice Routine [at most one active]
        │   └── ordered Practice Block
        │       ├── one Practice Focus
        │       └── optional Next Focus candidates
        ├── Learning Session
        ├── Practice Session
        │   ├── Practice Segments
        │   └── Practice Summary
        ├── Proof
        ├── Learning Trail
        └── Stage Review
```

The Today Agenda is a derived projection over existing records. It is not another stored plan and does not erase the semantics of its Agenda Items.

## 6. Primary workflows

### 6.1 Create and activate a Learning Plan

1. Open a Project Workspace and choose `Create Plan`.
2. Define the desired outcome, target range, expected Proof, and weekly availability.
3. Add ordered Plan Phases.
4. Add Planned Sessions with estimated duration and a Planning Window.
5. Define one optional active Practice Routine with cadence and ordered Practice Blocks.
6. Give each Practice Block one current Practice Focus and optional Next Focus candidates.
7. Run the deterministic Capacity Check.
8. If overloaded, show the weeks and source Projects responsible; offer changes but do not apply them automatically.
9. Preview the resulting Plan Draft.
10. Activate it explicitly. Activation must pass a Revision Guard and write the related structural records atomically.

Structural changes later use `Adjust Plan`, producing a Plan Revision Draft. Activating it supersedes the earlier revision without erasing it. Completing sessions, attaching Proof, recording practice, and moving an individual date remain ordinary execution updates.

### 6.2 Build the Today Agenda

The system derives Agenda Items from:

- Planned Sessions inside or beyond their Planning Window;
- scheduled Practice Routine occurrences;
- selected canonical Next Steps.

The first item is `Up Next`; remaining items are presented as `Later Today` or `Optional`. The learner may apply a Daily Override to reorder or skip an item for that day. A Daily Override does not complete, reschedule, or revise its source.

A Planned Session whose window passes becomes Carryover. It preserves the original timing and offers `Do Today`, `Reschedule`, `Skip`, or `Revise Plan`. Missed Practice occurrences remain cadence signals and do not become overdue task records.

### 6.3 Run a composite Practice Session

The iPhone Guided Routine Player:

1. Starts the Practice Session once.
2. Presents one current Practice Block and its Practice Focus.
3. Attributes active time to that Block.
4. Prompts at the soft target without moving automatically.
5. Allows `Next`, `Skip`, direct Block selection, pause, revisit, and extension.
6. Excludes paused time and combines repeated visits to the same Block.
7. Finishes and saves once.
8. Automatically stores total time, per-Block time, skipped or extended targets, and the Focus used.
9. Offers an optional note, one Attention Marker, and optional Proof attachment after saving.

No Block or exercise rating is required to save the Practice Session.

### 6.4 Publish a Stage Review

Stage Review belongs to one Project and normally one ending Plan Phase.

1. The system marks the Review ready when the target range ends, Planned Sessions are resolved, expected Proof is available, or the learner requests it.
2. The Review opens with deterministic, source-linked Review Facts.
3. The learner inspects sessions, Practice Summaries, Carryover, Proof, and relevant Trail events.
4. Optional suggestions may be considered, but the manual flow is complete without AI.
5. The learner records Review Decisions.
6. Completing or advancing a Phase requires Qualifying Proof.
7. Without Qualifying Proof, available decisions are extend, revise, pause, or abandon.
8. `Publish Review` passes a Revision Guard and atomically records the Review and accepted decisions.
9. Any structural Plan change becomes a Plan Revision Draft rather than an in-place overwrite.

### 6.5 Resolve a cross-device conflict

1. Independently created records and edits to different fields merge automatically.
2. Same-field or structural collisions create a Sync Conflict.
3. The conflict view shows both values, their surface and timestamp, and affected dependent records.
4. The learner chooses one value or combines them.
5. Activation and publication never proceed from stale state; the user refreshes or resolves first.
6. Conflict resolution itself is retained in the Audit Log, while only resulting meaningful decisions appear in the Learning Trail.

## 7. Screen requirements

### 7.1 Sign in

- Authenticate the Journal Owner using the Apple/iCloud identity that owns the private CloudKit Journal.
- Do not create a separate application password or Web account.
- Explain that Web and iPhone use the same private records.
- Expose development versus production CloudKit environment clearly in non-production builds.

### 7.2 Dashboard

Prioritize:

- active Phase outcomes and expected Proof;
- Stage Reviews ready or approaching readiness;
- unresolved Carryover and Sync Conflicts;
- projects without recent meaningful activity;
- Practice Block imbalance and Attention Markers;
- capacity warnings for upcoming weeks.

Time, streaks, counts, and frequency are explanatory Progress Signals, not the headline definition of progress.

### 7.3 Projects

- Show Active Projects separately from the Project Archive.
- Support Active, Paused, Completed, and Abandoned statuses.
- Status changes preserve all history.
- Permanent Deletion is a separate flow with dependency disclosure, confirmation, and export opportunity.

### 7.4 Project Overview

- Outcome and Project Status.
- Active Phase and expected Proof.
- canonical Next Step and nearest Planned Session.
- current Practice Routine and Block balance.
- latest meaningful Proof and Review Decision.
- clear actions: `Adjust Plan`, `Review Phase`, `Add Proof`, and status change.

### 7.5 Plan

- Timeline of Plan Phases and their outcomes.
- Planned Sessions, windows, durations, resolution state, and Carryover.
- expected and Qualifying Proof.
- current Plan Revision and accessible superseded revisions.
- draft editor, Capacity Check, activation preview, and Revision Guard errors.

### 7.6 Practice

- One active Routine, cadence, overall soft target, and ordered Blocks.
- Current Focus and short Next Focus candidates per Block.
- history of total and per-Block time.
- imbalance, skipped Blocks, Attention Markers, and related Proof.
- configuration and analysis only; Web does not add a second practice timer in the MVP.

### 7.7 Proof

- Browse Proof associated with the Project, Phase, Planned Session, Learning Session, or Practice Session.
- Preserve the learner statement explaining what each item proves.
- Allow the learner to accept an item as Qualifying Proof in the appropriate Review flow.
- Raw attachment capture remains primarily on iPhone.

### 7.8 Learning Trail

Include sessions, Practice Summaries, Proof events, phase transitions, published Plan revisions, canonical Next Step changes, Published Reviews, and Project Status decisions. Exclude draft keystrokes, navigation, autosaves, Daily Overrides, and other operational noise.

### 7.9 Review Inbox

- Ready and draft Stage Reviews grouped by Project.
- Weekly Review entry point for cross-project reflection.
- Published review history stays available inside each Project Workspace.

### 7.10 Sync & Conflicts

- Current CloudKit account and sync state.
- pending and failed operations where applicable.
- explicit same-field and structural conflicts.
- retry, refresh, choose, and combine actions.
- no last-write-wins action hidden behind automatic retry.

## 8. Guitar example

Project: **Build confident foundational guitar playing**

Active Plan Phase: **Coordinate harmony knowledge and clean transitions**

Expected Proof:

- explain the I-IV-V relationship in two keys;
- record a clean chord-transition drill at the chosen tempo;
- record one complete verse with singing and accompaniment.

Practice Routine: **Foundational guitar practice**, four times per week, 30-minute total target.

| Practice Block | Soft target | Current Practice Focus | Example Next Focus |
| --- | ---: | --- | --- |
| Theory | 7 min | I-IV-V in G and C | Transpose to D |
| Finger technique | 10 min | clean G-C-D changes at 70 BPM | move to 80 BPM |
| Sing and play | 13 min | complete first verse without stopping | add chorus transition |

One actual Practice Summary might report 5, 12, and 16 minutes. It remains valid despite exceeding the 30-minute target and missing the suggested balance. The imbalance becomes a Progress Signal; it does not become failure. A recording can later become Qualifying Proof only when explicitly accepted in the Stage Review.

## 9. Data and service boundaries

- CloudKit private database remains the canonical store.
- CloudKit JS performs Direct Journal Access from the authenticated browser.
- No second application database stores canonical Journal data.
- Recoverable Drafts may be buffered locally during transient network loss but cannot activate or publish offline.
- A future Support Service may perform protected AI calls and render exports without becoming the Journal authority.
- CloudKit record change tags implement optimistic concurrency and Revision Guards.
- Canonical record contracts and validation rules must remain equivalent between Swift and Web implementations.
- EventKit identifiers and confirmation remain local to iPhone.

## 10. MVP scope

The first usable milestone includes:

- Apple/iCloud Journal Owner authentication;
- Direct Journal Access and visible sync state;
- Dashboard, Projects, Project Workspace, Review Inbox, and Sync & Conflicts;
- manual Learning Plan creation, Capacity Check, activation, and Plan Revisions;
- Practice Routine, Block, Focus, cadence, history, and balance analysis;
- Proof browsing and acceptance as Qualifying Proof;
- Learning Trail and evidence-first manual Stage Review;
- Project Archive and separate Permanent Deletion;
- iPhone Today Agenda and Guided Routine Player changes required for the same domain model.

Not in the first milestone:

- AI plan generation or Review suggestions;
- background AI analysis;
- Shared Snapshots and enhanced exports;
- collaboration, roles, invitations, or comments;
- complete offline Web editing;
- Web-based practice timing;
- advanced predictive analytics;
- automatic Plan activation, Phase advancement, or Calendar writes.

## 11. Current iOS migration impacts

The repository already contains useful foundations: normalized Journal records, course plans and revisions, recurring routines, Proof, Review, Trail, CloudKit synchronization, conflicts, scheduling, and EventKit confirmation. The Web work must not assume the new product language and constraints already exist in code.

Required migrations include:

1. Generalize `CoursePlan` behavior and user language into Learning Plan while preserving compatible existing records.
2. Migrate Projects with multiple active Practice Routines through an explicit merge-or-archive decision; never silently pick one.
3. Add ordered Practice Blocks, one current Focus per Block, Practice Segments, and per-Block summaries.
4. Replace the visual separation of Primary Recommendation, Alternatives, and Practice with the derived Today Agenda while retaining source record semantics.
5. Reconcile existing Project statuses with Active, Paused, Completed, and Abandoned without losing historical meaning.
6. Extend conflict handling to Web mutations and structural publication guards.
7. Preserve current EventKit preview and iPhone confirmation boundaries.

## 12. Acceptance scenarios

The MVP is acceptable when all of the following work against the same Journal Owner and CloudKit environment:

1. A learner creates and activates a manual guitar Learning Plan on Web; the active Phase and Planned Sessions appear on iPhone.
2. A Routine with Theory, Finger Technique, and Sing and Play Blocks appears in Today Agenda.
3. One iPhone Guided Routine Player session records correct total and per-Block active time across pause, skip, reorder, and revisit actions.
4. The resulting Practice Summary and optional Proof appear in the Web Project Workspace.
5. A missed Planned Session becomes Carryover without its original window being rewritten.
6. Capacity Check identifies an overloaded week but allows acknowledged activation.
7. A Stage Review cannot advance a Phase without Qualifying Proof.
8. Publishing a Review with accepted Proof advances or revises the Project exactly once and creates meaningful Trail events.
9. Different-field Web and iPhone edits merge; a same-field edit appears as a resolvable Sync Conflict.
10. A stale Plan activation or Review publication fails without overwriting the newer revision.
11. Pausing, completing, or abandoning a Project archives rather than deletes its history.
12. The manual loop remains fully usable with the Support Service and every AI capability disabled.

## 13. Technical validation before implementation

These are validation tasks, not reopened product decisions:

- configure a dedicated CloudKit JS API token with allowed Web origins;
- prove authenticated access to the existing private custom zone in development;
- verify record-zone change fetching, atomic record modification, change-tag conflicts, and asset download/upload behavior from the chosen Web stack;
- define one versioned record contract and fixture suite shared conceptually by Swift and TypeScript;
- verify production schema promotion and same-account iPhone/Web convergence on real Apple infrastructure;
- define attachment size and browser preview limits without moving canonical assets to a second store;
- define recoverable-draft storage, expiration, encryption expectations, and cleanup behavior;
- add cross-surface acceptance tests for every scenario above.
