# Self Study Studio Web Workspace

The `/` route is the new content-progress MVP: local projects, ordered learning
units, completion, pause/resume, draft creation, and optional AI outline
generation. Confirmed projects and drafts are stored in a separate IndexedDB
database. They are currently **only in this browser**; cross-device sync is a
later stage. The previous Personal Learning Journal remains at `/legacy`.

## Run locally

```bash
npm install
npm run dev
```

The new home needs no CloudKit login. To enable its AI draft generator, set
server-only `PROGRESS_AI_ENDPOINT` to an HTTPS OpenAI-compatible
`/chat/completions` URL and `PROGRESS_AI_MODELS` to a comma-separated allowlist.
The user enters their own API key in the create dialog; it stays in page memory
and is sent through the same-origin proxy for that request. Neither the key nor
the AI response is stored with a confirmed project. Without configuration,
manual creation works. Automatic course-link reading is not enabled yet: paste
a course outline, or clear the link to generate from the topic.

The `/legacy` route starts in an explicitly labeled **Demo** mode backed by
deterministic fixtures. Its **Real journal** switch reads the older private
CloudKit journal used by iPhone. Real mode never falls back to Demo data:
missing configuration, authentication, schema, or zone failures remain visible.

To configure legacy Real mode locally, copy `.env.example` to `.env.local` and add the
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

`npx tsc --noEmit` currently reports missing `Fetcher` and `D1Database` types in
the pre-existing `worker/index.ts`; the build, tests, and lint are separate
checks. Canonical legacy Journal records remain in CloudKit. D1 and R2 are
intentionally not configured.
