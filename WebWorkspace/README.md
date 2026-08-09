# Self Study Studio Web Workspace

The browser planning and review surface for the Personal Learning Journal. The
first implementation slice includes the Dashboard, Project Workspace, Plan,
Practice, Proof, Learning Trail, Review Inbox, and Sync & Conflicts workspace.

## Run locally

```bash
npm install
npm run dev
```

The app starts in an explicitly labeled **Demo** mode backed by deterministic
fixtures. Use the visible **Real journal** mode switch to read the same private
CloudKit journal used by iPhone. Real mode never falls back to Demo data: missing
configuration, authentication, schema, or zone failures remain visible as a
blocked, signed-out, partial, or error state.

To configure Real mode locally, copy `.env.example` to `.env.local` and add the
Web API token created in CloudKit Dashboard. Credentials and site origins are
environment/configuration only and must never be committed.

```text
NEXT_PUBLIC_CLOUDKIT_CONTAINER_IDENTIFIER=iCloud.com.local.selfstudystudio
NEXT_PUBLIC_CLOUDKIT_API_TOKEN=your_web_api_token
NEXT_PUBLIC_CLOUDKIT_ENVIRONMENT=development
NEXT_PUBLIC_CLOUDKIT_ZONE_NAME=LearningJournalZone
```

`lib/journal-reader.ts` fetches every private-zone change page, normalizes
CloudKit fields through the shared contract (including legacy defaults), and
`lib/journal-projector.ts` projects canonical records into the Dashboard and
Project Workspace view models. Real-mode writes go through the typed
`lib/journal-writer.ts` adapter: approved plan/Next Step/review/proof operations
are atomic, use `ifServerRecordUnchanged`, and retain independent base/target
revision guards. Stale tags become an explicit conflict workspace; there is no
automatic last-write-wins retry. `lib/recoverable-drafts.ts` stores unfinished
edits in IndexedDB (with a localStorage fallback) and clears them only after a
semantic CloudKit commit. Demo fixtures never enter this write path.

Browser UI and fake CloudKit tests cover these semantics. Real CloudKit
production acceptance is still unverified here without a valid token,
provisioned schema/zone, allowed origin, and same-owner iPhone data; static
tests/builds do not establish device or two-surface convergence.

## Validate

```bash
npm test
npm run lint
npx tsc --noEmit
```

Canonical Journal records remain in CloudKit. D1 and R2 are intentionally not
configured; browser storage holds only recoverable unpublished drafts.
