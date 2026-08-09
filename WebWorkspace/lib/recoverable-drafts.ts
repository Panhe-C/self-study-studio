import type { JournalRecordPayload } from "./journal-contract.ts";

export const RECOVERABLE_DRAFT_SCHEMA_VERSION = 1 as const;
export const RECOVERABLE_DRAFT_TTL_MS = 30 * 24 * 60 * 60 * 1000;

export type RecoverableDraftKind =
  | "learningPlan"
  | "practiceRoutine"
  | "stageReview";

export type RecoverableDraftStatus = "draft" | "pending" | "conflict";

export type RecoverableDraft = {
  id: string;
  schemaVersion: typeof RECOVERABLE_DRAFT_SCHEMA_VERSION;
  kind: RecoverableDraftKind;
  projectId: string;
  payload: JournalRecordPayload;
  baseRevisionID?: string;
  baseRecordChangeTag?: string;
  targetRevisionID?: string;
  targetRecordChangeTag?: string;
  status: RecoverableDraftStatus;
  createdAt: string;
  updatedAt: string;
  expiresAt: string;
};

export type RecoverableDraftStore = {
  list(): Promise<RecoverableDraft[]>;
  get(id: string): Promise<RecoverableDraft | undefined>;
  save(draft: RecoverableDraft): Promise<void>;
  remove(id: string): Promise<void>;
  clearAfterCloudCompletion(
    id: string,
    result: { status: string; semanticCommit?: boolean },
  ): Promise<void>;
};

function nowISO() {
  return new Date().toISOString();
}

