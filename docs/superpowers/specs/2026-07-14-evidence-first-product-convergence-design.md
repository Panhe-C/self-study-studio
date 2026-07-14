# Self Study Studio Evidence-First Product Convergence Design

Date: 2026-07-14  
Status: Approved product direction  
Platform: iPhone-first, iOS 17+

## 1. Purpose

Self Study Studio is an evidence-first personal learning trail. Its primary job is to help one person answer:

1. What is the one useful thing I should do next?
2. What inspectable evidence shows that I actually learned or produced something?
3. Should I continue, change, reduce, pause, archive, or complete this project?

The product is not a generic task manager, habit tracker, calendar, knowledge base, course platform, or autonomous AI coach. Course planning, practice timing, Calendar integration, AI assistance, and iCloud synchronization are supporting capabilities. None may replace or block the core learning loop:

```text
Project -> Session -> Proof -> Review -> Decision
```

The current implementation already contains valuable planning, Calendar, practice, media, persistence, and synchronization infrastructure. This convergence keeps that infrastructure, freezes new feature expansion, and aligns every capability with the evidence-first model.

## 2. Product Contract

### 2.1 Core principles

- Continue first: opening the app should make the next useful learning action obvious.
- Evidence over activity: elapsed time and completion counts are context, not proof of learning.
- One next action: every committed project has exactly one canonical Next Step.
- Light daily capture, strict periodic judgment: a Session stays fast; Evidence Contracts and Reviews prevent indefinite input without output.
- Decisions, not summaries: a Review is incomplete until the user confirms an explicit decision.
- User authority: rules and AI may recommend; only the user changes commitments, project state, plans, or external Calendar events.
- Offline core: external services may degrade, but they may never block local learning records.
- No manufactured anxiety: the app states uncomfortable facts without streak pressure, shame, rankings, or punitive visuals.

### 2.2 Product success

The first validation period is four consecutive weeks of real use on an iPhone. The product is effective when:

- the user can quickly identify the Next Step for every active project;
- each ended Evidence Contract period is either satisfied or deliberately resolved through Review;
- Reviews produce explicit decisions;
- at least one project accumulates a coherent, inspectable sequence of Proof;
- silent failures are visible: a period with neither qualifying Proof nor a Review decision is unhealthy;
- Product Health is computed locally and is never uploaded automatically.

Opening frequency, accumulated minutes, Session count, and feature usage are not primary success measures.

## 3. Ubiquitous Language

### Project

A bounded learning commitment with a Goal, lifecycle state, canonical Next Step, and—when committed—one active Evidence Contract.

### Session

An intentional learning episode. It records project, timing, action type, one sentence describing what actually advanced, and confirmation or replacement of the canonical Next Step. A Session does not require a Proof.

### Proof

An inspectable artifact plus a separate statement answering “What does this prove?” A statement without an artifact is a Session note, not Proof.

Qualifying artifact types are:

- image;
- audio;
- file;
- valid external link;
- Text Proof with a distinct Markdown-capable artifact body.

### Evidence Contract

The current explicit agreement about what evidence a committed Project will produce and how it will be accepted. A Project has at most one primary Contract at a time. A Contract is either:

- time-based, such as one complete performance recording per week; or
- milestone-based, such as a runnable reproduction after each course chapter.

Every Contract contains a cadence or milestone trigger, expected artifact form, and short acceptance criteria.

### Review

A decision boundary grounded in Projects, Sessions, Proof, Contracts, and plan facts. A Review is complete only after the user confirms one decision.

### Decision

One of:

- continue unchanged;
- change the canonical Next Step;
- revise the Evidence Contract;
- change frequency;
- pause;
- archive;
- complete with a Capstone Proof.

### Capstone Proof

The final Proof evaluated against the Project Goal. A Project cannot become completed without a final Review that accepts a Capstone Proof.

### Silent miss

An ended Contract period with neither accepted Proof nor a Review decision. This is the primary unhealthy state. A deliberate revision, frequency reduction, pause, or archive is a valid closed loop, not failure.

## 4. Project Lifecycle and Attention

The lifecycle is:

```text
idea -> active / low-frequency -> paused / archived / completed -> trash
```

- `idea`: a captured learning possibility. It does not require Goal, Next Step, or Contract and does not consume attention capacity.
- `active`: a current commitment. It requires Goal, canonical Next Step, and active Contract.
- `low-frequency`: a continuing commitment with a deliberately sparse Contract. It remains reviewable but does not count toward the three-active-Project Attention Budget.
- `paused`: the user intends to return. The canonical Next Step is preserved, but Contract timing and notifications stop.
- `archived`: the user no longer intends to advance it and does not claim that the Goal was reached.
- `completed`: a final Review accepted a Capstone Proof against the Goal.
- `trash`: a recoverable deletion state synchronized across devices. Items remain for 30 days unless the user explicitly confirms immediate permanent deletion.

The default Attention Budget is three active Projects. The user may explicitly exceed it. Today and Review must then state the overload as a fact. Low-frequency Projects do not count toward that limit, but remain visible when their Contract or Review needs attention.

Activating an `idea` requires the user to confirm Goal, canonical Next Step, and Evidence Contract. Activation never requires creating a fake first Session or Proof.

## 5. Evidence Semantics

### 5.1 Qualification

A Proof qualifies only when:

1. an inspectable artifact exists;
2. the proof statement is non-empty;
3. a local artifact can be opened or rendered by the app at save time, or a Link Proof contains a syntactically valid HTTP(S) URL;
4. the user evaluates it against the active Contract when claiming Contract satisfaction.

Contract acceptance uses the user-authored criteria. AI may suggest an evaluation only when the user explicitly requests it. The user owns the final result.

### 5.2 Text Proof

Text Proof has two separate fields:

- `artifactBody`: the inspectable written output, stored as lightweight Markdown;
- `statement`: the user’s claim about what the writing demonstrates or reveals.

The editor remains deliberately small. It is not a general notebook or knowledge base.

### 5.3 Link Proof

A Link Proof requires a syntactically valid HTTP(S) URL. Saving always records the URL and records the remaining integrity metadata when retrieval is available:

- URL;
- resolved title and site, when available;
- successful retrieval timestamp, when available;
- a content fingerprint when content can be retrieved;
- an optional local snapshot selected by the user.

A network failure never blocks local Link Proof creation. A later broken or changed link is flagged as an integrity risk. Historical Proof is not silently rewritten.

### 5.4 Revisions

Proof referenced by a Review or accepted Contract may be corrected, but correction creates a revision. Historical Reviews preserve the referenced title, statement, artifact checksum, and acceptance result. Deletion follows the Trash policy.

### 5.5 Library

Library contains only qualifying Proof. Inputs such as course pages, saved reading, and reference material remain inside their Project or course plan.

Library search is local. It covers Proof title, statement, Project name, Text Proof body, and on-device extracted text or transcription when available. Search indexes are regenerable local caches and do not sync.

## 6. Daily Flow

### 6.1 Navigation

The permanent core tabs are:

1. Today
2. Projects
3. Library

Calendar becomes a primary tab only after the user enables learning scheduling. Before that, Calendar is entered contextually from Today or a Project.

The interface is localized for Simplified Chinese and English and follows the system language. User-authored content is never automatically translated.

Dedicated accessibility verification is not a release gate for the first four-week validation. The implementation continues to use standard SwiftUI controls and semantics where practical, while acknowledging that a later accessibility pass may require layout and interaction changes.

### 6.2 Today

Today presents one primary recommendation and at most two alternatives. It must explain each recommendation with a deterministic reason. Ordering is:

1. user-pinned intent;
2. Evidence Contract approaching its boundary;
3. a confirmed scheduled action;
4. a Project that has not advanced recently.

AI does not choose Today’s recommendation. The user may always ignore it.

When a course plan exists, the canonical Next Step points to one currently executable Planned Session. Completing it produces the next candidate, which becomes canonical only after user confirmation or editing. Plans never create competing Next Steps.

### 6.3 Session capture

Quick Log and Timer both create the same Session model. The minimum capture is:

- Project;
- duration or timestamps;
- action type;
- one sentence describing what actually advanced;
- confirmation of the existing canonical Next Step or a replacement Next Step.

Proof attachment is optional at Session time because Evidence Contract cadence—not every Session—controls evidence production.

### 6.4 Practice

A persistent Practice Routine must belong to a Project. Practice completion creates normal Project learning history and participates in Contract and Review. A temporary timer may exist without becoming an independently managed habit system.

## 7. Review and Product Health

### 7.1 Triggers

Review has two levels:

- a lightweight weekly portfolio check across committed Projects;
- a Project Review triggered by a Contract boundary, milestone completion, consecutive stagnation, or explicit user action.

After one missed Contract period, the product states the fact. After two consecutive unresolved periods, Review requires the user to choose whether to recommit, revise the Contract, reduce frequency, pause, or archive. The system never changes state automatically.

### 7.2 Completion

A Review is not completed by viewing generated text. The user must confirm one Decision. “Continue unchanged” is valid and explicit.

### 7.3 Product Health

Product Health is computed on-device from closed-loop facts. It reports:

- committed Projects with a canonical Next Step;
- ended Contract periods satisfied by accepted Proof;
- ended periods resolved by Review decisions;
- silent misses;
- Reviews missing a Decision;
- Projects with coherent Proof sequences.

It does not produce a Learning Score. The user may inspect and export the report; it is not uploaded automatically.

## 8. Supporting Capabilities

### 8.1 AI

AI is bring-your-own-key and device-to-provider:

- provider endpoint, model, and non-secret preferences may sync;
- API keys remain in Keychain and never sync;
- no application relay backend, account system, or billing is introduced;
- manual and deterministic fallbacks remain complete.

AI runs only when the user explicitly requests Planning or Review. It produces a sourced, editable draft and cannot activate plans, mutate Projects, accept Proof, change lifecycle state, or write Calendar events.

By default, an AI request receives structured metadata and proof statements. The user may select specific Proof artifacts for one request. That authorization expires with the request.

Course links are fetched on-device or accompanied by pasted/imported content. Before any content is sent, the app displays the exact text and selected artifacts. Failed retrieval falls back to manual input.

Long-term persistence retains only accepted Planning/Review output plus source record identifiers, model, timestamp, and required version metadata. Raw prompts, temporary artifact copies, and rejected provider responses are discarded after the request.

### 8.2 Course planning and Replan

Course planning remains optional. AI or manual planning produces an editable draft. Plan activation and Calendar writeback are separate confirmations.

Replan is suggested only after meaningful facts such as repeated missed sessions, milestone delay, Contract revision, or changed investment during Review. It runs only after explicit user entry.

Activated plans are immutable revisions. Completed Sessions, Proof, historical Contract snapshots, and historical Next Steps are never rewritten. A new revision affects only future work.

### 8.3 Calendar

Calendar remains optional and must not block the core loop.

- The first enablement creates or selects a dedicated “Self Study Studio” Calendar.
- A shared target Calendar requires a warning and second confirmation.
- Event titles default to detailed content: Project name, Session title, Goal, and expected Proof.
- The app must disclose that these details may appear on lock screens, widgets, shared screens, and shared calendars.
- Internal plan activation does not write Calendar events.
- Every create, move, and delete is shown in an exact change set and written only after confirmation.
- External event edits or deletions offer: adopt the external change, overwrite/recreate from the internal plan, or detach. The app never chooses automatically.
- Calendar titles, notes, attendees, contacts, locations, URLs, and raw events never enter AI requests or CloudKit. Scheduling uses privacy-stripped busy intervals.

### 8.4 Notifications

Notifications correspond only to explicit user commitments:

- confirmed learning times;
- approaching Contract boundaries;
- pending Reviews.

Each category is independently disableable. Lock-screen text is generic and does not disclose Project, Next Step, Contract, or Review details. No streak, ranking, shame, or generic “time to study” notifications are allowed.

## 9. Persistence, Sync, and Ownership

### 9.1 Local-first behavior

Local-first means local durability and complete offline core behavior. If an Apple Account is available, private iCloud synchronization starts automatically.

