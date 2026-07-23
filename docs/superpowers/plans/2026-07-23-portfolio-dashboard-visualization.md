# Portfolio Dashboard Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-Project Web Dashboard with a decision-first portfolio view that compares every active Project using cards, Review/attention summaries, meaningful-activity visualization, and capacity allocation.

**Architecture:** Add a pure `dashboard.ts` derivation module between Journal demo data and React. Keep Dashboard presentation in a focused `portfolio-dashboard.tsx` client component, while `workspace-app.tsx` only supplies navigation callbacks. CSS remains in the existing global stylesheet and uses semantic class names, responsive stacking, and accessible text equivalents for every visualization.

**Tech Stack:** TypeScript 5.9, React 19, Next.js 16 through Vinext/Vite, Node 22 test runner, CSS Grid/Flexbox, existing Cloudflare worker build.

## Global Constraints

- Project outcomes, expected Proof, Review readiness, and explicit decisions remain the primary signals.
- Time, frequency, counts, and charts are explanatory Progress Signals, not a headline definition of progress.
- Do not add an overall completion percentage, streak, rank, grade, or opaque engagement score.
- The Dashboard is read-oriented; consequential Plan, Review, Proof-acceptance, and Project-status changes remain in the Project Workspace.
- Meaningful activity includes Sessions, Practice Summaries, Proof, activated Plans, published Reviews/Decisions, and Project-status decisions; exclude drafts, navigation, autosaves, Daily Overrides, and sync retries.
- Desktop and narrow layouts preserve the order: portfolio pulse, active Projects, decisions/attention, explanatory visualizations.
- Every chart must have a textual or ARIA equivalent, and color must not be the only status carrier.
- Do not add charting or state-management dependencies.

---

## File Structure

- Create `WebWorkspace/lib/dashboard.ts`: pure display-model types and derivation functions.
- Modify `WebWorkspace/lib/journal.ts`: add machine-readable timestamps to meaningful Journal events and the latest meaningful Project activity.
- Create `WebWorkspace/tests/dashboard.test.mjs`: direct unit coverage for aggregation, ordering, activity, capacity, and edge cases.
- Create `WebWorkspace/app/portfolio-dashboard.tsx`: Dashboard-only React components and period state.
- Modify `WebWorkspace/app/workspace-app.tsx`: remove the old inline Dashboard and mount `PortfolioDashboard`.
- Modify `WebWorkspace/app/globals.css`: replace obsolete single-Project Dashboard styles with the approved portfolio layout and responsive rules.
- Modify `WebWorkspace/tests/rendered-html.test.mjs`: verify the server-rendered portfolio hierarchy and accessible chart summaries.
- Modify `WebWorkspace/tests/demo-data.test.mjs`: verify the Dashboard module/component boundaries.
- Modify `WebWorkspace/package.json`: enable Node's TypeScript stripping for direct selector tests.

### Task 1: Build and test the portfolio derivation model

**Files:**
- Create: `WebWorkspace/lib/dashboard.ts`
- Create: `WebWorkspace/tests/dashboard.test.mjs`
- Modify: `WebWorkspace/lib/journal.ts:16-30,31-37,110-298`
- Modify: `WebWorkspace/package.json:8-13`

**Interfaces:**
- Consumes: `ProjectDemo[]` from `WebWorkspace/lib/journal.ts`.
- Produces:
  - `derivePortfolioPulse(demos: ProjectDemo[]): PortfolioPulse`
  - `deriveProjectDashboardState(demo: ProjectDemo): ProjectDashboardState`
  - `deriveAttentionItems(demos: ProjectDemo[]): AttentionItem[]`
  - `deriveMeaningfulActivityBuckets(demos: ProjectDemo[], period: DashboardPeriod): ActivityRow[]`
  - `deriveCapacityAllocation(demos: ProjectDemo[]): CapacityAllocation`
  - `derivePortfolioDashboard(demos: ProjectDemo[], period: DashboardPeriod): PortfolioDashboardModel`

- [ ] **Step 1: Add failing selector tests**

Create `WebWorkspace/tests/dashboard.test.mjs`:

```js
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
```

- [ ] **Step 2: Run selector tests and verify the missing module failure**

Run:

```bash
cd WebWorkspace
node --experimental-strip-types --test tests/dashboard.test.mjs
```

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `lib/dashboard.ts`.

- [ ] **Step 3: Add machine-readable meaningful-activity timestamps**

Extend `ProjectSummary` and `TrailItem` in `WebWorkspace/lib/journal.ts`:

```ts
export type ProjectSummary = {
  id: string;
  token: string;
  name: string;
  area: string;
  goal: string;
  phase: string;
  phaseWindow: string;
  status: "Active" | "Paused" | "Completed" | "Abandoned";
  accent: string;
  nextStep: string;
  expectedProof: string;
  evidenceCount: number;
  evidenceTarget: number;
  lastMeaningfulActivity: string;
  lastMeaningfulActivityAt: string;
};

export type TrailItem = {
  id: string;
  date: string;
  occurredAt: string;
  title: string;
  detail: string;
  kind: "practice" | "proof" | "plan" | "review";
};
```

Add these values to the two Project records:

```ts
// guitarDemo.project
lastMeaningfulActivityAt: "2026-07-22T12:14:00Z",

// cs336Demo.project
lastMeaningfulActivityAt: "2026-07-18T03:14:00Z",
```

Replace the guitar Trail entries with:

