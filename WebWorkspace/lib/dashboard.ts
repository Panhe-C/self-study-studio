import type { ProjectDemo } from "./journal";

export type DashboardPeriod = "now" | "4w" | "12w";
export type DashboardLoadState =
  | "ready"
  | "empty"
  | "large"
  | "partial"
  | "conflict"
  | "loading"
  | "error";
export type DashboardSection = "evidence" | "activity" | "capacity";
export type AttentionKind =
  | "conflict"
  | "review"
  | "carryover"
  | "proof"
  | "capacity"
  | "practice"
  | "inactivity";

type ProjectTab =
  | "overview"
  | "plan"
  | "practice"
  | "proof"
  | "trail"
  | "reviews";

export type DashboardConflict = {
  id: string;
  projectId: string;
  label: string;
  detail: string;
  detectedAt: string;
};

type DashboardDataSnapshot = {
  loadState: "ready" | "empty" | "large" | "partial" | "conflict";
  asOf: string;
  demos: ProjectDemo[];
  unavailableSections: DashboardSection[];
  conflicts: DashboardConflict[];
};

export type DashboardSnapshot =
  | DashboardDataSnapshot
  | {
      loadState: "loading";
      asOf: string;
    }
  | {
      loadState: "error";
      asOf: string;
      message: string;
    };

type DashboardSnapshotInput =
  | {
      asOf: string;
      state: "loading";
    }
  | {
      asOf: string;
      state: "error";
      message: string;
    }
  | {
      asOf: string;
      demos: ProjectDemo[];
      unavailableSections?: DashboardSection[];
      conflicts?: DashboardConflict[];
    };

export type DashboardDerivationOptions = {
  asOf?: string;
  unavailableSections?: DashboardSection[];
  conflicts?: DashboardConflict[];
};

export type PortfolioPulse = {
  activeProjects: number;
  evidenceReady: number | null;
  evidenceExpected: number | null;
  reviewsReady: number;
  needsAttention: number;
};

export type ActivityBucket = {
  label: string;
  count: number;
  intensity: 0 | 1 | 2 | 3;
};

export type ActivityRow = {
  projectId: string;
  projectName: string;
  buckets: ActivityBucket[];
  accessibleSummary: string;
};

export type DashboardDestination =
  | { section: "project"; tab: ProjectTab }
  | { section: "sync" };

export type AttentionItem = {
  id: string;
  projectId: string;
  projectName: string;
  kind: AttentionKind;
  label: string;
  detail: string;
  destination: DashboardDestination;
  severity: number;
  explicitDecision: boolean;
  occurredAt: string;
};

export type ProjectDashboardState = {
  id: string;
  token: string;
  name: string;
  area: string;
  accent: string;
  status: ProjectDemo["project"]["status"];
  phaseWindow: string;
  outcome: string;
  expectedProof: string;
  activePhase?: { title: string; window: string; outcome: string };
  evidence: { ready: number; expected: number } | null;
  activity: number[] | null;
  attention: boolean;
  nextDecision: {
    kind: AttentionKind | "next-step";
    label: string;
    detail: string;
    destination: DashboardDestination;
    tab: ProjectTab;
  };
};

export type CapacityAllocation = {
  status: "available" | "full" | "over" | "unavailable";
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
  warningSegment?: {
    label: string;
    minutes: number;
    percent: number;
  };
  warning?: string;
  accessibleSummary: string;
};

export type PortfolioDashboardDataModel = {
  loadState: DashboardDataSnapshot["loadState"];
  asOf: string;
  pulse: PortfolioPulse;
  projects: ProjectDashboardState[];
  totalActiveProjects: number;
  hasMoreProjects: boolean;
  decisions: AttentionItem[];
  attention: AttentionItem[];
  movement: ActivityRow[] | null;
  capacity: CapacityAllocation | null;
  unavailableSections: DashboardSection[];
  conflicts: DashboardConflict[];
};