The following operations always save locally even when iCloud, AI, network, or Calendar services fail:

- Project creation and activation;
- Session and Proof creation;
- Next Step and Contract changes;
- Review Decisions;
- lifecycle changes.

Sync failures enter a retryable queue. AI falls back to manual/rule-based flows. Calendar changes remain local drafts.

### 9.2 Sync boundary

Private CloudKit synchronization includes:

- Projects, Sessions, Proof and attachments;
- Evidence Contracts and acceptance history;
- Reviews and Decisions;
- course plans and revisions;
- cross-device user preferences that are not secrets or device-bound.

It excludes:

- API keys;
- raw Calendar content;
- EventKit and device identifiers;
- filesystem paths;
- search indexes and local caches;
- temporary drafts and sync diagnostics.

Append-only history merges automatically. True concurrent conflicts in Goal, canonical Next Step, Evidence Contract, lifecycle state, or active plan preserve both values and create a non-blocking Conflict Review.

### 9.3 Account isolation

Each Apple Account and the unsigned local space have separate stores. Switching accounts never merges or deletes data automatically. A signed-out account’s local copy remains hidden until the account returns or the user explicitly exports or deletes it.

When a user signs in after creating local-only data, a preview offers:

- move into the account;
- copy into the account while preserving local data;
- continue using the local space.

The flow creates an archive and performs duplicate detection before mutation.

### 9.4 App lock

Optional Face ID/App Lock is off by default. When enabled it protects the app, search results, attachment previews, and export, and hides background app-switcher snapshots.

## 10. Export, Import, and Deletion

The app provides a versioned, round-trip archive containing:

- a schema manifest;
- structured records and revision history;
- attachments and link snapshots;
- relationship identifiers;
- checksums and record counts.

Import shows a preview, detects duplicates, validates checksums and relationships, and supports full restoration. Readable CSV/Markdown exports are separate and are not restoration formats.

Full archives default to password encryption. The user may explicitly choose an unencrypted archive after seeing a sensitive-content warning.

Trash synchronizes across devices and retains content for 30 days. Immediate permanent deletion is available only after the app enumerates affected records, attachments, revisions, and relationship consequences.

## 11. Migration from the Current Model

Migration is a release-blocking product feature, not an incidental schema conversion.

### 11.1 Safety sequence

1. Run a read-only dry run.
2. Present counts and ambiguous items.
3. Create a complete pre-migration archive.
4. Perform a transactional migration.
5. Validate record counts, relationships, attachment checksums, and store readability.
6. Commit only after validation; otherwise restore the old store automatically.

The application does not permanently maintain two live domain models.

### 11.2 Ambiguous data

- Existing Proof without an artifact or valid link becomes `needsEvidence`. It does not satisfy a Contract or appear in the default Library. The user may attach evidence, convert it to its related Session note, or move it to Trash.
- Standalone Practice Routines enter Migration Review. The user may attach them to an existing Project, create an `idea` Project and later activate it, or archive the Routine. Historical Practice Sessions remain.
- Existing active Projects enter a transitional `needsSetup` state. They remain visible and writable but do not consume Attention Budget or accrue Contract misses. Confirming Goal, canonical Next Step, and Contract returns them to active.
- No migration may invent a user commitment, accepted Proof, completion claim, or Project relationship.

## 12. Architecture

The implementation should add focused domain units rather than expanding `Domain.swift` and `JournalViewModel.swift` indefinitely.

### 12.1 Domain modules

- `Projects`: lifecycle, activation requirements, Attention Budget, canonical Next Step.
- `Evidence`: Proof qualification, artifact descriptors, link integrity, revisions.
- `Contracts`: cadence, milestones, acceptance criteria, periods, resolution.
- `Reviews`: triggers, sourced snapshots, Decisions, completion and Capstone acceptance.
- `ProductHealth`: deterministic local closed-loop reporting.
- `Migration`: dry run, issue classification, transactional execution, validation and rollback.

Supporting modules remain separated:

