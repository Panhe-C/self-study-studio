import assert from "node:assert/strict";
import test from "node:test";
import {
  deriveAttentionItems,
  deriveCapacityAllocation,
  deriveMeaningfulActivityBuckets,
  derivePortfolioDashboard,
  derivePortfolioPulse,
  deriveProjectDashboardState,
  formatDashboardDate,
} from "../lib/dashboard.ts";
import { projectDemos } from "../lib/journal.ts";

const AS_OF = "2026-07-24T12:00:00Z";

function cloneDemo(demo = projectDemos[0]) {
  return structuredClone(demo);
}

test("aggregates every active project and counts unique actionable attention items", () => {
  const model = derivePortfolioDashboard(projectDemos, "now", {
    asOf: AS_OF,
  });
  const attentionItems = deriveAttentionItems(projectDemos, { asOf: AS_OF });

  assert.equal(model.projects.length, 2);
  assert.equal(model.pulse.activeProjects, 2);
  assert.equal(model.pulse.evidenceReady, 3);
  assert.equal(model.pulse.evidenceExpected, 7);
  assert.equal(model.pulse.reviewsReady, 1);
  assert.equal(
    model.pulse.needsAttention,
    new Set(attentionItems.map((item) => item.id)).size,
  );
  assert.ok(
    attentionItems.length >
      new Set(attentionItems.map((item) => item.projectId)).size,
  );
  assert.ok(model.projects.every((item) => !("completionPercent" in item)));
});

test("formats the injected instant in an explicit local time zone", () => {
  assert.equal(
    formatDashboardDate("2026-07-24T16:30:00Z", "Asia/Shanghai"),
    "Saturday, July 25",
  );
});

test("counts multiple actionable items from one Project separately", () => {
  const demo = cloneDemo(projectDemos[0]);
  const attentionItems = deriveAttentionItems([demo], { asOf: AS_OF });

  assert.equal(new Set(attentionItems.map((item) => item.projectId)).size, 1);
  assert.ok(attentionItems.length > 1);
  assert.equal(
    derivePortfolioPulse([demo], { asOf: AS_OF }).needsAttention,
    new Set(attentionItems.map((item) => item.id)).size,
  );
});

test("uses the active Phase outcome, explicit Project status, and unified attention priority", () => {
  const demo = cloneDemo();
  demo.review.ready = false;

  const card = deriveProjectDashboardState(demo, { asOf: AS_OF });

  assert.equal(card.activePhase?.title, "Rhythm and root awareness");
  assert.equal(
    card.activePhase?.outcome,
    "Locate common roots, stabilize eighth notes, and make short phrases with only A, C, and D.",
  );
  assert.equal(card.outcome, card.activePhase?.outcome);
  assert.equal(card.status, "Active");
  assert.equal(card.nextDecision.kind, "carryover");
  assert.match(card.nextDecision.label, /Carryover/);
  assert.equal(card.nextDecision.tab, "plan");
});

test("derives the latest meaningful time from canonical Trail events", () => {
  const demo = cloneDemo(projectDemos[1]);
  demo.project.lastMeaningfulActivityAt = "2099-01-01T00:00:00Z";

  const items = deriveAttentionItems([demo], {
    asOf: "2026-07-26T03:14:00Z",
  });

  const inactivity = items.find((item) => item.kind === "inactivity");
  assert.ok(inactivity);
  assert.match(inactivity.label, /7 days/);
  assert.equal(inactivity.occurredAt, "2026-07-19T03:14:00.000Z");
});

test("reaches every Dashboard snapshot/load state without inventing data", async () => {
  const dashboard = await import("../lib/dashboard.ts");
  assert.equal(typeof dashboard.createDashboardSnapshot, "function");

  const createSnapshot = dashboard.createDashboardSnapshot;
  const ready = createSnapshot({ asOf: AS_OF, demos: projectDemos });
  const empty = createSnapshot({ asOf: AS_OF, demos: [] });
  const large = createSnapshot({
    asOf: AS_OF,
    demos: Array.from({ length: 9 }, (_, index) => {
      const demo = cloneDemo(projectDemos[1]);
      demo.project.id = `large-${index}`;
      return demo;
    }),
  });
  const partial = createSnapshot({
    asOf: AS_OF,
    demos: projectDemos,
    unavailableSections: ["capacity"],
  });
  const conflict = createSnapshot({
    asOf: AS_OF,
    demos: projectDemos,
    conflicts: [
      {
        id: "conflict-1",
        projectId: projectDemos[0].project.id,
        label: "Plan revision conflict",
        detail: "Choose which structural Plan revision remains canonical.",
        detectedAt: "2026-07-24T10:00:00Z",
      },
    ],
  });
  const loading = createSnapshot({ asOf: AS_OF, state: "loading" });
  const error = createSnapshot({
    asOf: AS_OF,
    state: "error",
    message: "Snapshot unavailable",
  });

  assert.deepEqual(
    [ready, empty, large, partial, conflict, loading, error].map(
      (snapshot) => snapshot.loadState,
    ),
    ["ready", "empty", "large", "partial", "conflict", "loading", "error"],
  );

  const conflictModel = derivePortfolioDashboard(conflict, "now");
  assert.equal(conflictModel.decisions[0].kind, "conflict");
  assert.equal(conflictModel.decisions[0].destination.section, "sync");

  const partialModel = derivePortfolioDashboard(partial, "now");
  assert.equal(partialModel.capacity, null);
  assert.deepEqual(partialModel.unavailableSections, ["capacity"]);
});