```ts
trail: [
  { id: "guitar-trail-1", date: "Yesterday · 20:14", occurredAt: "2026-07-22T12:14:00Z", title: "Improvisation foundation practice", detail: "31 min · rhythm 5m · fretboard 6m · technique 4m · phrases 11m · review 5m", kind: "practice" },
  { id: "guitar-trail-2", date: "Jul 20 · 20:48", occurredAt: "2026-07-20T12:48:00Z", title: "Three-note improvisation added", detail: "Proof: steady opening, but the second phrase rushes ahead of the backing track.", kind: "proof" },
  { id: "guitar-trail-3", date: "Jul 18 · 19:30", occurredAt: "2026-07-18T11:30:00Z", title: "Minimum executable routine selected", detail: "Five guided Blocks created from the 30-minute daily template.", kind: "plan" },
  { id: "guitar-trail-4", date: "Jul 15 · 09:12", occurredAt: "2026-07-15T01:12:00Z", title: "12-week plan activated", detail: "Revision 1 · 6 two-week phases · weekly comparison recording enabled.", kind: "review" },
],
```

Replace the CS336 Trail entries with:

```ts
trail: [
  { id: "cs-trail-1", date: "Jul 19 · 10:20", occurredAt: "2026-07-19T02:20:00Z", title: "BPE implementation session", detail: "52 min · recall 8m · build 38m · learning log 6m", kind: "practice" },
  { id: "cs-trail-2", date: "Jul 19 · 11:14", occurredAt: "2026-07-19T03:14:00Z", title: "BPE merge diagram added", detail: "Proof connects corpus pair counts, merge selection, vocabulary growth, encode, and decode.", kind: "proof" },
  { id: "cs-trail-3", date: "Jul 14 · 20:40", occurredAt: "2026-07-14T12:40:00Z", title: "Global-map stage reviewed", detail: "Advanced after explaining the LLM pipeline and next-token objective without notes.", kind: "review" },
  { id: "cs-trail-4", date: "Jul 1 · 09:00", occurredAt: "2026-07-01T01:00:00Z", title: "20-week core route activated", detail: "Revision 1 · 8 stages · 6–8 hours available each week.", kind: "plan" },
],
```

- [ ] **Step 4: Implement the pure derivation module**

Create `WebWorkspace/lib/dashboard.ts`:

```ts
import type { ProjectDemo } from "./journal";

export type DashboardPeriod = "now" | "4w" | "12w";
export type AttentionKind = "conflict" | "review" | "carryover" | "proof" | "capacity" | "practice" | "inactivity";

export type PortfolioPulse = {
  activeProjects: number;
  evidenceReady: number;
  evidenceExpected: number;
  reviewsReady: number;
  needsAttention: number;
};

export type ActivityBucket = { label: string; count: number; intensity: 0 | 1 | 2 | 3 };
export type ActivityRow = {
  projectId: string;
  projectName: string;
  buckets: ActivityBucket[];
  accessibleSummary: string;
};

export type AttentionItem = {
  id: string;
  projectId: string;
  projectName: string;
  kind: AttentionKind;
  label: string;
  detail: string;
  tab: "overview" | "plan" | "practice" | "proof" | "trail" | "reviews";
  priority: number;
};

export type ProjectDashboardState = {
  id: string;
  token: string;
  name: string;
  area: string;
  accent: string;
  phaseWindow: string;
  outcome: string;
  expectedProof: string;
  activePhase?: { title: string; window: string };
  evidence: { ready: number; expected: number };
  activity: number[];
  attention: boolean;
  nextDecision: {
    kind: "review" | "proof" | "next-step";
    label: string;
    detail: string;
    tab: "overview" | "proof" | "reviews";
  };
};

export type CapacityAllocation = {
  plannedMinutes: number;
  availableMinutes: number;
  remainingMinutes: number;
  overCapacityMinutes: number;
  segments: Array<{
    projectId: string;
    label: string;
    minutes: number;
    percent: number;
    color: string;
  }>;
  accessibleSummary: string;
};

export type PortfolioDashboardModel = {
  pulse: PortfolioPulse;
  projects: ProjectDashboardState[];
  totalActiveProjects: number;
  hasMoreProjects: boolean;
  decisions: AttentionItem[];
  attention: AttentionItem[];
  movement: ActivityRow[];
  capacity: CapacityAllocation;
};

const DASHBOARD_REFERENCE_TIME = Date.parse("2026-07-23T12:00:00Z");
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

function activeDemos(demos: ProjectDemo[]) {
  return demos.filter((demo) => demo.project.status === "Active");
}

function activityCounts(demo: ProjectDemo, bucketCount: number): number[] {
  const counts = Array.from({ length: bucketCount }, () => 0);
  for (const event of demo.trail) {
    const age = Math.floor(
      (DASHBOARD_REFERENCE_TIME - Date.parse(event.occurredAt)) / WEEK_MS,
    );
    if (age >= 0 && age < bucketCount) {
      counts[bucketCount - 1 - age] += 1;
    }
  }
  return counts;
}

export function deriveProjectDashboardState(demo: ProjectDemo): ProjectDashboardState {
  const activePhase = demo.planPhases.find((phase) => phase.status === "Active");
  const hasCarryover = demo.sessions.some((session) => session.status === "Carryover");
  const evidenceMissing = demo.project.evidenceCount < demo.project.evidenceTarget;
  const nextDecision = demo.review.ready
    ? {
        kind: "review" as const,
        label: "Stage Review is ready",
        detail: demo.review.headline,
        tab: "reviews" as const,
      }
    : evidenceMissing
      ? {
          kind: "proof" as const,
          label: "Expected Proof is still forming",
          detail: demo.project.nextStep,
          tab: "proof" as const,
        }
      : {
          kind: "next-step" as const,
          label: "Continue the canonical Next Step",
          detail: demo.project.nextStep,
          tab: "overview" as const,
        };

  return {
    id: demo.project.id,
    token: demo.project.token,
    name: demo.project.name,
    area: demo.project.area,
    accent: demo.project.accent,
    phaseWindow: demo.project.phaseWindow,
    outcome: demo.project.goal,
    expectedProof: demo.project.expectedProof,
    activePhase: activePhase
      ? { title: activePhase.title, window: activePhase.window }
      : undefined,
    evidence: {
      ready: demo.project.evidenceCount,
      expected: demo.project.evidenceTarget,
    },
    activity: activityCounts(demo, 6),
    attention: hasCarryover
      || demo.review.ready
      || DASHBOARD_REFERENCE_TIME - Date.parse(demo.project.lastMeaningfulActivityAt) >= 5 * 24 * 60 * 60 * 1000,
    nextDecision,
  };
}

export function deriveAttentionItems(demos: ProjectDemo[]): AttentionItem[] {
  const items: AttentionItem[] = [];
  for (const demo of activeDemos(demos)) {
    if (demo.review.ready) {
      items.push({
        id: `${demo.project.id}-review`,
        projectId: demo.project.id,
        projectName: demo.project.name,
        kind: "review",
        label: "Stage Review ready",
        detail: demo.review.summary,
        tab: "reviews",
        priority: 20,
      });
    }
    const carryovers = demo.sessions.filter((session) => session.status === "Carryover");
    if (carryovers.length > 0) {
      items.push({
        id: `${demo.project.id}-carryover`,
        projectId: demo.project.id,
        projectName: demo.project.name,
        kind: "carryover",
        label: `${carryovers.length} Carryover awaiting a decision`,
        detail: carryovers[0].title,
        tab: "plan",
        priority: 30,
      });
    }
    const quietDays = Math.floor(
      (DASHBOARD_REFERENCE_TIME - Date.parse(demo.project.lastMeaningfulActivityAt))
        / (24 * 60 * 60 * 1000),
    );
    if (quietDays >= 5) {
      items.push({
        id: `${demo.project.id}-inactivity`,
        projectId: demo.project.id,
        projectName: demo.project.name,
        kind: "inactivity",
        label: `No meaningful activity for ${quietDays} days`,
        detail: demo.project.nextStep,
        tab: "trail",
        priority: 70,
      });
    }
  }
  return items.sort((a, b) => a.priority - b.priority);
}

export function derivePortfolioPulse(demos: ProjectDemo[]): PortfolioPulse {
  const active = activeDemos(demos);
  const attentionProjectIds = new Set(
    deriveAttentionItems(active).map((item) => item.projectId),
  );
  return {
    activeProjects: active.length,
    evidenceReady: active.reduce((sum, demo) => sum + demo.project.evidenceCount, 0),
    evidenceExpected: active.reduce((sum, demo) => sum + demo.project.evidenceTarget, 0),
    reviewsReady: active.filter((demo) => demo.review.ready).length,
    needsAttention: attentionProjectIds.size,
  };
}

export function deriveMeaningfulActivityBuckets(
  demos: ProjectDemo[],
  period: DashboardPeriod,
): ActivityRow[] {
  const bucketCount = period === "12w" ? 12 : 4;
  return activeDemos(demos).map((demo) => {
    const counts = activityCounts(demo, bucketCount);
    const buckets = counts.map((count, index) => ({
      label: `${bucketCount - index} weeks ago`,
      count,
      intensity: Math.min(3, count) as 0 | 1 | 2 | 3,
    }));
    const total = buckets.reduce((sum, bucket) => sum + bucket.count, 0);
    return {
      projectId: demo.project.id,
      projectName: demo.project.name,
      buckets,
      accessibleSummary: `${demo.project.name}: ${total} meaningful events across ${bucketCount} weeks.`,
    };
  });
}

export function deriveCapacityAllocation(demos: ProjectDemo[]): CapacityAllocation {
  const active = activeDemos(demos);
  const plannedMinutes = active.reduce((sum, demo) => sum + demo.capacity.plannedMinutes, 0);
  const availableMinutes = active.reduce((sum, demo) => sum + demo.capacity.availableMinutes, 0);
  const denominator = Math.max(plannedMinutes, availableMinutes, 1);
  const remainingMinutes = Math.max(0, availableMinutes - plannedMinutes);
  const overCapacityMinutes = Math.max(0, plannedMinutes - availableMinutes);
  const segments = active.map((demo) => ({
    projectId: demo.project.id,
    label: demo.project.name,
    minutes: demo.capacity.plannedMinutes,
    percent: (demo.capacity.plannedMinutes / denominator) * 100,
    color: demo.project.accent,
  }));
  if (remainingMinutes > 0) {
    segments.push({
      projectId: "remaining",
      label: "Available",
      minutes: remainingMinutes,
      percent: (remainingMinutes / denominator) * 100,
      color: "#e5e7eb",
    });
  }
  return {
    plannedMinutes,
    availableMinutes,
    remainingMinutes,
    overCapacityMinutes,
    segments,
    accessibleSummary: `${plannedMinutes} planned minutes of ${availableMinutes} available; ${remainingMinutes} minutes remain.`,
  };
}

export function derivePortfolioDashboard(
  demos: ProjectDemo[],
  period: DashboardPeriod,
): PortfolioDashboardModel {
  const active = activeDemos(demos);
  const attention = deriveAttentionItems(demos);
  return {
    pulse: derivePortfolioPulse(demos),
    projects: active.slice(0, 8).map(deriveProjectDashboardState),
    totalActiveProjects: active.length,
    hasMoreProjects: active.length > 8,
    decisions: attention.filter((item) => item.kind === "review"),
    attention: attention.filter((item) => item.kind !== "review"),
    movement: deriveMeaningfulActivityBuckets(demos, period),
    capacity: deriveCapacityAllocation(demos),
  };
}
```

