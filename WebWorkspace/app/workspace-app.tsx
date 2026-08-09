"use client";

import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import {
  cloudKitConfig,
  configureCloudKit,
  hasCloudKitConfiguration,
  inspectCloudKitJournal,
  waitForCloudKit,
  type CloudKitDiagnostic,
} from "../lib/cloudkit";
import {
  readCloudKitJournal,
  type JournalReadRecord,
  type JournalReadResult,
} from "../lib/journal-reader";
import {
  projectJournalRecords,
  type JournalProjection,
} from "../lib/journal-projector";
import { createDashboardSnapshot, type DashboardSnapshot } from "../lib/dashboard";
import {
  projectDemos,
  projects,
  type ProjectDemo,
  type ProjectTab,
  type WorkspaceSection,
} from "../lib/journal";
import {
  projectNavigationState,
  type WorkspaceNavigationState,
} from "../lib/workspace-navigation";
import { PortfolioDashboard } from "./portfolio-dashboard";
import {
  createWebJournalWriter,
  type CanonicalWriteRecord,
  type WebWriteResult,
} from "../lib/journal-writer";
import {
  BrowserRecoverableDraftStore,
  createRecoverableDraft,
  type RecoverableDraft,
  type RecoverableDraftStore,
} from "../lib/recoverable-drafts";
import {
  resolveSyncConflict,
  type SyncConflictResolution,
  type WebSyncConflict,
} from "../lib/sync-conflicts";

const navigation: Array<{ id: WorkspaceSection; label: string; glyph: string }> = [
  { id: "dashboard", label: "Dashboard", glyph: "⌂" },
  { id: "projects", label: "Projects", glyph: "□" },
  { id: "reviews", label: "Reviews", glyph: "◇" },
  { id: "sync", label: "Sync & conflicts", glyph: "↻" },
];

const projectTabs: Array<{ id: ProjectTab; label: string }> = [
  { id: "overview", label: "Overview" },
  { id: "plan", label: "Plan" },
  { id: "practice", label: "Practice" },
  { id: "proof", label: "Proof" },
  { id: "trail", label: "Learning trail" },
  { id: "reviews", label: "Reviews" },
];

const initialDiagnostic: CloudKitDiagnostic = hasCloudKitConfiguration()
  ? { mode: "ready", message: "CloudKit configuration found. Run the check." }
  : {
      mode: "demo",
      message: "Demo data is active until a CloudKit Web API token is configured.",
    };

const workspaceSections: WorkspaceSection[] = [
  "dashboard",
  "projects",
  "project",
  "reviews",
  "sync",
];
const projectTabIds: ProjectTab[] = [
  "overview",
  "plan",
  "practice",
  "proof",
  "trail",
  "reviews",
];

function parseUrlState(search: string, availableProjectIds = projects.map((project) => project.id)): {
  section: WorkspaceSection;
  projectId: string;
  tab: ProjectTab;
} {
  const fallback = {
    section: "dashboard" as WorkspaceSection,
    projectId: availableProjectIds[0] ?? projects[0]?.id ?? "",
    tab: "overview" as ProjectTab,
  };
  const params = new URLSearchParams(search);
  const section = params.get("section") as WorkspaceSection | null;
  const projectId = params.get("project");
  const tab = params.get("tab") as ProjectTab | null;
  return {
    section:
      section && workspaceSections.includes(section) ? section : fallback.section,
    projectId:
      projectId && availableProjectIds.includes(projectId)
        ? projectId
        : fallback.projectId,
    tab: tab && projectTabIds.includes(tab) ? tab : fallback.tab,
  };
}

function diagnosticFromJournalRead(result: JournalReadResult): CloudKitDiagnostic {
  switch (result.status) {
    case "blocked":
      return { mode: "blocked", message: result.message };
    case "signed-out":
      return { mode: "signed-out", message: result.message };
    case "ready":
    case "empty":
      return {
        mode: "connected",
        message: result.message,
        userRecordName: result.userRecordName,
        recordCount: result.recordCount,
        latestChangeTag: result.latestChangeTag,
      };
    case "partial":
      return {
        mode: "partial",
        message: result.message,
        userRecordName: result.userRecordName,
        recordCount: result.recordCount,
        latestChangeTag: result.latestChangeTag,
      };
    case "error":
    default:
      return { mode: "error", message: result.message };
  }
}

function subscribeToUrl(callback: () => void) {
  window.addEventListener("popstate", callback);
  return () => window.removeEventListener("popstate", callback);
}

function formatMinutes(minutes: number) {
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  if (!hours) return `${remainder}m`;
  return remainder ? `${hours}h ${remainder}m` : `${hours}h`;
}

type WebJournalWriter = ReturnType<typeof createWebJournalWriter>;

function newRecordID() {
  if (typeof globalThis.crypto?.randomUUID === "function") return globalThis.crypto.randomUUID();
  return "00000000-0000-4000-8000-000000000001";
}

function canonicalRecord(record: JournalReadRecord): CanonicalWriteRecord {
  return {
    kind: record.kind,
    recordName: record.recordName,
    recordType: record.recordType,
    ...(record.recordChangeTag ? { recordChangeTag: record.recordChangeTag } : {}),
    payload: structuredClone(record.payload),
  };
}

function asWriteResultMessage(result: WebWriteResult) {
  switch (result.status) {
    case "committed":
      return "CloudKit committed the canonical change.";
    case "conflict":
      return "CloudKit rejected the stale revision. Choose an explicit conflict action.";
    case "signed-out":
      return result.message;
    case "blocked":
    case "cancelled":
    case "partial":
    case "error":
      return result.message;
  }
}

