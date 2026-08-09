import assert from "node:assert/strict";
import test from "node:test";

const { createWebJournalWriter, WebJournalWriteError } = await import(
  "../lib/journal-writer.ts"
);
const { MemoryRecoverableDraftStore, createRecoverableDraft } = await import(
  "../lib/recoverable-drafts.ts"
);
const { mergeJournalPayloads, resolveSyncConflict } = await import(
  "../lib/sync-conflicts.ts"
);

const config = {
  containerIdentifier: "iCloud.com.local.selfstudystudio",
  apiToken: "test-token",
  environment: "development",
  zoneName: "LearningJournalZone",
};

const projectID = "11111111-1111-4111-8111-111111111111";

function projectPayload(overrides = {}) {
  return {
    id: projectID,
    name: "Guitar",
    area: "Music",
    goal: "Build a daily fretboard habit",
    status: "active",
    currentNextStep: "Play the shape",
    lastActionType: "practice",
    defaultDurationMinutes: 30,
    createdAt: "2026-08-01T00:00:00Z",
    updatedAt: "2026-08-08T00:00:00Z",
    schemaVersion: 3,
    commitmentState: "ready",
    ...overrides,
  };
}

function projectRecord(overrides = {}) {
  return {
    kind: "project",
    recordName: projectID,
    recordType: "Project",
    payload: projectPayload(),
    ...overrides,
  };
}

function fakeCloudKit({ initialRecords = {}, rejectAtomic = false } = {}) {
  const records = new Map(Object.entries(initialRecords));
  const calls = [];
  let sequence = 10;

  function staleError(record) {
    return {
      recordName: record.recordName,
      reason: "serverRecordChanged",
      serverRecord: records.get(record.recordName),
    };
  }

  const database = {
    async modifyRecords(request, options) {
      calls.push({ request, options });
      const stale = request.recordsToSave.find((record) => {
        const current = records.get(record.recordName);
        return current && record.recordChangeTag !== current.recordChangeTag;
      });
      if (stale || rejectAtomic) {
        return {
          records: [],
          errors: stale ? [staleError(stale)] : [{ reason: "atomic batch rejected" }],
        };
      }

      const saved = request.recordsToSave.map((record) => {
        const saved = { ...record, recordChangeTag: `tag-${++sequence}` };
        records.set(record.recordName, saved);
        return saved;
      });
      return { records: saved, errors: [] };
    },
    async fetchRecords(recordNames) {
      return { records: recordNames.map((name) => records.get(name)).filter(Boolean) };
    },
  };

  return {
    calls,
    records,
    container: {
      async setUpAuth() {
        return { userRecordName: "user-record" };
      },
      privateCloudDatabase: database,
    },
  };
}

test("writes an approved Next Step batch atomically with independent base and target tags", async () => {
  const remote = projectRecord({
    recordChangeTag: "target-tag-1",
    payload: projectPayload({ currentNextStep: "Remote next step" }),
  });
  const fake = fakeCloudKit({ initialRecords: { [projectID]: remote } });
  const writer = createWebJournalWriter({
    mode: "real",
    config,
    container: fake.container,
  });

  const local = projectRecord({
    recordChangeTag: "target-tag-1",
    payload: projectPayload({ currentNextStep: "Write the bridge" }),
  });
  const result = await writer.writeBatch({
    operation: "updateNextStep",
    records: [local],
    guardedRecords: [
      {
        record: projectRecord({ recordName: projectID, recordChangeTag: "base-tag-1" }),
        role: "base",
        expectation: {
          baseRevisionID: projectID,
          baseRecordChangeTag: "base-tag-1",
          targetRevisionID: projectID,
          targetRecordChangeTag: "target-tag-1",
          recordState: "existingRecord",
          targetRecordState: "existingRecord",
        },
      },
      {
        record: local,
        role: "target",
        expectation: {
          baseRevisionID: projectID,
          baseRecordChangeTag: "base-tag-1",
          targetRevisionID: projectID,
          targetRecordChangeTag: "target-tag-1",
          recordState: "existingRecord",
          targetRecordState: "existingRecord",
        },
      },
    ],
  });

  assert.equal(result.status, "committed");
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0].options.atomic, true);
  assert.equal(fake.calls[0].options.savePolicy, "ifServerRecordUnchanged");
  assert.deepEqual(
    fake.calls[0].request.recordsToSave.map((record) => record.recordChangeTag),
    ["target-tag-1"],
  );
  assert.equal(fake.records.get(projectID).fields.currentNextStep.value, "Write the bridge");
});

