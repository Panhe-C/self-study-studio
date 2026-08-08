import sharedContract from "../../Sources/PersonalLearningJournal/Resources/JournalContract/contract-v1.json" with {
  type: "json",
};

export const JOURNAL_CONTRACT_VERSION = 1 as const;

export type JournalRecordKind =
  | "project"
  | "session"
  | "proof"
  | "review"
  | "evidenceContract"
  | "evidenceAcceptance"
  | "proofRevision"
  | "reviewDecision"
  | "trailEvent"
  | "coursePlan"
  | "planPhase"
  | "plannedSession"
  | "availabilityRule"
  | "schedulingPreferences"
  | "practiceRoutine"
  | "practiceSession";

export type JournalRecordFieldDefinition = {
  type: string;
  required: boolean;
  trim?: boolean;
  nonEmpty?: boolean;
  values?: string[];
  variants?: string[];
  minimum?: number;
  maximum?: number;
  sort?: string;
  objectFields?: Record<string, JournalRecordNestedFieldDefinition>;
  variantFields?: Record<string, Record<string, JournalRecordNestedFieldDefinition>>;
};

export type JournalRecordNestedFieldDefinition = {
  type: string;
  required: boolean;
  trim?: boolean;
  nonEmpty?: boolean;
  values?: string[];
  minimum?: number;
  maximum?: number;
  format?: string;
};

export type JournalRecordDefinition = {
  recordType: string;
  fields: Record<string, JournalRecordFieldDefinition>;
};

export type JournalRecordContractDocument = {
  version: number;
  formats: Record<string, string>;
  records: Record<JournalRecordKind, JournalRecordDefinition>;
};

export type JournalRecordPayload = Record<string, unknown>;

export type DecodedJournalRecord = {
  kind: JournalRecordKind;
  payload: JournalRecordPayload;
};

export class JournalRecordContractError extends Error {
  readonly code:
    | "missingField"
    | "unknownField"
    | "invalidField"
    | "unsupportedKind"
    | "invalidPayload";
  readonly kind?: JournalRecordKind;
  readonly field?: string;

  constructor(
    code: JournalRecordContractError["code"],
    message: string,
    options: { kind?: JournalRecordKind; field?: string } = {},
  ) {
    super(message);
    this.name = "JournalRecordContractError";
    this.code = code;
    this.kind = options.kind;
    this.field = options.field;
  }
}

export const journalRecordContract = sharedContract as JournalRecordContractDocument;

const recordKinds = Object.keys(journalRecordContract.records) as JournalRecordKind[];

export function decodeJournalRecord(
  payload: unknown,
  kind: JournalRecordKind,
  contract: JournalRecordContractDocument = journalRecordContract,
): DecodedJournalRecord {
  const definition = contract.records[kind];
  if (!definition) {
    throw new JournalRecordContractError(
      "unsupportedKind",
      `Unsupported Journal record kind: ${kind}`,
      { kind },
    );
  }
  if (!isObject(payload)) {
    throw new JournalRecordContractError(
      "invalidPayload",
      "Journal record payload must be an object.",
      { kind },
    );
  }

  const keys = new Set(Object.keys(payload));
  for (const [field, fieldDefinition] of Object.entries(definition.fields)) {
    if (fieldDefinition.required && !Object.hasOwn(payload, field)) {
      throw new JournalRecordContractError(
        "missingField",
        `${kind}.${field} is required.`,
        { kind, field },
      );
    }
    if (Object.hasOwn(payload, field)) {
      validateField(payload[field], field, fieldDefinition, kind, contract);
    }
  }
  for (const field of keys) {
    if (!definition.fields[field]) {
      throw new JournalRecordContractError(
        "unknownField",
        `${kind}.${field} is not in the versioned contract.`,
        { kind, field },
      );
    }
  }

  const normalized = normalizePayload(payload, definition.fields);
  validateCrossFieldRules(normalized, kind, contract);
  return { kind, payload: normalized };
}

export function journalRecordKinds(): JournalRecordKind[] {
  return [...recordKinds];
}

function validateField(
  value: unknown,
  field: string,
  definition: JournalRecordFieldDefinition,
  kind: JournalRecordKind,
  contract: JournalRecordContractDocument,
) {
  if (value === null) {
    if (definition.required) invalid(kind, field);
    return;
  }
  validateValue(value, field, definition, kind, contract);
}

