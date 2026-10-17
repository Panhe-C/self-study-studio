import { WorkspaceApp } from "../workspace-app";

export default function LegacyWorkspace() {
  const initialAsOf = new Date().toISOString();
  const initialTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  return <WorkspaceApp initialAsOf={initialAsOf} initialTimeZone={initialTimeZone} />;
}
