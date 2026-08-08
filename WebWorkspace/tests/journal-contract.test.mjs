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
    assert.deepEqual(decoded.payload, fixture.expectedNormalized, fixture.id);
  }
});

test("accepts the shared fractional-seconds ISO fixture", () => {
  const fixture = fixtureSuite.valid.find((candidate) => candidate.id === "session-fractional");
  assert.ok(fixture);
  assert.deepEqual(decodeJournalRecord(fixture.payload, fixture.kind).payload, fixture.expectedNormalized);
});

test("uses the shared symbolic date format and rejects unknown formats", () => {
  assert.equal(journalRecordContract.formats.iso8601, "utcIso8601OptionalFraction");
  const fixture = fixtureSuite.valid.find((candidate) => candidate.id === "session-fractional");
  assert.ok(fixture);
  assert.deepEqual(decodeJournalRecord(fixture.payload, fixture.kind).payload, fixture.expectedNormalized);

  const unsupportedContract = {
    ...journalRecordContract,
    formats: { ...journalRecordContract.formats, iso8601: "unknownDateFormat" },
  };
  assert.throws(() => decodeJournalRecord(fixture.payload, fixture.kind, unsupportedContract));
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
  const encodeEntries = [...mapper.matchAll(/case \.([A-Za-z0-9_]+): "([^"]+)"/g)].map(([, kind, recordType]) => [kind, recordType]);
  const decodeEntries = [...mapper.matchAll(/case "([^"]+)": return \.([A-Za-z0-9_]+)\(/g)].map(([, recordType, kind]) => [recordType, kind]);
  const encode = Object.fromEntries(encodeEntries);
  const decode = Object.fromEntries(decodeEntries);
  const expected = Object.fromEntries(
    Object.entries(contractFixture.records).map(([kind, definition]) => [kind, definition.recordType]),
  );
  assert.equal(encodeEntries.length, Object.keys(expected).length, "CloudKit encoder must map every kind exactly once");
  assert.equal(new Set(encodeEntries.map(([, recordType]) => recordType)).size, encodeEntries.length, "CloudKit record types must be unique");
  assert.equal(decodeEntries.length, Object.keys(expected).length, "CloudKit decoder must map every record type exactly once");
  assert.equal(new Set(decodeEntries.map(([recordType]) => recordType)).size, decodeEntries.length, "CloudKit decoder record types must be unique");
  assert.deepEqual(encode, expected, "CloudKit kind-to-recordType mapping must be exact");
  assert.deepEqual(
    decode,
    Object.fromEntries(Object.entries(expected).map(([kind, recordType]) => [recordType, kind])),
    "CloudKit recordType-to-kind mapping must be exact",
  );
});

test("wires the shared contract source and resources into the unsigned app target", async () => {
  const project = await readFile(new URL("SelfStudyStudio.xcodeproj/project.pbxproj", repositoryRoot), "utf8");
  assert.match(project, /JournalRecordContract\.swift in Sources/);
  assert.match(project, /contract-v1\.json in Resources/);
  assert.match(project, /fixtures-v1\.json in Resources/);
  assert.match(project, /path = Sources\/PersonalLearningJournal\/Contracts\/JournalRecordContract\.swift/);
  assert.match(project, /path = Sources\/PersonalLearningJournal\/Resources\/JournalContract\/contract-v1\.json/);
  assert.match(project, /path = Sources\/PersonalLearningJournal\/Resources\/JournalContract\/fixtures-v1\.json/);
});

test("includes explicit nested/date invalid fixtures", () => {
  const expected = new Set([
    "project-invalid-safe-integer",
    "proof-invalid-int64",
    "session-invalid-date",
    "proof-invalid-artifact",
    "evidence-contract-invalid-trigger",
    "practice-routine-invalid-reminder",
    "review-invalid-map",
    "practice-routine-blocks-scalar",
    "practice-routine-blocks-duplicate-id",
    "practice-session-segments-scalar",
    "practice-session-segment-pause-with-active-time",
    "practice-session-summary-missing-block",
    "practice-session-summary-total-mismatch",
  ]);
  const actual = new Set(fixtureSuite.invalid.map((fixture) => fixture.id));
  assert.deepEqual(new Set([...expected].filter((id) => actual.has(id))), expected);
});
