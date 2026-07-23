"use client";

import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import {
  cloudKitConfig,
  hasCloudKitConfiguration,
  inspectCloudKitJournal,
  type CloudKitDiagnostic,
} from "../lib/cloudkit";
import {
  getProjectDemo,
  projectDemos,
  projects,
  type ProjectDemo,
  type ProjectTab,
  type WorkspaceSection,
} from "../lib/journal";
import { PortfolioDashboard } from "./portfolio-dashboard";

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

function parseUrlState(search: string): {
  section: WorkspaceSection;
  projectId: string;
  tab: ProjectTab;
} {
  const fallback = {
    section: "dashboard" as WorkspaceSection,
    projectId: projects[0].id,
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
      projectId && projects.some((project) => project.id === projectId)
        ? projectId
        : fallback.projectId,
    tab: tab && projectTabIds.includes(tab) ? tab : fallback.tab,
  };
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

export function WorkspaceApp() {
  // URL search is an external store: SSR renders the fallback (dashboard),
  // hydration matches it, and React re-reads the real search right after.
  const search = useSyncExternalStore(
    subscribeToUrl,
    () => window.location.search,
    () => "",
  );
  const urlState = parseUrlState(search);
  const [localState, setLocalState] = useState<{
    section: WorkspaceSection;
    projectId: string;
    tab: ProjectTab;
  } | null>(null);

  const section = localState?.section ?? urlState.section;
  const selectedProjectId = localState?.projectId ?? urlState.projectId;
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

  const selectedDemo = useMemo(
    () => getProjectDemo(selectedProjectId),
    [selectedProjectId],
  );

  function openProject(projectId: string, tab: ProjectTab = "overview") {
    setLocalState({ section: "project", projectId, tab });
  }

  async function runCloudKitCheck() {
    setIsCheckingCloud(true);
    setDiagnostic({ mode: "checking", message: "Checking the private journal…" });
    const result = await inspectCloudKitJournal();
    setDiagnostic(result);
    setIsCheckingCloud(false);
  }

  const sectionTitle =
    section === "project"
      ? selectedDemo.project.name
      : navigation.find((item) => item.id === section)?.label ?? "Dashboard";

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
            <span>Active projects</span>
            <button aria-label="Add project">+</button>
          </div>
          {projects.map((project) => (
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
          ))}
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
              {diagnostic.mode === "connected" ? "iCloud connected" : "Demo workspace"}
            </button>
          </div>
        </header>

        <div className="content-scroll">
          {section === "dashboard" && (
            <PortfolioDashboard
              openProject={openProject}
              openProjects={() => setSection("projects")}
              openReviews={() => setSection("reviews")}
            />
          )}
          {section === "projects" && <Projects openProject={openProject} />}
          {section === "project" && (
            <ProjectWorkspace
              demo={selectedDemo}
              tab={projectTab}
              setTab={setProjectTab}
              showDraft={() => setShowDraft(true)}
            />
          )}
          {section === "reviews" && <Reviews openProject={openProject} />}
          {section === "sync" && (
            <SyncDiagnostics
              diagnostic={diagnostic}
              isChecking={isCheckingCloud}
              runCheck={runCloudKitCheck}
            />
          )}
        </div>
      </main>

      {showDraft && <PlanDraftSheet demo={selectedDemo} close={() => setShowDraft(false)} />}
    </div>
  );
}