- [ ] **Step 5: Update the Node test command**

Change the `test` script in `WebWorkspace/package.json` to:

```json
"test": "npm run build && node --experimental-strip-types --test tests/*.test.mjs"
```

- [ ] **Step 6: Run selector tests and verify they pass**

Run:

```bash
cd WebWorkspace
node --experimental-strip-types --test tests/dashboard.test.mjs
```

Expected: 7 tests pass, 0 fail.

- [ ] **Step 7: Commit the derivation model**

```bash
git add WebWorkspace/lib/dashboard.ts WebWorkspace/lib/journal.ts WebWorkspace/tests/dashboard.test.mjs WebWorkspace/package.json
git commit -m "feat(web): derive portfolio dashboard state"
```

### Task 2: Render the portfolio cards and decision hierarchy

**Files:**
- Create: `WebWorkspace/app/portfolio-dashboard.tsx`
- Modify: `WebWorkspace/app/workspace-app.tsx:1-18,259-262,287-449`
- Modify: `WebWorkspace/tests/demo-data.test.mjs`
- Modify: `WebWorkspace/tests/rendered-html.test.mjs`

**Interfaces:**
- Consumes: `derivePortfolioDashboard(projectDemos, period)` and `ProjectTab`.
- Produces:
  - `PortfolioDashboard({ openProject, openProjects, openReviews }: PortfolioDashboardProps)`
  - semantic markup for pulse cards, Project cards, decision/attention panels, movement matrix, and capacity bar.

- [ ] **Step 1: Add failing component-boundary and rendered-output assertions**

Append to `WebWorkspace/tests/demo-data.test.mjs`:

```js
test("keeps portfolio derivation and dashboard presentation in focused modules", async () => {
  const [workspace, dashboard, selectors] = await Promise.all([
    readFile(workspaceUrl, "utf8"),
    readFile(new URL("../app/portfolio-dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/dashboard.ts", import.meta.url), "utf8"),
  ]);

  assert.match(workspace, /<PortfolioDashboard/);
  assert.doesNotMatch(workspace, /const demo = projectDemos\\[0\\]/);
  assert.match(dashboard, /derivePortfolioDashboard/);
  assert.match(dashboard, /PortfolioProjectCard/);
  assert.match(dashboard, /PortfolioMovementMatrix/);
  assert.match(selectors, /deriveAttentionItems/);
  assert.match(selectors, /deriveCapacityAllocation/);
});
```

Replace the old Dashboard-specific assertions in the first test of `WebWorkspace/tests/rendered-html.test.mjs` with:

```js
assert.match(html, /Your learning portfolio/);
assert.match(html, /Active Projects/);
assert.match(html, /Electric guitar improvisation/);
assert.match(html, /CS336 · Language Modeling from Scratch/);
assert.match(html, /Stage Review is ready/);
assert.match(html, /Portfolio movement/);
assert.match(html, /Next 2 weeks capacity/);
assert.match(html, /meaningful events across 4 weeks/i);
assert.doesNotMatch(html, /completion percentage|streak|rank|grade/i);
```

- [ ] **Step 2: Run the relevant tests and verify they fail**

Run:

```bash
cd WebWorkspace
node --experimental-strip-types --test tests/demo-data.test.mjs tests/rendered-html.test.mjs
```

Expected: FAIL because `portfolio-dashboard.tsx` does not exist and the old Dashboard copy still renders.

- [ ] **Step 3: Create the focused Dashboard component**

Create `WebWorkspace/app/portfolio-dashboard.tsx` with:

```tsx
"use client";

import { useMemo, useState, type CSSProperties } from "react";
import {
  derivePortfolioDashboard,
  type AttentionItem,
  type DashboardPeriod,
  type ProjectDashboardState,
} from "../lib/dashboard";
import { projectDemos, type ProjectTab } from "../lib/journal";

type PortfolioDashboardProps = {
  openProject: (id: string, tab?: ProjectTab) => void;
  openProjects: () => void;
  openReviews: () => void;
};

const periods: Array<{ id: DashboardPeriod; label: string }> = [
  { id: "now", label: "Now" },
  { id: "4w", label: "4 weeks" },
  { id: "12w", label: "12 weeks" },
];

function PulseCard({ label, value, detail, attention = false }: {
  label: string;
  value: string;
  detail: string;
  attention?: boolean;
}) {
  return (
    <article className={`portfolio-pulse-card${attention ? " attention" : ""}`}>
      <span>{label}</span><strong>{value}</strong><small>{detail}</small>
    </article>
  );
}

function PortfolioProjectCard({ project, openProject }: {
  project: ProjectDashboardState;
  openProject: PortfolioDashboardProps["openProject"];
}) {
  const maxActivity = Math.max(...project.activity, 1);
  const evidencePercent = project.evidence.expected === 0
    ? 0
    : Math.min(100, project.evidence.ready / project.evidence.expected * 100);
  return (
    <article className="portfolio-project-card">
      <header>
        <div className="portfolio-project-identity">
          <span className="portfolio-token" style={{ "--project-accent": project.accent } as CSSProperties}>{project.token}</span>
          <div><h4>{project.name}</h4><p>{project.area} · {project.phaseWindow}</p></div>
        </div>
        <span className={`portfolio-state${project.attention ? " attention" : ""}`}>{project.attention ? "Attention" : "On course"}</span>
      </header>
      <div className="portfolio-project-body">
        <div>
          <span className="mini-label">Active Phase</span>
          <h5>{project.activePhase?.title ?? "No active Phase"}</h5>
          <p className="portfolio-outcome">{project.outcome}</p>
          <div className="portfolio-evidence">
            <div><span>Expected Proof</span><strong>{project.evidence.ready} of {project.evidence.expected} signals ready</strong></div>
            <div className="portfolio-evidence-track" aria-label={`${project.evidence.ready} of ${project.evidence.expected} expected Proof signals ready`}>
              <span style={{ width: `${evidencePercent}%` }} />
            </div>
          </div>
        </div>
        <div className="portfolio-activity">
          <span className="mini-label">Meaningful activity</span>
          <div className="portfolio-sparkline" aria-label={`${project.name} meaningful activity over 6 weeks`}>
            {project.activity.map((count, index) => <span key={index} style={{ height: `${Math.max(8, count / maxActivity * 100)}%` }} />)}
          </div>
          <small>6 weeks ago <span>This week</span></small>
        </div>
      </div>
      <footer>
        <div><span className="mini-label">Next decision</span><strong>{project.nextDecision.label}</strong><small>{project.nextDecision.detail}</small></div>
        <button className="secondary-button" onClick={() => openProject(project.id, project.nextDecision.tab)}>Open Project</button>
      </footer>
    </article>
  );
}

function AttentionRow({ item, openProject }: {
  item: AttentionItem;
  openProject: PortfolioDashboardProps["openProject"];
}) {
  return (
    <button className="portfolio-attention-row" onClick={() => openProject(item.projectId, item.tab)}>
      <span className="attention-dot" aria-hidden="true" />
      <span><strong>{item.projectName}</strong><small>{item.label}</small></span>
      <span aria-hidden="true">›</span>
    </button>
  );
}

function PortfolioMovementMatrix({ movement }: {
  movement: ReturnType<typeof derivePortfolioDashboard>["movement"];
}) {
  return (
    <article className="card portfolio-viz-card">
      <div className="section-heading"><div><span className="mini-label">Meaningful events only</span><h3>Portfolio movement</h3></div></div>
      <div className="movement-matrix">
        {movement.map((row) => (
          <div className="movement-row" key={row.projectId} aria-label={row.accessibleSummary}>
            <strong>{row.projectName}</strong>
            <div>{row.buckets.map((bucket) => <span className={`movement-cell intensity-${bucket.intensity}`} key={bucket.label} title={`${bucket.label}: ${bucket.count} meaningful events`} />)}</div>
            <small>{row.accessibleSummary}</small>
          </div>
        ))}
      </div>
    </article>
  );
}

function CapacityAllocation({ capacity }: {
  capacity: ReturnType<typeof derivePortfolioDashboard>["capacity"];
}) {
  return (
    <article className="card portfolio-viz-card">
      <div className="section-heading"><div><span className="mini-label">Planned allocation</span><h3>Next 2 weeks capacity</h3></div></div>
      <div className="portfolio-capacity-bar" aria-label={capacity.accessibleSummary}>
        {capacity.segments.map((segment) => <span key={segment.projectId} style={{ width: `${segment.percent}%`, background: segment.color }} />)}
      </div>
      <ul className="capacity-legend">
        {capacity.segments.map((segment) => <li key={segment.projectId}><i style={{ background: segment.color }} /><span>{segment.label}</span><strong>{segment.minutes}m</strong></li>)}
      </ul>
      <p className="sr-only">{capacity.accessibleSummary}</p>
    </article>
  );
}

export function PortfolioDashboard({ openProject, openProjects, openReviews }: PortfolioDashboardProps) {
  const [period, setPeriod] = useState<DashboardPeriod>("now");
  const model = useMemo(() => derivePortfolioDashboard(projectDemos, period), [period]);
  const primaryDecision = model.decisions[0];
  return (
    <div className="portfolio-dashboard page-stack">
      <header className="portfolio-header">
        <div><p className="date-line">Wednesday, July 23</p><h2>Your learning portfolio</h2><p>See where every active Project stands and what needs a decision.</p></div>
        <div className="portfolio-period" aria-label="Dashboard period">
          {periods.map((item) => <button className={period === item.id ? "active" : ""} aria-pressed={period === item.id} key={item.id} onClick={() => setPeriod(item.id)}>{item.label}</button>)}
        </div>
      </header>
      <section className="portfolio-pulse" aria-label="Portfolio pulse">
        <PulseCard label="Active Projects" value={`${model.pulse.activeProjects}`} detail="Projects with an active Phase" />
        <PulseCard label="Evidence ready" value={`${model.pulse.evidenceReady} / ${model.pulse.evidenceExpected}`} detail="Expected Proof signals" />
        <PulseCard label="Reviews ready" value={`${model.pulse.reviewsReady}`} detail="Decisions waiting" />
        <PulseCard label="Needs attention" value={`${model.pulse.needsAttention}`} detail="Distinct Projects" attention />
      </section>
      <div className="portfolio-main-grid">
        <section>
          <div className="section-heading">
            <h3>Active Projects</h3>
            {model.hasMoreProjects && <button className="text-button" onClick={openProjects}>View all {model.totalActiveProjects}</button>}
          </div>
          {model.projects.length > 0
            ? <div className="portfolio-project-list">{model.projects.map((project) => <PortfolioProjectCard project={project} openProject={openProject} key={project.id} />)}</div>
            : <div className="portfolio-empty-state"><h3>No active Projects</h3><p>Paused, Completed, and Abandoned Projects remain in the archive.</p><button className="secondary-button" onClick={openProjects}>View Projects and archive</button></div>}
        </section>
        <aside>
          <div className="section-heading"><h3>Decisions</h3><button className="text-button" onClick={openReviews}>Review inbox</button></div>
          {primaryDecision ? <article className="portfolio-decision-card"><span className="mini-label">Review ready</span><h3>{primaryDecision.projectName}</h3><p>{primaryDecision.detail}</p><button onClick={() => openProject(primaryDecision.projectId, "reviews")}>Start Stage Review</button><small>Nothing advances until you publish.</small></article> : <p className="portfolio-empty-note">No Stage Review is waiting.</p>}
          <article className="portfolio-attention-card"><h3>Needs attention</h3>{model.attention.map((item) => <AttentionRow item={item} openProject={openProject} key={item.id} />)}</article>
        </aside>
      </div>
      <section className="portfolio-lower-grid">
        <PortfolioMovementMatrix movement={model.movement} />
        <CapacityAllocation capacity={model.capacity} />
      </section>
    </div>
  );
}
```