test("stale writes return a conflict workspace and never retry or overwrite remote state", async () => {
  const remote = projectRecord({
    recordChangeTag: "remote-tag-2",
    payload: projectPayload({ currentNextStep: "iPhone changed this" }),
  });
  const fake = fakeCloudKit({ initialRecords: { [projectID]: remote } });
  const writer = createWebJournalWriter({
    mode: "real",
    config,
    container: fake.container,
  });
  const local = projectRecord({
    payload: projectPayload({ currentNextStep: "Web changed this" }),
    recordChangeTag: "stale-tag-1",
  });

  const result = await writer.writeBatch({
    operation: "updateNextStep",
    records: [local],
    guardedRecords: [
      {
        record: local,
        role: "target",
        expectation: {
          baseRevisionID: projectID,
          baseRecordChangeTag: "stale-tag-1",
          targetRevisionID: projectID,
          targetRecordChangeTag: "stale-tag-1",
          recordState: "existingRecord",
          targetRecordState: "existingRecord",
        },
      },
    ],
  });

  assert.equal(result.status, "conflict");
  assert.equal(fake.calls.length, 1);
  assert.equal(result.conflict?.localPayload.currentNextStep, "Web changed this");
  assert.equal(result.conflict?.serverPayload.currentNextStep, "iPhone changed this");
  assert.ok(result.conflict?.conflictingFields.includes("currentNextStep"));
  assert.equal(fake.records.get(projectID).payload.currentNextStep, "iPhone changed this");
});

test("plan activation sends base and new target records in one atomic group", async () => {
  const planID = "22222222-2222-4222-8222-222222222222";
  const phaseID = "33333333-3333-4333-8333-333333333333";
  const base = {
    kind: "coursePlan",
    recordName: "99999999-9999-4999-8999-999999999999",
    recordType: "CoursePlan",
    payload: {
      id: "99999999-9999-4999-8999-999999999999",
      projectId: projectID,
      revision: 1,
      status: "active",
      courseTitle: "Current plan",
      courseOutline: "Outline",
      goal: "Goal",
      expectedOutcome: "Outcome",
      startsOn: "2026-08-01T00:00:00Z",
      weeklyBudgetMinutes: 120,
      summary: "Current",
      createdAt: "2026-08-01T00:00:00Z",
      updatedAt: "2026-08-08T00:00:00Z",
      schemaVersion: 3,
    },
  };
  const plan = {
    kind: "coursePlan",
    recordName: planID,
    recordType: "CoursePlan",
    payload: {
      id: planID,
      projectId: projectID,
      revision: 2,
      planSeriesID: "99999999-9999-4999-8999-999999999999",
      revisionID: planID,
      baseRevisionID: base.recordName,
      supersedesID: base.recordName,
      status: "active",
      courseTitle: "New plan",
      courseOutline: "Outline",
      goal: "Goal",
      expectedOutcome: "Outcome",
      startsOn: "2026-08-01T00:00:00Z",
      weeklyBudgetMinutes: 120,
      summary: "New",
      createdAt: "2026-08-08T00:00:00Z",
      updatedAt: "2026-08-08T00:00:00Z",
      schemaVersion: 3,
    },
  };
  const phase = {
    kind: "planPhase",
    recordName: phaseID,
    recordType: "PlanPhase",
    payload: {
      id: phaseID,
      planId: planID,
      planRevisionID: planID,
      planSeriesID: base.recordName,
      isStructuralLocked: false,
      title: "Phase one",
      objective: "Build",
      expectedProof: "Demo",
      progress: "active",
      ordinal: 0,
      targetStart: "2026-08-01T00:00:00Z",
      targetEnd: "2026-08-15T00:00:00Z",
      createdAt: "2026-08-08T00:00:00Z",
      updatedAt: "2026-08-08T00:00:00Z",
      schemaVersion: 3,
    },
  };
  const fake = fakeCloudKit({ initialRecords: { [base.recordName]: { ...base, recordChangeTag: "base-tag" } } });
  const writer = createWebJournalWriter({ mode: "real", config, container: fake.container });
  const result = await writer.writeBatch({
    operation: "activateLearningPlan",
    records: [plan, phase],
    guardedRecords: [{
      record: base,
      role: "base",
      expectation: {
        baseRevisionID: base.recordName,
        baseRecordChangeTag: "base-tag",
        recordState: "existingRecord",
        targetRecordState: "newRecord",
      },
    }],
  });
  assert.equal(result.status, "committed");
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0].request.recordsToSave.length, 3);
  assert.ok(fake.calls[0].request.recordsToSave.some((record) => record.recordName === base.recordName && record.recordChangeTag === "base-tag"));
  assert.ok(fake.calls[0].request.recordsToSave.some((record) => record.recordName === planID && !record.recordChangeTag));
});

