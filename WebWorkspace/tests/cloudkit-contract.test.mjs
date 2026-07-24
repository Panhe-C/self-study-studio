import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const repositoryRoot = new URL("../../", import.meta.url);
process.env.NEXT_PUBLIC_CLOUDKIT_API_TOKEN = "test-cloudkit-token";

const { inspectCloudKitJournal } = await import("../lib/cloudkit.ts");

function installFakeCloudKit(pages) {
  const requests = [];

  globalThis.window = {
    CloudKit: {
      DEVELOPMENT_ENVIRONMENT: "development",
      PRODUCTION_ENVIRONMENT: "production",
      configure() {},
      getDefaultContainer() {
        return {
          async setUpAuth() {
            return { userRecordName: "test-user" };
          },
          privateCloudDatabase: {
            async fetchRecordZoneChanges(options) {
              requests.push(options);
              const page = pages[requests.length - 1];
              assert.ok(page, `Unexpected CloudKit request ${requests.length}`);
              return page;
            },
          },
        };
      },
    },
    setTimeout,
  };

  return requests;
}

const expectedRecordTypes = [
  "Project",
  "LearningSession",
  "Proof",
  "Review",
  "EvidenceContract",
  "EvidenceAcceptance",
  "ProofRevision",
  "ReviewDecision",
  "TrailEvent",
  "CoursePlan",
  "PlanPhase",
  "PlannedSession",
  "AvailabilityRule",
  "SchedulingPreferences",
  "PracticeRoutine",
  "PracticeSession",
];

test("Web CloudKit constants match the iPhone sync client", async () => {
  const [webClient, swiftClient, swiftCoordinator] = await Promise.all([
    readFile(new URL("../lib/cloudkit.ts", import.meta.url), "utf8"),
    readFile(
      new URL(
        "Sources/PersonalLearningJournal/Sync/CKSyncEngineDatabaseClient.swift",
        repositoryRoot,
      ),
      "utf8",
    ),
    readFile(
      new URL(
        "Sources/PersonalLearningJournal/Sync/CloudSyncCoordinator.swift",
        repositoryRoot,
      ),
      "utf8",
    ),
  ]);

  for (const source of [webClient, swiftClient]) {
    assert.match(source, /iCloud\.com\.local\.selfstudystudio/);
  }
  for (const source of [webClient, swiftCoordinator]) {
    assert.match(source, /LearningJournalZone/);
  }
  assert.match(swiftClient, /privateCloudDatabase/);
  assert.match(swiftClient, /savePolicy:\s*\.ifServerRecordUnchanged/);
  assert.match(webClient, /recordChangeTag/);
  assert.match(webClient, /privateCloudDatabase\.fetchRecordZoneChanges/);
});

test("Web diagnostics recognize every current iPhone CloudKit record type", async () => {
  const mapper = await readFile(
    new URL(
      "Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift",
      repositoryRoot,
    ),
    "utf8",
  );

  for (const recordType of expectedRecordTypes) {
    assert.match(
      mapper,
      new RegExp(`case \\"${recordType}\\"|\\"${recordType}\\"`),
      `CloudRecordMapper should still expose ${recordType}`,
    );
  }
});

test("Web diagnostics fetch every CloudKit zone change page", async () => {
  const requests = installFakeCloudKit([
    {
      zones: [
        {
          records: [
            {
              recordName: "project-1",
              recordType: "Project",
              recordChangeTag: "tag-1",
            },
          ],
          moreComing: true,
          syncToken: "page-2-token",
        },
      ],
    },
    {
      zones: [
        {
          records: [
            {
              recordName: "project-1",
              recordType: "Project",
              recordChangeTag: "tag-2",
            },
            {
              recordName: "proof-1",
              recordType: "Proof",
              recordChangeTag: "tag-3",
            },
          ],
          moreComing: false,
          syncToken: "complete-token",
        },
      ],
    },
  ]);

  const diagnostic = await inspectCloudKitJournal();

  assert.equal(diagnostic.mode, "connected");
  assert.equal(diagnostic.recordCount, 2);
  assert.deepEqual(diagnostic.recordTypes, { Project: 1, Proof: 1 });
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[1], {
    zoneID: { zoneName: "LearningJournalZone" },
    syncToken: "page-2-token",
  });
});

test("Web diagnostics mark records with zone errors as partial", async () => {
  installFakeCloudKit([
    {
      zones: [
        {
          records: [
            {
              recordName: "project-1",
              recordType: "Project",
            },
          ],
          errors: [{ reason: "Proof record was not readable." }],
          moreComing: false,
        },
      ],
    },
  ]);

  const diagnostic = await inspectCloudKitJournal();

  assert.equal(diagnostic.mode, "partial");
  assert.equal(diagnostic.recordCount, 1);
  assert.match(diagnostic.message, /partial/i);
  assert.match(diagnostic.message, /Proof record was not readable/);
});

test("Web diagnostics mark a zone-only failure as an error", async () => {
  installFakeCloudKit([
    {
      zones: [
        {
          errors: [{ reason: "Zone not found." }],
          moreComing: false,
        },
      ],
    },
  ]);

  const diagnostic = await inspectCloudKitJournal();

  assert.equal(diagnostic.mode, "error");
  assert.equal(diagnostic.recordCount, 0);
  assert.match(diagnostic.message, /Zone not found/);
});

test("Web diagnostics do not report connected when a continuation token is missing", async () => {
  const requests = installFakeCloudKit([
    {
      zones: [
        {
          records: [
            {
              recordName: "project-1",
              recordType: "Project",
            },
          ],
          moreComing: true,
        },
      ],
    },
  ]);

  const diagnostic = await inspectCloudKitJournal();

  assert.equal(diagnostic.mode, "partial");
  assert.equal(diagnostic.recordCount, 1);
  assert.match(diagnostic.message, /sync token/i);
  assert.equal(requests.length, 1);
});

test("Web diagnostics stop when CloudKit repeats a continuation token", async () => {
  const repeatedPage = {
    zones: [
      {
        records: [
          {
            recordName: "project-1",
            recordType: "Project",
          },
        ],
        moreComing: true,
        syncToken: "stalled-token",
      },
    ],
  };
  const requests = installFakeCloudKit([repeatedPage, repeatedPage]);

  const diagnostic = await inspectCloudKitJournal();

  assert.equal(diagnostic.mode, "partial");
  assert.equal(diagnostic.recordCount, 1);
  assert.deepEqual(diagnostic.recordTypes, { Project: 1 });
  assert.match(diagnostic.message, /repeated a sync token/i);
  assert.equal(requests.length, 2);
});