- [ ] **Step 4: Mount the new component and delete the old inline Dashboard**

In `WebWorkspace/app/workspace-app.tsx`:

1. Add:

```tsx
import { PortfolioDashboard } from "./portfolio-dashboard";
```

2. Replace the Dashboard call with:

```tsx
{section === "dashboard" && (
  <PortfolioDashboard
    openProject={openProject}
    openProjects={() => setSection("projects")}
    openReviews={() => setSection("reviews")}
  />
)}
```

3. Delete the old `Dashboard` function at lines 287–449.
4. Remove `formatMinutes` only if its remaining Plan and draft usages have first been moved to a shared helper; otherwise keep it.

- [ ] **Step 5: Run build-backed tests**

Run:

```bash
cd WebWorkspace
npm test
```

Expected: build succeeds and all Node tests pass.

- [ ] **Step 6: Commit the portfolio component**

```bash
git add WebWorkspace/app/portfolio-dashboard.tsx WebWorkspace/app/workspace-app.tsx WebWorkspace/tests/demo-data.test.mjs WebWorkspace/tests/rendered-html.test.mjs
git commit -m "feat(web): render portfolio dashboard cards"
```

### Task 3: Apply the approved visual system and verify responsive accessibility

**Files:**
- Modify: `WebWorkspace/app/globals.css:88-176,353-398`
- Modify: `WebWorkspace/tests/rendered-html.test.mjs`

**Interfaces:**
- Consumes: semantic class names emitted by `portfolio-dashboard.tsx`.
- Produces: desktop, tablet, and narrow layouts with no horizontal chart scrolling and visible text alternatives.

- [ ] **Step 1: Add failing accessibility and structure assertions**

Append inside the first rendered-HTML test after `const html = await response.text()`:

```js
assert.match(html, /aria-label="Portfolio pulse"/);
assert.match(html, /aria-label="Dashboard period"/);
assert.match(html, /aria-pressed="true"/);
assert.match(html, /meaningful activity over 6 weeks/i);
assert.match(html, /planned minutes of .* available/i);
```

Add a source-level CSS test:

```js
test("keeps portfolio visualizations responsive and text-equivalent", async () => {
  const [css, dashboard] = await Promise.all([
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../app/portfolio-dashboard.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(css, /\\.portfolio-main-grid/);
  assert.match(css, /\\.portfolio-lower-grid/);
  assert.match(css, /@media \\(max-width: 820px\\)[\\s\\S]*\\.portfolio-main-grid/);
  assert.match(css, /\\.sr-only/);
  assert.match(dashboard, /accessibleSummary/);
  assert.doesNotMatch(css, /overflow-x:\\s*scroll[^}]*movement-matrix/);
});
```

- [ ] **Step 2: Run the rendered test and verify the CSS contract fails**

Run:

```bash
cd WebWorkspace
npm run build
node --experimental-strip-types --test tests/rendered-html.test.mjs
```

Expected: FAIL because the portfolio CSS classes and responsive contract are not implemented.

- [ ] **Step 3: Replace obsolete Dashboard CSS with the portfolio styles**

Replace the old `.dashboard-grid`, `.hero-grid`, `.signal-grid`, `.lower-grid`, `.phase-card`, `.review-card`, `.capacity-card`, `.practice-card`, `.carryover-card`, `.trail-card`, and `.next-card` Dashboard-only rules with:

