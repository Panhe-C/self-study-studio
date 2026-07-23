import assert from "node:assert/strict";
import test from "node:test";
import {
  deriveAttentionItems,
  deriveCapacityAllocation,
  deriveMeaningfulActivityBuckets,
  derivePortfolioDashboard,
  derivePortfolioPulse,
  deriveProjectDashboardState,
} from "../lib/dashboard.ts";
import { projectDemos } from "../lib/journal.ts";

test("aggregates every active project without treating evidence as completion", () => {
  const model = derivePortfolioDashboard(projectDemos, "now");

  assert.equal(model.projects.length, 2);
  assert.deepEqual(model.projects.map((item) => item.id), [
    "electric-guitar-improvisation",
    "cs336",
  ]);
  assert.deepEqual(model.pulse, {
    activeProjects: 2,
    evidenceReady: 3,
    evidenceExpected: 7,
    reviewsReady: 1,
    needsAttention: 2,
  });
  assert.ok(model.projects.every((item) => !("completionPercent" in item)));
});

test("derives a project card with active phase, evidence, activity, and next decision", () => {
  const card = deriveProjectDashboardState(projectDemos[0]);

  assert.equal(card.activePhase?.title, "Rhythm and root awareness");
  assert.equal(card.evidence.ready, 1);
  assert.equal(card.evidence.expected, 3);
  assert.equal(card.nextDecision.kind, "review");
  assert.equal(card.nextDecision.label, "Stage Review is ready");
  assert.equal(card.activity.length, 6);
});

test("orders review before carryover and inactivity without duplicate labels", () => {
  const items = deriveAttentionItems(projectDemos);

  assert.deepEqual(items.map((item) => item.kind), [
    "review",
    "carryover",
    "inactivity",
  ]);
  assert.equal(new Set(items.map((item) => item.id)).size, items.length);
});

test("buckets meaningful events for each project and changes the visible period", () => {
  const now = deriveMeaningfulActivityBuckets(projectDemos, "now");
  const twelveWeeks = deriveMeaningfulActivityBuckets(projectDemos, "12w");

  assert.equal(now.length, 2);
  assert.equal(now[0].buckets.length, 4);
  assert.equal(twelveWeeks[0].buckets.length, 12);
  assert.match(now[0].accessibleSummary, /meaningful events/i);
});

test("allocates capacity safely when availability is present or zero", () => {
  const normal = deriveCapacityAllocation(projectDemos);
  assert.equal(normal.plannedMinutes, 600);
  assert.equal(normal.availableMinutes, 720);
  assert.equal(normal.remainingMinutes, 120);
  assert.equal(normal.overCapacityMinutes, 0);

  const zeroAvailability = projectDemos.map((demo) => ({
    ...demo,
    capacity: { ...demo.capacity, availableMinutes: 0 },
  }));
  const zero = deriveCapacityAllocation(zeroAvailability);
  assert.ok(zero.segments.every((segment) => Number.isFinite(segment.percent)));
  assert.equal(zero.remainingMinutes, 0);
  assert.equal(zero.overCapacityMinutes, 600);
});

test("excludes archived projects from active cards", () => {
  const archived = {
    ...projectDemos[0],
    project: { ...projectDemos[0].project, id: "archived", status: "Completed" },
  };

  assert.equal(
    derivePortfolioPulse([...projectDemos, archived]).activeProjects,
    2,
  );
  assert.equal(
    derivePortfolioDashboard([...projectDemos, archived], "now").projects.length,
    2,
  );
});

test("handles an empty and large active portfolio deterministically", () => {
  const empty = derivePortfolioDashboard([], "now");
  assert.equal(empty.projects.length, 0);
  assert.equal(empty.totalActiveProjects, 0);
  assert.equal(empty.hasMoreProjects, false);

  const many = Array.from({ length: 10 }, (_, index) => ({
    ...projectDemos[index % projectDemos.length],
    project: {
      ...projectDemos[index % projectDemos.length].project,
      id: `project-${index}`,
      name: `Project ${index}`,
    },
  }));
  const large = derivePortfolioDashboard(many, "now");
  assert.equal(large.totalActiveProjects, 10);
  assert.equal(large.projects.length, 8);
  assert.equal(large.hasMoreProjects, true);
});
