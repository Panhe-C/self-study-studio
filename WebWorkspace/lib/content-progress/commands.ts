import { ProgressError, validateProject, type LearningUnit, type ProgressProject } from "./domain.ts";

export function createProject(
  name: string,
  titles: string[],
  now: Date = new Date(),
  makeID: () => string = () => crypto.randomUUID(),
): ProgressProject {
  const units: LearningUnit[] = titles.map((title, order) => ({
    id: makeID(), title: title.trim(), order, isCompleted: false, completedAt: null,
  }));
  const project: ProgressProject = {
    schemaVersion: 1, id: makeID(), name: name.trim(), isPaused: false,
    createdAt: now.toISOString(), updatedAt: now.toISOString(), units,
  };
  validateProject(project);
  return project;
}

function changed(project: ProgressProject, units: LearningUnit[], now: Date): ProgressProject {
  const updated = { ...project, units, updatedAt: new Date(Math.max(now.getTime(), Date.parse(project.updatedAt))).toISOString() };
  validateProject(updated);
  return updated;
}

export function setCompleted(project: ProgressProject, unitID: string, completed: boolean, now = new Date()): ProgressProject {
  if (project.isPaused) throw new ProgressError("pausedProject");
  const unit = project.units.find((candidate) => candidate.id === unitID);
  if (!unit) throw new ProgressError("missingUnit");
  if (unit.isCompleted === completed) return project;
  return changed(project, project.units.map((item) => item.id === unitID
    ? { ...item, isCompleted: completed, completedAt: completed ? now.toISOString() : null }
    : item), now);
}

export function addUnit(project: ProgressProject, title: string, id = crypto.randomUUID(), now = new Date()): ProgressProject {
  return changed(project, [...project.units, {
    id, title: title.trim(), order: project.units.length, isCompleted: false, completedAt: null,
  }], now);
}

export function renameUnit(project: ProgressProject, unitID: string, title: string, now = new Date()): ProgressProject {
  const unit = project.units.find((candidate) => candidate.id === unitID);
  if (!unit) throw new ProgressError("missingUnit");
  const normalized = title.trim();
  if (unit.title === normalized) return project;
  return changed(project, project.units.map((item) => item.id === unitID ? { ...item, title: normalized } : item), now);
}

export function deleteUnit(project: ProgressProject, unitID: string, now = new Date()): ProgressProject {
  if (!project.units.some((unit) => unit.id === unitID)) throw new ProgressError("missingUnit");
  return changed(project, project.units.filter((unit) => unit.id !== unitID)
    .map((unit, order) => ({ ...unit, order })), now);
}

export function reorder(project: ProgressProject, ids: string[], now = new Date()): ProgressProject {
  const existing = new Map(project.units.map((unit) => [unit.id, unit]));
  if (ids.length !== existing.size || new Set(ids).size !== ids.length || ids.some((id) => !existing.has(id))) {
    throw new ProgressError("invalidReorder");
  }
  if (ids.every((id, index) => project.units[index].id === id)) return project;
  return changed(project, ids.map((id, order) => ({ ...existing.get(id)!, order })), now);
}

export function setPaused(project: ProgressProject, paused: boolean, now = new Date()): ProgressProject {
  if (project.isPaused === paused) return project;
  const updated = {
    ...project, isPaused: paused,
    updatedAt: new Date(Math.max(now.getTime(), Date.parse(project.updatedAt))).toISOString(),
  };
  validateProject(updated);
  return updated;
}
