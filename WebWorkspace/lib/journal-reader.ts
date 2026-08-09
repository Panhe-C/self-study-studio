import {
  cloudKitConfig,
  cloudKitFieldValue,
  configureCloudKit,
  waitForCloudKit,
  type CloudKitConfig,
  type CloudKitContainer,
  type CloudKitDatabase,
  type CloudKitNamespace,
  type CloudKitRecord,
  type CloudKitZoneChange,
} from "./cloudkit.ts";
import {
  decodeJournalRecord,
  journalRecordContract,
  type JournalRecordKind,
  type JournalRecordPayload,
} from "./journal-contract.ts";

export type JournalQuery = {
  projectId?: string;
  kinds?: JournalRecordKind[];
  limit?: number;
};

export type JournalReadRecord = {
  kind: JournalRecordKind;
  recordName: string;
  recordType: string;
  recordChangeTag?: string;
  payload: JournalRecordPayload;
};

export type JournalReadIssue = {
  recordName?: string;
  recordType?: string;
  message: string;
};

export type JournalReadStatus =
  | "blocked"
  | "signed-out"
  | "ready"
  | "empty"
  | "partial"
  | "error";

export type JournalReadResult = {
  status: JournalReadStatus;
  message: string;
  records: JournalReadRecord[];
  issues: JournalReadIssue[];
  userRecordName?: string;
  syncToken?: string;
  latestChangeTag?: string;
  recordCount: number;
  demoFallbackUsed: false;
  provenance: {
    source: "cloudkit";
    mode: "real";
    readAt: string;
    zoneName: string;
  };
};

export type JournalReaderOptions = {
  config?: CloudKitConfig;
  container?: CloudKitContainer;
  cloudKit?: CloudKitNamespace;
  query?: JournalQuery;
};

const kindByRecordType = new Map<
  string,
  JournalRecordKind
>(
  Object.entries(journalRecordContract.records).map(([kind, definition]) => [
    definition.recordType,
    kind as JournalRecordKind,
  ]),
);

const directFieldAliases = new Set([
  "statusMigrationSource",
  "statusMigrationDecision",
  "statusMigrationDecidedAt",
  "statusMigrationSourceArchivedAt",
  "planningWindowStart",
  "planningWindowEnd",
  "planningWindowGranularity",
  "reminderHour",
  "reminderMinute",
  "asset",
  "contentHash",
]);

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function unwrapCloudKitValue(value: unknown): unknown {
  if (value instanceof Date) return value.toISOString();
  if (Array.isArray(value)) return value.map(unwrapCloudKitValue);
  if (!isObject(value)) return value;
  if (Object.hasOwn(value, "value")) {
    return unwrapCloudKitValue(value.value);
  }
  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [
      key,
      unwrapCloudKitValue(entry),
    ]),
  );
}

function parseJSON(value: unknown): unknown {
  if (isObject(value) || Array.isArray(value)) return value;
  if (typeof value !== "string") return value;

  try {
    return JSON.parse(value);
  } catch {
    // CloudKit JS may expose Data fields as base64. Decode without requiring
    // Node's Buffer so this adapter remains browser-safe.
  }

  try {
    if (typeof globalThis.atob !== "function") return value;
    const binary = globalThis.atob(value);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const text = new TextDecoder().decode(bytes);
    return JSON.parse(text);
  } catch {
    return value;
  }
}

function serializedFieldValue(value: unknown): unknown {
  return parseJSON(unwrapCloudKitValue(value));
}

function normalizeDateLike(value: unknown): unknown {
  if (value instanceof Date) return value.toISOString();
  return value;
}

