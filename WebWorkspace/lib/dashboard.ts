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