test("Qualifying Proof acceptance uses canonical payload records and atomic failure preserves the group", async () => {
  const acceptanceID = "66666666-6666-4666-8666-666666666666";
  const revisionID = "77777777-7777-4777-8777-777777777777";
  const proofID = "88888888-8888-4888-8888-888888888888";
  const phaseID = "33333333-3333-4333-8333-333333333333";
  const reviewID = "44444444-4444-4444-8444-444444444444";
  const acceptance = {
    kind: "evidenceAcceptance",
    recordName: acceptanceID,
    recordType: "EvidenceAcceptance",
    payload: {
      id: acceptanceID,
      contractId: "55555555-5555-4555-8555-555555555555",
      proofId: proofID,
      phaseId: phaseID,
      reviewId: reviewID,
      proofRevisionId: revisionID,
      acceptedCriteria: ["Runs"],
      acceptedAt: "2026-08-08T00:00:00Z",
    },
  };
  const revision = {
    kind: "proofRevision",
    recordName: revisionID,
    recordType: "ProofRevision",
    payload: {
      id: revisionID,
      proofId: proofID,
      revision: 1,
      title: "Demo",
      statement: "Runs",
      artifactChecksum: "sha256:test",
      createdAt: "2026-08-08T00:00:00Z",
    },
  };
  const fake = fakeCloudKit({ rejectAtomic: true });
  const writer = createWebJournalWriter({ mode: "real", config, container: fake.container });
  const result = await writer.writeBatch({
    operation: "acceptQualifyingProof",
    records: [acceptance, revision],
  });
  assert.equal(result.status, "partial");
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.records.size, 0);
  assert.equal(fake.calls[0].options.atomic, true);
  assert.match(fake.calls[0].request.recordsToSave[0].fields.payload.value, /^[A-Za-z0-9+/]+=*$/);
});

test("cancellation before transport does not authenticate or write", async () => {
  const fake = fakeCloudKit();
  const writer = createWebJournalWriter({ mode: "real", config, container: fake.container });
  const controller = new AbortController();
  controller.abort();
  const result = await writer.writeBatch({
    operation: "acceptQualifyingProof",
    records: [],
    signal: controller.signal,
  });
  assert.equal(result.status, "cancelled");
  assert.equal(fake.calls.length, 0);
});

test("different-field edits merge while same-field and structural collisions remain explicit", () => {
  const base = projectPayload({ goal: "Learn the map", currentNextStep: "Play the shape" });
  const local = { ...base, goal: "Learn the map in every key" };
  const remote = { ...base, currentNextStep: "Record one minute" };
  const compatible = mergeJournalPayloads(base, local, remote, { kind: "project" });
  assert.deepEqual(compatible.conflictingFields, []);
  assert.equal(compatible.payload.goal, "Learn the map in every key");
  assert.equal(compatible.payload.currentNextStep, "Record one minute");

  const sameField = mergeJournalPayloads(
    base,
    { ...base, goal: "Web goal" },
    { ...base, goal: "iPhone goal" },
    { kind: "project" },
  );
  assert.deepEqual(sameField.conflictingFields, ["goal"]);

  const structural = mergeJournalPayloads(
    { id: "plan", title: "Plan", objective: "Old" },
    { id: "plan", title: "Plan", objective: "Web" },
    { id: "plan", title: "Plan", objective: "iPhone" },
    { kind: "coursePlan" },
  );
  assert.ok(structural.conflictingFields.includes("objective"));
  assert.equal(structural.structural, true);
});