function payloadFromRecord(record: CloudKitRecord, kind: JournalRecordKind) {
  const definition = journalRecordContract.records[kind];
  const payloadValue = cloudKitFieldValue<unknown>(record, "payload");
  const decodedPayload = payloadValue === undefined
    ? undefined
    : serializedFieldValue(payloadValue);

  if (isObject(decodedPayload)) {
    return {
      ...decodedPayload,
      id: decodedPayload.id ?? record.recordName,
    } as JournalRecordPayload;
  }

  const payload: JournalRecordPayload = {
    id: record.recordName,
  };

  for (const fieldName of Object.keys(definition.fields)) {
    const fieldValue = cloudKitFieldValue<unknown>(record, fieldName);
    if (fieldValue !== undefined) {
      payload[fieldName] = normalizeDateLike(serializedFieldValue(fieldValue));
    }
  }

  // CloudRecordMapper stores migration provenance as four flat fields while
  // the canonical contract exposes one nested object.
  if (kind === "project") {
    const sourceStatus = cloudKitFieldValue<unknown>(record, "statusMigrationSource");
    const decision = cloudKitFieldValue<unknown>(record, "statusMigrationDecision");
    const decidedAt = cloudKitFieldValue<unknown>(record, "statusMigrationDecidedAt");
    const sourceArchivedAt = cloudKitFieldValue<unknown>(record, "statusMigrationSourceArchivedAt");
    if (sourceStatus !== undefined || decision !== undefined || decidedAt !== undefined) {
      payload.statusMigrationProvenance = {
        sourceStatus: normalizeDateLike(serializedFieldValue(sourceStatus)),
        decision: normalizeDateLike(serializedFieldValue(decision)),
        decidedAt: normalizeDateLike(serializedFieldValue(decidedAt)),
        ...(sourceArchivedAt === undefined
          ? {}
          : { sourceArchivedAt: normalizeDateLike(serializedFieldValue(sourceArchivedAt)) }),
      };
    }
  }

  // PlannedSession's nested window is represented by three CloudKit fields.
  if (kind === "plannedSession") {
    const start = cloudKitFieldValue<unknown>(record, "planningWindowStart");
    const end = cloudKitFieldValue<unknown>(record, "planningWindowEnd");
    const granularity = cloudKitFieldValue<unknown>(record, "planningWindowGranularity");
    if (start !== undefined || end !== undefined || granularity !== undefined) {
      payload.planningWindow = {
        start: normalizeDateLike(serializedFieldValue(start)),
        end: normalizeDateLike(serializedFieldValue(end)),
        granularity: normalizeDateLike(serializedFieldValue(granularity)),
      };
    }
  }

  // PracticeRoutine's reminder is also flattened by the iPhone mapper.
  if (kind === "practiceRoutine") {
    const hour = cloudKitFieldValue<unknown>(record, "reminderHour");
    const minute = cloudKitFieldValue<unknown>(record, "reminderMinute");
    if (hour !== undefined || minute !== undefined) {
      payload.reminderTime = {
        hour: normalizeDateLike(serializedFieldValue(hour)),
        minute: normalizeDateLike(serializedFieldValue(minute)),
      };
    }
  }

  // These are mapper-only fields, not canonical contract fields. Keeping the
  // allow-list above prevents CloudKit metadata from leaking into decoding.
  for (const alias of directFieldAliases) delete payload[alias];
  return payload;
}

function issueForRecord(
  record: CloudKitRecord,
  error: unknown,
): JournalReadIssue {
  return {
    recordName: record.recordName,
    recordType: record.recordType,
    message: error instanceof Error ? error.message : String(error),
  };
}

function matchesQuery(record: JournalReadRecord, query?: JournalQuery) {
  if (!query) return true;
  if (query.kinds && !query.kinds.includes(record.kind)) return false;
  if (query.projectId) {
    const payloadProjectID = record.kind === "project"
      ? record.payload.id
      : record.payload.projectId ?? record.payload.linkedProjectId;
    if (payloadProjectID !== query.projectId) return false;
  }
  return true;
}

function safeQueryLimit(limit: number | undefined) {
  if (limit === undefined) return undefined;
  if (!Number.isFinite(limit)) return 0;
  return Math.max(0, Math.floor(limit));
}

async function fetchZoneRecords(
  database: CloudKitDatabase,
  config: CloudKitConfig,
) {
  const recordsByName = new Map<string, CloudKitRecord>();
  const issues: JournalReadIssue[] = [];
  const seenSyncTokens = new Set<string>();
  let syncToken: string | undefined;
  let lastChangeTag: string | undefined;

  while (true) {
    let response: { zones?: CloudKitZoneChange[] };
    try {
      response = await database.fetchRecordZoneChanges({
        zoneID: { zoneName: config.zoneName },
        ...(syncToken ? { syncToken } : {}),
      });
    } catch (error) {
      issues.push({
        message: error instanceof Error ? error.message : String(error),
      });
      break;
    }

    const zone = response.zones?.[0];
    if (!zone) {
      issues.push({ message: `CloudKit returned no result for ${config.zoneName}.` });
      break;
    }

    for (const record of zone.records ?? []) {
      recordsByName.set(record.recordName, record);
      if (record.recordChangeTag) lastChangeTag = record.recordChangeTag;
    }
    issues.push(
      ...(zone.errors ?? []).map((error) => ({
        message: error.reason ?? "CloudKit reported an unspecified zone error.",
      })),
    );

    if (!zone.moreComing) {
      syncToken = zone.syncToken ?? syncToken;
      break;
    }

    const nextSyncToken = zone.syncToken?.trim();
    if (!nextSyncToken) {
      issues.push({ message: "CloudKit reported more changes but did not return a sync token." });
      break;
    }
    if (seenSyncTokens.has(nextSyncToken)) {
      issues.push({ message: "CloudKit repeated a sync token before the zone read completed." });
      break;
    }
    seenSyncTokens.add(nextSyncToken);
    syncToken = nextSyncToken;
  }

  return {
    records: [...recordsByName.values()].sort(
      (left, right) => left.recordName.localeCompare(right.recordName),
    ),
    issues,
    syncToken,
    lastChangeTag,
  };
}