test("derives only source-backed proof, capacity, and Practice attention", () => {
  const proofBoundary = cloneDemo();
  proofBoundary.review.ready = true;
  proofBoundary.project.evidenceCount = 1;
  proofBoundary.project.evidenceTarget = 3;

  const overCapacity = cloneDemo(projectDemos[1]);
  overCapacity.project.id = "over-capacity";
  overCapacity.review.ready = false;
  overCapacity.capacity.plannedMinutes = 500;
  overCapacity.capacity.availableMinutes = 300;

  const practiceMarker = cloneDemo(projectDemos[1]);
  practiceMarker.project.id = "practice-marker";
  practiceMarker.review.ready = false;
  practiceMarker.practiceAttention = {
    id: "learning-log-balance",
    label: "Learning log needs attention",
    detail: practiceMarker.practiceBalanceNote,
    markedAt: "2026-07-19T02:20:00Z",
  };

  const plain = cloneDemo(projectDemos[1]);
  plain.project.id = "plain";
  plain.review.ready = false;
  plain.project.evidenceCount = 0;
  plain.project.evidenceTarget = 4;
  plain.sessions = plain.sessions.filter(
    (session) => session.status !== "Carryover",
  );

  const items = deriveAttentionItems(
    [proofBoundary, overCapacity, practiceMarker, plain],
    { asOf: AS_OF },
  );

  assert.ok(
    items.some(
      (item) =>
        item.projectId === proofBoundary.project.id && item.kind === "proof",
    ),
  );
  assert.ok(
    items.some(
      (item) =>
        item.projectId === overCapacity.project.id &&
        item.kind === "capacity",
    ),
  );
  assert.ok(
    items.some(
      (item) =>
        item.projectId === practiceMarker.project.id &&
        item.kind === "practice",
    ),
  );
  assert.ok(
    !items.some(
      (item) => item.projectId === plain.project.id && item.kind === "proof",
    ),
  );
});

test("keeps additional ready Reviews visible after selecting the primary decision", () => {
  const first = cloneDemo();
  first.project.id = "review-a";
  first.project.name = "Review A";
  first.sessions = [];
  const second = cloneDemo();
  second.project.id = "review-b";
  second.project.name = "Review B";
  second.sessions = [];

  const model = derivePortfolioDashboard([first, second], "now", {
    asOf: AS_OF,
  });

  assert.equal(model.decisions.filter((item) => item.kind === "review").length, 2);
  assert.equal(model.attention.filter((item) => item.kind === "review").length, 1);
});

test("ranks the top eight by explicit decision, severity, age, then stable id", () => {
  const many = Array.from({ length: 10 }, (_, index) => {
    const demo = cloneDemo(projectDemos[1]);
    demo.project.id = `project-${String(index).padStart(2, "0")}`;
    demo.project.name = `Project ${index}`;
    demo.review.ready = false;
    demo.sessions = demo.sessions.filter(
      (session) => session.status !== "Carryover",
    );
    delete demo.practiceAttention;
    demo.trail = [
      {
        id: `event-${index}`,
        date: "Jul 24",
        occurredAt: "2026-07-24T10:00:00Z",
        title: "Meaningful event",
        detail: "Canonical event",
        kind: "practice",
      },
    ];
    return demo;
  });
  many[9].review.ready = true;
  many[9].review.readySinceAt = "2026-07-24T09:00:00Z";

  const model = derivePortfolioDashboard(many, "now", { asOf: AS_OF });

  assert.equal(model.projects.length, 8);
  assert.equal(model.projects[0].id, "project-09");
  assert.ok(model.projects.some((project) => project.id === "project-09"));
  assert.ok(!model.projects.some((project) => project.id === "project-08"));
});

