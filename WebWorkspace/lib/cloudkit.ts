export const CLOUDKIT_SCRIPT_URL =
  "https://cdn.apple-cloudkit.com/ck/2/CloudKit.js";

export type CloudKitMode =
  | "demo"
  | "blocked"
  | "ready"
  | "checking"
  | "signed-out"
  | "connected"
  | "partial"
  | "error";

export type CloudKitDiagnostic = {
  mode: CloudKitMode;
  message: string;
  userRecordName?: string;
  recordCount?: number;
  recordTypes?: Record<string, number>;
  latestChangeTag?: string;
};

export type CloudKitRecordField = { value?: unknown } | unknown;

export type CloudKitRecord = {
  recordName: string;
  recordType: string;
  recordChangeTag?: string;
  deleted?: boolean;
  fields?: Record<string, CloudKitRecordField>;
};

export type CloudKitModifyRecordsRequest = {
  recordsToSave: CloudKitRecord[];
  recordNamesToDelete?: string[];
};

export type CloudKitModifyRecordsOptions = {
  zoneID: { zoneName: string };
  atomic: boolean;
  savePolicy: "ifServerRecordUnchanged";
};

export type CloudKitRecordError = {
  recordName?: string;
  reason?: string;
  serverRecord?: CloudKitRecord;
  record?: CloudKitRecord;
};

export type CloudKitModifyRecordsResponse = {
  records?: CloudKitRecord[];
  errors?: CloudKitRecordError[];
};

export type CloudKitZoneChange = {
  records?: CloudKitRecord[];
  moreComing?: boolean;
  syncToken?: string;
  errors?: Array<{ reason?: string }>;
};

export type CloudKitDatabase = {
  fetchRecordZoneChanges(
    options: Record<string, unknown>,
  ): Promise<{ zones?: CloudKitZoneChange[] }>;
  modifyRecords?(
    request: CloudKitModifyRecordsRequest,
    options: CloudKitModifyRecordsOptions,
  ): Promise<CloudKitModifyRecordsResponse>;
  fetchRecords?(recordNames: string[]): Promise<{
    records?: CloudKitRecord[];
    errors?: CloudKitRecordError[];
  }>;
};

export type CloudKitContainer = {
  privateCloudDatabase: CloudKitDatabase;
  setUpAuth(): Promise<{ userRecordName?: string } | null>;
};

export type CloudKitNamespace = {
  DEVELOPMENT_ENVIRONMENT: string;
  PRODUCTION_ENVIRONMENT: string;
  configure(config: Record<string, unknown>): void;
  getDefaultContainer(): CloudKitContainer;
};

declare global {
  interface Window {
    CloudKit?: CloudKitNamespace;
  }
}

export type CloudKitConfig = {
  containerIdentifier: string;
  apiToken: string;
  environment: "development" | "production";
  zoneName: string;
};

export const cloudKitConfig: CloudKitConfig = {
  containerIdentifier:
    process.env.NEXT_PUBLIC_CLOUDKIT_CONTAINER_IDENTIFIER ??
    "iCloud.com.local.selfstudystudio",
  apiToken: process.env.NEXT_PUBLIC_CLOUDKIT_API_TOKEN ?? "",
  environment:
    process.env.NEXT_PUBLIC_CLOUDKIT_ENVIRONMENT === "production"
      ? "production"
      : "development",
  zoneName:
    process.env.NEXT_PUBLIC_CLOUDKIT_ZONE_NAME ?? "LearningJournalZone",
};

export function hasCloudKitConfiguration() {
  return cloudKitConfig.apiToken.trim().length > 0;
}

export function cloudKitFieldValue<T>(
  record: CloudKitRecord,
  key: string,
): T | undefined {
  const field = record.fields?.[key];
  if (field && typeof field === "object" && Object.hasOwn(field, "value")) {
    return (field as { value?: unknown }).value as T | undefined;
  }
  return field as T | undefined;
}

