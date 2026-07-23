import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const repositoryRoot = new URL("../../", import.meta.url);

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
