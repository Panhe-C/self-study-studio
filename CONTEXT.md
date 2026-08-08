# Self Study Studio

Self Study Studio is one personal learning system with complementary interaction surfaces for planning, execution, evidence, and reflection.

## How to read this document

This is the accepted target domain language. It is ahead of the code. Every term carries an implementation status so a reader can tell target from reality without opening the source:

- `[shipped]` — implemented and usable on at least its primary surface.
- `[partial]` — a related mechanism exists, but the term's defining constraint is not enforced yet. The gap is stated.
- `[planned]` — decided but not built.

Statuses were checked against the repository on 2026-08-09. The sequence that closes the gaps is [跨端迁移路线图](docs/cross-surface-migration-roadmap.md); when a milestone lands, update the affected statuses in the same change.

## Surfaces

**Web Workspace** `[partial]`:
The browser-based surface for deliberate planning, analysis, learning-trail exploration, and stage review over the same personal learning journal used on iPhone.
_Avoid_: Website backend, admin panel, separate web platform
_Gap_: `WebWorkspace/` renders every surface from two hardcoded demos in `lib/journal.ts`; CloudKit access is read-only diagnostics.

**iPhone App** `[shipped]`:
The mobile surface for carrying out learning, timing practice, making quick records, and capturing proof in the moment.
_Avoid_: Mobile client, companion app

**Personal Workspace** `[shipped]`:
The learner's private Web Workspace and iPhone App experience; the first release has one owner and no members, roles, invitations, or collaborative editing.
_Avoid_: Team workspace, organization, shared project

**Project Workspace** `[partial]`:
The primary Web context that brings one Project's Overview, Plan, Practice, Proof, Learning Trail, and Reviews together; global navigation is limited to cross-project orientation and Review entry points.
_Avoid_: Feature dashboard, global practice manager, folder
_Gap_: the Web tab structure exists on demo data; the iPhone equivalent is a Project detail screen with a different shape.

**Project Status** `[shipped]`:
The learner's explicit lifecycle decision for a Project: Active, Paused, Completed, or Abandoned; status changes preserve the Project's Journal history.
_Avoid_: Progress percentage, deletion state, plan status
_Gap_: Legacy `low-frequency`, `archived`, and `trash` values remain readable for migration compatibility; canonical writes use the four lifecycle values plus pre-commitment `idea`.

**Pre-commitment Project** `[shipped]`:
A Project the learner has recorded but not yet committed to, carrying no Goal, canonical Next Step, or Evidence Contract, and counting toward neither the attention budget nor the Today Agenda.
_Avoid_: Active Project, draft plan, archived project

**Project Archive** `[shipped]`:
The read-accessible collection of Paused, Completed, and Abandoned Projects removed from active planning and the Today Agenda while retaining their Plans, Practice, Proof, Trail, and Reviews.
_Avoid_: Trash, backup, deleted projects
_Gap_: Physical-device and production-data acceptance remains a later release gate; the iPhone archive view and status filters are implemented.

**Permanent Deletion** `[shipped]`:
A separate destructive operation that removes a Project and its dependent records and attachments after impact disclosure and explicit confirmation, optionally preceded by export.
_Avoid_: Archive, abandon, complete
_Gap_: Repository purge commits first and project-scoped attachment cleanup is retryable through a local private queue only after a canonical purge tombstone is present; legacy queues migrate project IDs when unambiguous and surface allowlisted ImportedAssets/attachment-root paths as explicitly confirmed orphan cleanup, while unsafe/unclassifiable paths remain visible for explicit quarantine review. Corrupt or unsafe legacy queues can be quarantined into shareable timestamped artifacts before a new queue is accepted; failed quarantine keeps the active queue blocked. Trash exports are unencrypted and require trusted-location confirmation; physical-device acceptance remains unverified.

**Review Inbox** `[partial]`:
The global list of Stage Reviews that are ready or in draft plus the entry point for Weekly Review, without moving project-specific review content out of its Project Workspace.
_Avoid_: Notification center, all activity, review archive
_Gap_: exists as a Web surface on demo data; Stage Reviews themselves do not exist yet.