export async function waitForCloudKit(): Promise<CloudKitNamespace> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (window.CloudKit) return window.CloudKit;
    await new Promise((resolve) => window.setTimeout(resolve, 100));
  }
  throw new Error("Apple CloudKit JS did not load.");
}

export function configureCloudKit(
  cloudKit: CloudKitNamespace,
  config: CloudKitConfig = cloudKitConfig,
) {
  const environment =
    config.environment === "production"
      ? cloudKit.PRODUCTION_ENVIRONMENT
      : cloudKit.DEVELOPMENT_ENVIRONMENT;

  cloudKit.configure({
    containers: [
      {
        containerIdentifier: config.containerIdentifier,
        apiTokenAuth: {
          apiToken: config.apiToken,
          persist: true,
        },
        environment,
      },
    ],
  });
}

export async function inspectCloudKitJournal(): Promise<CloudKitDiagnostic> {
  if (!hasCloudKitConfiguration()) {
    return {
      mode: "demo",
      message: "Add a CloudKit Web API token to test the private journal.",
    };
  }

  try {
    const cloudKit = await waitForCloudKit();
    configureCloudKit(cloudKit);
    const container = cloudKit.getDefaultContainer();
    const identity = await container.setUpAuth();

    if (!identity) {
      return {
        mode: "signed-out",
        message: "Sign in with the Apple Account that owns this journal.",
      };
    }

    const records: CloudKitRecord[] = [];
    const readIssues: string[] = [];
    const seenSyncTokens = new Set<string>();
    let syncToken: string | undefined;

    while (true) {
      const response =
        await container.privateCloudDatabase.fetchRecordZoneChanges({
          zoneID: { zoneName: cloudKitConfig.zoneName },
          ...(syncToken ? { syncToken } : {}),
        });
      const zone = response.zones?.[0];

      if (!zone) {
        readIssues.push(
          `CloudKit returned no result for ${cloudKitConfig.zoneName}.`,
        );
        break;
      }

      records.push(...(zone.records ?? []));
      readIssues.push(
        ...(zone.errors ?? []).map(
          (error) =>
            error.reason ?? "CloudKit reported an unspecified zone error.",
        ),
      );

      if (!zone.moreComing) break;

      const nextSyncToken = zone.syncToken?.trim();
      if (!nextSyncToken) {
        readIssues.push(
          "CloudKit reported more changes but did not return a sync token.",
        );
        break;
      }
      if (seenSyncTokens.has(nextSyncToken)) {
        readIssues.push(
          "CloudKit repeated a sync token before the zone read completed.",
        );
        break;
      }

      seenSyncTokens.add(nextSyncToken);
      syncToken = nextSyncToken;
    }

    const recordsByName = new Map(
      records.map((record) => [record.recordName, record]),
    );
    const activeRecords = [...recordsByName.values()].filter(
      (record) => !record.deleted,
    );
    const recordTypes = activeRecords.reduce<Record<string, number>>(
      (counts, record) => {
        counts[record.recordType] = (counts[record.recordType] ?? 0) + 1;
        return counts;
      },
      {},
    );
    const latestChangeTag = activeRecords.find((record) => record.recordChangeTag)
      ?.recordChangeTag;

    if (readIssues.length > 0) {
      const mode = activeRecords.length > 0 ? "partial" : "error";
      return {
        mode,
        message:
          mode === "partial"
            ? `Partial read: read ${activeRecords.length} records from ${cloudKitConfig.zoneName}, but ${readIssues.join(" ")}`
            : `CloudKit validation failed for ${cloudKitConfig.zoneName}: ${readIssues.join(" ")}`,
        userRecordName: identity.userRecordName,
        recordCount: activeRecords.length,
        recordTypes,
        latestChangeTag,
      };
    }

    return {
      mode: "connected",
      message: `Read ${activeRecords.length} records from ${cloudKitConfig.zoneName}.`,
      userRecordName: identity.userRecordName,
      recordCount: activeRecords.length,
      recordTypes,
      latestChangeTag,
    };
  } catch (error) {
    return {
      mode: "error",
      message:
        error instanceof Error ? error.message : "CloudKit validation failed.",
    };
  }
}