export function WorkspaceApp({
  initialAsOf,
  initialTimeZone,
}: {
  initialAsOf: string;
  initialTimeZone: string;
}) {
  // URL search is an external store: SSR renders the fallback (dashboard),
  // hydration matches it, and React re-reads the real search right after.
  const search = useSyncExternalStore(
    subscribeToUrl,
    () => window.location.search,
    () => "",
  );
  const [dataMode, setDataMode] = useState<"demo" | "real">("demo");
  const [realProjection, setRealProjection] = useState<JournalProjection | null>(null);
  const [realRead, setRealRead] = useState<JournalReadResult | null>(null);
  const [realWriter, setRealWriter] = useState<WebJournalWriter | null>(null);
  const [conflicts, setConflicts] = useState<WebSyncConflict[]>([]);
  const [writeMessage, setWriteMessage] = useState<string | null>(null);
  const [draftStore] = useState<RecoverableDraftStore>(() => new BrowserRecoverableDraftStore());
  const [drafts, setDrafts] = useState<RecoverableDraft[]>([]);
  const [realDashboardSnapshot, setRealDashboardSnapshot] =
    useState<DashboardSnapshot>(() =>
      createDashboardSnapshot({ asOf: initialAsOf, state: "loading" }),
    );
  const availableDemos = useMemo(
    () => (dataMode === "real" ? realProjection?.demos ?? [] : projectDemos),
    [dataMode, realProjection],
  );
  const urlState = parseUrlState(search, availableDemos.map((demo) => demo.project.id));
  const [localState, setLocalState] =
    useState<WorkspaceNavigationState | null>(null);

  const section = localState?.section ?? urlState.section;
  const requestedProjectId = localState?.projectId ?? urlState.projectId;
  const selectedDemo = useMemo(
    () => availableDemos.find((demo) => demo.project.id === requestedProjectId) ?? availableDemos[0],
    [availableDemos, requestedProjectId],
  );
  const selectedProjectId = selectedDemo?.project.id ?? requestedProjectId;
  const projectTab = localState?.tab ?? urlState.tab;
  const setSection = (next: WorkspaceSection) =>
    setLocalState({ section: next, projectId: selectedProjectId, tab: projectTab });
  const setProjectTab = (next: ProjectTab) =>
    setLocalState({ section, projectId: selectedProjectId, tab: next });

  const [diagnostic, setDiagnostic] =
    useState<CloudKitDiagnostic>(initialDiagnostic);
  const [isCheckingCloud, setIsCheckingCloud] = useState(false);
  const [showDraft, setShowDraft] = useState(false);

  useEffect(() => {
    void draftStore.list().then(setDrafts).catch(() => setDrafts([]));
  }, [draftStore]);

  useEffect(() => {
    if (!localState) return;
    const params = new URLSearchParams();
    if (localState.section !== "dashboard") params.set("section", localState.section);
    if (localState.section === "project") {
      params.set("project", localState.projectId);
      if (localState.tab !== "overview") params.set("tab", localState.tab);
    }
    const query = params.toString();
    window.history.replaceState(
      null,
      "",
      query ? `?${query}` : window.location.pathname,
    );
  }, [localState]);

  function openProject(projectId: string, tab: ProjectTab = "overview") {
    setLocalState(projectNavigationState(projectId, tab));
  }

  async function loadRealJournal() {
    setIsCheckingCloud(true);
    setDiagnostic({ mode: "checking", message: "Checking the private journal…" });
    setRealDashboardSnapshot(
      createDashboardSnapshot({ asOf: initialAsOf, state: "loading" }),
    );
    try {
      const result = await readCloudKitJournal();
      setRealRead(result);
      setDiagnostic(diagnosticFromJournalRead(result));
      if (["ready", "empty", "partial"].includes(result.status)) {
        try {
          const cloudKit = await waitForCloudKit();
          configureCloudKit(cloudKit);
          setRealWriter(createWebJournalWriter({
            mode: "real",
            config: cloudKitConfig,
            container: cloudKit.getDefaultContainer(),
            draftStore,
          }));
        } catch {
          setRealWriter(null);
        }
        const projection = projectJournalRecords(result.records, { asOf: initialAsOf });
        setRealProjection(projection);
        setRealDashboardSnapshot(
          createDashboardSnapshot({
            asOf: initialAsOf,
            demos: projection.demos,
            unavailableSections: projection.unavailableSections,
          }),
        );
      } else {
        setRealWriter(null);
        setRealProjection(null);
        setRealDashboardSnapshot(
          createDashboardSnapshot({ asOf: initialAsOf, state: "error", message: result.message }),
        );
      }
    } finally {
      setIsCheckingCloud(false);
    }
  }

  function switchDataMode(nextMode: "demo" | "real") {
    setDataMode(nextMode);
    setShowDraft(false);
    if (nextMode === "demo") {
      setRealRead(null);
      setRealProjection(null);
      setRealWriter(null);
      setConflicts([]);
      setWriteMessage(null);
      setDiagnostic(initialDiagnostic);
      return;
    }
    void loadRealJournal();
  }

  async function runCloudKitCheck() {
    if (dataMode === "real") {
      await loadRealJournal();
      return;
    }
    setIsCheckingCloud(true);
    setDiagnostic({ mode: "checking", message: "Checking the private journal…" });
    try {
      setDiagnostic(await inspectCloudKitJournal());
    } finally {
      setIsCheckingCloud(false);
    }
  }

  async function refreshDrafts() {
    try {
      setDrafts(await draftStore.list());
    } catch {
      setDrafts([]);
    }
  }

  async function handleWriteResult(result: WebWriteResult) {
    setWriteMessage(asWriteResultMessage(result));
    if (result.status === "conflict") {
      setConflicts((current) => [result.conflict, ...current.filter((item) => item.id !== result.conflict.id)]);
      setSection("sync");
    }
    await refreshDrafts();
    if (result.status === "committed" && dataMode === "real") await loadRealJournal();
  }

  async function updateNextStep(projectId: string, nextStep: string) {
    const value = nextStep.trim();
    if (!value) return;
    if (dataMode !== "real" || !realWriter || !realRead) {
      setWriteMessage("Demo data is noncanonical; switch to Real journal to write a guarded Next Step.");
      return;
    }
    const source = realRead.records.find((record) => record.kind === "project" && record.recordName === projectId);
    if (!source || !source.recordChangeTag) {
      setWriteMessage("This Project has no CloudKit change tag, so the guarded write is unavailable.");
      return;
    }
    const next = canonicalRecord({
      ...source,
      payload: { ...source.payload, currentNextStep: value, updatedAt: new Date().toISOString() },
    });
    const result = await realWriter.writeBatch({
      operation: "updateNextStep",
      records: [next],
      guardedRecords: [{
        record: next,
        role: "target",
        expectation: {
          baseRevisionID: projectId,
          baseRecordChangeTag: source.recordChangeTag,
          targetRevisionID: projectId,
          targetRecordChangeTag: source.recordChangeTag,
          recordState: "existingRecord",
          targetRecordState: "existingRecord",
        },
      }],
    });
    await handleWriteResult(result);
  }

  function handleConflictResolution(conflict: WebSyncConflict, resolution: SyncConflictResolution) {
    try {
      resolveSyncConflict(conflict, resolution);
      if (resolution === "keepRemote" || resolution === "discardLocal") {
        setConflicts((current) => current.filter((item) => item.id !== conflict.id));
        setWriteMessage(resolution === "keepRemote" ? "Remote value kept; no Trail event was created." : "Local edit discarded; no Trail event was created.");
      } else {
        setWriteMessage(`${resolution === "rebaseLocal" ? "Rebase" : "Fork"} is staged as an explicit decision; publish a new canonical revision from the editor.`);
      }
    } catch (error) {
      setWriteMessage(error instanceof Error ? error.message : String(error));
    }
  }

  const sectionTitle =
    section === "project"
      ? selectedDemo?.project.name ?? (dataMode === "real" ? "Real journal" : "Project")
      : navigation.find((item) => item.id === section)?.label ?? "Dashboard";

  const provenanceLabel = dataMode === "real"
    ? realRead?.status === "blocked"
      ? "Real journal · configuration blocked"
        : realRead?.status === "signed-out"
          ? "Real journal · sign-in required"
        : realWriter
          ? "Real journal · CloudKit private database · guarded writes"
          : "Real journal · CloudKit private database · read-only"
    : "Demo data · deterministic fixture";

  return (
    <div className="workspace-shell">
      <aside className="sidebar">
        <button
          className="brand"
          onClick={() => setSection("dashboard")}
          aria-label="Open dashboard"
        >
          <span className="brand-mark" aria-hidden="true">
            S
          </span>
          <span>
            <strong>Self Study</strong>
            <small>Studio</small>
          </span>
        </button>

        <nav className="primary-nav" aria-label="Workspace navigation">
          {navigation.map((item) => (
            <button
              key={item.id}
              className={section === item.id ? "nav-item active" : "nav-item"}
              onClick={() => setSection(item.id)}
            >
              <span className="nav-glyph" aria-hidden="true">
                {item.glyph}
              </span>
              {item.label}
              {item.id === "reviews" && <span className="nav-count">1</span>}
            </button>
          ))}
        </nav>

        <div className="sidebar-projects">
          <div className="sidebar-label">
            <span>{dataMode === "real" ? "Journal projects" : "Active projects"}</span>
            <button aria-label="Add project">+</button>
          </div>
          {availableDemos.map((demo) => {
            const project = demo.project;
            return (
            <button
              key={project.id}
              className={
                section === "project" && selectedProjectId === project.id
                  ? "project-shortcut selected"
                  : "project-shortcut"
              }
              onClick={() => openProject(project.id)}
            >
              <span
                className="project-dot"
                style={{ backgroundColor: project.accent }}
                aria-hidden="true"
              />
              <span>
                <strong>{project.name}</strong>
                <small>{project.phase}</small>
              </span>
            </button>
            );
          })}
          {dataMode === "real" && availableDemos.length === 0 && (
            <p className="sidebar-empty">No canonical Projects loaded.</p>
          )}
        </div>

        <div className="sidebar-footer">
          <div className="owner-avatar">PH</div>
          <div>
            <strong>Personal workspace</strong>
            <small>One private journal</small>
          </div>
          <button aria-label="Workspace settings">•••</button>
        </div>
      </aside>

      <main className="main-panel">
        <header className="topbar">
          <div>
            <span className="eyebrow">Personal learning journal</span>
            <h1>{sectionTitle}</h1>
          </div>
          <div className="topbar-actions">
            <div className="mode-switch" role="group" aria-label="Workspace data mode">
              <button
                className={dataMode === "demo" ? "active" : ""}
                aria-pressed={dataMode === "demo"}
                onClick={() => switchDataMode("demo")}
              >
                Demo
              </button>
              <button
                className={dataMode === "real" ? "active" : ""}
                aria-pressed={dataMode === "real"}
                onClick={() => switchDataMode("real")}
              >
                Real journal
              </button>
            </div>
            <button className="search-button" aria-label="Search">
              <span aria-hidden="true">⌕</span>
              <span>Search</span>
              <kbd>⌘ K</kbd>
            </button>
            <button
              className={`sync-pill ${diagnostic.mode}`}
              onClick={() => setSection("sync")}
            >
              <span className="sync-dot" aria-hidden="true" />
              {dataMode === "demo"
                ? "Demo workspace"
                : diagnostic.mode === "connected"
                  ? "Real journal connected"
                  : "Real journal status"}
            </button>
          </div>
        </header>

        <div className={`workspace-provenance ${dataMode}`} role="status">
          <span>{provenanceLabel}</span>
          {dataMode === "real" && realRead?.recordCount !== undefined && (
            <small>{realRead.recordCount} canonical records · {realWriter ? "writes require revision guards" : "writes unavailable"}</small>
          )}
          {writeMessage && <small role="status">{writeMessage}</small>}
        </div>

        <div className="content-scroll">
          {section === "dashboard" && (
            <PortfolioDashboard
              initialAsOf={initialAsOf}
              initialTimeZone={initialTimeZone}
              openProject={openProject}
              openProjects={() => setSection("projects")}
              openReviews={() => setSection("reviews")}
              openSync={() => setSection("sync")}
              snapshot={dataMode === "real" ? realDashboardSnapshot : undefined}
              provenance={provenanceLabel}
            />
          )}
          {section === "projects" && <Projects demos={availableDemos} openProject={openProject} dataMode={dataMode} />}
          {section === "project" && (
            selectedDemo ? (
              <ProjectWorkspace
                demo={selectedDemo}
                tab={projectTab}
                setTab={setProjectTab}
                showDraft={() => setShowDraft(true)}
                dataMode={dataMode}
                canWrite={Boolean(realWriter)}
                onUpdateNextStep={updateNextStep}
              />
            ) : (
              <RealJournalEmptyState mode={dataMode} />
            )
          )}
          {section === "reviews" && <Reviews demos={availableDemos} openProject={openProject} dataMode={dataMode} />}
          {section === "sync" && (
            <SyncDiagnostics
              diagnostic={diagnostic}
              isChecking={isCheckingCloud}
              runCheck={runCloudKitCheck}
              dataMode={dataMode}
              conflicts={conflicts}
              drafts={drafts}
              onResolveConflict={handleConflictResolution}
            />
          )}
        </div>
      </main>

      {showDraft && selectedDemo && (
        <PlanDraftSheet
          demo={selectedDemo}
          close={() => setShowDraft(false)}
          dataMode={dataMode}
          writer={realWriter}
          records={realRead?.records ?? []}
          onResult={handleWriteResult}
          onDraftSaved={async (draft) => {
            await draftStore.save(draft);
            await refreshDrafts();
            setWriteMessage("Recoverable draft saved locally; it clears only after CloudKit commits.");
          }}
        />
      )}
    </div>
  );
}