- `Planning` owns editable plan drafts and immutable revisions.
- `Calendar` owns local schedule drafts, EventKit bindings and confirmed writes.
- `Practice` owns timer mechanics but emits Project Sessions.
- `Sync` maps syncable semantic records and never imports device-bound state.
- `AI` accepts explicit, privacy-filtered request packages and returns drafts.
- `Archive` owns versioned backup, restore, encryption and readable exports.

### 12.2 Data flow

```text
SwiftUI intent
  -> domain service validation
  -> repository transaction
  -> local committed state
  -> optional outbox / notification / Calendar draft
  -> view-model projection
```

No external service call sits between user intent and the local repository commit. Derived views such as Today recommendations, Review triggers, Product Health, and Library search are rebuildable projections.

### 12.3 Error handling

- Domain validation returns actionable field-level errors.
- Attachment or link validation fails before a Proof is committed.
- Repository transactions are atomic.
- Sync errors remain retryable and visible without modal interruption to local work.
- AI errors preserve user input and offer manual/rule-based continuation.
- Calendar errors preserve the unapplied change set with per-item retry.
- Migration and import errors leave the original store untouched and produce a local diagnostic report that excludes private content by default.

## 13. Delivery Phases

The product convergence is delivered as independently testable phases:

1. Domain foundation: lifecycle, Evidence Contract, qualifying Proof, revisions, Review Decisions, Product Health.
2. Safe migration: dry run, archive, ambiguous-item review, transactional conversion and rollback.
3. Core UI: activation, Today ranking, Session capture, Proof flows, Reviews, Library-only Proof search, conditional Calendar tab, bilingual structure.
4. Supporting integration: Project-bound Practice, plan/canonical-step alignment, AI privacy packages, Calendar disclosure and notification privacy.
5. Ownership and resilience: sync mappings/conflicts, account-space migration, Trash, round-trip encrypted archive, optional App Lock.
6. Acceptance: full automated verification, signed physical-device capability checks, then four-week Product Health validation.

No new feature family begins until these phases converge the existing product.

## 14. Verification and Release Gates

### 14.1 Release-blocking

- domain invariants and transitions;
- Evidence Contract period and resolution behavior;
- Proof qualification and revision snapshots;
- migration dry run, rollback, and ambiguous-item handling;
- attachment durability and checksums;
- automatic private iCloud synchronization and account isolation;
- offline writes and retry;
- round-trip archive restoration;
- real-iPhone camera/photo/file/audio, notification, Calendar, offline, and iCloud restore checks.

### 14.2 Safety baseline for optional capabilities

AI, Calendar, and course planning must pass privacy-boundary, confirmation, failure-preservation, and no-core-blocking tests. Their broader UX polish does not block the start of the four-week core validation.

### 14.3 Not a first-validation gate

- TestFlight or App Store distribution;
- iPad-specific layouts;
- macOS, Web, or Android clients;
- dedicated accessibility audit beyond standard SwiftUI behavior;
- social, collaboration, rankings, streaks, marketplaces, or autonomous agents.

## 15. Explicit Trade-offs

The approved direction intentionally accepts these trade-offs:

- iCloud synchronization starts automatically when an Apple Account is available; privacy is protected through a narrow sync boundary and account isolation rather than an opt-in switch.
- Calendar events default to detailed learning content; dedicated-calendar selection, shared-calendar warnings, and generic notification copy reduce—but do not eliminate—exposure.
- a dedicated accessibility audit does not block the first four-week validation, so later accessibility work may require structural UI changes.
- low-friction Sessions may exist without Proof, while Contract boundaries enforce evidence over time.
- user judgment remains authoritative even when it produces lower completion or Contract adherence metrics.

## 16. Out of Scope

- social identity, shared Projects, teams, roles, comments, rankings, or public feeds;
- general task management, knowledge management, bookmarks, or habit tracking;
- automatic Project state changes, automatic Proof acceptance, or autonomous replanning;
- provider-hosted AI accounts, application AI billing, or an AI relay backend;
- remote behavioral analytics or a cloud semantic-search index;
- desktop, Web, Android, and iPad-specific product surfaces before the iPhone validation completes.