export type PortfolioDashboardModel =
  | PortfolioDashboardDataModel
  | {
      loadState: "loading";
      asOf: string;
    }
  | {
      loadState: "error";
      asOf: string;
      errorMessage: string;
    };

const DAY_MS = 24 * 60 * 60 * 1000;
const WEEK_MS = 7 * DAY_MS;
const DEFAULT_AS_OF = () => new Date().toISOString();

const ATTENTION_SEVERITY: Record<AttentionKind, number> = {
  conflict: 10,
  review: 20,
  carryover: 30,
  proof: 40,
  capacity: 50,
  practice: 60,
  inactivity: 70,
};

function activeDemos(demos: ProjectDemo[]) {
  return demos.filter((demo) => demo.project.status === "Active");
}

function asTimestamp(value: string) {
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function normalizedAsOf(value?: string) {
  const timestamp = value ? asTimestamp(value) : null;
  return new Date(timestamp ?? Date.now()).toISOString();
}

function latestMeaningfulEvent(
  demo: ProjectDemo,
  asOf: string,
): { timestamp: number; occurredAt: string } | null {
  const asOfTimestamp = asTimestamp(asOf) ?? Date.now();
  let latest: { timestamp: number; occurredAt: string } | null = null;

  for (const event of demo.trail) {
    const timestamp = asTimestamp(event.occurredAt);
    if (
      timestamp !== null &&
      timestamp <= asOfTimestamp &&
      (!latest || timestamp > latest.timestamp)
    ) {
      latest = {
        timestamp,
        occurredAt: new Date(timestamp).toISOString(),
      };
    }
  }

  return latest;
}

function activityCounts(
  demo: ProjectDemo,
  bucketCount: number,
  asOf: string,
): number[] {
  const counts = Array.from({ length: bucketCount }, () => 0);
  const asOfTimestamp = asTimestamp(asOf) ?? Date.now();

  for (const event of demo.trail) {
    const eventTimestamp = asTimestamp(event.occurredAt);
    if (eventTimestamp === null) continue;

    const age = Math.floor((asOfTimestamp - eventTimestamp) / WEEK_MS);
    if (age >= 0 && age < bucketCount) {
      counts[bucketCount - 1 - age] += 1;
    }
  }

  return counts;
}

function attentionSort(a: AttentionItem, b: AttentionItem) {
  return (
    a.severity - b.severity ||
    Date.parse(a.occurredAt) - Date.parse(b.occurredAt) ||
    a.id.localeCompare(b.id)
  );
}

function projectDestination(tab: ProjectTab): DashboardDestination {
  return { section: "project", tab };
}

function createAttentionItem(
  item: Omit<AttentionItem, "severity">,
): AttentionItem {
  return {
    ...item,
    severity: ATTENTION_SEVERITY[item.kind],
  };
}

function periodBucketCount(period: DashboardPeriod) {
  if (period === "now") return 1;
  if (period === "4w") return 4;
  return 12;
}

export function createDashboardSnapshot(
  input: DashboardSnapshotInput,
): DashboardSnapshot {
  const asOf = normalizedAsOf(input.asOf);

  if ("state" in input) {
    if (input.state === "loading") {
      return { loadState: "loading", asOf };
    }
    return { loadState: "error", asOf, message: input.message };
  }

  const unavailableSections = [...new Set(input.unavailableSections ?? [])];
  const conflicts = input.conflicts ?? [];
  const activeCount = activeDemos(input.demos).length;
  const loadState = conflicts.length > 0
    ? "conflict"
    : unavailableSections.length > 0
      ? "partial"
      : activeCount === 0
        ? "empty"
        : activeCount > 8
          ? "large"
          : "ready";

  return {
    loadState,
    asOf,
    demos: input.demos,
    unavailableSections,
    conflicts,
  };
}

export function formatDashboardDate(asOf: string) {
  const timestamp = asTimestamp(asOf);
  if (timestamp === null) return "Date unavailable";

  return new Intl.DateTimeFormat("en-US", {
    weekday: "long",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  }).format(new Date(timestamp));
}

export function deriveAttentionItems(
  demos: ProjectDemo[],
  options: DashboardDerivationOptions = {},
): AttentionItem[] {
  const asOf = normalizedAsOf(options.asOf);
  const asOfTimestamp = Date.parse(asOf);
  const unavailable = new Set(options.unavailableSections ?? []);
  const active = activeDemos(demos);
  const activeIds = new Set(active.map((demo) => demo.project.id));
  const items: AttentionItem[] = [];

  for (const conflict of options.conflicts ?? []) {
    const demo = active.find(
      (candidate) => candidate.project.id === conflict.projectId,
    );
    if (!demo || !activeIds.has(conflict.projectId)) continue;
    items.push(
      createAttentionItem({
        id: `conflict-${conflict.id}`,
        projectId: conflict.projectId,
        projectName: demo.project.name,
        kind: "conflict",
        label: conflict.label,
        detail: conflict.detail,
        destination: { section: "sync" },
        explicitDecision: true,
        occurredAt: normalizedAsOf(conflict.detectedAt),
      }),
    );
  }

  for (const demo of active) {
    const latest = latestMeaningfulEvent(demo, asOf);
    const fallbackOccurredAt = latest?.occurredAt ?? asOf;

    if (demo.review.ready) {
      items.push(
        createAttentionItem({
          id: `${demo.project.id}-review`,
          projectId: demo.project.id,
          projectName: demo.project.name,
          kind: "review",
          label: "Stage Review ready",
          detail: demo.review.summary,
          destination: projectDestination("reviews"),
          explicitDecision: true,
          occurredAt: normalizedAsOf(
            demo.review.readySinceAt ?? fallbackOccurredAt,
          ),
        }),
      );
    }

    const carryovers = demo.sessions.filter(
      (session) => session.status === "Carryover",
    );
    if (carryovers.length > 0) {
      const oldestCarryoverAt = carryovers
        .map((session) => session.attentionAt)
        .filter((value): value is string => Boolean(value))
        .sort()[0];
      items.push(
        createAttentionItem({
          id: `${demo.project.id}-carryover`,
          projectId: demo.project.id,
          projectName: demo.project.name,
          kind: "carryover",
          label: `${carryovers.length} Carryover awaiting a decision`,
          detail: carryovers[0].title,
          destination: projectDestination("plan"),
          explicitDecision: true,
          occurredAt: normalizedAsOf(
            oldestCarryoverAt ?? fallbackOccurredAt,
          ),
        }),
      );
    }

    const evidenceMissing =
      demo.project.evidenceCount < demo.project.evidenceTarget;
    if (!unavailable.has("evidence") && demo.review.ready && evidenceMissing) {
      items.push(
        createAttentionItem({
          id: `${demo.project.id}-proof-boundary`,
          projectId: demo.project.id,
          projectName: demo.project.name,
          kind: "proof",
          label: "Expected Proof gap at the Phase boundary",
          detail: `${demo.project.evidenceCount} of ${demo.project.evidenceTarget} expected Proof signals are ready.`,
          destination: projectDestination("proof"),
          explicitDecision: false,
          occurredAt: normalizedAsOf(
            demo.review.readySinceAt ?? fallbackOccurredAt,
          ),
        }),
      );
    }

    if (
      !unavailable.has("capacity") &&
      demo.capacity.plannedMinutes > demo.capacity.availableMinutes
    ) {
      const overBy =
        demo.capacity.plannedMinutes - demo.capacity.availableMinutes;
      items.push(
        createAttentionItem({
          id: `${demo.project.id}-capacity`,
          projectId: demo.project.id,
          projectName: demo.project.name,
          kind: "capacity",
          label: "Planned capacity needs a decision",
          detail: `Planned time exceeds declared availability by ${overBy} minutes.`,
          destination: projectDestination("plan"),
          explicitDecision: true,
          occurredAt: asOf,
        }),
      );
    }

    if (!unavailable.has("activity") && demo.practiceAttention) {
      items.push(
        createAttentionItem({
          id: `${demo.project.id}-practice-${demo.practiceAttention.id}`,
          projectId: demo.project.id,
          projectName: demo.project.name,
          kind: "practice",
          label: demo.practiceAttention.label,
          detail: demo.practiceAttention.detail,
          destination: projectDestination("practice"),
          explicitDecision: false,
          occurredAt: normalizedAsOf(demo.practiceAttention.markedAt),
        }),
      );
    }

    if (!unavailable.has("activity") && latest) {
      const quietDays = Math.floor(
        (asOfTimestamp - latest.timestamp) / DAY_MS,
      );
      if (quietDays >= 5) {
        items.push(
          createAttentionItem({
            id: `${demo.project.id}-inactivity`,
            projectId: demo.project.id,
            projectName: demo.project.name,
            kind: "inactivity",
            label: `No meaningful activity for ${quietDays} days`,
            detail: demo.project.nextStep,
            destination: projectDestination("trail"),
            explicitDecision: false,
            occurredAt: latest.occurredAt,
          }),
        );
      }
    }
  }

  return items.sort(attentionSort);
}

function nextDecisionFromAttention(
  demo: ProjectDemo,
  item?: AttentionItem,
): ProjectDashboardState["nextDecision"] {
  if (!item) {
    return {
      kind: "next-step",
      label: "Continue the canonical Next Step",
      detail: demo.project.nextStep,
      destination: projectDestination("overview"),
      tab: "overview",
    };
  }

  const tab =
    item.destination.section === "project" ? item.destination.tab : "overview";
  const labels: Partial<Record<AttentionKind, string>> = {
    conflict: "Resolve the sync conflict",
    review: "Stage Review is ready",
    capacity: "Planned capacity needs a decision",
  };
  const detail =
    item.kind === "review" ? demo.review.headline : item.detail;

  return {
    kind: item.kind,
    label: labels[item.kind] ?? item.label,
    detail,
    destination: item.destination,
    tab,
  };
}

export function deriveProjectDashboardState(
  demo: ProjectDemo,
  options: DashboardDerivationOptions = {},
): ProjectDashboardState {
  const asOf = normalizedAsOf(options.asOf);
  const unavailable = new Set(options.unavailableSections ?? []);
  const activePhase = demo.planPhases.find(
    (phase) => phase.status === "Active",
  );
  const attention = deriveAttentionItems([demo], {
    ...options,
    asOf,
  });
  const outcome = activePhase?.description ?? demo.project.goal;

  return {
    id: demo.project.id,
    token: demo.project.token,
    name: demo.project.name,
    area: demo.project.area,
    accent: demo.project.accent,
    status: demo.project.status,
    phaseWindow: demo.project.phaseWindow,
    outcome,
    expectedProof: demo.project.expectedProof,
    activePhase: activePhase
      ? {
          title: activePhase.title,
          window: activePhase.window,
          outcome: activePhase.description,
        }
      : undefined,
    evidence: unavailable.has("evidence")
      ? null
      : {
          ready: demo.project.evidenceCount,
          expected: demo.project.evidenceTarget,
        },
    activity: unavailable.has("activity")
      ? null
      : activityCounts(demo, 6, asOf),
    attention: attention.length > 0,
    nextDecision: nextDecisionFromAttention(demo, attention[0]),
  };
}

export function derivePortfolioPulse(
  demos: ProjectDemo[],
  options: DashboardDerivationOptions = {},
): PortfolioPulse {
  const active = activeDemos(demos);
  const unavailable = new Set(options.unavailableSections ?? []);
  const attentionProjectIds = new Set(
    deriveAttentionItems(active, options).map((item) => item.projectId),
  );

  return {
    activeProjects: active.length,
    evidenceReady: unavailable.has("evidence")
      ? null
      : active.reduce(
          (sum, demo) => sum + demo.project.evidenceCount,
          0,
        ),
    evidenceExpected: unavailable.has("evidence")
      ? null
      : active.reduce(
          (sum, demo) => sum + demo.project.evidenceTarget,
          0,
        ),
    reviewsReady: active.filter((demo) => demo.review.ready).length,
    needsAttention: attentionProjectIds.size,
  };
}

export function deriveMeaningfulActivityBuckets(
  demos: ProjectDemo[],
  period: DashboardPeriod,
  options: DashboardDerivationOptions = {},
): ActivityRow[] {
  const asOf = normalizedAsOf(options.asOf);
  const bucketCount = periodBucketCount(period);
  const rows = activeDemos(demos).map((demo) => ({
    demo,
    counts: activityCounts(demo, bucketCount, asOf),
  }));
  const visibleMaximum = Math.max(
    0,
    ...rows.flatMap((row) => row.counts),
  );

  return rows.map(({ demo, counts }) => {
    const buckets = counts.map((count, index) => {
      const weeksAgo = bucketCount - 1 - index;
      const intensity = count === 0 || visibleMaximum === 0
        ? 0
        : Math.min(
            3,
            Math.ceil((count / visibleMaximum) * 3),
          );
      return {
        label:
          weeksAgo === 0
            ? "This week"
            : `${weeksAgo} week${weeksAgo === 1 ? "" : "s"} ago`,
        count,
        intensity: intensity as 0 | 1 | 2 | 3,
      };
    });
    const total = buckets.reduce((sum, bucket) => sum + bucket.count, 0);
    return {
      projectId: demo.project.id,
      projectName: demo.project.name,
      buckets,
      accessibleSummary: `${demo.project.name}: ${total} meaningful events across ${bucketCount} week${bucketCount === 1 ? "" : "s"}.`,
    };
  });
}

export function deriveCapacityAllocation(
  demos: ProjectDemo[],
): CapacityAllocation {
  const active = activeDemos(demos);
  const plannedMinutes = active.reduce(
    (sum, demo) => sum + demo.capacity.plannedMinutes,
    0,
  );
  const availableMinutes = active.reduce(
    (sum, demo) => sum + demo.capacity.availableMinutes,
    0,
  );
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

  if (overCapacityMinutes > 0) {
    const zeroAvailability = availableMinutes === 0;
    return {
      status: "over",
      plannedMinutes,
      availableMinutes,
      remainingMinutes,
      overCapacityMinutes,
      segments,
      warningSegment: {
        label: "Over capacity",
        minutes: overCapacityMinutes,
        percent: zeroAvailability
          ? 100
          : Math.min(100, (overCapacityMinutes / plannedMinutes) * 100),
      },
      warning: `Capacity is over capacity by ${overCapacityMinutes} minutes.`,
      accessibleSummary: zeroAvailability
        ? `No availability is declared; ${plannedMinutes} planned minutes need a capacity decision.`
        : `${plannedMinutes} planned minutes exceeds ${availableMinutes} available by ${overCapacityMinutes} minutes.`,
    };
  }

  if (plannedMinutes === 0 && availableMinutes === 0) {
    return {
      status: "unavailable",
      plannedMinutes,
      availableMinutes,
      remainingMinutes,
      overCapacityMinutes,
      segments,
      accessibleSummary:
        "No planned time or availability is declared for the next 2 weeks.",
    };
  }

  return {
    status: plannedMinutes === availableMinutes ? "full" : "available",
    plannedMinutes,
    availableMinutes,
    remainingMinutes,
    overCapacityMinutes,
    segments,
    accessibleSummary:
      plannedMinutes === availableMinutes
        ? `${plannedMinutes} planned minutes use all ${availableMinutes} available minutes.`
        : `${plannedMinutes} planned minutes of ${availableMinutes} available; ${remainingMinutes} minutes remain.`,
  };
}

function normalizedSnapshot(
  source: ProjectDemo[] | DashboardSnapshot,
  options: DashboardDerivationOptions,
): DashboardSnapshot {
  if (Array.isArray(source)) {
    return createDashboardSnapshot({
      asOf: options.asOf ?? DEFAULT_AS_OF(),
      demos: source,
      unavailableSections: options.unavailableSections,
      conflicts: options.conflicts,
    });
  }
  return source;
}

function projectPriority(
  demo: ProjectDemo,
  items: AttentionItem[],
  asOf: string,
) {
  const projectItems = items.filter(
    (item) => item.projectId === demo.project.id,
  );
  const explicitDecision = projectItems.some(
    (item) => item.explicitDecision,
  );
  const severity = projectItems[0]?.severity ?? Number.POSITIVE_INFINITY;
  const sameSeverityItems = projectItems.filter(
    (item) => item.severity === severity,
  );
  const priorityAge =
    sameSeverityItems.length > 0
      ? Math.min(
          ...sameSeverityItems.map((item) => Date.parse(item.occurredAt)),
        )
      : latestMeaningfulEvent(demo, asOf)?.timestamp ??
        Number.POSITIVE_INFINITY;

  return { explicitDecision, severity, priorityAge };
}

export function derivePortfolioDashboard(
  source: ProjectDemo[] | DashboardSnapshot,
  period: DashboardPeriod,
  options: DashboardDerivationOptions = {},
): PortfolioDashboardModel {
  const snapshot = normalizedSnapshot(source, options);
  if (snapshot.loadState === "loading") {
    return { loadState: "loading", asOf: snapshot.asOf };
  }
  if (snapshot.loadState === "error") {
    return {
      loadState: "error",
      asOf: snapshot.asOf,
      errorMessage: snapshot.message,
    };
  }

  const derivationOptions = {
    asOf: snapshot.asOf,
    unavailableSections: snapshot.unavailableSections,
    conflicts: snapshot.conflicts,
  };
  const active = activeDemos(snapshot.demos);
  const allAttention = deriveAttentionItems(
    snapshot.demos,
    derivationOptions,
  );
  const ranked = [...active].sort((a, b) => {
    const aPriority = projectPriority(a, allAttention, snapshot.asOf);
    const bPriority = projectPriority(b, allAttention, snapshot.asOf);
    return (
      Number(bPriority.explicitDecision) -
        Number(aPriority.explicitDecision) ||
      aPriority.severity - bPriority.severity ||
      aPriority.priorityAge - bPriority.priorityAge ||
      a.project.id.localeCompare(b.project.id)
    );
  });
  const decisions = allAttention.filter(
    (item) => item.explicitDecision,
  );
  const primaryDecision = decisions[0];

  return {
    loadState: snapshot.loadState,
    asOf: snapshot.asOf,
    pulse: derivePortfolioPulse(snapshot.demos, derivationOptions),
    projects: ranked
      .slice(0, 8)
      .map((demo) =>
        deriveProjectDashboardState(demo, derivationOptions),
      ),
    totalActiveProjects: active.length,
    hasMoreProjects: active.length > 8,
    decisions,
    attention: allAttention.filter(
      (item) => item.id !== primaryDecision?.id,
    ),
    movement: snapshot.unavailableSections.includes("activity")
      ? null
      : deriveMeaningfulActivityBuckets(
          snapshot.demos,
          period,
          derivationOptions,
        ),
    capacity: snapshot.unavailableSections.includes("capacity")
      ? null
      : deriveCapacityAllocation(snapshot.demos),
    unavailableSections: snapshot.unavailableSections,
    conflicts: snapshot.conflicts,
  };
}