function Projects({
  demos,
  openProject,
  dataMode,
}: {
  demos: ProjectDemo[];
  openProject: (id: string) => void;
  dataMode: "demo" | "real";
}) {
  const projectItems = demos.map((demo) => demo.project);
  return (
    <div className="page-stack narrow-page">
      <div className="section-heading page-heading">
        <div>
          <span className="mini-label">{projectItems.filter((project) => project.status === "Active").length} active · {projectItems.filter((project) => project.status === "Paused").length} paused</span>
          <h2>Projects</h2>
          <p>{dataMode === "real" ? "Read-only projection from the canonical CloudKit journal." : "Each project keeps its plan, practice, proof, trail, and reviews together."}</p>
        </div>
        <button className="primary-button" disabled={dataMode === "real"}>New project</button>
      </div>
      <div className="project-list">
        {projectItems.map((project) => (
          <button className="project-list-card" key={project.id} onClick={() => openProject(project.id)}>
            <span className="project-list-accent" style={{ background: project.accent }} />
            <div className="project-list-main">
              <span className="mini-label">{project.area} · {project.status}</span>
              <h3>{project.name}</h3>
              <p>{project.goal}</p>
              <div className="project-meta-row">
                <span>{project.phase}</span>
                <span>{project.phaseWindow}</span>
                <span>{project.lastMeaningfulActivity}</span>
              </div>
            </div>
            <div className="project-evidence-stat">
              <strong>{project.evidenceCount}/{project.evidenceTarget}</strong>
              <span>proof signals</span>
            </div>
            <span className="chevron" aria-hidden="true">›</span>
          </button>
        ))}
        {projectItems.length === 0 && (
          <section className="empty-history"><span>□</span><h3>No canonical Projects loaded</h3><p>Switch to Demo or configure Real journal access.</p></section>
        )}
      </div>
    </div>
  );
}