**Shared Snapshot** `[planned]`:
A read-only export of a Plan, Learning Trail, or Published Review intended for discussion outside the Personal Workspace without granting access to its canonical records.
_Avoid_: Collaborator access, shared workspace, editable link

## Core Record

**Personal Learning Journal** `[shipped]`:
The canonical personal record containing projects, plans, learning sessions, practice sessions, proof, trail events, and reviews across every surface.
_Avoid_: Web data, mobile data, backend data

**Journal Owner** `[shipped]`:
The single learner whose Apple/iCloud identity owns and authorizes access to the Personal Learning Journal across the Web Workspace and iPhone App.
_Avoid_: Web user, mobile account, workspace member

**Progress Signal** `[partial]`:
Evidence-linked information about movement toward a Project or Phase outcome; time, frequency, and completion counts explain progress but do not establish it alone.
_Avoid_: Hours logged, streak, productivity score
_Gap_: `ProductHealthService` produces deterministic facts and the Web Dashboard treats counts as explanatory, but signals are not yet anchored to Plan Phase outcomes.

**Today Agenda** `[planned]`:
A derived, ordered view of the learner's executable commitments for one day, combining due Planned Sessions, scheduled Practice Routines, and selected Next Steps without turning them into a new canonical plan.
_Avoid_: Daily plan, recommendation card, task list
_Gap_: Today currently shows a primary recommendation, separate alternatives, and practice as three sections.

**Agenda Item** `[planned]`:
A presentation of one existing Planned Session, Practice Routine occurrence, or selected Next Step inside the Today Agenda; its source type and completion semantics remain unchanged.
_Avoid_: Copied task, generic activity, merged session

**Up Next** `[planned]`:
The first recommended Agenda Item, expressed as a position in the Today Agenda rather than a separate kind of recommendation.
_Avoid_: Primary Recommendation, required task, active project
_Gap_: `TodayRecommendationService` produces exactly the Primary Recommendation this term replaces.

**Daily Override** `[planned]`:
A learner choice that repositions an Agenda Item as Up Next, Later Today, or Skip Today without changing its source Plan, Routine, completion state, or longer-term schedule.
_Avoid_: Reschedule, plan revision, completion, recommendation feedback
_Gap_: a `userPinned` recommendation reason exists; Later Today and Skip Today do not.

**Learning Trail** `[shipped]`:
A readable, chronological account of meaningful learning activity, evidence, phase transitions, published plan changes, and Review Decisions.
_Avoid_: Audit log, activity feed, edit history

**Audit Log** `[planned]`:
A diagnostic record of technical mutations and intermediate edits kept separate from the learner-facing Learning Trail.
_Avoid_: Learning Trail, progress history
_Gap_: no audit log exists; the separation is currently maintained by keeping noise out of the Trail.

## Synchronization

**Sync Merge** `[shipped]`:
Automatic reconciliation of compatible changes from the Web Workspace and iPhone App, including independently created records and edits to different fields of the same record.
_Avoid_: Last write wins, overwrite, manual sync
_Gap_: implemented for iPhone-to-iPhone; Web is not yet a writer.

**Sync Conflict** `[shipped]`:
A same-field or structural collision that cannot be merged without changing user intent; it remains unresolved until the learner chooses or combines the competing values.
_Avoid_: Sync error, newest version, duplicate record

**Revision Guard** `[partial]`:
A freshness check applied before consequential publication operations such as activating a Learning Plan or publishing a Review; stale input must be refreshed or resolved instead of overwriting newer canonical state. Local repository paths and fake Cloud clients verify captured base revisions, frozen outbox change tags, terminal stale writes, and grouped transactions; real CloudKit conditional-write behavior remains unverified here.
_Avoid_: Background merge, last-write-wins, warning-only check

**Online-First Workspace** `[partial]`:
The Web Workspace operating mode in which canonical records are read and changed through a live connection; only unfinished drafts are locally recoverable, while complete offline execution remains an iPhone responsibility.
_Avoid_: Offline-first web app, local replica, background sync queue
_Gap_: Web has no local replica, but it also has no live canonical reads or recoverable drafts yet.