test("uses the highest-severity attention age before the stable Project id", () => {
  const olderDecision = cloneDemo();
  olderDecision.project.id = "z-older-decision";
  olderDecision.review.readySinceAt = "2026-07-20T09:00:00Z";
  olderDecision.sessions = [];
  olderDecision.trail = [
    {
      id: "recent-event",
      date: "Jul 24",
      occurredAt: "2026-07-24T10:00:00Z",
      title: "Recent event",
      detail: "The Review decision itself is older.",
      kind: "practice",
    },
  ];

  const newerDecisionWithOldTrail = cloneDemo();
  newerDecisionWithOldTrail.project.id = "a-newer-decision";
  newerDecisionWithOldTrail.review.readySinceAt = "2026-07-21T09:00:00Z";
  newerDecisionWithOldTrail.sessions = [];
  newerDecisionWithOldTrail.trail = [
    {
      id: "old-event",
      date: "Jul 19",
      occurredAt: "2026-07-19T10:00:00Z",
      title: "Old event",
      detail: "This must not replace the Review decision age.",
      kind: "practice",
    },
  ];

  const stableB = cloneDemo();
  stableB.project.id = "stable-b";
  stableB.review.readySinceAt = "2026-07-22T09:00:00Z";
  stableB.sessions = [];
  const stableA = cloneDemo();
  stableA.project.id = "stable-a";
  stableA.review.readySinceAt = "2026-07-22T09:00:00Z";
  stableA.sessions = [];

  const model = derivePortfolioDashboard(
    [stableB, newerDecisionWithOldTrail, stableA, olderDecision],
    "now",
    { asOf: AS_OF },
  );

  assert.deepEqual(
    model.projects.map((project) => project.id),
    [
      "z-older-decision",
      "a-newer-decision",
      "stable-a",
      "stable-b",
    ],
  );
});

test("makes Now, 4 weeks, and 12 weeks distinct and normalizes intensity to the visible maximum", () => {
  const demo = cloneDemo(projectDemos[1]);
  demo.trail = [
    {
      id: "only-event",
      date: "Jul 24",
      occurredAt: "2026-07-24T10:00:00Z",
      title: "Only meaningful event",
      detail: "One event is the visible maximum.",
      kind: "practice",
    },
  ];

  const now = deriveMeaningfulActivityBuckets([demo], "now", {
    asOf: AS_OF,
  });
  const fourWeeks = deriveMeaningfulActivityBuckets([demo], "4w", {
    asOf: AS_OF,
  });
  const twelveWeeks = deriveMeaningfulActivityBuckets([demo], "12w", {
    asOf: AS_OF,
  });

  assert.deepEqual(
    [now[0].buckets.length, fourWeeks[0].buckets.length, twelveWeeks[0].buckets.length],
    [1, 4, 12],
  );
  assert.equal(now[0].buckets[0].intensity, 3);
  assert.match(now[0].accessibleSummary, /across 1 week\./);
});

test("makes overload and zero availability explicit in capacity state", () => {
  const overloaded = cloneDemo(projectDemos[1]);
  overloaded.capacity.plannedMinutes = 500;
  overloaded.capacity.availableMinutes = 300;

  const capacity = deriveCapacityAllocation([overloaded]);
  assert.equal(capacity.status, "over");
  assert.equal(capacity.overCapacityMinutes, 200);
  assert.equal(capacity.warningSegment?.minutes, 200);
  assert.match(capacity.accessibleSummary, /exceeds.*200 minutes/i);
  assert.match(capacity.warning, /over capacity/i);

  overloaded.capacity.availableMinutes = 0;
  const zero = deriveCapacityAllocation([overloaded]);
  assert.equal(zero.status, "over");
  assert.ok(zero.segments.every((segment) => Number.isFinite(segment.percent)));
  assert.equal(zero.warningSegment?.percent, 100);
  assert.match(zero.accessibleSummary, /No availability is declared/i);
  assert.doesNotMatch(zero.accessibleSummary, /0 minutes remain/i);
});

test("excludes archived projects from active cards", () => {
  const archived = cloneDemo();
  archived.project.id = "archived";
  archived.project.status = "Completed";

  assert.equal(
    derivePortfolioPulse([...projectDemos, archived], { asOf: AS_OF })
      .activeProjects,
    2,
  );
  assert.equal(
    derivePortfolioDashboard([...projectDemos, archived], "now", {
      asOf: AS_OF,
    }).projects.length,
    2,
  );
});
