import assert from "node:assert/strict";
import test from "node:test";

const {
  readCloudKitJournal,
} = await import("../lib/journal-reader.ts");
const {
  projectJournalRecords,
} = await import("../lib/journal-projector.ts");

const projectID = "11111111-1111-4111-8111-111111111111";
const planID = "22222222-2222-4222-8222-222222222222";
const phaseID = "33333333-3333-4333-8333-333333333333";
const plannedSessionID = "44444444-4444-4444-8444-444444444444";

const config = {
  containerIdentifier: "iCloud.com.local.selfstudystudio",
  apiToken: "test-token",
  environment: "development",
  zoneName: "LearningJournalZone",
};

function fakeContainer(pages) {
  const requests = [];
  return {
    requests,
    container: {
      async setUpAuth() {
        return { userRecordName: "user-record" };
      },
      privateCloudDatabase: {
        async fetchRecordZoneChanges(options) {
          requests.push(options);
          const page = pages[requests.length - 1];
          assert.ok(page, `unexpected CloudKit request ${requests.length}`);
          return page;
        },
      },
    },
  };
}

function projectFields(overrides = {}) {
  return {
    name: { value: "Guitar" },
    area: { value: "Music" },
    goal: { value: "Build a daily fretboard habit" },
    status: { value: "active" },
    currentNextStep: { value: "Play the minor pentatonic shape" },
    lastActionType: { value: "practice" },
    defaultDurationMinutes: { value: 30 },
    createdAt: { value: "2026-08-01T00:00:00.000Z" },
    updatedAt: { value: "2026-08-08T00:00:00.000Z" },
    schemaVersion: { value: 1 },
    commitmentState: { value: "ready" },
    ...overrides,
  };
}

test("CloudKit reader paginates, maps wrapped fields, and applies legacy defaults", async () => {
  const fake = fakeContainer([
    {
      zones: [
        {
          records: [
            {
              recordName: projectID,
              recordType: "Project",
              recordChangeTag: "project-1",
              fields: projectFields(),
            },
          ],
          moreComing: true,
          syncToken: "next-page",
        },
      ],
    },
    {
      zones: [
        {
          records: [
            {
              recordName: planID,
              recordType: "CoursePlan",
              recordChangeTag: "plan-1",
              fields: {
                payload: {
                  value: JSON.stringify({
                    id: planID,
                    projectId: projectID,
                    revision: 1,
                    status: "active",
                    courseTitle: "Fretboard foundations",
                    courseOutline: "Shapes",
                    goal: "Learn the map",
                    expectedOutcome: "Play without hesitation",
                    startsOn: "2026-08-01T00:00:00.000Z",
                    weeklyBudgetMinutes: 120,
                    summary: "A short plan",
                    createdAt: "2026-08-01T00:00:00.000Z",
                    updatedAt: "2026-08-08T00:00:00.000Z",
                    schemaVersion: 1,
                  }),
                },
              },
            },
          ],
          moreComing: false,
          syncToken: "complete",
        },
      ],
    },
  ]);

  const result = await readCloudKitJournal({ config, container: fake.container });

  assert.equal(result.status, "ready");
  assert.equal(result.userRecordName, "user-record");
  assert.equal(result.records.length, 2);
  assert.deepEqual(
    result.records.map((record) => record.kind),
    ["project", "coursePlan"],
  );
  assert.equal(result.records[0].payload.id, projectID);
  assert.equal(result.records[1].payload.planSeriesID, planID);
  assert.equal(result.records[1].payload.revisionID, planID);
  assert.deepEqual(fake.requests[1], {
    zoneID: { zoneName: "LearningJournalZone" },
    syncToken: "next-page",
  });
});

test("Real CloudKit mode is explicitly blocked when configuration is missing", async () => {
  const result = await readCloudKitJournal({
    config: { ...config, apiToken: "" },
  });

  assert.equal(result.status, "blocked");
  assert.match(result.message, /NEXT_PUBLIC_CLOUDKIT_API_TOKEN/);
  assert.deepEqual(result.records, []);
});

