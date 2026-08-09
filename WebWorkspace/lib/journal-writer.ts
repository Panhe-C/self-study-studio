import {
  cloudKitFieldValue,
  type CloudKitConfig,
  type CloudKitContainer,
  type CloudKitDatabase,
  type CloudKitModifyRecordsOptions,
  type CloudKitRecord,
  type CloudKitRecordError,
} from "./cloudkit.ts";
import {
  decodeJournalRecord,
  journalRecordContract,
  type JournalRecordKind,
  type JournalRecordPayload,
} from "./journal-contract.ts";
import {
  createSyncConflict,
  type WebSyncConflict,
} from "./sync-conflicts.ts";
import type { RecoverableDraftStore } from "./recoverable-drafts.ts";

export type RevisionGuardExpectation = {
  baseRevisionID?: string;
  baseRecordChangeTag?: string;
  targetRevisionID?: string;
  targetRecordChangeTag?: string;
  recordState: "newRecord" | "existingRecord";
  targetRecordState: "newRecord" | "existingRecord";
};

export type CanonicalWriteRecord = {
  kind: JournalRecordKind;
  recordName: string;
  recordType?: string;
  recordChangeTag?: string;
  payload: JournalRecordPayload;
};

export type GuardedWriteRecord = {
  record: CanonicalWriteRecord;
  role: "base" | "target";
  expectation: RevisionGuardExpectation;
};

export type WebWriteOperation =
  | "updateNextStep"
  | "savePlanDraft"
  | "activateLearningPlan"
  | "savePlanRevisionDraft"
  | "savePracticeRoutine"
  | "acceptQualifyingProof"
  | "publishStageReview";

export type WebWriteBatch = {
  operation: WebWriteOperation;
  records: CanonicalWriteRecord[];
  guardedRecords?: GuardedWriteRecord[];
  draftId?: string;
  signal?: AbortSignal;
};

export type WebWriteResult =
  | {
      status: "committed";
      records: CloudKitRecord[];
      transactionID: string;
      semanticCommit: true;
    }
  | {
      status: "conflict";
      conflict: WebSyncConflict;
      transactionID: string;
      semanticCommit: false;
    }
  | {
      status: "signed-out" | "blocked" | "cancelled" | "partial" | "error";
      message: string;
      retryable: boolean;
      transactionID: string;
      semanticCommit: false;
    };

export class WebJournalWriteError extends Error {
  readonly code:
    | "demoWriteBlocked"
    | "missingCloudKitWriter"
    | "signedOut"
    | "unsupportedOperation"
    | "invalidContract"
    | "missingRevisionGuard"
    | "staleRevision"
    | "partialCommit"
    | "cancelled";

  constructor(code: WebJournalWriteError["code"], message: string) {
    super(message);
    this.name = "WebJournalWriteError";
    this.code = code;
  }
}

const operationKinds: Record<WebWriteOperation, ReadonlySet<JournalRecordKind>> = {
  updateNextStep: new Set(["project", "trailEvent"]),
  savePlanDraft: new Set(["coursePlan", "planPhase", "plannedSession", "practiceRoutine"]),
  activateLearningPlan: new Set(["coursePlan", "planPhase", "plannedSession", "practiceRoutine", "trailEvent"]),
  savePlanRevisionDraft: new Set(["coursePlan", "planPhase", "plannedSession", "practiceRoutine"]),
  savePracticeRoutine: new Set(["practiceRoutine"]),
  acceptQualifyingProof: new Set(["evidenceAcceptance", "proofRevision"]),
  publishStageReview: new Set([
    "review", "reviewDecision", "evidenceAcceptance", "proofRevision", "trailEvent",
    "project", "coursePlan", "planPhase", "plannedSession", "practiceRoutine",
  ]),
};

const payloadKinds = new Set<JournalRecordKind>([
  "evidenceContract",
  "evidenceAcceptance",
  "proofRevision",
  "reviewDecision",
]);

const pairMapFields = new Set(["projectRecommendations", "nextSteps", "sourceReferences"]);
const flattenedFields = new Set([
  "planningWindowStart",
  "planningWindowEnd",
  "planningWindowGranularity",
  "reminderHour",
  "reminderMinute",
  "statusMigrationSource",
  "statusMigrationDecision",
  "statusMigrationDecidedAt",
  "statusMigrationSourceArchivedAt",
]);