function ProjectWorkspace({
  demo,
  tab,
  setTab,
  showDraft,
  dataMode,
  canWrite,
  onUpdateNextStep,
}: {
  demo: ProjectDemo;
  tab: ProjectTab;
  setTab: (tab: ProjectTab) => void;
  showDraft: () => void;
  dataMode: "demo" | "real";
  canWrite: boolean;
  onUpdateNextStep: (projectId: string, nextStep: string) => Promise<void>;
}) {
  const project = demo.project;
  return (
    <div className="project-page page-stack">
      <section className="project-hero">
        <div>
          <div className="project-identity">
            <span className="project-token coral" style={{ backgroundColor: project.accent }}>{project.token}</span>
            <span className="status-pill">{project.status}</span>
          </div>
          <h2>{project.name}</h2>
          <p>{project.goal}</p>
          <small className="demo-source">{demo.sourceLabel}</small>
        </div>
        <div className="project-hero-actions">
          <button className="secondary-button" disabled={dataMode === "demo"}>Add proof</button>
          <button className="primary-button" onClick={showDraft}>Adjust plan</button>
        </div>
      </section>

      <div className="tab-list" role="tablist" aria-label="Project workspace sections">
        {projectTabs.map((item) => (
          <button
            key={item.id}
            role="tab"
            aria-selected={tab === item.id}
            className={tab === item.id ? "tab-button active" : "tab-button"}
            onClick={() => setTab(item.id)}
          >
            {item.label}
            {item.id === "reviews" && <span className="tab-alert" />}
          </button>
        ))}
      </div>

      {tab === "overview" && <ProjectOverview demo={demo} dataMode={dataMode} canWrite={canWrite} onUpdateNextStep={onUpdateNextStep} />}
      {tab === "plan" && <PlanPanel demo={demo} showDraft={showDraft} dataMode={dataMode} />}
      {tab === "practice" && <PracticePanel demo={demo} />}
      {tab === "proof" && <ProofPanel demo={demo} />}
      {tab === "trail" && <TrailPanel demo={demo} />}
      {tab === "reviews" && <ProjectReviews demo={demo} />}
    </div>
  );
}