```css
.sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
.portfolio-dashboard { max-width: 1280px; margin: 0 auto; }
.portfolio-header { display: flex; align-items: flex-end; justify-content: space-between; gap: 20px; padding: 4px 2px 8px; }
.portfolio-header h2 { margin: 0; font-size: clamp(28px, 3vw, 38px); line-height: 1.04; letter-spacing: -0.055em; }
.portfolio-header > div:first-child > p:last-child { margin: 9px 0 0; color: var(--muted); font-size: 13px; }
.portfolio-period { display: flex; gap: 2px; padding: 3px; border: 1px solid var(--line-strong); border-radius: 10px; background: white; }
.portfolio-period button { min-height: 32px; padding: 0 11px; border: 0; border-radius: 7px; background: transparent; color: var(--muted); font-size: 10px; font-weight: 700; cursor: pointer; }
.portfolio-period button.active { background: var(--ink); color: white; }
.portfolio-pulse { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
.portfolio-pulse-card { min-height: 96px; padding: 17px; border: 1px solid var(--line); border-radius: 14px; background: white; box-shadow: var(--shadow); }
.portfolio-pulse-card > span { color: var(--faint); font-size: 9px; font-weight: 760; letter-spacing: 0.07em; text-transform: uppercase; }
.portfolio-pulse-card strong { display: block; margin-top: 10px; font-size: 27px; letter-spacing: -0.05em; }
.portfolio-pulse-card small { display: block; margin-top: 4px; color: var(--muted); font-size: 9px; }
.portfolio-pulse-card.attention { border-color: #ecd9bc; background: #fffaf2; }
.portfolio-pulse-card.attention strong { color: var(--amber); }
.portfolio-main-grid { display: grid; grid-template-columns: minmax(0, 1.55fr) minmax(280px, 0.62fr); gap: 18px; align-items: start; }
.portfolio-project-list { display: grid; gap: 12px; margin-top: 12px; }
.portfolio-empty-state { margin-top: 12px; padding: 34px; border: 1px dashed var(--line-strong); border-radius: 16px; background: rgba(255, 255, 255, 0.55); text-align: center; }
.portfolio-empty-state h3 { margin: 0; font-size: 17px; }
.portfolio-empty-state p { margin: 8px 0 16px; color: var(--muted); font-size: 10px; }
.portfolio-project-card { padding: 20px; border: 1px solid var(--line); border-radius: 16px; background: white; box-shadow: var(--shadow); }
.portfolio-project-card > header { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; }
.portfolio-project-identity { display: flex; align-items: center; gap: 11px; min-width: 0; }
.portfolio-token { --project-accent: var(--blue); width: 38px; height: 38px; display: grid; place-items: center; flex: 0 0 auto; border-radius: 11px; background: color-mix(in srgb, var(--project-accent) 15%, white); color: var(--project-accent); font-size: 11px; font-weight: 800; }
.portfolio-project-identity h4 { margin: 0; font-size: 15px; letter-spacing: -0.02em; }
.portfolio-project-identity p { margin: 4px 0 0; color: var(--muted); font-size: 9px; }
.portfolio-state { padding: 5px 9px; border-radius: 10px; background: var(--green-soft); color: var(--green); font-size: 8px; font-weight: 760; }
.portfolio-state.attention { background: var(--amber-soft); color: var(--amber); }
.portfolio-project-body { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(150px, 0.75fr); gap: 22px; margin-top: 20px; }
.portfolio-project-body h5 { margin: 7px 0 0; font-size: 15px; letter-spacing: -0.025em; }
.portfolio-outcome { margin: 7px 0 0; color: var(--muted); font-size: 10px; line-height: 1.55; }
.portfolio-evidence { margin-top: 16px; }
.portfolio-evidence > div:first-child { display: flex; justify-content: space-between; gap: 12px; color: var(--muted); font-size: 9px; }
.portfolio-evidence > div:first-child strong { color: #555a62; }
.portfolio-evidence-track { height: 7px; margin-top: 7px; overflow: hidden; border-radius: 5px; background: #eceef1; }
.portfolio-evidence-track span { display: block; height: 100%; border-radius: inherit; background: var(--green); }
.portfolio-activity { padding-left: 20px; border-left: 1px solid var(--line); }
.portfolio-sparkline { height: 65px; display: flex; align-items: flex-end; gap: 6px; margin-top: 14px; }
.portfolio-sparkline span { flex: 1; min-height: 5px; border-radius: 4px 4px 1px 1px; background: #6f8fc9; }
.portfolio-activity > small { display: flex; justify-content: space-between; margin-top: 6px; color: var(--faint); font-size: 8px; }
.portfolio-project-card > footer { display: flex; align-items: flex-end; justify-content: space-between; gap: 18px; margin-top: 18px; padding-top: 15px; border-top: 1px solid var(--line); }
.portfolio-project-card > footer strong, .portfolio-project-card > footer small { display: block; }
.portfolio-project-card > footer strong { margin-top: 5px; font-size: 11px; }
.portfolio-project-card > footer small { max-width: 560px; margin-top: 4px; color: var(--muted); font-size: 9px; line-height: 1.4; }
.portfolio-decision-card { margin-top: 12px; padding: 21px; border-radius: 16px; background: var(--ink); color: white; }
.portfolio-decision-card h3 { margin: 14px 0 0; font-size: 20px; }
.portfolio-decision-card p { color: #b9bec7; font-size: 10px; line-height: 1.55; }
.portfolio-decision-card button { width: 100%; min-height: 40px; margin-top: 15px; border: 0; border-radius: 9px; background: white; color: var(--ink); font-size: 10px; font-weight: 760; cursor: pointer; }
.portfolio-decision-card small { display: block; margin-top: 9px; color: #8f949d; font-size: 8px; text-align: center; }
.portfolio-attention-card { margin-top: 12px; padding: 18px; border: 1px solid #ead9bf; border-radius: 16px; background: #fffaf3; }
.portfolio-attention-card h3 { margin: 0 0 8px; font-size: 14px; }
.portfolio-attention-row { width: 100%; display: grid; grid-template-columns: 7px minmax(0, 1fr) auto; gap: 9px; align-items: start; min-height: 52px; padding: 11px 0; border: 0; border-top: 1px solid #eee1ce; background: transparent; text-align: left; cursor: pointer; }
.attention-dot { width: 6px; height: 6px; margin-top: 4px; border-radius: 50%; background: var(--amber); }
.portfolio-attention-row strong, .portfolio-attention-row small { display: block; }
.portfolio-attention-row strong { font-size: 9px; }
.portfolio-attention-row small { margin-top: 3px; color: #84725b; font-size: 8px; line-height: 1.4; }
.portfolio-empty-note { color: var(--muted); font-size: 10px; }
.portfolio-lower-grid { display: grid; grid-template-columns: 1.25fr 0.75fr; gap: 18px; }
.portfolio-viz-card { min-width: 0; }
.movement-matrix { display: grid; gap: 13px; margin-top: 20px; }
.movement-row { display: grid; grid-template-columns: minmax(120px, 0.7fr) minmax(180px, 1.3fr); gap: 15px; align-items: center; }
.movement-row > strong { overflow: hidden; font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.movement-row > div { display: grid; grid-auto-flow: column; grid-auto-columns: minmax(12px, 1fr); gap: 5px; }
.movement-cell { height: 20px; border: 1px solid #e8ebe9; border-radius: 5px; background: #eff1f0; }
.movement-cell.intensity-1 { background: #dce9df; }
.movement-cell.intensity-2 { background: #a8c5af; }
.movement-cell.intensity-3 { background: #6f997a; }
.movement-row > small { grid-column: 1 / -1; color: var(--muted); font-size: 8px; }
.portfolio-capacity-bar { height: 14px; display: flex; margin-top: 24px; overflow: hidden; border-radius: 8px; background: var(--line); }
.portfolio-capacity-bar span { min-width: 0; height: 100%; }
.capacity-legend { display: grid; gap: 9px; margin: 17px 0 0; padding: 0; list-style: none; }
.capacity-legend li { display: grid; grid-template-columns: 8px 1fr auto; gap: 8px; align-items: center; color: var(--muted); font-size: 9px; }
.capacity-legend i { width: 8px; height: 8px; border-radius: 3px; }
.capacity-legend strong { color: var(--ink); }
```