function makeTransactionID() {
  return typeof globalThis.crypto?.randomUUID === "function"
    ? globalThis.crypto.randomUUID()
    : `web-tx-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function base64Encode(value: string) {
  if (typeof globalThis.btoa === "function") {
    const bytes = new TextEncoder().encode(value);
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return globalThis.btoa(binary);
  }
  return Buffer.from(value, "utf8").toString("base64");
}

function base64Decode(value: string) {
  if (typeof globalThis.atob === "function") {
    const binary = globalThis.atob(value);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  }
  return Buffer.from(value, "base64").toString("utf8");
}

function pairMap(value: unknown) {
  if (!isObject(value)) return value;
  return Object.entries(value).flatMap(([key, entry]) => [key, entry]);
}

function flattenFields(record: CanonicalWriteRecord): Record<string, { value: unknown }> {
  const payload = record.payload;
  if (payloadKinds.has(record.kind)) {
    return { payload: { value: base64Encode(JSON.stringify(payload)) } };
  }

  const fields: Record<string, { value: unknown }> = {};
  const definition = journalRecordContract.records[record.kind];
  for (const field of Object.keys(definition.fields)) {
    if (field === "id" || payload[field] === undefined) continue;
    let value: unknown = payload[field];
    if (pairMapFields.has(field)) value = pairMap(value);
    if (field === "blocks" && Array.isArray(value)) value = base64Encode(JSON.stringify(value));
    if (field === "planningWindow" && isObject(value)) {
      fields.planningWindowStart = { value: value.start };
      fields.planningWindowEnd = { value: value.end };
      fields.planningWindowGranularity = { value: value.granularity };
      continue;
    }
    if (field === "reminderTime" && isObject(value)) {
      fields.reminderHour = { value: value.hour };
      fields.reminderMinute = { value: value.minute };
      continue;
    }
    if (field === "statusMigrationProvenance" && isObject(value)) {
      fields.statusMigrationSource = { value: value.sourceStatus };
      fields.statusMigrationDecision = { value: value.decision };
      fields.statusMigrationDecidedAt = { value: value.decidedAt };
      if (value.sourceArchivedAt !== undefined) fields.statusMigrationSourceArchivedAt = { value: value.sourceArchivedAt };
      continue;
    }
    fields[field] = { value };
  }
  return fields;
}

function toCloudKitRecord(record: CanonicalWriteRecord, tag?: string): CloudKitRecord {
  const expectedRecordType = journalRecordContract.records[record.kind]?.recordType;
  return {
    recordName: record.recordName,
    recordType: record.recordType ?? expectedRecordType,
    ...(tag ? { recordChangeTag: tag } : {}),
    fields: flattenFields(record),
  };
}

function payloadFromCloudKitRecord(record: CloudKitRecord, kind: JournalRecordKind): JournalRecordPayload {
  const candidate = record as CloudKitRecord & { payload?: unknown };
  if (isObject(candidate.payload)) return structuredClone(candidate.payload);
  const encoded = cloudKitFieldValue<unknown>(record, "payload");
  if (typeof encoded === "string") {
    try {
      const parsed = JSON.parse(encoded);
      if (isObject(parsed)) return parsed;
    } catch {
      try {
        const parsed = JSON.parse(base64Decode(encoded));
        if (isObject(parsed)) return parsed;
      } catch {
        // Continue to direct-field reconstruction.
      }
    }
  }
  const payload: JournalRecordPayload = { id: record.recordName };
  for (const field of Object.keys(journalRecordContract.records[kind].fields)) {
    if (field === "id") continue;
    const value = cloudKitFieldValue<unknown>(record, field);
    if (value === undefined || flattenedFields.has(field)) continue;
    if (pairMapFields.has(field) && Array.isArray(value)) {
      const map: Record<string, unknown> = {};
      for (let index = 0; index + 1 < value.length; index += 2) {
        if (typeof value[index] === "string") map[value[index]] = value[index + 1];
      }
      payload[field] = map;
      continue;
    }
    if (field === "blocks" && typeof value === "string") {
      try {
        payload[field] = JSON.parse(base64Decode(value));
        continue;
      } catch {
        // Keep the raw value so the contract decoder reports the malformed field.
      }
    }
    payload[field] = value;
  }
  if (kind === "plannedSession") {
    const start = cloudKitFieldValue<unknown>(record, "planningWindowStart");
    const end = cloudKitFieldValue<unknown>(record, "planningWindowEnd");
    const granularity = cloudKitFieldValue<unknown>(record, "planningWindowGranularity");
    if (start !== undefined || end !== undefined || granularity !== undefined) {
      payload.planningWindow = { start, end, granularity };
    }
  }
  if (kind === "practiceRoutine") {
    const hour = cloudKitFieldValue<unknown>(record, "reminderHour");
    const minute = cloudKitFieldValue<unknown>(record, "reminderMinute");
    if (hour !== undefined || minute !== undefined) payload.reminderTime = { hour, minute };
  }
  if (kind === "project") {
    const sourceStatus = cloudKitFieldValue<unknown>(record, "statusMigrationSource");
    const decision = cloudKitFieldValue<unknown>(record, "statusMigrationDecision");
    const decidedAt = cloudKitFieldValue<unknown>(record, "statusMigrationDecidedAt");
    const sourceArchivedAt = cloudKitFieldValue<unknown>(record, "statusMigrationSourceArchivedAt");
    if (sourceStatus !== undefined || decision !== undefined || decidedAt !== undefined) {
      payload.statusMigrationProvenance = {
        sourceStatus,
        decision,
        decidedAt,
        ...(sourceArchivedAt === undefined ? {} : { sourceArchivedAt }),
      };
    }
  }
  return payload;
}

function staleError(error: CloudKitRecordError) {
  const text = `${error.reason ?? ""}`.toLowerCase();
  return text.includes("change") || text.includes("conflict") || text.includes("stale");
}

function requireRealMode(mode: "demo" | "real") {
  if (mode === "demo") throw new WebJournalWriteError("demoWriteBlocked", "Demo data is noncanonical and cannot be written.");
}

function validateBatch(batch: WebWriteBatch) {
  const allowed = operationKinds[batch.operation];
  if (!allowed) throw new WebJournalWriteError("unsupportedOperation", `Unsupported Web write operation ${batch.operation}.`);
  if (batch.records.length === 0) throw new WebJournalWriteError("invalidContract", "A canonical write batch must contain at least one record.");
  const seen = new Set<string>();
  for (const record of batch.records) {
    if (!allowed.has(record.kind)) throw new WebJournalWriteError("unsupportedOperation", `${record.kind} is not allowed for ${batch.operation}.`);
    if (seen.has(record.recordName)) throw new WebJournalWriteError("invalidContract", `Duplicate record ${record.recordName} in one batch.`);
    seen.add(record.recordName);
    if (record.payload.id !== record.recordName) throw new WebJournalWriteError("invalidContract", `${record.kind}.id must match its CloudKit recordName.`);
    const decoded = decodeJournalRecord(record.payload, record.kind);
    if (decoded.payload.id !== record.recordName) throw new WebJournalWriteError("invalidContract", `${record.kind} failed canonical decoding.`);
  }
  if (["updateNextStep", "activateLearningPlan", "savePlanRevisionDraft", "savePracticeRoutine", "publishStageReview"].includes(batch.operation) && !(batch.guardedRecords?.length)) {
    throw new WebJournalWriteError("missingRevisionGuard", `${batch.operation} requires an explicit Revision Guard.`);
  }
  if (batch.operation === "acceptQualifyingProof" && (
    !batch.records.some((record) => record.kind === "evidenceAcceptance")
    || !batch.records.some((record) => record.kind === "proofRevision")
  )) {
    throw new WebJournalWriteError("invalidContract", "Qualifying Proof acceptance requires an EvidenceAcceptance and ProofRevision.");
  }
  if (batch.operation === "publishStageReview" && (!batch.records.some((record) => record.kind === "review") || !batch.records.some((record) => record.kind === "reviewDecision"))) {
    throw new WebJournalWriteError("invalidContract", "Stage Review publication requires a Review and ReviewDecision.");
  }
}

function guardRecords(batch: WebWriteBatch) {
  const map = new Map<string, CloudKitRecord>();
  for (const record of batch.records) map.set(record.recordName, toCloudKitRecord(record, record.recordChangeTag));
  for (const guarded of batch.guardedRecords ?? []) {
    const expectation = guarded.expectation;
    const tag = guarded.role === "base"
      ? expectation.baseRecordChangeTag
      : expectation.targetRecordChangeTag ?? guarded.record.recordChangeTag;
    if ((guarded.role === "base" && expectation.recordState === "existingRecord" || guarded.role === "target" && expectation.targetRecordState === "existingRecord") && !tag) {
      throw new WebJournalWriteError("missingRevisionGuard", `Missing CloudKit change tag for ${guarded.role} guard ${guarded.record.recordName}.`);
    }
    const existing = map.get(guarded.record.recordName);
    if (!existing || guarded.role === "target") map.set(guarded.record.recordName, toCloudKitRecord(guarded.record, tag));
  }
  return [...map.values()];
}

async function remoteRecordFor(
  database: CloudKitDatabase,
  error: CloudKitRecordError,
  recordName: string,
) {
  if (error.serverRecord ?? error.record) return error.serverRecord ?? error.record;
  if (!database.fetchRecords) return undefined;
  const response = await database.fetchRecords([recordName]);
  return response.records?.find((record) => record.recordName === recordName);
}

export function createWebJournalWriter(options: {
  mode: "demo" | "real";
  config: CloudKitConfig;
  container: CloudKitContainer;
  draftStore?: RecoverableDraftStore;
}) {
  const database = options.container.privateCloudDatabase;
  return {
    async writeBatch(batch: WebWriteBatch): Promise<WebWriteResult> {
      requireRealMode(options.mode);
      const transactionID = makeTransactionID();
      if (batch.signal?.aborted) {
        return { status: "cancelled", message: "The Web write was cancelled before it started.", retryable: true, transactionID, semanticCommit: false };
      }
      validateBatch(batch);
      const identity = await options.container.setUpAuth();
      if (!identity) return { status: "signed-out", message: "Sign in with the Apple Account that owns this journal.", retryable: false, transactionID, semanticCommit: false };
      if (!database.modifyRecords) throw new WebJournalWriteError("missingCloudKitWriter", "CloudKit JS does not expose atomic record modification.");

      const request = { recordsToSave: guardRecords(batch), recordNamesToDelete: [] };
      const writeOptions: CloudKitModifyRecordsOptions = {
        zoneID: { zoneName: options.config.zoneName },
        atomic: true,
        savePolicy: "ifServerRecordUnchanged",
      };
      let response;
      try {
        response = await database.modifyRecords(request, writeOptions);
      } catch (error) {
        const isAbortError = typeof DOMException !== "undefined" && error instanceof DOMException && error.name === "AbortError";
        if (batch.signal?.aborted || isAbortError) {
          return { status: "cancelled", message: "The Web write was cancelled.", retryable: true, transactionID, semanticCommit: false };
        }
        return { status: "error", message: error instanceof Error ? error.message : String(error), retryable: true, transactionID, semanticCommit: false };
      }
      if (batch.signal?.aborted) return { status: "cancelled", message: "The Web write was cancelled.", retryable: true, transactionID, semanticCommit: false };

      const errors = response.errors ?? [];
      const stale = errors.find(staleError);
      if (stale) {
        const target = batch.records.find((record) => record.recordName === (stale.recordName ?? batch.records[0].recordName)) ?? batch.records[0];
        const remote = await remoteRecordFor(database, stale, target.recordName);
        const base = batch.guardedRecords?.find((guard) => guard.role === "base" && guard.record.recordName === target.recordName)?.record
          ?? batch.guardedRecords?.find((guard) => guard.role === "base")?.record;
        const conflict = createSyncConflict({
          kind: target.kind,
          basePayload: base ? base.payload : { id: target.recordName },
          localPayload: target.payload,
          serverPayload: remote ? payloadFromCloudKitRecord(remote, target.kind) : { id: target.recordName },
          affectedRecords: batch.records.map((record) => record.recordName),
          source: "cloudkit",
        });
        return { status: "conflict", conflict, transactionID, semanticCommit: false };
      }
      if (errors.length > 0) {
        return { status: "partial", message: errors.map((error) => error.reason ?? "CloudKit rejected part of the atomic batch.").join(" "), retryable: true, transactionID, semanticCommit: false };
      }
      const result: WebWriteResult = { status: "committed", records: response.records ?? [], transactionID, semanticCommit: true };
      if (batch.draftId && options.draftStore) await options.draftStore.clearAfterCloudCompletion(batch.draftId, result);
      return result;
    },
  };
}