function Projects({ openProject }: { openProject: (id: string) => void }) {
  return (
    <div className="page-stack narrow-page">
      <div className="section-heading page-heading">
        <div>
          <span className="mini-label">2 active · 0 paused</span>
          <h2>Projects</h2>
          <p>Each project keeps its plan, practice, proof, trail, and reviews together.</p>
        </div>
        <button className="primary-button">New project</button>
      </div>
      <div className="project-list">
        {projects.map((project) => (
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
      </div>
    </div>
  );
}

function ProjectWorkspace({
  demo,
  tab,
  setTab,
  showDraft,
}: {
  demo: ProjectDemo;
  tab: ProjectTab;
  setTab: (tab: ProjectTab) => void;
  showDraft: () => void;
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
          <button className="secondary-button">Add proof</button>
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

      {tab === "overview" && <ProjectOverview demo={demo} />}
      {tab === "plan" && <PlanPanel demo={demo} showDraft={showDraft} />}
      {tab === "practice" && <PracticePanel demo={demo} />}
      {tab === "proof" && <ProofPanel demo={demo} />}
      {tab === "trail" && <TrailPanel demo={demo} />}
      {tab === "reviews" && <ProjectReviews demo={demo} />}
    </div>
  );
}

function ProjectOverview({ demo }: { demo: ProjectDemo }) {
  const project = demo.project;
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
          <h3>{project.nextStep}</h3>
          <button className="dark-button">Make Up Next</button>
        </article>
        <article className="card mini-practice-card">
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

function PlanPanel({ demo, showDraft }: { demo: ProjectDemo; showDraft: () => void }) {
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
          <p>Imported as deterministic Demo data · no structural conflicts.</p>
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

function Reviews({ openProject }: { openProject: (id: string, tab?: ProjectTab) => void }) {
  const readyReviews = projectDemos.filter((demo) => demo.review.ready);
  return (
    <div className="page-stack narrow-page">
      <div className="section-heading page-heading">
        <div><span className="mini-label">{readyReviews.length} decision waiting</span><h2>Review inbox</h2><p>Evidence first, interpretation second, publication always explicit.</p></div>
        <button className="secondary-button">Start weekly review</button>
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

function SyncDiagnostics({
  diagnostic,
  isChecking,
  runCheck,
}: {
  diagnostic: CloudKitDiagnostic;
  isChecking: boolean;
  runCheck: () => void;
}) {
  const recordTypes = Object.entries(diagnostic.recordTypes ?? {}).sort((a, b) => b[1] - a[1]);
  return (
    <div className="page-stack narrow-page">
      <div className="section-heading page-heading">
        <div>
          <span className="mini-label">Direct journal access</span>
          <h2>Sync & conflicts</h2>
          <p>Validate the same private CloudKit zone used by the iPhone App.</p>
        </div>
        <button className="primary-button" onClick={runCheck} disabled={isChecking || !hasCloudKitConfiguration()}>
          {isChecking ? "Checking…" : "Run CloudKit check"}
        </button>
      </div>

      <section className="diagnostic-grid">
        <article className="card cloud-status-card">
          <div className={`large-status-dot ${diagnostic.mode}`} />
          <div>
            <span className="mini-label">Connection status</span>
            <h3>{diagnostic.mode === "connected" ? "Private journal connected" : diagnostic.mode === "demo" ? "Demo mode" : diagnostic.mode.replace("-", " ")}</h3>
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

      <section className="card conflict-empty-state">
        <span className="conflict-icon">↻</span>
        <div><h3>No Web conflicts loaded</h3><p>Same-field and structural collisions will appear here. Last-write-wins is never applied silently.</p></div>
      </section>
    </div>
  );
}

function PlanDraftSheet({ demo, close }: { demo: ProjectDemo; close: () => void }) {
  const activePhase = demo.planPhases.find((phase) => phase.status === "Active") ?? demo.planPhases[0];
  return (
    <div className="sheet-backdrop" role="presentation" onMouseDown={close}>
      <section className="plan-sheet" role="dialog" aria-modal="true" aria-labelledby="draft-title" onMouseDown={(event) => event.stopPropagation()}>
        <header className="sheet-header">
          <div><span className="mini-label">Recoverable draft · not active</span><h2 id="draft-title">Adjust learning plan</h2></div>
          <button className="close-button" onClick={close} aria-label="Close plan draft">×</button>
        </header>
        <div className="sheet-body">
          <label><span>Phase outcome</span><textarea defaultValue={activePhase.description} /></label>
          <div className="field-row">
            <label><span>Plan window</span><input value={activePhase.window} readOnly /></label>
            <label><span>Revision</span><input value={`Revision ${demo.planRevision + 1} draft`} readOnly /></label>
          </div>
          <label><span>Expected proof</span><textarea defaultValue={demo.project.expectedProof} /></label>
          <div className="draft-warning"><span>i</span><div><strong>Capacity check</strong><p>{formatMinutes(demo.capacity.plannedMinutes)} planned against {formatMinutes(demo.capacity.availableMinutes)} available. {demo.capacity.note}</p></div></div>
          <div className="revision-note"><span className="mini-label">What creates a new revision?</span><p>Changing this outcome, phase dates, expected proof, phase order, or Routine structure. Session completion and Proof remain ordinary execution updates.</p></div>
        </div>
        <footer className="sheet-footer">
          <button className="secondary-button" onClick={close}>Save draft</button>
          <button className="primary-button" disabled title="CloudKit writes are enabled after contract validation">Review activation</button>
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