**Direct Journal Access** `[partial]`:
The Web Workspace reads and writes the Journal Owner's private CloudKit database through CloudKit JS rather than routing canonical records through an application-owned data service.
_Avoid_: Web database, synchronization backend, server-owned journal
_Gap_: `lib/cloudkit.ts` verifies authentication, private zone access, record types, and change tags; no read or write path feeds the product yet.

**Support Service** `[planned]`:
A stateless or derived Web service used only for capabilities that should not run in the browser, such as protected AI calls or export rendering; it does not become a source of truth for Journal records.
_Avoid_: Journal backend, second database, sync authority

**AI Context Pack** `[partial]`:
A purpose-limited selection of Project data, Review Facts, recent summaries, and explicitly chosen Proof prepared for one learner-initiated AI request.
_Avoid_: Full journal access, background index, training dataset
_Gap_: AI planning already sends only course input and summarized context, never Calendar content, contacts, or location; the selection is not yet a named, inspectable pack.

**AI Context Preview** `[planned]`:
A human-readable disclosure of the records and attachment summaries in an AI Context Pack before it is sent; raw attachments require explicit inclusion.
_Avoid_: Privacy policy, hidden system prompt, blanket consent

## Publication

**Plan Draft** `[shipped]`:
An editable learning-plan proposal that has not yet changed what the learner has committed to execute.
_Avoid_: Temporary plan, unsaved plan

**Generated Plan Draft** `[shipped]`:
An AI-assisted Plan Draft proposed from the Project goal, learner context, materials, time budget, and desired outcome; it has no authority until edited and activated by the learner.
_Avoid_: AI plan, automatic plan, active plan

**Recoverable Draft** `[planned]`:
A locally buffered Plan Draft or unpublished Review that survives a transient Web connection loss but cannot become canonical until connectivity and revision checks succeed.
_Avoid_: Offline workspace, synchronized record, published change

**Active Plan** `[shipped]`:
A published learning plan that guides upcoming learning sessions across the Web Workspace and iPhone App.
_Avoid_: Approved mobile plan, final plan
_Gap_: guides iPhone only; Web does not read it yet.

**Plan Revision Draft** `[shipped]`:
An editable proposal for structurally changing an Active Plan, including its Phase objectives, ordering, expected Proof, or Practice Routine structure; activation supersedes the prior published revision without erasing it.
_Avoid_: Direct plan edit, duplicate plan, execution update
_Gap_: Web authoring and publication remain a later C1/C2 responsibility.

**Plan Revision** `[shipped]`:
One immutable published structural version of a Learning Plan; only one revision is active, while superseded revisions remain available to explain historical learning decisions.
_Avoid_: Backup, edit history, separate learning plan
_Gap_: Web reads and writes arrive in C1/C2; the iPhone repository and Cloud sync now preserve immutable revision identity and revision-scoped Practice Routine snapshots.

**Learning Plan** `[shipped]`:
A Project-owned plan that turns a learning goal into ordered Phases, Planned Sessions, and expected Proof; course material may inform it but is not required.
_Avoid_: Course Plan, curriculum, task list
_Gap_: Web has not yet switched from demo data to the real Journal; the iPhone keeps `CoursePlan` as an indefinite persistence/CloudKit compatibility alias.

**Plan Phase** `[shipped]`:
A coherent stage of a Learning Plan with its own objective, expected Proof, and target time range.
_Avoid_: Chapter, sprint, section

**Planning Window** `[planned]`:
A flexible target day, week, or date range for a Phase or Planned Session that guides the Today Agenda without reserving an exact clock time.
_Avoid_: Calendar event, deadline, exact appointment
_Gap_: `PlannedSession` carries a single optional `deadline`, which is the concept this term replaces.

**Practice Cadence** `[partial]`:
The intended weekly frequency and optional preferred days for a Practice Routine, without requiring exact start times.
_Avoid_: Recurring calendar event, streak rule, daily quota
_Gap_: `PracticeRoutine.weekdays` fixes specific days rather than expressing a frequency with optional preferred days.