function makeID() {
  if (typeof globalThis.crypto?.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `draft-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function normalizeDraft(value: unknown): RecoverableDraft | undefined {
  if (!value || typeof value !== "object") return undefined;
  const candidate = value as Partial<RecoverableDraft>;
  if (typeof candidate.id !== "string" || typeof candidate.projectId !== "string") return undefined;
  if (!candidate.payload || typeof candidate.payload !== "object" || Array.isArray(candidate.payload)) return undefined;
  if (!candidate.kind || !["learningPlan", "practiceRoutine", "stageReview"].includes(candidate.kind)) return undefined;
  const createdAt = typeof candidate.createdAt === "string" ? candidate.createdAt : nowISO();
  const updatedAt = typeof candidate.updatedAt === "string" ? candidate.updatedAt : createdAt;
  const expiresAt = typeof candidate.expiresAt === "string"
    ? candidate.expiresAt
    : new Date(Date.parse(updatedAt) + RECOVERABLE_DRAFT_TTL_MS).toISOString();
  return {
    id: candidate.id,
    schemaVersion: RECOVERABLE_DRAFT_SCHEMA_VERSION,
    kind: candidate.kind,
    projectId: candidate.projectId,
    payload: structuredClone(candidate.payload),
    ...(typeof candidate.baseRevisionID === "string" ? { baseRevisionID: candidate.baseRevisionID } : {}),
    ...(typeof candidate.baseRecordChangeTag === "string" ? { baseRecordChangeTag: candidate.baseRecordChangeTag } : {}),
    ...(typeof candidate.targetRevisionID === "string" ? { targetRevisionID: candidate.targetRevisionID } : {}),
    ...(typeof candidate.targetRecordChangeTag === "string" ? { targetRecordChangeTag: candidate.targetRecordChangeTag } : {}),
    status: candidate.status === "pending" || candidate.status === "conflict" ? candidate.status : "draft",
    createdAt,
    updatedAt,
    expiresAt,
  };
}

export function migrateRecoverableDraft(value: unknown): RecoverableDraft | undefined {
  return normalizeDraft(value);
}

export function createRecoverableDraft(input: {
  id?: string;
  kind: RecoverableDraftKind;
  projectId: string;
  payload: JournalRecordPayload;
  baseRevisionID?: string;
  baseRecordChangeTag?: string;
  targetRevisionID?: string;
  targetRecordChangeTag?: string;
  status?: RecoverableDraftStatus;
  createdAt?: string;
  updatedAt?: string;
  expiresAt?: string;
}): RecoverableDraft {
  const createdAt = input.createdAt ?? nowISO();
  const updatedAt = input.updatedAt ?? createdAt;
  return {
    id: input.id ?? makeID(),
    schemaVersion: RECOVERABLE_DRAFT_SCHEMA_VERSION,
    kind: input.kind,
    projectId: input.projectId,
    payload: structuredClone(input.payload),
    ...(input.baseRevisionID ? { baseRevisionID: input.baseRevisionID } : {}),
    ...(input.baseRecordChangeTag ? { baseRecordChangeTag: input.baseRecordChangeTag } : {}),
    ...(input.targetRevisionID ? { targetRevisionID: input.targetRevisionID } : {}),
    ...(input.targetRecordChangeTag ? { targetRecordChangeTag: input.targetRecordChangeTag } : {}),
    status: input.status ?? "draft",
    createdAt,
    updatedAt,
    expiresAt: input.expiresAt ?? new Date(Date.parse(updatedAt) + RECOVERABLE_DRAFT_TTL_MS).toISOString(),
  };
}

export class MemoryRecoverableDraftStore implements RecoverableDraftStore {
  private readonly backing: Map<string, RecoverableDraft>;

  constructor(backing = new Map<string, RecoverableDraft>()) {
    this.backing = backing;
  }

  async list() {
    return [...this.backing.values()]
      .map(normalizeDraft)
      .filter((draft): draft is RecoverableDraft => Boolean(draft))
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  }

  async get(id: string) {
    const draft = normalizeDraft(this.backing.get(id));
    return draft ? structuredClone(draft) : undefined;
  }

  async save(draft: RecoverableDraft) {
    const normalized = normalizeDraft(draft);
    if (!normalized) throw new Error("Invalid recoverable draft.");
    this.backing.set(normalized.id, normalized);
  }

  async remove(id: string) {
    this.backing.delete(id);
  }

  async clearAfterCloudCompletion(id: string, result: { status: string; semanticCommit?: boolean }) {
    if (result.status === "committed" || result.semanticCommit === true) await this.remove(id);
  }
}

type IndexedDBDraftStoreOptions = {
  databaseName?: string;
  storeName?: string;
  storage?: Storage;
};

/**
 * Browser persistence for unfinished Web work. IndexedDB is preferred; the
 * localStorage fallback keeps a draft recoverable on browsers without IDB,
 * but stores only unpublished payloads and never canonical Journal records.
 */
export class BrowserRecoverableDraftStore implements RecoverableDraftStore {
  private readonly databaseName: string;
  private readonly storeName: string;
  private readonly storage?: Storage;
  private dbPromise?: Promise<IDBDatabase>;

  constructor(options: IndexedDBDraftStoreOptions = {}) {
    this.databaseName = options.databaseName ?? "self-study-studio-drafts";
    this.storeName = options.storeName ?? "recoverable-drafts-v1";
    this.storage = options.storage ?? (typeof globalThis.localStorage !== "undefined" ? globalThis.localStorage : undefined);
  }

  private openDB() {
    if (this.dbPromise) return this.dbPromise;
    if (typeof globalThis.indexedDB === "undefined") return undefined;
    this.dbPromise = new Promise<IDBDatabase>((resolve, reject) => {
      const request = globalThis.indexedDB.open(this.databaseName, 1);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(this.storeName)) db.createObjectStore(this.storeName, { keyPath: "id" });
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error ?? new Error("Unable to open draft storage."));
    });
    return this.dbPromise;
  }

  private storageKey(id: string) {
    return `${this.storeName}:${id}`;
  }

  private async readLocalStorage() {
    if (!this.storage) return [];
    const drafts: RecoverableDraft[] = [];
    for (let index = 0; index < this.storage.length; index += 1) {
      const key = this.storage.key(index);
      if (!key?.startsWith(`${this.storeName}:`)) continue;
      const raw = this.storage.getItem(key);
      if (!raw) continue;
      try {
        const draft = normalizeDraft(JSON.parse(raw));
        if (draft) drafts.push(draft);
      } catch {
        // Corrupt drafts are ignored; they cannot become canonical records.
      }
    }
    return drafts;
  }

  async list() {
    const db = this.openDB();
    if (!db) return (await this.readLocalStorage()).sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
    const database = await db;
    const raw = await new Promise<unknown[]>((resolve, reject) => {
      const request = database.transaction(this.storeName, "readonly").objectStore(this.storeName).getAll();
      request.onsuccess = () => resolve(request.result as unknown[]);
      request.onerror = () => reject(request.error ?? new Error("Unable to list drafts."));
    });
    return raw
      .map(normalizeDraft)
      .filter((draft): draft is RecoverableDraft => Boolean(draft))
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  }

  async get(id: string) {
    const db = this.openDB();
    if (!db) {
      const raw = this.storage?.getItem(this.storageKey(id));
      if (!raw) return undefined;
      try { return normalizeDraft(JSON.parse(raw)); } catch { return undefined; }
    }
    return db.then((database) => new Promise<RecoverableDraft | undefined>((resolve, reject) => {
      const request = database.transaction(this.storeName, "readonly").objectStore(this.storeName).get(id);
      request.onsuccess = () => resolve(normalizeDraft(request.result));
      request.onerror = () => reject(request.error ?? new Error("Unable to read draft."));
    }));
  }

  async save(draft: RecoverableDraft) {
    const normalized = normalizeDraft(draft);
    if (!normalized) throw new Error("Invalid recoverable draft.");
    const db = this.openDB();
    if (!db) {
      this.storage?.setItem(this.storageKey(normalized.id), JSON.stringify(normalized));
      return;
    }
    const database = await db;
    await new Promise<void>((resolve, reject) => {
      const request = database.transaction(this.storeName, "readwrite").objectStore(this.storeName).put(normalized);
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error ?? new Error("Unable to save draft."));
    });
  }

  async remove(id: string) {
    const db = this.openDB();
    if (!db) {
      this.storage?.removeItem(this.storageKey(id));
      return;
    }
    const database = await db;
    await new Promise<void>((resolve, reject) => {
      const request = database.transaction(this.storeName, "readwrite").objectStore(this.storeName).delete(id);
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error ?? new Error("Unable to remove draft."));
    });
  }

  async clearAfterCloudCompletion(id: string, result: { status: string; semanticCommit?: boolean }) {
    if (result.status === "committed" || result.semanticCommit === true) await this.remove(id);
  }
}
