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

test("journal projector surfaces the latest confirmed record summary and amendment info", () => {
  const sessionID = "66666666-6666-4666-8666-666666666666";
  const revisionID = "77777777-7777-4777-8777-777777777777";
  const projection = projectJournalRecords(
    [
      {
        kind: "project",
        recordName: projectID,
        recordType: "Project",
        payload: {
          id: projectID,
          name: "Guitar",
          status: "active",
          updatedAt: "2026-08-08T00:00:00.000Z",
        },
      },
      {
        kind: "session",
        recordName: sessionID,
        recordType: "LearningSession",
        payload: {
          id: sessionID,
          projectId: projectID,
          source: "timer",
          actionType: "practice",
          startedAt: "2026-08-07T10:00:00.000Z",
          endedAt: "2026-08-07T10:30:00.000Z",
          durationMinutes: 30,
          note: "Confirmed: mapped the minor pentatonic shape",
          nextStepBefore: "Play the shape",
          nextStepAfter: "Add a metronome",
          createdAt: "2026-08-07T10:30:00.000Z",
          updatedAt: "2026-08-08T09:00:00.000Z",
          schemaVersion: 3,
          assessment: {
            progress: "mostlyCompleted",
            completedCriterionIDs: ["criterion-1"],
            understanding: "mostlyUnderstood",
            blocker: "Timing drifts at 90bpm",
            aiDraftedSummary: true,
            userEditedSummary: true,
            confirmedAt: "2026-08-08T09:00:00.000Z",
            revision: 2,
          },
        },
      },
      {
        kind: "session",
        recordName: "88888888-8888-4888-8888-888888888888",
        recordType: "LearningSession",
        payload: {
          id: "88888888-8888-4888-8888-888888888888",
          projectId: projectID,
          source: "quickLog",
          actionType: "practice",
          startedAt: "2026-08-06T10:00:00.000Z",
          endedAt: "2026-08-06T10:20:00.000Z",
          durationMinutes: 20,
          note: "Legacy quick log without confirmation",
          nextStepBefore: "",
          nextStepAfter: "",
          createdAt: "2026-08-06T10:20:00.000Z",
          updatedAt: "2026-08-06T10:20:00.000Z",
          schemaVersion: 3,
        },
      },
      {
        kind: "learningRecordRevision",
        recordName: revisionID,
        recordType: "LearningRecordRevision",
        payload: {
          id: revisionID,
          sessionID: sessionID,
          revision: 2,
          previousNote: "Played the shape once",
          previousAssessment: {
            progress: "partial",
            completedCriterionIDs: [],
            aiDraftedSummary: false,
            userEditedSummary: false,
            confirmedAt: "2026-08-07T10:30:00.000Z",
            revision: 1,
          },
          revisedAt: "2026-08-08T09:00:00.000Z",
        },
      },
    ],
    { asOf: "2026-08-09T00:00:00.000Z" },
  );

  assert.equal(projection.demos.length, 1);
  const records = projection.demos[0].confirmedRecords;
  assert.equal(records.length, 1);
  assert.equal(records[0].id, sessionID);
  assert.equal(records[0].summary, "Confirmed: mapped the minor pentatonic shape");
  assert.equal(records[0].progress, "mostlyCompleted");
  assert.equal(records[0].understanding, "mostlyUnderstood");
  assert.equal(records[0].revision, 2);
  assert.equal(records[0].confirmedAt, "2026-08-08T09:00:00.000Z");
  assert.equal(records[0].lastAmendedAt, "2026-08-08T09:00:00.000Z");
});

test("journal projector exposes pending adjustment suggestions read-only", () => {
  const pendingID = "99999999-9999-4999-8999-999999999999";
  const projection = projectJournalRecords(
    [
      {
        kind: "project",
        recordName: projectID,
        recordType: "Project",
        payload: {
          id: projectID,
          name: "Guitar",
          status: "active",
          updatedAt: "2026-08-08T00:00:00.000Z",
        },
      },
      {
        kind: "learningAdjustmentSuggestion",
        recordName: pendingID,
        recordType: "LearningAdjustmentSuggestion",
        payload: {
          id: pendingID,
          projectID: projectID,
          sourceSessionIDs: [],
          kind: "nextStep",
          title: "Repeated partial progress on shape drills",
          rationale: "The last 2 confirmed records ended partially.",
          proposedValue: "Split the drill into a smaller checkpoint",
          decision: "pending",
          createdAt: "2026-08-08T08:00:00.000Z",
        },
      },
      {
        kind: "learningAdjustmentSuggestion",
        recordName: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        recordType: "LearningAdjustmentSuggestion",
        payload: {
          id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          projectID: projectID,
          sourceSessionIDs: [],
          kind: "temporaryDuration",
          title: "Shorten late-night sessions",
          rationale: "Late-night sessions keep slipping.",
          proposedValue: "25 minutes for 3 days",
          decision: "adopted",
          createdAt: "2026-08-07T08:00:00.000Z",
          decidedAt: "2026-08-07T09:00:00.000Z",
        },
      },
      {
        kind: "learningAdjustmentSuggestion",
        recordName: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        recordType: "LearningAdjustmentSuggestion",
        payload: {
          id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          projectID: projectID,
          sourceSessionIDs: [],
          kind: "nextStep",
          title: "Deleted pending suggestion",
          rationale: "Superseded.",
          proposedValue: "Ignore",
          decision: "pending",
          createdAt: "2026-08-06T08:00:00.000Z",
          deletedAt: "2026-08-07T08:00:00.000Z",
        },
      },
    ],
    { asOf: "2026-08-09T00:00:00.000Z" },
  );

  const suggestions = projection.demos[0].pendingSuggestions;
  assert.equal(suggestions.length, 1);
  assert.deepEqual(suggestions[0], {
    id: pendingID,
    kind: "nextStep",
    title: "Repeated partial progress on shape drills",
    rationale: "The last 2 confirmed records ended partially.",
    proposedValue: "Split the drill into a smaller checkpoint",
    createdAt: "2026-08-08T08:00:00.000Z",
  });
});

test("journal projector tolerates unknown vNext fields and record kinds", () => {
  const projection = projectJournalRecords(
    [
      {
        kind: "project",
        recordName: projectID,
        recordType: "Project",
        payload: {
          id: projectID,
          name: "Guitar",
          status: "active",
          futureProjectField: { nested: ["values"] },
          updatedAt: "2026-08-08T00:00:00.000Z",
        },
      },
      {
        kind: "session",
        recordName: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        recordType: "LearningSession",
        payload: {
          id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          projectId: projectID,
          note: "Confirmed with extra fields",
          endedAt: "2026-08-07T10:30:00.000Z",
          assessment: {
            progress: "completed",
            completedCriterionIDs: [],
            aiDraftedSummary: false,
            userEditedSummary: false,
            confirmedAt: "2026-08-07T10:30:00.000Z",
            revision: 1,
            futureAssessmentField: 42,
          },
          futureSessionField: true,
        },
      },
      {
        kind: "futureEntityKind",
        recordName: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        recordType: "FutureEntity",
        payload: { id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", anything: "goes" },
      },
    ],
    { asOf: "2026-08-09T00:00:00.000Z" },
  );

  assert.equal(projection.demos.length, 1);
  assert.equal(projection.demos[0].confirmedRecords.length, 1);
  assert.equal(projection.demos[0].confirmedRecords[0].summary, "Confirmed with extra fields");
  assert.deepEqual(projection.issues, []);
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