function ProjectOverview({
  demo,
  dataMode,
  canWrite,
  onUpdateNextStep,
}: {
  demo: ProjectDemo;
  dataMode: "demo" | "real";
  canWrite: boolean;
  onUpdateNextStep: (projectId: string, nextStep: string) => Promise<void>;
}) {
  const project = demo.project;
  const [nextStep, setNextStep] = useState(project.nextStep);
  const [isSaving, setIsSaving] = useState(false);
  async function saveNextStep() {
    setIsSaving(true);
    try {
      await onUpdateNextStep(project.id, nextStep);
    } finally {
      setIsSaving(false);
    }
  }
  return (
    <div className="project-content-grid">
      <div className="project-main-column page-stack small-gap">
        <article className="card phase-detail-card">
          <div className="section-heading compact">
            <div>
              <span className="mini-label">Active phase · {project.phaseWindow}</span>
              <h3>{project.phase}</h3>
            </div>
            <span className="soft-badge">Revision 1</span>
          </div>
          <div className="phase-detail-grid">
            <div>
              <span className="mini-label">Outcome</span>
              <p>{project.goal}</p>
            </div>
            <div>
              <span className="mini-label">Expected proof</span>
              <p>{project.expectedProof}</p>
            </div>
          </div>
          <div className="phase-progress-row">
            <span className="phase-number">02</span>
            <div>
              <strong>{project.evidenceCount} proof signals collected</strong>
              <span>{project.evidenceTarget - project.evidenceCount} still need to qualify before this phase can advance.</span>
            </div>
            <button className="text-button">Inspect</button>
          </div>
        </article>
        <article className="card">
          <div className="section-heading compact">
            <div>
              <span className="mini-label">Planned work</span>
              <h3>Sessions</h3>
            </div>
            <button className="text-button">View plan</button>
          </div>
          <SessionList sessions={demo.sessions} />
        </article>
      </div>
      <aside className="project-side-column page-stack small-gap">
        <article className="card next-step-card">
          <span className="mini-label">Canonical next step</span>
          <input aria-label="Canonical next step" value={nextStep} onChange={(event) => setNextStep(event.target.value)} />
          <button className="dark-button" disabled={dataMode !== "real" || !canWrite || isSaving} onClick={() => void saveNextStep()}>
            {isSaving ? "Saving…" : dataMode === "real" && canWrite ? "Save guarded Next Step" : "Real journal write only"}
          </button>
        </article>
        <article className="card">
          <div className="section-heading compact">
            <div>
              <span className="mini-label">Practice routine</span>
              <h3>{demo.routineTitle} · {demo.routineTargetMinutes}m</h3>
            </div>
            <span className="soft-badge">{demo.routineFrequency}</span>
          </div>
          {demo.practiceBlocks.map((block) => (
            <div className="mini-block" key={block.id}>
              <span className={`block-dot ${block.tone}`} />
              <div>
                <strong>{block.name}</strong>
                <span>{block.focus}</span>
              </div>
              <small>{block.targetMinutes}m</small>
            </div>
          ))}
        </article>
      </aside>
    </div>
  );
}

function PlanPanel({ demo, showDraft, dataMode }: { demo: ProjectDemo; showDraft: () => void; dataMode: "demo" | "real" }) {
  return (
    <div className="panel-layout">
      <section className="card plan-timeline-card">
        <div className="section-heading">
          <div>
            <span className="mini-label">Active learning plan · Revision {demo.planRevision}</span>
            <h3>{demo.planTitle}</h3>
            <p>{demo.sourceLabel}</p>
          </div>
          <button className="primary-button" onClick={showDraft}>Adjust plan</button>
        </div>
        <div className="phase-timeline">
          {demo.planPhases.map((phase) => (
            <div className={`timeline-phase ${phase.status.toLowerCase()}`} key={phase.id}>
              <span className="timeline-marker">{phase.status === "Complete" ? "✓" : phase.order}</span>
              <div>
                <span className="mini-label">Phase {phase.order} · {phase.status}</span>
                <h4>{phase.title}</h4>
                <p>{phase.description}</p>
                <div className="phase-milestones">
                  {phase.milestones.map((milestone) => <span key={milestone}>{milestone}</span>)}
                </div>
                {phase.status === "Active" && <SessionList sessions={demo.sessions} />}
              </div>
              <span>{phase.window}</span>
            </div>
          ))}
        </div>
      </section>
      <aside className="page-stack small-gap">
        <article className="card capacity-summary-card">
          <span className="mini-label">Capacity check</span>
          <strong>{formatMinutes(demo.capacity.plannedMinutes)} / {formatMinutes(demo.capacity.availableMinutes)}</strong>
          <div className="capacity-track"><span className="capacity-used" style={{ width: `${Math.min(100, demo.capacity.plannedMinutes / demo.capacity.availableMinutes * 100)}%` }} /></div>
          <p>{demo.capacity.note}</p>
        </article>
        <article className="card revision-card">
          <span className="mini-label">Plan history</span>
          <h3>{demo.planRevision} published revision</h3>
          <p>{dataMode === "real" ? "Revision identity and structural changes are guarded in CloudKit." : "Imported as deterministic Demo data · no structural conflicts."}</p>
          <button className="secondary-button">View history</button>
        </article>
      </aside>
    </div>
  );
}

function PracticePanel({ demo }: { demo: ProjectDemo }) {
  const lastSessionMinutes = demo.practiceBlocks.reduce((total, block) => total + block.actualMinutes, 0);
  const attentionBlock = demo.practiceBlocks.find((block) => block.actualMinutes < block.targetMinutes);
  return (
    <div className="panel-layout">
      <section className="card routine-card">
        <div className="section-heading">
          <div>
            <span className="mini-label">Active routine · {demo.routineFrequency}</span>
            <h3>{demo.routineTitle}</h3>
            <p>{demo.routineTargetMinutes}-minute overall target · Block targets are guidance.</p>
          </div>
          <button className="secondary-button">Edit routine</button>
        </div>
        <div className="block-table">
          {demo.practiceBlocks.map((block, index) => (
            <div className="block-row" key={block.id}>
              <span className="block-index">0{index + 1}</span>
              <span className={`large-block-dot ${block.tone}`} />
              <div className="block-main">
                <span className="mini-label">{block.name} · target {block.targetMinutes}m</span>
                <h4>{block.focus}</h4>
                <p>Next focus: {block.nextFocus}</p>
              </div>
              <div className="block-actual">
                <strong>{block.actualMinutes}m</strong>
                <span>last session</span>
              </div>
            </div>
          ))}
        </div>
      </section>
      <aside className="page-stack small-gap">
        <article className="card">
          <span className="mini-label">Last session</span>
          <div className="big-metric">{lastSessionMinutes}m</div>
          <p>{demo.lastSessionLabel}</p>
          <div className="attention-callout">
            <span>!</span>
            {attentionBlock?.name ?? "Routine balance"} is marked for attention.
          </div>
        </article>
        <article className="card">
          <span className="mini-label">iPhone execution</span>
          <h3>Guided Routine Player</h3>
          <p>Start once, move between Blocks, and save one Practice Summary.</p>
          <span className="read-only-note">View-only on Web</span>
        </article>
      </aside>
    </div>
  );
}