- [ ] **Step 4: Add portfolio-specific responsive rules**

Inside the existing media queries add:

```css
@media (max-width: 1100px) {
  .portfolio-pulse { grid-template-columns: 1fr 1fr; }
  .portfolio-main-grid { grid-template-columns: 1fr; }
}

@media (max-width: 820px) {
  .portfolio-header { align-items: flex-start; flex-direction: column; }
  .portfolio-main-grid, .portfolio-lower-grid { grid-template-columns: 1fr; }
  .portfolio-project-body { grid-template-columns: 1fr; }
  .portfolio-activity { padding: 0; border-left: 0; }
}

@media (max-width: 540px) {
  .portfolio-pulse { grid-template-columns: 1fr; }
  .portfolio-period { width: 100%; }
  .portfolio-period button { flex: 1; }
  .portfolio-project-card > footer { align-items: stretch; flex-direction: column; }
  .portfolio-project-card > footer .secondary-button { width: 100%; min-height: 44px; }
  .movement-row { grid-template-columns: 1fr; }
  .movement-row > small { grid-column: auto; }
}
```

- [ ] **Step 5: Run lint, tests, and production build**

Run:

```bash
cd WebWorkspace
npm run lint
npm test
```

Expected: ESLint passes; Vinext production build succeeds; all selector, source-contract, CloudKit-contract, and rendered-HTML tests pass.

- [ ] **Step 6: Perform a browser acceptance pass**

With the dev server running, verify:

1. Dashboard initially shows both Project cards.
2. `Now`, `4 weeks`, and `12 weeks` update the activity matrix without hiding decisions.
3. Each `Open Project`, attention item, and Review action reaches the correct Project tab.
4. At 1280 px the decision rail sits beside Project cards.
5. At 820 px the rail and charts stack below Project cards.
6. At 390 px there is no horizontal scrolling, every touch action is at least 44 px, and text summaries remain visible.
7. Keyboard focus follows pulse → Projects → decisions → charts.
8. Reduced-motion mode introduces no required animation.

Expected: all eight checks pass with no console errors or hydration warnings.

- [ ] **Step 7: Commit the visual and responsive implementation**

```bash
git add WebWorkspace/app/globals.css WebWorkspace/tests/rendered-html.test.mjs
git commit -m "style(web): polish portfolio dashboard visualization"
```

### Task 4: Final regression verification

**Files:**
- Verify only; no new production files expected.

**Interfaces:**
- Consumes: all deliverables from Tasks 1–3.
- Produces: current evidence that the complete Web Workspace remains buildable and the Dashboard matches the approved spec.

- [ ] **Step 1: Run the complete Web validation**

```bash
cd WebWorkspace
npm run lint
npm test
```

Expected: both commands exit 0.

- [ ] **Step 2: Verify scope and stale single-Project assumptions**

```bash
rg -n "const demo = projectDemos\\[0\\]|Make the next decision clear|hero-grid|signal-grid|practice-card|carryover-card" WebWorkspace/app WebWorkspace/lib
```

Expected: no matches.

- [ ] **Step 3: Verify the approved vocabulary and hierarchy**

```bash
rg -n "Your learning portfolio|Portfolio pulse|Active Projects|Stage Review is ready|Portfolio movement|Next 2 weeks capacity|Expected Proof|Meaningful activity" WebWorkspace/app WebWorkspace/lib
```

Expected: matches in `portfolio-dashboard.tsx` and the selector module; no generic completion-score copy.

- [ ] **Step 4: Review the final diff**

```bash
git diff --check
git status --short
git log -4 --oneline
```

Expected: no whitespace errors; only pre-existing unrelated worktree changes remain; the three implementation commits are visible after the design commit.