test("invalid records produce a partial read and never substitute demo records", async () => {
  const fake = fakeContainer([
    {
      zones: [
        {
          records: [
            {
              recordName: projectID,
              recordType: "Project",
              fields: { name: { value: "Missing required fields" } },
            },
            {
              recordName: "55555555-5555-4555-8555-555555555555",
              recordType: "Project",
              fields: projectFields({ name: { value: "Valid project" } }),
            },
          ],
          moreComing: false,
        },
      ],
    },
  ]);

  const result = await readCloudKitJournal({ config, container: fake.container });

  assert.equal(result.status, "partial");
  assert.equal(result.records.length, 1);
  assert.equal(result.issues.length, 1);
  assert.match(result.issues[0].message, /required/i);
  assert.equal(result.demoFallbackUsed, false);
});

test("journal queries filter canonical records deterministically", async () => {
  const fake = fakeContainer([
    {
      zones: [
        {
          records: [
            {
              recordName: projectID,
              recordType: "Project",
              fields: projectFields(),
            },
            {
              recordName: planID,
              recordType: "CoursePlan",
              fields: {
                payload: {
                  value: JSON.stringify({
                    id: planID,
                    projectId: projectID,
                    revision: 1,
                    status: "active",
                    courseTitle: "Plan",
                    courseOutline: "Outline",
                    goal: "Goal",
                    expectedOutcome: "Outcome",
                    startsOn: "2026-08-01T00:00:00.000Z",
                    weeklyBudgetMinutes: 60,
                    summary: "Summary",
                    createdAt: "2026-08-01T00:00:00.000Z",
                    updatedAt: "2026-08-08T00:00:00.000Z",
                    schemaVersion: 1,
                  }),
                },
              },
            },
          ],
          moreComing: false,
        },
      ],
    },
  ]);

  const result = await readCloudKitJournal({
    config,
    container: fake.container,
    query: { projectId: projectID, kinds: ["coursePlan"] },
  });

  assert.equal(result.status, "ready");
  assert.deepEqual(result.records.map((record) => record.kind), ["coursePlan"]);
});

test("journal projector creates an existing workspace view model from canonical records", () => {
  const projection = projectJournalRecords(
    [
      {
        kind: "project",
        recordName: projectID,
        recordType: "Project",
        payload: {
          id: projectID,
          name: "Guitar",
          area: "Music",
          goal: "Build a daily fretboard habit",
          status: "active",
          currentNextStep: "Play the shape",
          defaultDurationMinutes: 30,
          updatedAt: "2026-08-08T00:00:00.000Z",
        },
      },
      {
        kind: "coursePlan",
        recordName: planID,
        recordType: "CoursePlan",
        payload: {
          id: planID,
          projectId: projectID,
          revision: 1,
          status: "active",
          courseTitle: "Fretboard foundations",
          goal: "Learn the map",
          expectedOutcome: "Play without hesitation",
          startsOn: "2026-08-01T00:00:00.000Z",
          deadline: "2026-09-01T00:00:00.000Z",
          weeklyBudgetMinutes: 120,
          summary: "A short plan",
          updatedAt: "2026-08-08T00:00:00.000Z",
        },
      },
      {
        kind: "planPhase",
        recordName: phaseID,
        recordType: "PlanPhase",
        payload: {
          id: phaseID,
          planId: planID,
          title: "Map the neck",
          objective: "Connect shapes",
          expectedProof: "One recorded run",
          progress: "active",
          ordinal: 1,
          targetStart: "2026-08-01T00:00:00.000Z",
          targetEnd: "2026-08-15T00:00:00.000Z",
        },
      },
      {
        kind: "plannedSession",
        recordName: plannedSessionID,
        recordType: "PlannedSession",
        payload: {
          id: plannedSessionID,
          planId: planID,
          phaseId: phaseID,
          projectId: projectID,
          title: "Play shape one",
          actionType: "practice",
          durationMinutes: 30,
          status: "scheduled",
          deadline: "2026-08-10T00:00:00.000Z",
          updatedAt: "2026-08-08T00:00:00.000Z",
        },
      },
    ],
    { asOf: "2026-08-09T00:00:00.000Z" },
  );

  assert.equal(projection.demos.length, 1);
  assert.equal(projection.demos[0].project.id, projectID);
  assert.equal(projection.demos[0].project.name, "Guitar");
  assert.equal(projection.demos[0].planTitle, "Fretboard foundations");
  assert.equal(projection.demos[0].planPhases[0].title, "Map the neck");
  assert.equal(projection.demos[0].sessions[0].title, "Play shape one");
  assert.equal(projection.demos[0].sourceLabel, "Real journal · CloudKit private database · read-only");
});