function ProofPanel({ demo }: { demo: ProjectDemo }) {
  return (
    <div className="proof-grid">
      {demo.proofs.map((proof, index) => (
        <article className={index === 0 ? "proof-card strong-proof" : "proof-card"} key={proof.id}>
          <div className={`proof-preview ${proof.kind === "Audio" ? "audio-preview" : "note-preview"}`}>
            <span>{proof.preview}</span>
            {proof.kind === "Audio" ? <div className="waveform">{proof.previewDetail}</div> : <small>{proof.previewDetail}</small>}
          </div>
          <span className="proof-type">{proof.kind} · {proof.status}</span>
          <h3>{proof.title}</h3>
          <p>{proof.detail}</p>
          <div className="proof-footer"><span>{proof.date}</span><button className="text-button">Inspect</button></div>
        </article>
      ))}
      <button className="add-proof-card"><span>+</span><strong>Add proof</strong><small>Capture works best on iPhone</small></button>
    </div>
  );
}

function TrailPanel({ demo }: { demo: ProjectDemo }) {
  return (
    <section className="card wide-card">
      <div className="section-heading">
        <div><span className="mini-label">Meaningful history</span><h3>Learning trail</h3></div>
        <button className="secondary-button">Filter</button>
      </div>
      <TrailList items={demo.trail} />
    </section>
  );
}

function ProjectReviews({ demo }: { demo: ProjectDemo }) {
  const project = demo.project;
  return (
    <div className="panel-layout">
      <section className="card review-workbench">
        <span className="mini-label">{demo.review.ready ? "Stage review ready" : "Stage review not ready"}</span>
        <h3>{demo.review.headline}</h3>
        <p className="large-copy">{demo.review.summary}</p>
        <div className="review-facts">
          <div><strong>{project.evidenceCount}</strong><span>proof signals</span></div>
          <div><strong>{demo.review.practiceSessions}</strong><span>practice sessions</span></div>
          <div><strong>{demo.review.carryovers}</strong><span>carryover</span></div>
        </div>
        <button className="dark-button" disabled={!demo.review.ready}>{demo.review.ready ? "Start evidence review" : "Collect more proof"}</button>
      </section>
      <aside className="card">
        <span className="mini-label">Publication rule</span>
        <h3>Nothing changes silently.</h3>
        <p>Review Facts are deterministic. Only your published Review Decisions can advance or revise the plan.</p>
      </aside>
    </div>
  );
}

function Reviews({
  demos,
  openProject,
  dataMode,
}: {
  demos: ProjectDemo[];
  openProject: (id: string, tab?: ProjectTab) => void;
  dataMode: "demo" | "real";
}) {
  const readyReviews = demos.filter((demo) => demo.review.ready);
  return (
    <div className="page-stack narrow-page">
      <div className="section-heading page-heading">
        <div><span className="mini-label">{readyReviews.length} decision waiting</span><h2>Review inbox</h2><p>{dataMode === "real" ? "Read-only Reviews projected from the canonical journal." : "Evidence first, interpretation second, publication always explicit."}</p></div>
        <button className="secondary-button" disabled={dataMode === "real"}>Start weekly review</button>
      </div>
      {readyReviews.map((demo) => (
        <article className="review-inbox-card" key={demo.project.id}>
          <span className="review-status-orb">◇</span>
          <div>
            <span className="mini-label">Stage review · {demo.project.name}</span>
            <h3>{demo.review.headline}</h3>
            <p>Target window reached · {demo.project.evidenceCount} proof signals · {demo.review.carryovers} carryover</p>
          </div>
          <div className="review-inbox-actions">
            <span>{demo.review.readySince}</span>
            <button className="primary-button" onClick={() => openProject(demo.project.id, "reviews")}>Open review</button>
          </div>
        </article>
      ))}
      <section className="empty-history"><span>◇</span><h3>No draft reviews</h3><p>Started reviews remain here until you publish or discard them.</p></section>
    </div>
  );
}

function RealJournalEmptyState({ mode }: { mode: "demo" | "real" }) {
  return (
    <div className="page-stack narrow-page">
      <section className="card portfolio-error-state" role="status">
        <span className="mini-label">{mode === "real" ? "Real journal" : "Project"}</span>
        <h3>{mode === "real" ? "No canonical Project selected" : "No Project selected"}</h3>
        <p>{mode === "real" ? "CloudKit returned no readable Project for this route. Demo data is not substituted." : "Choose a Project from the sidebar."}</p>
      </section>
    </div>
  );
}

