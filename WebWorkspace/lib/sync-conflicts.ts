import type { JournalRecordKind, JournalRecordPayload } from "./journal-contract.ts";

export type SyncConflictResolution = "keepRemote" | "discardLocal" | "rebaseLocal" | "fork";

export type WebSyncConflict = {
  id: string;
  kind: JournalRecordKind;
  basePayload: JournalRecordPayload;
  localPayload: JournalRecordPayload;
  serverPayload: JournalRecordPayload;
  conflictingFields: string[];
  structural: boolean;
  source: "web" | "iphone" | "cloudkit";
  createdAt: string;
  affectedRecords: string[];
  resolution?: SyncConflictResolution;
};

export type MergeResult = {
  payload: JournalRecordPayload;
  conflictingFields: string[];
  structural: boolean;
};

const STRUCTURAL_FIELDS: Partial<Record<JournalRecordKind, ReadonlySet<string>>> = {
  coursePlan: new Set([
    "projectId", "revision", "planSeriesID", "revisionID", "baseRevisionID", "supersedesID",
    "status", "courseTitle", "courseOutline", "goal", "objective", "expectedOutcome", "startsOn", "deadline",
    "weeklyBudgetMinutes",
  ]),
  planPhase: new Set([
    "planId", "planRevisionID", "planSeriesID", "title", "objective", "expectedProof", "progress",
    "ordinal", "targetStart", "targetEnd",
  ]),
  practiceRoutine: new Set([
    "projectId", "planRevisionID", "planSeriesID", "name", "symbolName", "color", "targetMinutes",
    "weekdays", "blocks", "reminderTime", "isArchived",
  ]),
};

function equal(left: unknown, right: unknown) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function makeID() {
  return typeof globalThis.crypto?.randomUUID === "function"
    ? globalThis.crypto.randomUUID()
    : `conflict-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function mergeJournalPayloads(
  basePayload: JournalRecordPayload,
  localPayload: JournalRecordPayload,
  serverPayload: JournalRecordPayload,
  options: { kind: JournalRecordKind },
): MergeResult {
  const fields = new Set([
    ...Object.keys(basePayload),
    ...Object.keys(localPayload),
    ...Object.keys(serverPayload),
  ]);
  const payload: JournalRecordPayload = {};
  const conflictingFields: string[] = [];
  const structuralFields = STRUCTURAL_FIELDS[options.kind] ?? new Set<string>();
  let structural = false;

  for (const field of [...fields].sort()) {
    const base = basePayload[field];
    const local = localPayload[field];
    const server = serverPayload[field];
    if (equal(local, server)) {
      if (local !== undefined) payload[field] = structuredClone(local);
      continue;
    }
    if (equal(local, base)) {
      if (server !== undefined) payload[field] = structuredClone(server);
      continue;
    }
    if (equal(server, base)) {
      if (local !== undefined) payload[field] = structuredClone(local);
      continue;
    }
    payload[field] = structuredClone(local);
    conflictingFields.push(field);
    if (structuralFields.has(field)) structural = true;
  }
  return { payload, conflictingFields, structural };
}

export function createSyncConflict(input: {
  kind: JournalRecordKind;
  basePayload: JournalRecordPayload;
  localPayload: JournalRecordPayload;
  serverPayload: JournalRecordPayload;
  source?: WebSyncConflict["source"];
  affectedRecords?: string[];
}): WebSyncConflict {
  const merge = mergeJournalPayloads(input.basePayload, input.localPayload, input.serverPayload, { kind: input.kind });
  return {
    id: makeID(),
    kind: input.kind,
    basePayload: structuredClone(input.basePayload),
    localPayload: structuredClone(input.localPayload),
    serverPayload: structuredClone(input.serverPayload),
    conflictingFields: merge.conflictingFields,
    structural: merge.structural,
    source: input.source ?? "cloudkit",
    createdAt: new Date().toISOString(),
    affectedRecords: input.affectedRecords ?? [String(input.localPayload.id ?? "")].filter(Boolean),
  };
}

export type SyncConflictInput = Omit<WebSyncConflict, "structural" | "createdAt" | "id">
  & Partial<Pick<WebSyncConflict, "id" | "createdAt" | "structural">>;

export function resolveSyncConflict(
  conflict: WebSyncConflict | SyncConflictInput,
  resolution: SyncConflictResolution,
): { resolution: SyncConflictResolution; payload: JournalRecordPayload; requiresPublish: boolean } {
  const structural = conflict.structural ?? false;
  switch (resolution) {
    case "keepRemote":
    case "discardLocal":
      return { resolution, payload: structuredClone(conflict.serverPayload), requiresPublish: false };
    case "rebaseLocal": {
      const merged = mergeJournalPayloads(conflict.basePayload, conflict.localPayload, conflict.serverPayload, { kind: conflict.kind });
      if (merged.conflictingFields.length > 0) {
        throw new Error(`Cannot rebase while ${merged.conflictingFields.join(", ")} still conflicts.`);
      }
      return { resolution, payload: merged.payload, requiresPublish: true };
    }
    case "fork": {
      if (!(structural || conflict.kind === "coursePlan" || conflict.kind === "planPhase" || conflict.kind === "practiceRoutine")) {
        throw new Error("Fork is reserved for structural plan or routine conflicts.");
      }
      const payload = structuredClone(conflict.localPayload);
      payload.id = makeID();
      if (conflict.kind === "coursePlan") {
        payload.status = "draft";
        payload.baseRevisionID = conflict.serverPayload.revisionID ?? conflict.serverPayload.id;
        payload.supersedesID = conflict.serverPayload.revisionID ?? conflict.serverPayload.id;
      }
      return { resolution, payload, requiresPublish: true };
    }
  }
}
