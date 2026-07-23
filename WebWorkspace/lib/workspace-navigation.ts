import type { ProjectTab, WorkspaceSection } from "./journal";

export type WorkspaceNavigationState = {
  section: WorkspaceSection;
  projectId: string;
  tab: ProjectTab;
};

export function projectNavigationState(
  projectId: string,
  tab: ProjectTab,
): WorkspaceNavigationState {
  return {
    section: "project",
    projectId,
    tab,
  };
}