function SyncDiagnostics({
  diagnostic,
  isChecking,
  runCheck,
  dataMode,
  conflicts,
  drafts,
  onResolveConflict,
}: {
  diagnostic: CloudKitDiagnostic;
  isChecking: boolean;
  runCheck: () => void;
  dataMode: "demo" | "real";
  conflicts: WebSyncConflict[];
  drafts: RecoverableDraft[];
  onResolveConflict: (conflict: WebSyncConflict, resolution: SyncConflictResolution) => void;
}) {
  const recordTypes = Object.entries(diagnostic.recordTypes ?? {}).sort((a, b) => b[1] - a[1]);
  return (
    <div className="page-stack narrow-page">
      <div className="section-heading page-heading">
        <div>
          <span className="mini-label">Direct journal access</span>
          <h2>Sync & conflicts</h2>
          <p>{dataMode === "real" ? "Real mode reads and writes the same private CloudKit zone used by the iPhone App. Every write is atomic and change-tag guarded." : "Run a read-only diagnostic before switching to Real journal mode."}</p>
        </div>
        <button className="primary-button" onClick={runCheck} disabled={isChecking}>
          {isChecking ? "Checking…" : "Run CloudKit check"}
        </button>
      </div>

      <section className="diagnostic-grid">
        <article className="card cloud-status-card">
          <div className={`large-status-dot ${diagnostic.mode}`} />
          <div>
            <span className="mini-label">Connection status</span>
            <h3>{diagnostic.mode === "connected" ? "Private journal connected" : diagnostic.mode === "demo" ? "Demo mode" : diagnostic.mode === "blocked" ? "Real mode blocked" : diagnostic.mode.replace("-", " ")}</h3>
            <p>{diagnostic.message}</p>
          </div>
          <div id="apple-sign-in-button" className="apple-auth-slot" />
          <div id="apple-sign-out-button" className="apple-auth-slot" />
        </article>
        <article className="card config-card">
          <span className="mini-label">Configuration</span>
          <dl>
            <div><dt>Container</dt><dd>{cloudKitConfig.containerIdentifier}</dd></div>
            <div><dt>Environment</dt><dd>{cloudKitConfig.environment}</dd></div>
            <div><dt>Private zone</dt><dd>{cloudKitConfig.zoneName}</dd></div>
            <div><dt>Web API token</dt><dd>{hasCloudKitConfiguration() ? "Configured" : "Missing"}</dd></div>
          </dl>
        </article>
      </section>

      {!hasCloudKitConfiguration() && (
        <section className="setup-callout">
          <span className="callout-number">01</span>
          <div>
            <span className="mini-label">Apple setup required</span>
            <h3>Create a CloudKit Web API token</h3>
            <p>Add the development and production site origins in CloudKit Dashboard, then set the public token in the Web environment. Until then, no Apple sign-in or private record read is attempted.</p>
          </div>
          <code>NEXT_PUBLIC_CLOUDKIT_API_TOKEN</code>
        </section>
      )}

      {diagnostic.mode === "connected" && (
        <section className="card record-diagnostics">
          <div className="section-heading compact">
            <div><span className="mini-label">Read-only validation</span><h3>{diagnostic.recordCount} records found</h3></div>
            <span className="soft-badge">change tags retained</span>
          </div>
          <div className="record-type-grid">
            {recordTypes.map(([type, count]) => <div key={type}><strong>{count}</strong><span>{type}</span></div>)}
          </div>
          {diagnostic.latestChangeTag && <p className="change-tag">Latest sampled change tag: <code>{diagnostic.latestChangeTag}</code></p>}
        </section>
      )}

      {drafts.length > 0 && (
        <section className="card recoverable-drafts-card">
          <div className="section-heading compact"><div><span className="mini-label">Recoverable drafts</span><h3>{drafts.length} unfinished edit{drafts.length === 1 ? "" : "s"}</h3></div><span className="soft-badge">local only</span></div>
          <p>Drafts survive a browser restart and clear only after CloudKit reports a semantic commit.</p>
          <div className="draft-list">{drafts.map((draft) => <div className="draft-list-row" key={draft.id}><strong>{draft.kind}</strong><span>{draft.status}</span><small>{new Date(draft.updatedAt).toLocaleString()}</small></div>)}</div>
        </section>
      )}

      {conflicts.length > 0 ? conflicts.map((conflict) => (
        <section className="card sync-conflict-card" key={conflict.id}>
          <div className="section-heading compact"><div><span className="mini-label">{conflict.structural ? "Structural conflict" : "Same-field conflict"} · {conflict.kind}</span><h3>CloudKit needs an explicit decision</h3></div><span className="soft-badge">no silent LWW</span></div>
          <div className="conflict-columns">
            <div><span className="mini-label">Base</span><pre>{JSON.stringify(conflict.basePayload, null, 2)}</pre></div>
            <div><span className="mini-label">Local Web edit</span><pre>{JSON.stringify(conflict.localPayload, null, 2)}</pre></div>
            <div><span className="mini-label">Remote CloudKit</span><pre>{JSON.stringify(conflict.serverPayload, null, 2)}</pre></div>
          </div>
          <p className="conflict-fields">Conflicting fields: {conflict.conflictingFields.join(", ") || "structural identity"}</p>
          <div className="conflict-actions">
            {(["keepRemote", "discardLocal", "rebaseLocal", "fork"] as SyncConflictResolution[]).map((resolution) => <button key={resolution} className={resolution === "keepRemote" ? "secondary-button" : "text-button"} onClick={() => onResolveConflict(conflict, resolution)}>{resolution === "keepRemote" ? "Keep remote" : resolution === "discardLocal" ? "Discard local" : resolution === "rebaseLocal" ? "Rebase local" : "Fork revision"}</button>)}
          </div>
        </section>
      )) : (
        <section className="card conflict-empty-state">
          <span className="conflict-icon">↻</span>
          <div><h3>{dataMode === "real" ? "No unresolved CloudKit conflicts" : "No Web conflicts loaded"}</h3><p>{dataMode === "real" ? "Guarded writes never retry stale revisions or apply last-write-wins. Same-field and structural collisions will appear here." : "Same-field and structural collisions will appear here. Last-write-wins is never applied silently."}</p></div>
        </section>
      )}
    </div>
  );
}

