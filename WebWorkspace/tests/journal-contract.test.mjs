import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  JOURNAL_CONTRACT_VERSION,
  decodeJournalRecord,
  journalRecordContract,
  journalRecordKinds,
} from "../lib/journal-contract.ts";

const repositoryRoot = new URL("../../", import.meta.url);
const contractURL = new URL(
  "Sources/PersonalLearningJournal/Resources/JournalContract/contract-v1.json",
  repositoryRoot,
);
const fixturesURL = new URL(
  "Sources/PersonalLearningJournal/Resources/JournalContract/fixtures-v1.json",
  repositoryRoot,
);

const [contractFixture, fixtureSuite] = await Promise.all([
  readFile(contractURL, "utf8").then(JSON.parse),
  readFile(fixturesURL, "utf8").then(JSON.parse),
]);

test("loads the same versioned contract and covers every Journal kind", () => {
  assert.equal(contractFixture.version, JOURNAL_CONTRACT_VERSION);
  assert.equal(journalRecordContract.version, contractFixture.version);
  assert.deepEqual(
    journalRecordKinds().sort(),
    Object.keys(contractFixture.records).sort(),
  );
  assert.deepEqual(
    new Set(fixtureSuite.valid.map((fixture) => fixture.kind)),
    new Set(journalRecordKinds()),
  );
});

test("decodes every shared valid fixture with the same normalization", () => {
  for (const fixture of fixtureSuite.valid) {
    const decoded = decodeJournalRecord(fixture.payload, fixture.kind);
    assert.equal(decoded.kind, fixture.kind);
    assert.equal(typeof decoded.payload.id, "string", fixture.id);
  }

  const session = fixtureSuite.valid.find((fixture) => fixture.id === "session-trimmed");
  assert.equal(decodeJournalRecord(session.payload, session.kind).payload.note, "Read chapter one");
  assert.equal(
    decodeJournalRecord(session.payload, session.kind).payload.nextStepBefore,
    "Start",
  );

  const routine = fixtureSuite.valid.find((fixture) => fixture.id === "practice-routine");
  const normalizedRoutine = decodeJournalRecord(routine.payload, routine.kind).payload;
  assert.equal(normalizedRoutine.name, "Focused build");
  assert.equal(normalizedRoutine.symbolName, "hammer");
});

test("rejects every shared invalid fixture, including one-sided field drift", () => {
  for (const fixture of fixtureSuite.invalid) {
    assert.throws(
      () => decodeJournalRecord(fixture.payload, fixture.kind),
      undefined,
      fixture.id,
    );
  }
});

test("contract field metadata remains the exact source for the Web decoder", () => {
  assert.deepEqual(journalRecordContract, contractFixture);
  for (const [kind, definition] of Object.entries(contractFixture.records)) {
    assert.ok(definition.recordType, `${kind} must retain a CloudKit record type`);
    assert.ok(Object.keys(definition.fields).length > 0, `${kind} must declare fields`);
  }
});

test("keeps the existing CloudKit record-type names stable", async () => {
  const mapper = await readFile(
    new URL(
      "Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift",
      repositoryRoot,
    ),
    "utf8",
  );
  for (const [kind, definition] of Object.entries(contractFixture.records)) {
    assert.match(
      mapper,
      new RegExp(`\\"${definition.recordType}\\"`),
      `${kind} must remain mapped to ${definition.recordType}`,
    );
  }
});