function resultBase(config: CloudKitConfig): Pick<JournalReadResult, "demoFallbackUsed" | "provenance"> {
  return {
    demoFallbackUsed: false,
    provenance: {
      source: "cloudkit",
      mode: "real",
      readAt: new Date().toISOString(),
      zoneName: config.zoneName,
    },
  };
}

export async function readCloudKitJournal(
  options: JournalReaderOptions = {},
): Promise<JournalReadResult> {
  const config = options.config ?? cloudKitConfig;
  const base = resultBase(config);

  if (!config.apiToken.trim()) {
    return {
      ...base,
      status: "blocked",
      message:
        "Real journal mode is blocked. Set NEXT_PUBLIC_CLOUDKIT_API_TOKEN (and the container, environment, zone, and allowed origin) before reading CloudKit.",
      records: [],
      issues: [],
      recordCount: 0,
    };
  }

  try {
    let container = options.container;
    if (!container) {
      const cloudKit = options.cloudKit ?? await waitForCloudKit();
      configureCloudKit(cloudKit, config);
      container = cloudKit.getDefaultContainer();
    }

    const identity = await container.setUpAuth();
    if (!identity) {
      return {
        ...base,
        status: "signed-out",
        message: "Sign in with the Apple Account that owns this journal.",
        records: [],
        issues: [],
        recordCount: 0,
      };
    }

    const fetched = await fetchZoneRecords(container.privateCloudDatabase, config);
    const issues = [...fetched.issues];
    const records: JournalReadRecord[] = [];

    for (const record of fetched.records) {
      if (record.deleted) continue;
      const kind = kindByRecordType.get(record.recordType);
      if (!kind) {
        issues.push({
          recordName: record.recordName,
          recordType: record.recordType,
          message: `Unsupported CloudKit record type ${record.recordType}.`,
        });
        continue;
      }

      try {
        const payload = payloadFromRecord(record, kind);
        const decoded = decodeJournalRecord(payload, kind);
        if (decoded.payload.id !== record.recordName) {
          throw new Error(
            `${kind}.id ${String(decoded.payload.id)} does not match CloudKit record ${record.recordName}.`,
          );
        }
        const journalRecord: JournalReadRecord = {
          kind,
          recordName: record.recordName,
          recordType: record.recordType,
          recordChangeTag: record.recordChangeTag,
          payload: decoded.payload,
        };
        if (matchesQuery(journalRecord, options.query)) records.push(journalRecord);
      } catch (error) {
        issues.push(issueForRecord(record, error));
      }
    }

    const limit = safeQueryLimit(options.query?.limit);
    const visibleRecords = limit === undefined ? records : records.slice(0, limit);
    const status: JournalReadStatus = issues.length > 0
      ? visibleRecords.length > 0 ? "partial" : "error"
      : visibleRecords.length > 0 ? "ready" : "empty";
    const message = issues.length > 0
      ? `${status === "partial" ? "Partial" : "CloudKit"} journal read: ${visibleRecords.length} canonical records; ${issues.map((issue) => issue.message).join(" ")}`
      : `Read ${visibleRecords.length} canonical records from ${config.zoneName}.`;

    return {
      ...base,
      status,
      message,
      records: visibleRecords,
      issues,
      userRecordName: identity.userRecordName,
      syncToken: fetched.syncToken,
      latestChangeTag: fetched.lastChangeTag,
      recordCount: visibleRecords.length,
    };
  } catch (error) {
    return {
      ...base,
      status: "error",
      message: error instanceof Error ? error.message : "CloudKit journal read failed.",
      records: [],
      issues: [{ message: error instanceof Error ? error.message : String(error) }],
      recordCount: 0,
    };
  }
}
