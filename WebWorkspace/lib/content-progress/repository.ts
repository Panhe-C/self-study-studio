import { decodeProject, validateProject, type ProgressProject } from "./domain.ts";

export type DraftUnit = { id: string; title: string };
export type ProgressDraft = {
  id: string;
  name: string;
  outlineText: string;
  courseURL: string | null;
  units: DraftUnit[];
  createdAt: string;
  updatedAt: string;
};

export function confirmedProject(draft: ProgressDraft, now = new Date()): ProgressProject {
  const project: ProgressProject = {
    schemaVersion: 1,
    id: draft.id,
    name: draft.name.trim(),
    isPaused: false,
    createdAt: draft.createdAt,
    updatedAt: new Date(Math.max(now.getTime(), Date.parse(draft.createdAt))).toISOString(),
    units: draft.units.map((unit, order) => ({
      id: unit.id, title: unit.title.trim(), order, isCompleted: false, completedAt: null,
    })),
  };
  validateProject(project);
  return project;
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
  });
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error ?? new Error("IndexedDB transaction aborted"));
    transaction.onerror = () => reject(transaction.error ?? new Error("IndexedDB transaction failed"));
  });
}

export class BrowserProgressRepository {
  private readonly database: IDBDatabase;

  private constructor(database: IDBDatabase) {
    this.database = database;
  }

  static async open(scope: "local" | "demo" = "local"): Promise<BrowserProgressRepository> {
    if (typeof indexedDB === "undefined") throw new Error("Browser storage is unavailable");
    const name = `self-study-content-progress-${scope}-v1`;
    const database = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open(name, 1);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains("projects")) db.createObjectStore("projects", { keyPath: "id" });
        if (!db.objectStoreNames.contains("drafts")) db.createObjectStore("drafts", { keyPath: "id" });
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error ?? new Error("Cannot open progress storage"));
      request.onblocked = () => reject(new Error("Close other tabs to upgrade progress storage"));
    });
    return new BrowserProgressRepository(database);
  }

  close(): void { this.database.close(); }

  async projects(): Promise<ProgressProject[]> {
    const transaction = this.database.transaction("projects", "readonly");
    const done = transactionDone(transaction);
    const records = await requestResult<unknown[]>(transaction.objectStore("projects").getAll());
    await done;
    return records.map(decodeProject).sort((left, right) => left.createdAt.localeCompare(right.createdAt));
  }

  async project(id: string): Promise<ProgressProject | null> {
    const transaction = this.database.transaction("projects", "readonly");
    const done = transactionDone(transaction);
    const record = await requestResult<unknown>(transaction.objectStore("projects").get(id));
    await done;
    return record === undefined ? null : decodeProject(record);
  }

  async saveProject(project: ProgressProject): Promise<void> {
    validateProject(project);
    const transaction = this.database.transaction("projects", "readwrite");
    const done = transactionDone(transaction);
    transaction.objectStore("projects").put(project);
    await done;
  }

  async drafts(): Promise<ProgressDraft[]> {
    const transaction = this.database.transaction("drafts", "readonly");
    const done = transactionDone(transaction);
    const records = await requestResult<ProgressDraft[]>(transaction.objectStore("drafts").getAll());
    await done;
    return records.sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  }

  async draft(id: string): Promise<ProgressDraft | null> {
    const transaction = this.database.transaction("drafts", "readonly");
    const done = transactionDone(transaction);
    const record = await requestResult<ProgressDraft | undefined>(transaction.objectStore("drafts").get(id));
    await done;
    return record ?? null;
  }

  async saveDraft(draft: ProgressDraft): Promise<void> {
    const transaction = this.database.transaction("drafts", "readwrite");
    const done = transactionDone(transaction);
    transaction.objectStore("drafts").put(draft);
    await done;
  }

  async removeDraft(id: string): Promise<void> {
    const transaction = this.database.transaction("drafts", "readwrite");
    const done = transactionDone(transaction);
    transaction.objectStore("drafts").delete(id);
    await done;
  }

  async confirmDraft(id: string, now = new Date()): Promise<ProgressProject> {
    const transaction = this.database.transaction(["projects", "drafts"], "readwrite");
    const done = transactionDone(transaction);
    const projects = transaction.objectStore("projects");
    const drafts = transaction.objectStore("drafts");
    try {
      const existing = await requestResult<unknown>(projects.get(id));
      if (existing !== undefined) {
        const project = decodeProject(existing);
        drafts.delete(id);
        await done;
        return project;
      }
      const draft = await requestResult<ProgressDraft | undefined>(drafts.get(id));
      if (!draft) throw new Error("Draft was not found");
      const project = confirmedProject(draft, now);
      projects.put(project);
      drafts.delete(id);
      await done;
      return project;
    } catch (error) {
      try { transaction.abort(); } catch { /* Already committed or aborted. */ }
      void done.catch(() => undefined);
      throw error;
    }
  }
}
