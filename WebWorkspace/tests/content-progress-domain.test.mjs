import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { PROGRESS_SCHEMA_VERSION, PROGRESS_LIMITS, validateProject } from "../lib/content-progress/domain.ts";
import { projectProgress } from "../lib/content-progress/projection.ts";
import { setCompleted, reorder, deleteUnit, setPaused } from "../lib/content-progress/commands.ts";

const base = new URL("../../Sources/PersonalLearningJournal/Resources/ContentProgressContract/", import.meta.url);
const contract = JSON.parse(await readFile(new URL("progress-contract-v1.json", base), "utf8"));
const fixtures = JSON.parse(await readFile(new URL("progress-fixtures-v1.json", base), "utf8"));

test("reads the shared version, limits, valid projections and invalid errors", () => {
  assert.equal(contract.version, PROGRESS_SCHEMA_VERSION);
  assert.deepEqual(contract.limits, PROGRESS_LIMITS);
  assert.equal(fixtures.version, PROGRESS_SCHEMA_VERSION);
  for (const fixture of fixtures.valid) {
    validateProject(fixture.payload);
    assert.deepEqual(projectProgress(fixture.payload), fixture.expected, fixture.id);
  }
  for (const fixture of fixtures.invalid) {
    assert.throws(() => validateProject(fixture.payload), { code: fixture.error }, fixture.id);
  }
});

test("strict decode rejects unknown fields and non-canonical dates", () => {
  const original = fixtures.valid[0].payload;
  assert.throws(() => validateProject({ ...original, legacyGoal: "not part of progress" }), { code: "invalidShape" });
  assert.throws(() => validateProject({ ...original, updatedAt: "2026-10-17T03:00:00.1234Z" }), { code: "invalidTimestamps" });
});

test("commands preserve unit identity, time and progress across reorder and correction", () => {
  const original = fixtures.valid.find((entry) => entry.id === "partial").payload;
  const id = original.units[0].id;
  const later = new Date("2026-10-17T03:01:40Z");
  assert.equal(setCompleted(original, id, true, later), original);
  const changed = reorder(original, original.units.map((unit) => unit.id).reverse(), later);
  assert.equal(changed.units.at(-1).completedAt, original.units[0].completedAt);
  assert.equal(projectProgress(changed).currentUnitID, original.units[2].id);
  const cancelled = setCompleted(changed, id, false, later);
  assert.equal(cancelled.units.at(-1).completedAt, null);
  const again = setCompleted(cancelled, id, true, later);
  assert.equal(again.units.at(-1).completedAt, later.toISOString());
  const reduced = deleteUnit(again, original.units[1].id, later);
  assert.deepEqual(reduced.units.map((unit) => unit.order), [0, 1]);
  assert.equal(projectProgress(reduced).percentage, 50);
  const paused = setPaused(reduced, true, later);
  assert.throws(() => setCompleted(paused, original.units[2].id, true, later), { code: "pausedProject" });
});