function validateValue(
  value: unknown,
  field: string,
  definition: JournalRecordFieldDefinition | JournalRecordNestedFieldDefinition,
  kind: JournalRecordKind,
  contract: JournalRecordContractDocument,
) {
  switch (definition.type) {
    case "uuid":
      if (typeof value !== "string" || !isUUID(value)) invalid(kind, field);
      break;
    case "date":
      if (typeof value !== "string" || !isISO8601(value, contract, definition.format)) {
        invalid(kind, field);
      }
      break;
    case "url":
      if (typeof value !== "string") invalid(kind, field);
      else {
        try {
          const url = new URL(value);
          if (!["http:", "https:"].includes(url.protocol) || !url.hostname) {
            invalid(kind, field);
          }
        } catch {
          invalid(kind, field);
        }
      }
      break;
    case "string":
      if (typeof value !== "string") invalid(kind, field);
      else if (definition.nonEmpty && value.trim().length === 0) invalid(kind, field);
      break;
    case "enum":
      if (typeof value !== "string" || !definition.values?.includes(value)) {
        invalid(kind, field);
      }
      break;
    case "integer":
      if (typeof value !== "number" || !Number.isInteger(value)) invalid(kind, field);
      else if (definition.minimum !== undefined && value < definition.minimum) invalid(kind, field);
      else if (definition.maximum !== undefined && value > definition.maximum) invalid(kind, field);
      break;
    case "boolean":
      if (typeof value !== "boolean") invalid(kind, field);
      break;
    case "stringArray":
      if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
        invalid(kind, field);
      }
      break;
    case "uuidArray":
      if (!Array.isArray(value) || !value.every((item) => typeof item === "string" && isUUID(item))) {
        invalid(kind, field);
      }
      break;
    case "integerArray":
      if (!Array.isArray(value) || !value.every((item) => typeof item === "number" && Number.isInteger(item))) {
        invalid(kind, field);
      }
      break;
    case "object":
      if (!isObject(value) || !definition.objectFields) invalid(kind, field);
      else validateObject(value, field, definition.objectFields, kind, contract);
      break;
    case "taggedUnion":
      if (!isObject(value) || Object.keys(value).length !== 1 ||
          !definition.variants?.includes(Object.keys(value)[0])) {
        invalid(kind, field);
      }
      if (isObject(value)) {
        const tag = Object.keys(value)[0];
        const inner = value[tag];
        const fields = definition.variantFields?.[tag];
        if (!isObject(inner) || !fields) invalid(kind, field);
        else validateObject(inner, `${field}.${tag}`, fields, kind, contract);
      }
      break;
    case "uuidEnumMap":
      validatePairs(value, field, kind, "enum", definition.values);
      break;
    case "uuidStringMap":
      validatePairs(value, field, kind, "string");
      break;
    case "stringArrayMap":
      validatePairs(value, field, kind, "stringArray");
      break;
    case "stringArrayDictionary":
      if (!isObject(value) || !Object.values(value).every((item) => Array.isArray(item) && item.every((entry) => typeof entry === "string"))) {
        invalid(kind, field);
      }
      break;
    default:
      invalid(kind, field);
  }
}

function validateObject(
  value: Record<string, unknown>,
  field: string,
  fields: Record<string, JournalRecordNestedFieldDefinition>,
  kind: JournalRecordKind,
  contract: JournalRecordContractDocument,
) {
  for (const [name, definition] of Object.entries(fields)) {
    if (!Object.hasOwn(value, name)) {
      if (definition.required) invalid(kind, `${field}.${name}`);
      continue;
    }
    const nested = value[name];
    if (nested === null) {
      if (definition.required) invalid(kind, `${field}.${name}`);
      continue;
    }
    validateValue(nested, `${field}.${name}`, definition, kind, contract);
  }
  for (const name of Object.keys(value)) {
    if (!fields[name]) invalid(kind, `${field}.${name}`);
  }
}

function validatePairs(
  value: unknown,
  field: string,
  kind: JournalRecordKind,
  valueType: "enum" | "string" | "stringArray",
  values?: string[],
) {
  if (!Array.isArray(value) || value.length % 2 !== 0) invalid(kind, field);
  const keys = new Set<string>();
  for (let index = 0; index < value.length; index += 2) {
    const key = value[index];
    if (typeof key !== "string" || keys.has(key)) invalid(kind, field);
    keys.add(key);
    if (valueType !== "stringArray" && !isUUID(key)) invalid(kind, field);
    const item = value[index + 1];
    if (valueType === "stringArray") {
      if (!Array.isArray(item) || !item.every((entry) => typeof entry === "string")) invalid(kind, field);
    } else if (typeof item !== "string" || (valueType === "enum" && !values?.includes(item))) {
      invalid(kind, field);
    }
  }
}

function normalizePayload(
  payload: JournalRecordPayload,
  fields: Record<string, JournalRecordFieldDefinition>,
): JournalRecordPayload {
  const normalized: JournalRecordPayload = structuredClone(payload);
  for (const [field, definition] of Object.entries(fields)) {
    const value = normalized[field];
    if (!definition.trim || value === undefined || value === null) continue;
    if (typeof value === "string") normalized[field] = value.trim();
    else if (Array.isArray(value)) {
      normalized[field] = value.map((item) =>
        typeof item === "string" ? item.trim() : item,
      );
      if (definition.sort === "ascending" && normalized[field].every((item) => typeof item === "number")) {
        normalized[field].sort((a, b) => a - b);
      }
    }
    if (definition.type === "object" && isObject(value) && definition.objectFields) {
      normalizeObject(value, definition.objectFields);
    } else if (definition.type === "taggedUnion" && isObject(value) && definition.variantFields) {
      const tag = Object.keys(value)[0];
      const inner = value[tag];
      const innerFields = definition.variantFields[tag];
      if (isObject(inner) && innerFields) normalizeObject(inner, innerFields);
    }
  }
  return normalized;
}