**Calendar Commitment** `[shipped]`:
An optional exact start and end time selected when learning should reserve real calendar space; EventKit creation or modification still requires confirmation on iPhone.
_Avoid_: Planning Window, automatic calendar sync, due date

**Capacity Check** `[partial]`:
A deterministic comparison of estimated Planned Session and Practice Cadence load against the learner's stated weekly availability, broken down by week and source Project.
_Avoid_: Productivity score, hard schedule, AI estimate
_Gap_: `CoursePlanValidator` compares one plan's weekly budget against supplied availability; there is no per-week, per-Project breakdown and Practice load is excluded.

**Capacity Warning** `[partial]`:
A visible, acknowledged warning that a proposed Plan exceeds stated availability; it offers adjustments but never edits the Plan automatically or prevents deliberate activation.
_Avoid_: Validation error, activation failure, automatic optimization
_Gap_: the existing warning is non-blocking text with no acknowledgement step and no suggested adjustments.

**Planned Session** `[shipped]`:
A concrete future learning action within a Plan Phase, with an expected duration and optional expected Proof.
_Avoid_: Task, calendar event, Practice Routine

**Carryover** `[planned]`:
An unresolved Planned Session whose Planning Window has passed; its original timing remains visible until the learner does it, reschedules it, skips it, or revises the Plan.
_Avoid_: Automatically rescheduled session, overdue task, failed session
_Gap_: overdue planned sessions appear in Today, but there is no Carryover state and no `Do Today` / `Reschedule` / `Skip` / `Revise Plan` resolution.

**Skipped Session** `[shipped]`:
A Planned Session explicitly resolved as intentionally not performed, preserving the decision without treating it as completed learning.
_Avoid_: Completed session, deleted session, missed practice occurrence

## Practice

**Practice Routine** `[partial]`:
A repeatable, Project-owned practice format with one schedule, one overall target, and an ordered set of Practice Blocks; a Project has at most one active Routine.
_Avoid_: Learning Plan, daily task list, collection of unrelated drills
_Gap_: the iPhone editor, Guided Routine Player, one-operational-Routine service guard, and B1/B2/B3 startup gate are wired for local use; physical-device and real CloudKit release acceptance, plus later Web parity, remain separate checks. B2 Plan Revision identity/structural locking remains compatible.

**Practice Block** `[partial]`:
A named part of a Practice Routine that preserves a distinct training purpose and target duration while participating in one continuous practice experience.
_Avoid_: Separate Practice Routine, Planned Session, checklist item
_Gap_: ordered targets, Focus, and Next Focus candidates are authored and executed by the iPhone player, with observed values retained for session history; cross-surface Web parity and physical-device/real CloudKit acceptance remain pending.

**Practice Focus** `[partial]`:
The single current emphasis within a Practice Block, usually derived from the active Plan Phase and optionally carrying guidance, resources, and a success cue without changing the Routine's stable structure.
_Avoid_: Plan Phase, permanent block name, Next Step
_Gap_: iPhone authoring, player display, and session-summary snapshots are wired; Review-wide and Web consumption remain pending.

**Next Focus** `[partial]`:
An optional lightweight candidate for what a Practice Block may emphasize after its current Practice Focus; it has no completion state, timer, or reporting identity of its own.
_Avoid_: Exercise task, checklist item, planned session
_Gap_: iPhone authoring, player display, and session-summary snapshots are wired; Review-wide and Web consumption remain pending.

**Practice Session** `[partial]`:
One completed run of a Practice Routine that records both total active time and the actual time spent in each Practice Block.
_Avoid_: Learning Session, block session, timer run
_Gap_: iPhone Finish atomically persists the base Session, Segments, observed Block snapshots, and derived Summary before showing reflection. Notes and an Attention Marker are guarded post-save updates to that same session; leaving reflection only clears the local draft. Proof attachment remains an explicit follow-up, and physical-device/real CloudKit acceptance is separate.

**Guided Routine Player** `[partial]`:
The iPhone execution flow that starts and finishes a Practice Session once, presents one current Block at a time, and attributes active time as the learner advances, skips, or directly switches Blocks.
_Avoid_: Block checklist, separate timers, forced sequence
_Gap_: the iPhone player starts, pauses, resumes, skips, switches, recovers, and finishes one guided session with per-Block attribution; Web timing and physical-device/real CloudKit acceptance remain out of this local slice.

