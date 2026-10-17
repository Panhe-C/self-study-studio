import type { ProgressProject } from "./domain.ts";

export type ProgressProjection = {
  total: number;
  completed: number;
  percentage: number;
  currentUnitID: string | null;
  nextUnitID: string | null;
  isAllCompleted: boolean;
};

export function projectProgress(project: ProgressProject): ProgressProjection {
  const total = project.units.length;
  const completed = project.units.filter((unit) => unit.isCompleted).length;
  const remaining = project.units.filter((unit) => !unit.isCompleted);
  return {
    total,
    completed,
    percentage: total === 0 ? 0 : Math.floor((completed * 100 + total / 2) / total),
    currentUnitID: remaining[0]?.id ?? null,
    nextUnitID: remaining[1]?.id ?? null,
    isAllCompleted: total > 0 && completed === total,
  };
}