function PlanDraftSheet({
  demo,
  close,
  dataMode,
  writer,
  records,
  onResult,
  onDraftSaved,
}: {
  demo: ProjectDemo;
  close: () => void;
  dataMode: "demo" | "real";
  writer: WebJournalWriter | null;
  records: JournalReadRecord[];
  onResult: (result: WebWriteResult) => Promise<void>;
  onDraftSaved: (draft: RecoverableDraft) => Promise<void>;
}) {
  const activePhase = demo.planPhases.find((phase) => phase.status === "Active") ?? demo.planPhases[0];
  const [outcome, setOutcome] = useState(activePhase?.description ?? "");
  const [expectedProof, setExpectedProof] = useState(demo.project.expectedProof);
  const [draftId, setDraftId] = useState<string | undefined>();
  const [isSaving, setIsSaving] = useState(false);
  const activePlan = records.find((record) => record.kind === "coursePlan" && record.payload.projectId === demo.project.id && record.payload.status === "active");
  const canActivate = dataMode === "real" && Boolean(writer && activePlan?.recordChangeTag);

  async function saveDraft() {
    const draft = createRecoverableDraft({
      kind: "learningPlan",
      projectId: demo.project.id,
      payload: {
        title: demo.planTitle,
        outcome,
        expectedProof,
        source: "Web Workspace plan editor",
      },
    });
    setDraftId(draft.id);
    await onDraftSaved(draft);
  }

  async function activateRevision() {
    if (!writer || !activePlan?.recordChangeTag) return;
    setIsSaving(true);
    try {
      let currentDraftID = draftId;
      if (!currentDraftID) {
        const draft = createRecoverableDraft({
          kind: "learningPlan",
          projectId: demo.project.id,
          payload: { title: demo.planTitle, outcome, expectedProof, source: "Web Workspace plan editor" },
          status: "pending",
        });
        currentDraftID = draft.id;
        setDraftId(currentDraftID);
        await onDraftSaved(draft);
      }
      const id = newRecordID();
      const now = new Date().toISOString();
      const payload = {
        ...activePlan.payload,
        id,
        revision: Number(activePlan.payload.revision ?? demo.planRevision) + 1,
        revisionID: id,
        baseRevisionID: activePlan.recordName,
        supersedesID: activePlan.recordName,
        status: "active",
        courseOutline: outcome,
        expectedOutcome: expectedProof,
        updatedAt: now,
        activatedAt: now,
      };
      const target: CanonicalWriteRecord = {
        kind: "coursePlan",
        recordName: id,
        recordType: activePlan.recordType,
        payload,
      };
      const result = await writer.writeBatch({
        operation: "activateLearningPlan",
        records: [target],
        draftId: currentDraftID,
        guardedRecords: [{
          record: canonicalRecord(activePlan),
          role: "base",
          expectation: {
            baseRevisionID: activePlan.recordName,
            baseRecordChangeTag: activePlan.recordChangeTag,
            targetRevisionID: id,
            recordState: "existingRecord",
            targetRecordState: "newRecord",
          },
        }],
      });
      await onResult(result);
      if (result.status === "committed") close();
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <div className="sheet-backdrop" role="presentation" onMouseDown={close}>
      <section className="plan-sheet" role="dialog" aria-modal="true" aria-labelledby="draft-title" onMouseDown={(event) => event.stopPropagation()}>
        <header className="sheet-header">
          <div><span className="mini-label">Recoverable draft · not active</span><h2 id="draft-title">Adjust learning plan</h2></div>
          <button className="close-button" onClick={close} aria-label="Close plan draft">×</button>
        </header>
        <div className="sheet-body">
          <label><span>Phase outcome</span><textarea value={outcome} onChange={(event) => setOutcome(event.target.value)} /></label>
          <div className="field-row">
            <label><span>Plan window</span><input value={activePhase?.window ?? ""} readOnly /></label>
            <label><span>Revision</span><input value={`Revision ${demo.planRevision + 1} draft`} readOnly /></label>
          </div>
          <label><span>Expected proof</span><textarea value={expectedProof} onChange={(event) => setExpectedProof(event.target.value)} /></label>
          <div className="draft-warning"><span>i</span><div><strong>Capacity check</strong><p>{formatMinutes(demo.capacity.plannedMinutes)} planned against {formatMinutes(demo.capacity.availableMinutes)} available. {demo.capacity.note}</p></div></div>
          <div className="revision-note"><span className="mini-label">What creates a new revision?</span><p>Changing this outcome, phase dates, expected proof, phase order, or Routine structure. Session completion and Proof remain ordinary execution updates.</p></div>
          <p className="read-only-note">{dataMode === "real" ? (canActivate ? "Activation creates a new immutable CoursePlan revision and checks the current CloudKit change tag." : "Activation is unavailable until a canonical CoursePlan and change tag are loaded.") : "Demo records are noncanonical. This editor can only save a local recoverable draft."}</p>
        </div>
        <footer className="sheet-footer">
          <button className="secondary-button" onClick={() => void saveDraft()} disabled={isSaving}>Save recoverable draft</button>
          <button className="primary-button" disabled={!canActivate || isSaving} onClick={() => void activateRevision()} title={canActivate ? "Create and activate a guarded CoursePlan revision" : "CloudKit writes require Real journal mode and a revision guard"}>{isSaving ? "Activating…" : "Activate guarded revision"}</button>
        </footer>
      </section>
    </div>
  );
}

function SessionList({ sessions }: { sessions: ProjectDemo["sessions"] }) {
  return (
    <div className="session-list">
      {sessions.map((session) => (
        <div className="session-row" key={session.id}>
          <span className={`session-state ${session.status.toLowerCase()}`}>{session.status === "Done" ? "✓" : session.status === "Carryover" ? "!" : ""}</span>
          <div><strong>{session.title}</strong><span>{session.window} · {session.duration} min</span></div>
          <span className={`session-badge ${session.status.toLowerCase()}`}>{session.status}</span>
        </div>
      ))}
    </div>
  );
}

function TrailList({ items, limit }: { items: ProjectDemo["trail"]; limit?: number }) {
  return (
    <div className="trail-list">
      {items.slice(0, limit).map((item) => (
        <div className="trail-row" key={item.id}>
          <span className={`trail-marker ${item.kind}`} />
          <div className="trail-content"><span>{item.date}</span><strong>{item.title}</strong><p>{item.detail}</p></div>
        </div>
      ))}
    </div>
  );
}
