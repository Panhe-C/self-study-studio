import type {
  PlanPhase,
  PlanSession,
  PlanningWindow,
  PracticeBlock,
  ProjectDemo,
  ProofItem,
  ProjectSummary,
  TrailItem,
} from "./journal";
import type { DashboardSection } from "./dashboard";
import type { JournalRecordKind, JournalRecordPayload } from "./journal-contract";
import type { JournalReadRecord } from "./journal-reader";

export type JournalProjectionInput = Pick<JournalReadRecord, "kind" | "recordName" | "recordType" | "payload">;

export type JournalProjection = {
  demos: ProjectDemo[];
  unavailableSections: DashboardSection[];
  issues: string[];
  provenance: "real";
};

type RecordLike = JournalProjectionInput;
type Payload = JournalRecordPayload & { [key: string]: unknown };

const REAL_SOURCE_LABEL = "Real journal · CloudKit private database · read-only";
const ACCENTS = ["#eb5b4f", "#356bc7", "#18856d", "#9b59b6", "#d97706", "#087f8c"];

function payload(record: RecordLike): Payload {
  return record.payload as Payload;
}

function stringValue(value: unknown, fallback = "") {
  return typeof value === "string" ? value : fallback;
}

function numberValue(value: unknown, fallback = 0) {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function booleanValue(value: unknown, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function timestamp(value: unknown) {
  if (typeof value !== "string") return Number.NEGATIVE_INFINITY;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Number.NEGATIVE_INFINITY;
}

function iso(value: unknown, fallback = "") {
  return typeof value === "string" && Number.isFinite(Date.parse(value))
    ? new Date(value).toISOString()
    : fallback;
}

function dateWindow(start: unknown, end: unknown) {
  const startValue = iso(start).slice(0, 10);
  const endValue = iso(end).slice(0, 10);
  if (!startValue && !endValue) return "Window unavailable";
  if (!endValue || startValue === endValue) return startValue;
  return `${startValue} → ${endValue}`;
}

function statusForProject(value: unknown): ProjectSummary["status"] {
  switch (value) {
    case "active": return "Active";
    case "completed": return "Completed";
    case "abandoned":
    case "archived":
    case "trash": return "Abandoned";
    case "idea":
    case "paused":
    case "low-frequency":
    default: return "Paused";
  }
}

function projectToken(name: string, id: string) {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const token = words.length > 1
    ? `${words[0][0] ?? ""}${words[1][0] ?? ""}`
    : name.slice(0, 2);
  return (token || id.slice(0, 2)).toUpperCase();
}

function accentFor(id: string) {
  let hash = 0;
  for (const character of id) hash = (hash * 31 + character.charCodeAt(0)) >>> 0;
  return ACCENTS[hash % ACCENTS.length];
}

function byNewest(left: RecordLike, right: RecordLike) {
  return (
    timestamp(payload(right).updatedAt ?? payload(right).createdAt ?? payload(right).occurredAt) -
      timestamp(payload(left).updatedAt ?? payload(left).createdAt ?? payload(left).occurredAt) ||
    left.recordName.localeCompare(right.recordName)
  );
}

function activePlanForProject(
  project: Payload,
  plans: RecordLike[],
) {
  const candidates = plans
    .filter((record) => payload(record).projectId === project.id)
    .sort((left, right) => (
      Number(payload(right).status === "active") - Number(payload(left).status === "active") ||
      numberValue(payload(right).revision) - numberValue(payload(left).revision) ||
      byNewest(left, right)
    ));
  const preferredID = stringValue(project.activeCoursePlanId);
  return candidates.find((candidate) => candidate.recordName === preferredID) ?? candidates[0];
}

function phaseStatus(value: unknown): PlanPhase["status"] {
  if (value === "completed") return "Complete";
  if (value === "active") return "Active";
  return "Planned";
}

function proofKind(value: unknown): ProofItem["kind"] {
  switch (value) {
    case "audio": return "Audio";
    case "image": return "Diagram";
    case "file": return "Code";
    case "link": return "Text";
    case "text":
    default: return "Text";
  }
}

function trailKind(value: unknown): TrailItem["kind"] {
  switch (value) {
    case "session": return "practice";
    case "proof": return "proof";
    case "planActivated":
    case "planRevised":
    case "scheduleChanged": return "plan";
    case "review": return "review";
    default: return "plan";
  }
}

function plannedSessionStatus(record: RecordLike, asOfTimestamp: number): PlanSession["status"] {
  const value = payload(record);
  if (value.status === "completed" || value.completedSessionId) return "Done";
  const end = timestamp(
    (value.planningWindow as Record<string, unknown> | undefined)?.end ?? value.deadline,
  );
  return end !== Number.NEGATIVE_INFINITY && end < asOfTimestamp ? "Carryover" : "Planned";
}

function sessionWindow(value: Payload) {
  const window = value.planningWindow as Record<string, unknown> | undefined;
  if (window) return dateWindow(window.start, window.end);
  if (value.deadline) return `Due ${iso(value.deadline).slice(0, 10)}`;
  return iso(value.createdAt).slice(0, 10) || "Window unavailable";
}

function practiceBlocksForRoutine(
  routine: Payload | undefined,
  latestPractice: Payload | undefined,
) {
  const rawBlocks = Array.isArray(routine?.blocks) ? routine.blocks : [];
  const summaries = Array.isArray(latestPractice?.summary)
    ? latestPractice?.summary
    : (latestPractice?.summary as Record<string, unknown> | undefined)?.blockSummaries;
  const blockSummaries = Array.isArray(summaries) ? summaries as Array<Record<string, unknown>> : [];
  const toneByColor: Record<string, PracticeBlock["tone"]> = {
    coral: "coral",
    yellow: "coral",
    teal: "blue",
    blue: "blue",
    green: "green",
    pink: "coral",
  };

  return rawBlocks
    .filter((block): block is Record<string, unknown> => typeof block === "object" && block !== null)
    .map((block, index) => {
      const id = stringValue(block.id, `block-${index + 1}`);
      const summary = blockSummaries.find((candidate) => candidate.blockID === id);
      const nextFocusCandidates = Array.isArray(block.nextFocusCandidates)
        ? block.nextFocusCandidates.filter((item): item is string => typeof item === "string")
        : [];
      return {
        id,
        name: stringValue(block.name, `Block ${index + 1}`),
        targetMinutes: numberValue(block.targetMinutes),
        ordinal: numberValue(block.ordinal, index),
        focus: stringValue(block.focus, "Focus not recorded"),
        nextFocusCandidates,
        actualMinutes: Math.round(numberValue(summary?.activeDurationSeconds) / 60),
        nextFocus: nextFocusCandidates[0] ?? "No next focus recorded",
        tone: toneByColor[stringValue(routine?.color)] ?? (index % 2 ? "blue" : "coral"),
      } satisfies PracticeBlock;
    })
    .sort((left, right) => (left.ordinal ?? 0) - (right.ordinal ?? 0) || left.id.localeCompare(right.id));
}

function latestPracticeForRoutine(
  routine: Payload | undefined,
  practiceSessions: RecordLike[],
) {
  if (!routine) return undefined;
  return practiceSessions
    .filter((record) => payload(record).routineId === routine.id)
    .sort(byNewest)[0]
    ? payload(practiceSessions.filter((record) => payload(record).routineId === routine.id).sort(byNewest)[0])
    : undefined;
}

function projectRoutine(
  project: Payload,
  plan: Payload | undefined,
  routines: RecordLike[],
  practiceSessions: RecordLike[],
) {
  const routine = routines
    .filter((record) => {
      const value = payload(record);
      return value.projectId === project.id && !booleanValue(value.isArchived);
    })
    .sort((left, right) => (
      Number(payload(right).planRevisionID === plan?.revisionID) - Number(payload(left).planRevisionID === plan?.revisionID) ||
      byNewest(left, right)
    ))[0];
  const routinePayload = routine ? payload(routine) : undefined;
  const latestPractice = latestPracticeForRoutine(routinePayload, practiceSessions);
  const blocks = practiceBlocksForRoutine(routinePayload, latestPractice);
  const weekdays = Array.isArray(routinePayload?.weekdays) ? routinePayload.weekdays : [];
  return {
    routinePayload,
    blocks,
    title: stringValue(routinePayload?.name, "No active Practice Routine"),
    frequency: routinePayload
      ? `${weekdays.length} day${weekdays.length === 1 ? "" : "s"} each week`
      : "Schedule unavailable",
    targetMinutes: numberValue(routinePayload?.targetMinutes),
    latestPractice,
  };
}

function projectProofs(projectID: string, proofs: RecordLike[]) {
  return proofs
    .filter((record) => payload(record).projectId === projectID)
    .sort(byNewest)
    .map((record) => {
      const value = payload(record);
      const kind = proofKind(value.type);
      const integrity = stringValue(value.integrity, "recorded");
      const date = iso(value.createdAt).slice(0, 10) || "Date unavailable";
      return {
        id: stringValue(value.id, record.recordName),
        kind,
        status: integrity,
        title: stringValue(value.title, "Untitled proof"),
        detail: stringValue(value.statement, "No statement recorded."),
        date,
        preview: kind === "Audio" ? "Audio" : kind,
        previewDetail: stringValue(value.mimeType, stringValue(value.url, "Canonical journal record")),
      } satisfies ProofItem;
    });
}

function projectTrail(projectID: string, trailEvents: RecordLike[]) {
  return trailEvents
    .filter((record) => payload(record).projectId === projectID)
    .sort((left, right) => (
      timestamp(payload(right).occurredAt) - timestamp(payload(left).occurredAt) ||
      left.recordName.localeCompare(right.recordName)
    ))
    .map((record) => {
      const value = payload(record);
      const occurredAt = iso(value.occurredAt);
      return {
        id: stringValue(value.id, record.recordName),
        date: occurredAt.slice(0, 10) || "Date unavailable",
        occurredAt,
        title: stringValue(value.title, "Journal event"),
        detail: stringValue(value.detail, "No detail recorded."),
        kind: trailKind(value.type),
      } satisfies TrailItem;
    });
}

function projectReviews(projectID: string, reviews: RecordLike[], phaseID?: string) {
  const candidate = reviews
    .filter((record) => {
      const value = payload(record);
      return value.projectId === projectID || (phaseID && value.phaseId === phaseID);
    })
    .sort(byNewest)[0];
  if (!candidate) {
    return {
      ready: false,
      headline: "No Review recorded",
      summary: "Review facts are unavailable until a canonical Review is read.",
      practiceSessions: 0,
      carryovers: 0,
      readySince: "Not ready",
    };
  }
  const value = payload(candidate);
  const facts = Array.isArray(value.facts) ? value.facts.filter((item): item is string => typeof item === "string") : [];
  const patterns = Array.isArray(value.patterns) ? value.patterns.filter((item): item is string => typeof item === "string") : [];
  const ready = value.status === "published";
  return {
    ready,
    headline: facts[0] ?? "Canonical Review",
    summary: [...facts, ...patterns].join(" · ") || "No Review summary recorded.",
    practiceSessions: facts.length,
    carryovers: 0,
    readySince: ready ? `Published ${iso(value.publishedAt ?? value.updatedAt).slice(0, 10)}` : "Draft Review",
    readySinceAt: iso(value.publishedAt ?? value.updatedAt),
  };
}

function deriveCapacity(
  projectID: string,
  sessions: RecordLike[],
  availabilityRules: RecordLike[],
  asOfTimestamp: number,
) {
  const plannedMinutes = sessions
    .filter((record) => payload(record).projectId === projectID && plannedSessionStatus(record, asOfTimestamp) !== "Done")
    .reduce((total, record) => total + numberValue(payload(record).durationMinutes), 0);
  const availableMinutes = availabilityRules
    .filter((record) => {
      const value = payload(record);
      return booleanValue(value.enabled) &&
        timestamp(value.validFrom ?? "1970-01-01T00:00:00.000Z") <= asOfTimestamp &&
        (value.validThrough === undefined || timestamp(value.validThrough) >= asOfTimestamp);
    })
    .reduce((total, record) => total + Math.max(0, numberValue(payload(record).endMinute) - numberValue(payload(record).startMinute)), 0);
  return {
    plannedMinutes,
    availableMinutes,
    note: availabilityRules.length === 0
      ? "Availability rules are not declared in the canonical journal."
      : availableMinutes >= plannedMinutes
        ? `${availableMinutes - plannedMinutes} minutes remain under declared availability.`
        : `Planned time exceeds declared availability by ${plannedMinutes - availableMinutes} minutes.`,
  };
}

function canonicalRecordsByKind(records: RecordLike[]) {
  const groups = new Map<JournalRecordKind, RecordLike[]>();
  for (const record of records) {
    const existing = groups.get(record.kind) ?? [];
    existing.push(record);
    groups.set(record.kind, existing);
  }
  return groups;
}

export function projectJournalRecords(
  records: RecordLike[],
  options: { asOf?: string } = {},
): JournalProjection {
  const asOf = iso(options.asOf, new Date().toISOString());
  const asOfTimestamp = timestamp(asOf);
  const groups = canonicalRecordsByKind(records);
  const projects = (groups.get("project") ?? [])
    .sort((left, right) => left.recordName.localeCompare(right.recordName));
  const plans = groups.get("coursePlan") ?? [];
  const phases = groups.get("planPhase") ?? [];
  const plannedSessions = groups.get("plannedSession") ?? [];
  const routines = groups.get("practiceRoutine") ?? [];
  const practiceSessions = groups.get("practiceSession") ?? [];
  const proofs = groups.get("proof") ?? [];
  const trailEvents = groups.get("trailEvent") ?? [];
  const reviews = groups.get("review") ?? [];
  const availabilityRules = groups.get("availabilityRule") ?? [];
  const evidenceAcceptances = groups.get("evidenceAcceptance") ?? [];
  const unavailable = new Set<DashboardSection>();
  const demos: ProjectDemo[] = [];

  for (const projectRecord of projects) {
    const project = payload(projectRecord);
    const projectID = stringValue(project.id, projectRecord.recordName);
    const planRecord = activePlanForProject(project, plans);
    const plan = planRecord ? payload(planRecord) : undefined;
    const phaseRecords = phases
      .filter((record) => recordPayloadPlanID(record) === plan?.id)
      .sort((left, right) => numberValue(payload(left).ordinal) - numberValue(payload(right).ordinal) || left.recordName.localeCompare(right.recordName));
    const planPhases: PlanPhase[] = phaseRecords.map((record) => {
      const value = payload(record);
      return {
        id: stringValue(value.id, record.recordName),
        order: numberValue(value.ordinal),
        title: stringValue(value.title, "Untitled Phase"),
        description: stringValue(value.objective, "No objective recorded."),
        window: dateWindow(value.targetStart, value.targetEnd),
        status: phaseStatus(value.progress),
        milestones: stringValue(value.expectedProof) ? [stringValue(value.expectedProof)] : [],
      };
    });
    const activePhaseRecord = phaseRecords.find((record) => payload(record).progress === "active") ?? phaseRecords.find((record) => payload(record).progress !== "completed");
    const activePhase = activePhaseRecord ? payload(activePhaseRecord) : undefined;
    const projectSessions = plannedSessions
      .filter((record) => payload(record).projectId === projectID)
      .sort((left, right) => timestamp(payload(left).deadline ?? payload(left).createdAt) - timestamp(payload(right).deadline ?? payload(right).createdAt) || left.recordName.localeCompare(right.recordName))
      .map((record) => {
        const value = payload(record);
        const status = plannedSessionStatus(record, asOfTimestamp);
        const rawPlanningWindow = value.planningWindow;
        const planningWindow = rawPlanningWindow && typeof rawPlanningWindow === "object"
          ? rawPlanningWindow as Partial<PlanningWindow>
          : undefined;
        const normalizedPlanningWindow = planningWindow &&
          typeof planningWindow.start === "string" &&
          typeof planningWindow.end === "string" &&
          typeof planningWindow.granularity === "string"
          ? planningWindow as PlanningWindow
          : undefined;
        return {
          id: stringValue(value.id, record.recordName),
          title: stringValue(value.title, "Planned session"),
          window: sessionWindow(value),
          duration: numberValue(value.durationMinutes),
          status,
          ...(status === "Carryover" ? { attentionAt: iso(value.deadline ?? value.updatedAt, asOf) } : {}),
          ...(normalizedPlanningWindow ? { planningWindow: normalizedPlanningWindow } : {}),
        } satisfies PlanSession;
      });
    const projectProofsValue = projectProofs(projectID, proofs);
    const projectTrailValue = projectTrail(projectID, trailEvents);
    const routine = projectRoutine(project, plan, routines, practiceSessions);
    const review = projectReviews(projectID, reviews, activePhase ? stringValue(activePhase.id) : undefined);
    const capacity = deriveCapacity(projectID, plannedSessions, availabilityRules, asOfTimestamp);
    const evidenceReady = evidenceAcceptances.filter((record) => {
      const acceptance = payload(record);
      return projectProofsValue.some((proof) => proof.id === acceptance.proofId);
    }).length;
    const evidenceTarget = activePhase && stringValue(activePhase.expectedProof) ? 1 : 0;

    if (!activePhase) unavailable.add("evidence");
    if (projectTrailValue.length === 0 && practiceSessions.filter((record) => payload(record).linkedProjectId === projectID).length === 0) unavailable.add("activity");
    if (availabilityRules.length === 0) unavailable.add("capacity");

    const projectSummary: ProjectSummary = {
      id: projectID,
      token: projectToken(stringValue(project.name, projectID), projectID),
      name: stringValue(project.name, "Untitled Project"),
      area: stringValue(project.area, "Uncategorized"),
      goal: stringValue(project.goal, "No goal recorded."),
      phase: stringValue(activePhase?.title, "No active Phase"),
      phaseWindow: dateWindow(activePhase?.targetStart, activePhase?.targetEnd),
      status: statusForProject(project.status),
      accent: accentFor(projectID),
      nextStep: stringValue(project.currentNextStep, "No canonical Next Step recorded."),
      expectedProof: stringValue(activePhase?.expectedProof, "No Expected Proof recorded."),
      evidenceCount: evidenceReady,
      evidenceTarget,
      lastMeaningfulActivity: projectTrailValue[0]
        ? `${projectTrailValue[0].date} · ${projectTrailValue[0].title}`
        : "No meaningful activity recorded",
    };

    demos.push({
      project: projectSummary,
      sourceLabel: REAL_SOURCE_LABEL,
      planTitle: stringValue(plan?.courseTitle, "No active Learning Plan"),
      planRevision: numberValue(plan?.revision),
      planPhases,
      sessions: projectSessions,
      routineTitle: routine.title,
      routineFrequency: routine.frequency,
      routineTargetMinutes: routine.targetMinutes,
      practiceBlocks: routine.blocks,
      practiceBalanceNote: routine.blocks.length > 0
        ? "Practice data is projected from the latest canonical routine and session."
        : "Practice routine blocks are unavailable in the canonical journal.",
      ...(routine.latestPractice
        ? {
            practiceAttention: (routine.latestPractice.summary as Record<string, unknown> | undefined)?.attentionMarker
              ? {
                  id: `${projectID}-practice-attention`,
                  label: "Practice session needs attention",
                  detail: stringValue((routine.latestPractice.summary as Record<string, unknown>).attentionMarker),
                  markedAt: iso(routine.latestPractice.endedAt ?? routine.latestPractice.updatedAt, asOf),
                }
              : undefined,
            lastSessionLabel: `${iso(routine.latestPractice.endedAt).slice(0, 10)} · ${Math.round(numberValue(routine.latestPractice.activeDurationSeconds) / 60)}m recorded`,
          }
        : { lastSessionLabel: "No Practice Session recorded" }),
      trail: projectTrailValue,
      proofs: projectProofsValue,
      review,
      capacity,
    });
  }

  return {
    demos,
    unavailableSections: [...unavailable].sort(),
    issues: [],
    provenance: "real",
  };
}

function recordPayloadPlanID(record: RecordLike) {
  const value = payload(record);
  return value.planRevisionID ?? value.planId;
}