function normalizeObject(
  object: Record<string, unknown>,
  fields: Record<string, JournalRecordNestedFieldDefinition>,
) {
  for (const [field, definition] of Object.entries(fields)) {
    const value = object[field];
    if (!definition.trim || value === undefined || value === null) continue;
    if (typeof value === "string") object[field] = value.trim();
    else if (Array.isArray(value)) object[field] = value.map((item) => typeof item === "string" ? item.trim() : item);
  }
}

function validateCrossFieldRules(
  payload: JournalRecordPayload,
  kind: JournalRecordKind,
  contract: JournalRecordContractDocument,
) {
  const date = (field: string) => {
    const value = payload[field];
    return typeof value === "string" && isISO8601(value, contract) ? Date.parse(value) : Number.NaN;
  };
  const integer = (field: string) =>
    typeof payload[field] === "number" ? payload[field] : Number.NaN;
  const fail = (field: string): never => invalid(kind, field);

  switch (kind) {
    case "session":
      if (!(date("endedAt") >= date("startedAt"))) fail("endedAt");
      break;
    case "review":
      if (!(date("periodEnd") >= date("periodStart"))) fail("periodEnd");
      break;
    case "evidenceContract": {
      const trigger = payload.trigger;
      if (!isObject(trigger) || Object.keys(trigger).length !== 1) fail("trigger");
      if (isObject(trigger) && isObject(trigger.interval)) {
        if (typeof trigger.interval.days !== "number" || trigger.interval.days <= 0) fail("trigger");
      } else if (isObject(trigger) && isObject(trigger.milestone)) {
        if (typeof trigger.milestone._0 !== "string" || trigger.milestone._0.trim() === "") fail("trigger");
      } else {
        fail("trigger");
      }
      break;
    }
    case "coursePlan":
      if (payload.deadline !== undefined && !(date("deadline") >= date("startsOn"))) fail("deadline");
      break;
    case "planPhase":
      if (!(date("targetEnd") >= date("targetStart"))) fail("targetEnd");
      break;
    case "availabilityRule":
      if (!(integer("endMinute") > integer("startMinute"))) fail("endMinute");
      if (integer("endMinute") - integer("startMinute") < integer("minimumSessionMinutes")) fail("endMinute");
      if (payload.validFrom !== undefined && payload.validThrough !== undefined && date("validFrom") > date("validThrough")) {
        fail("validThrough");
      }
      break;
    case "practiceRoutine": {
      const weekdays = payload.weekdays;
      if (!Array.isArray(weekdays) || weekdays.length === 0 || !weekdays.every((day) => typeof day === "number" && day >= 1 && day <= 7)) {
        fail("weekdays");
      }
      if (isObject(payload.reminderTime)) {
        if (typeof payload.reminderTime.hour !== "number" || payload.reminderTime.hour < 0 || payload.reminderTime.hour > 23 ||
            typeof payload.reminderTime.minute !== "number" || payload.reminderTime.minute < 0 || payload.reminderTime.minute > 59) {
          fail("reminderTime");
        }
      }
      break;
    }
    case "practiceSession": {
      if (!(date("endedAt") >= date("startedAt"))) fail("endedAt");
      if (!(integer("activeDurationSeconds") >= 0 && integer("activeDurationSeconds") <= (date("endedAt") - date("startedAt")) / 1000 + 1)) {
        fail("activeDurationSeconds");
      }
      break;
    }
    case "reviewDecision": {
      const decision = payload.kind;
      if (decision === "changeNextStep" && (typeof payload.nextStep !== "string" || payload.nextStep.trim() === "")) fail("nextStep");
      if ((decision === "reviseContract" || decision === "changeFrequency") && payload.contractId === undefined) fail("contractId");
      if (decision === "complete" && payload.capstoneProofId === undefined) fail("capstoneProofId");
      break;
    }
    default:
      break;
  }
}

function invalid(kind: JournalRecordKind, field: string): never {
  throw new JournalRecordContractError(
    "invalidField",
    `${kind}.${field} is invalid.`,
    { kind, field },
  );
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function isISO8601(
  value: string,
  contract: JournalRecordContractDocument,
  format = "iso8601",
): boolean {
  const pattern = contract.formats?.[format];
  if (!pattern) return false;
  const expression = new RegExp(pattern);
  return expression.test(value) && Number.isFinite(Date.parse(value));
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
