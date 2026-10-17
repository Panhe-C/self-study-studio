/** Versioned progress model, intentionally separate from the legacy Journal. */
export const PROGRESS_SCHEMA_VERSION = 1;
export const PROGRESS_LIMITS = {
  projectNameScalars: 120,
  unitTitleScalars: 200,
  units: 300,
  encodedBytes: 256 * 1024,
} as const;

export type LearningUnit = {
  id: string;
  title: string;
  order: number;
  isCompleted: boolean;
  completedAt: string | null;
};

export type ProgressProject = {
  schemaVersion: number;
  id: string;
  name: string;
  isPaused: boolean;
  createdAt: string;
  updatedAt: string;
  units: LearningUnit[];
};

export type ProgressErrorCode =
  | "unsupportedSchema" | "invalidName" | "invalidTitle" | "tooManyUnits"
  | "duplicateUnitID" | "invalidOrder" | "invalidCompletionTime"
  | "invalidTimestamps" | "oversizedProject" | "missingUnit"
  | "invalidReorder" | "pausedProject" | "invalidShape";

export class ProgressError extends Error {
  readonly code: ProgressErrorCode;

  constructor(code: ProgressErrorCode) {
    super(code);
    this.code = code;
    this.name = "ProgressError";
  }
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const utcPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;
const projectKeys = ["schemaVersion", "id", "name", "isPaused", "createdAt", "updatedAt", "units"];
const unitKeys = ["id", "title", "order", "isCompleted", "completedAt"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function hasExactKeys(value: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(value).length === keys.length && keys.every((key) => Object.hasOwn(value, key));
}
function isUTC(value: unknown): value is string {
  if (typeof value !== "string" || !utcPattern.test(value)) return false;
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) return false;
  const [datePart, timePart] = value.split("T");
  const [year, month, day] = datePart.split("-").map(Number);
  const [hour, minute, second] = timePart.slice(0, 8).split(":").map(Number);
  return parsed.getUTCFullYear() === year && parsed.getUTCMonth() + 1 === month
    && parsed.getUTCDate() === day && parsed.getUTCHours() === hour
    && parsed.getUTCMinutes() === minute && parsed.getUTCSeconds() === second;
}
function scalars(value: string): number { return Array.from(value).length; }
function validText(value: unknown, limit: number): value is string {
  return typeof value === "string" && value.length > 0
    && value.trim() === value && scalars(value) <= limit;
}

export function validateProject(value: unknown): asserts value is ProgressProject {
  if (!isRecord(value) || !hasExactKeys(value, projectKeys)
      || typeof value.id !== "string" || !uuidPattern.test(value.id)
      || typeof value.isPaused !== "boolean" || !Array.isArray(value.units)) {
    throw new ProgressError("invalidShape");
  }
  if (value.schemaVersion !== PROGRESS_SCHEMA_VERSION) throw new ProgressError("unsupportedSchema");
  if (!validText(value.name, PROGRESS_LIMITS.projectNameScalars)) throw new ProgressError("invalidName");
  if (!isUTC(value.createdAt) || !isUTC(value.updatedAt)
      || Date.parse(value.updatedAt) < Date.parse(value.createdAt)) {
    throw new ProgressError("invalidTimestamps");
  }
  if (value.units.length > PROGRESS_LIMITS.units) throw new ProgressError("tooManyUnits");
  const ids = new Set<string>();
  for (const [index, unit] of value.units.entries()) {
    if (!isRecord(unit) || !hasExactKeys(unit, unitKeys)
        || typeof unit.id !== "string" || !uuidPattern.test(unit.id)
        || typeof unit.isCompleted !== "boolean") throw new ProgressError("invalidShape");
    if (!validText(unit.title, PROGRESS_LIMITS.unitTitleScalars)) throw new ProgressError("invalidTitle");
    const canonicalID = unit.id.toLowerCase();
    if (ids.has(canonicalID)) throw new ProgressError("duplicateUnitID");
    ids.add(canonicalID);
    if (unit.order !== index) throw new ProgressError("invalidOrder");
    if (unit.completedAt !== null && !isUTC(unit.completedAt)) {
      throw new ProgressError("invalidCompletionTime");
    }
    if (unit.isCompleted !== (unit.completedAt !== null)) {
      throw new ProgressError("invalidCompletionTime");
    }
  }
  if (new TextEncoder().encode(JSON.stringify(value)).length > PROGRESS_LIMITS.encodedBytes) {
    throw new ProgressError("oversizedProject");
  }
}

export function decodeProject(value: unknown): ProgressProject {
  validateProject(value);
  return value;
}