**Practice Segment** `[partial]`:
A contiguous interval of active time attributed to one Practice Block inside a Practice Session; pauses are excluded and repeated visits to the same Block are combined in the session summary.
_Avoid_: Practice Session, exercise timer, planned session
_Gap_: Codable/CloudKit mapping, summary aggregation, and runtime pause/skip/direct-selection attribution are wired on iPhone; real CloudKit and physical-device acceptance remain release checks.

**Practice Summary** `[partial]`:
The automatically saved outcome of a Practice Session containing total active time, per-Block time, skipped or extended targets, and the Practice Focus used, with optional notes, Proof, and one Attention Marker.
_Avoid_: Required reflection, block report, stage review
_Gap_: iPhone Finish atomically persists per-Block time, skipped/extended targets, and observed Focus/Next Focus; notes and an optional Attention Marker are later guarded updates to the same session. Proof attachment is not wired and remains an explicit gap; physical-device/real CloudKit acceptance is separate.

**Attention Marker** `[partial]`:
An optional indication that one Practice Block deserves attention in the next session or Review; it is a learner signal rather than a score or failure state.
_Avoid_: Rating, failed block, automatic recommendation
_Gap_: the iPhone finish flow can save one optional marker and history displays it; Review-wide and Web consumption remain pending.

**Practice Target** `[partial]`:
A soft time goal for a Practice Routine or Block; the Routine's total target determines whether the day met its goal, while Block targets guide balance without blocking completion.
_Avoid_: Required checklist, completion gate, quota
_Gap_: Routine and Block targets remain soft; runtime target feedback and guided UI wiring are present on iPhone, with physical-device/real CloudKit acceptance still required.

**Published Review** `[shipped]`:
A completed reflection whose decisions become part of the Personal Learning Journal and may change a project's status or Next Step.
_Avoid_: Mobile-approved review, review report

## Reflection

**Stage Review** `[planned]`:
A reflection on one Project, usually anchored to a completed or ending Plan Phase, that evaluates evidence and decides how the Project should proceed.
_Avoid_: Monthly report, portfolio review, long weekly review
_Gap_: only the cross-project Weekly Review exists.

**Review Fact** `[shipped]`:
A deterministic, source-linked observation derived from plans, sessions, practice, proof, or trail history without interpretation by AI.
_Avoid_: Insight, recommendation, AI summary

**Review Suggestion** `[shipped]`:
An optional interpretation or proposed adjustment, possibly AI-assisted, that has no effect until the learner accepts it as a Review Decision.
_Avoid_: Automatic decision, fact, instruction

**Review Decision** `[shipped]`:
A learner-confirmed outcome of a Review that may advance a Phase or change a Project, Learning Plan, Practice Routine, or Next Step.
_Avoid_: AI recommendation, generated conclusion
_Gap_: `ReviewDecisionKind` cannot advance a Plan Phase yet; legacy `archive` remains decode-only compatibility for migrated records.

**Qualifying Proof** `[partial]`:
Proof explicitly accepted as satisfying a Plan Phase's expected outcome; it is required before a Stage Review can complete that Phase or advance to the next one.
_Avoid_: Attachment, activity record, unreviewed evidence
_Gap_: `EvidenceAcceptance` accepts Proof against Evidence Contract criteria, not against a Plan Phase outcome, and nothing gates Phase completion.

**Stage Review Readiness** `[planned]`:
A system-detected state indicating that a Plan Phase is due, its Planned Sessions are resolved, its expected Proof is available, or the learner explicitly requests reflection.
_Avoid_: Automatic review, completed Phase, AI trigger
_Gap_: Review prompts fire for Projects quiet for seven days, which is a staleness signal rather than Phase readiness.

**Weekly Review** `[shipped]`:
A time-boxed reflection across the learner's active Projects that identifies portfolio-level patterns, neglected work, and near-term adjustments.
_Avoid_: Stage Review, project retrospective