test("recoverable drafts survive a new store instance and clear only after semantic completion", async () => {
  const backing = new Map();
  const firstStore = new MemoryRecoverableDraftStore(backing);
  const draft = createRecoverableDraft({
    kind: "learningPlan",
    projectId: projectID,
    payload: { title: "Bridge plan" },
  });
  await firstStore.save(draft);

  const restartedStore = new MemoryRecoverableDraftStore(backing);
  assert.equal((await restartedStore.list()).length, 1);
  assert.equal((await restartedStore.get(draft.id)).payload.title, "Bridge plan");
  await restartedStore.clearAfterCloudCompletion(draft.id, { status: "conflict" });
  assert.ok(await restartedStore.get(draft.id));
  await restartedStore.clearAfterCloudCompletion(draft.id, { status: "committed" });
  assert.equal(await restartedStore.get(draft.id), undefined);
});

test("Demo mode and unauthenticated Real mode never invoke CloudKit writes", async () => {
  const fake = fakeCloudKit();
  const record = projectRecord({ payload: projectPayload({ currentNextStep: "No write" }) });
  const demoWriter = createWebJournalWriter({ mode: "demo", config, container: fake.container });
  await assert.rejects(
    demoWriter.writeBatch({ operation: "updateNextStep", records: [record] }),
    (error) => error instanceof WebJournalWriteError && error.code === "demoWriteBlocked",
  );
  assert.equal(fake.calls.length, 0);

  const signedOutWriter = createWebJournalWriter({
    mode: "real",
    config,
    container: { ...fake.container, async setUpAuth() { return null; } },
  });
  const result = await signedOutWriter.writeBatch({
    operation: "updateNextStep",
    records: [record],
    guardedRecords: [{
      record,
      role: "target",
      expectation: {
        baseRevisionID: projectID,
        baseRecordChangeTag: "tag-1",
        targetRevisionID: projectID,
        targetRecordChangeTag: "tag-1",
        recordState: "existingRecord",
        targetRecordState: "existingRecord",
      },
    }],
  });
  assert.equal(result.status, "signed-out");
  assert.equal(fake.calls.length, 0);
});

test("conflict workspace keeps explicit resolution actions separate from Trail writes", () => {
  const conflict = {
    id: "conflict-1",
    kind: "project",
    basePayload: { id: projectID, currentNextStep: "Base" },
    localPayload: { id: projectID, currentNextStep: "Web" },
    serverPayload: { id: projectID, currentNextStep: "iPhone" },
    conflictingFields: ["currentNextStep"],
    source: "web",
    affectedRecords: [projectID],
  };
  assert.equal(resolveSyncConflict(conflict, "keepRemote").payload.currentNextStep, "iPhone");
  assert.equal(resolveSyncConflict(conflict, "discardLocal").payload.currentNextStep, "iPhone");
  assert.throws(() => resolveSyncConflict(conflict, "rebaseLocal"), /conflict/i);
  assert.throws(() => resolveSyncConflict(conflict, "fork"), /reserved/);
  const structuralConflict = {
    ...conflict,
    kind: "coursePlan",
    structural: true,
    localPayload: { id: "plan-1", revisionID: "plan-1", objective: "Web plan" },
    serverPayload: { id: "plan-1", revisionID: "plan-1", objective: "iPhone plan" },
    basePayload: { id: "plan-1", revisionID: "plan-1", objective: "Base plan" },
  };
  assert.equal(resolveSyncConflict(structuralConflict, "fork").resolution, "fork");
});
