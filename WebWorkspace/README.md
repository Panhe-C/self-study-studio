# Self Study Studio Web Workspace

The browser planning and review surface for the Personal Learning Journal. The
first implementation slice includes the Dashboard, Project Workspace, Plan,
Practice, Proof, Learning Trail, Review Inbox, and read-only CloudKit diagnostics.

## Run locally

```bash
npm install
npm run dev
```

The app starts in an explicitly labeled demo mode. To validate the same private
CloudKit journal used by iPhone, copy `.env.example` to `.env.local` and add the
Web API token created in CloudKit Dashboard.

```text
NEXT_PUBLIC_CLOUDKIT_CONTAINER_IDENTIFIER=iCloud.com.local.selfstudystudio
NEXT_PUBLIC_CLOUDKIT_API_TOKEN=your_web_api_token
NEXT_PUBLIC_CLOUDKIT_ENVIRONMENT=development
NEXT_PUBLIC_CLOUDKIT_ZONE_NAME=LearningJournalZone
```

The current CloudKit slice is deliberately read-only. It verifies Apple account
authentication, private custom-zone access, record types, and record change tags
before any browser write path is enabled.

## Validate

```bash
npm test
npm run lint
```

Canonical Journal records remain in CloudKit. D1 and R2 are intentionally not
configured; browser storage may later hold only recoverable unpublished drafts.
