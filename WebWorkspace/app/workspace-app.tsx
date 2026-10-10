"use client";

import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type CSSProperties } from "react";
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

const navigation: Array<{ id: WorkspaceSection; label: string; hint: string }> = [
  { id: "dashboard", label: "学习总览", hint: "今天先做什么" },
  { id: "projects", label: "学习项目", hint: "计划、练习与证据" },
  { id: "reviews", label: "复盘", hint: "对照证据做决定" },
  { id: "sync", label: "数据与同步", hint: "连接 iPhone 记录" },
];

function NavIcon({ id }: { id: WorkspaceSection }) {
  const paths: Record<string, string> = {
    dashboard: "M4 11.5 12 5l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5h-5v5H5a1 1 0 0 1-1-1z",
    projects: "M4 6.5h6l2 2h8V18a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1z",
    reviews: "M6 4h9l3 3v13H6zM9 11h6M9 15h4",
    sync: "M18.5 9A7 7 0 0 0 6 7.5L4.5 9M5.5 15A7 7 0 0 0 18 16.5l1.5-1.5M4.5 4.5V9H9M19.5 19.5V15H15",
  };
  return (
    <svg className="nav-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d={paths[id]} />
    </svg>
  );
}

const projectTabs: Array<{ id: ProjectTab; label: string; intro: string }> = [
  { id: "overview", label: "概览", intro: "先看当前阶段、完成标准和下一步。" },
  { id: "plan", label: "学习计划", intro: "查看全部阶段；需要调整时，先保存草稿再启用。" },
  { id: "practice", label: "练习安排", intro: "查看每次练习的模块与时长；练习在 iPhone 上进行。" },
  { id: "proof", label: "学习证据", intro: "录音、代码或笔记，用来判断本阶段是否达成。" },
  { id: "trail", label: "学习记录", intro: "按时间顺序查看练习、证据和计划的变化。" },
  { id: "reviews", label: "复盘", intro: "对照证据判断是否进入下一阶段；发布决定在 iPhone 上完成。" },
];

const initialDiagnostic: CloudKitDiagnostic = hasCloudKitConfiguration()
  ? { mode: "ready", message: "已找到连接配置，可运行连接检查。" }
  : {
      mode: "demo",
      message: "当前展示示例数据。完成连接配置后，可读取个人学习记录。",
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
  if (!hours) return `${remainder} 分钟`;
  return remainder ? `${hours} 小时 ${remainder} 分钟` : `${hours} 小时`;
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
      return "个人学习记录已保存到云端。";
    case "conflict":
      return "云端版本已更新。请到「数据与同步」选择要保留的修改。";
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
    const destination = query ? `${window.location.pathname}?${query}` : window.location.pathname;
    if (destination !== `${window.location.pathname}${window.location.search}`) {
      const previous = new URLSearchParams(window.location.search);
      const pageChanged = (previous.get("section") ?? "dashboard") !== localState.section
        || (localState.section === "project" && previous.get("project") !== localState.projectId);
      window.history.pushState(null, "", destination);
      if (pageChanged) {
        document.getElementById("workspace-content")?.focus({ preventScroll: true });
        window.scrollTo({ top: 0, behavior: "auto" });
      }
    }
  }, [localState]);

  useEffect(() => {
    const restoreNavigation = () => setLocalState(null);
    window.addEventListener("popstate", restoreNavigation);
    return () => window.removeEventListener("popstate", restoreNavigation);
  }, []);

  function openProject(projectId: string, tab: ProjectTab = "overview") {
    setLocalState(projectNavigationState(projectId, tab));
  }

  async function loadRealJournal() {
    setIsCheckingCloud(true);
    setDiagnostic({ mode: "checking", message: "正在检查个人学习记录…" });
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
    setDiagnostic({ mode: "checking", message: "正在检查个人学习记录…" });
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
      setWriteMessage("示例数据不会保存。切换到「个人记录」后可编辑下一步。");
      return;
    }
    const source = realRead.records.find((record) => record.kind === "project" && record.recordName === projectId);
    if (!source || !source.recordChangeTag) {
      setWriteMessage("这个项目缺少云端版本标记，暂时无法安全保存。");
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
        setWriteMessage(resolution === "keepRemote" ? "已保留云端版本，学习记录未变化。" : "已放弃本次网页修改，学习记录未变化。");
      } else {
        setWriteMessage(`已选择「${resolution === "rebaseLocal" ? "按新版本重新应用修改" : "另存为新版本"}」。请在编辑器中确认并保存新版本。`);
      }
    } catch (error) {
      setWriteMessage(error instanceof Error ? error.message : String(error));
    }
  }

  const sectionTitle =
    section === "project"
      ? selectedDemo?.project.name ?? (dataMode === "real" ? "个人记录" : "学习项目")
      : navigation.find((item) => item.id === section)?.label ?? "学习总览";

  const provenanceLabel = dataMode === "real"
    ? realRead?.status === "blocked"
      ? "个人记录暂不可用，请到「数据与同步」完成配置。"
        : realRead?.status === "signed-out"
          ? "请先到「数据与同步」登录 Apple 账户。"
        : realWriter
          ? "已连接个人记录。保存前会检查版本，避免覆盖其他设备的修改。"
          : "个人记录 · 当前仅可查看"
    : "你正在看示例数据：可以随意点击，不会修改个人学习记录。";

  const reviewCount = availableDemos.filter((demo) => demo.review.ready).length;
  const isNavActive = (id: WorkspaceSection) => section === id || (section === "project" && id === "projects");

  return (
    <div className="workspace-shell">
      <a className="skip-link" href="#workspace-content">跳到主要内容</a>
      <aside className="sidebar">
        <button className="brand" onClick={() => setSection("dashboard")} aria-label="返回学习总览">
          <span className="brand-mark" aria-hidden="true">学</span>
          <span>
            <strong>Self Study Studio</strong>
            <small>网页做计划与复盘 · iPhone 做练习</small>
          </span>
        </button>

        <nav className="primary-nav" aria-label="主要导航">
          {navigation.map((item) => (
            <button
              key={item.id}
              className={isNavActive(item.id) ? "nav-item active" : "nav-item"}
              aria-current={isNavActive(item.id) ? "page" : undefined}
              onClick={() => setSection(item.id)}
            >
              <NavIcon id={item.id} />
              <span className="nav-text">
                <strong>{item.label}</strong>
                <small>{item.hint}</small>
              </span>
              {item.id === "reviews" && reviewCount > 0 && (
                <span className="nav-count" aria-label={`${reviewCount} 项待复盘`}>{reviewCount}</span>
              )}
            </button>
          ))}
        </nav>

        <div className="sidebar-projects">
          <div className="sidebar-label">直接打开项目</div>
          {availableDemos.map((demo) => {
            const project = demo.project;
            const selected = section === "project" && selectedProjectId === project.id;
            return (
              <button
                key={project.id}
                className={selected ? "project-shortcut selected" : "project-shortcut"}
                aria-current={selected ? "page" : undefined}
                onClick={() => openProject(project.id)}
              >
                <span className="project-dot" style={{ backgroundColor: project.accent }} aria-hidden="true" />
                <span>
                  <strong>{project.name}</strong>
                  <small>{project.phase}</small>
                </span>
              </button>
            );
          })}
          {dataMode === "real" && availableDemos.length === 0 && (
            <p className="sidebar-empty">尚未读取到个人项目。</p>
          )}
        </div>
      </aside>

      <main className="main-panel">
        <header className="topbar">
          <nav className="breadcrumb" aria-label="当前位置">
            {section === "project" ? (
              <>
                <button onClick={() => setSection("projects")}>学习项目</button>
                <span aria-hidden="true">/</span>
                <strong aria-current="page">{sectionTitle}</strong>
              </>
            ) : (
              <strong aria-current="page">{sectionTitle}</strong>
            )}
          </nav>
          <div className="topbar-actions">
            <div className="mode-switch" role="group" aria-label="数据来源">
              <span className="mode-label">正在查看</span>
              <button className={dataMode === "demo" ? "active" : ""} aria-pressed={dataMode === "demo"} onClick={() => switchDataMode("demo")}>
                示例数据
              </button>
              <button className={dataMode === "real" ? "active" : ""} aria-pressed={dataMode === "real"} onClick={() => switchDataMode("real")}>
                个人记录
              </button>
            </div>
          </div>
        </header>

        <div className={`workspace-provenance ${dataMode}`} role="status">
          <span className="provenance-dot" aria-hidden="true" />
          <span>{provenanceLabel}</span>
          {dataMode === "real" && realRead?.recordCount !== undefined && (
            <small>{realRead.recordCount} 条记录 · {realWriter ? "可保存" : "仅可查看"}</small>
          )}
          {writeMessage && <small role="status">{writeMessage}</small>}
          {section !== "sync" && (dataMode === "demo" || diagnostic.mode !== "connected") && (
            <button className="text-button" onClick={() => setSection("sync")}>
              {dataMode === "demo" ? "如何连接个人记录" : "查看连接状态"}
            </button>
          )}
        </div>

        <div className="content-scroll" id="workspace-content" tabIndex={-1}>
          {section === "dashboard" && (
            <PortfolioDashboard
              initialAsOf={initialAsOf}
              initialTimeZone={initialTimeZone}
              openProject={openProject}
              openProjects={() => setSection("projects")}
              openReviews={() => setSection("reviews")}
              openSync={() => setSection("sync")}
              snapshot={dataMode === "real" ? realDashboardSnapshot : undefined}
              provenance=""
            />
          )}
          {section === "projects" && <Projects demos={availableDemos} openProject={openProject} dataMode={dataMode} />}
          {section === "project" && (
            selectedDemo ? (
              <ProjectWorkspace
                key={selectedDemo.project.id}
                demo={selectedDemo}
                openProjects={() => setSection("projects")}
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
            setWriteMessage("草稿已保存在当前浏览器，云端确认保存后才会清除。");
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
  const [query, setQuery] = useState("");
  const projectItems = demos.map((demo) => demo.project);
  const filteredProjects = projectItems.filter((project) =>
    `${project.name} ${project.area} ${project.goal}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()),
  );
  return (
    <div className="page-stack narrow-page">
      <div className="section-heading page-heading">
        <div>
          <span className="mini-label">{projectItems.filter((project) => project.status === "Active").length} 个进行中 · {projectItems.filter((project) => project.status === "Paused").length} 个已暂停</span>
          <h2>学习项目</h2>
          <p>{dataMode === "real" ? "这里展示个人记录中的项目。新建项目和练习采集请在 iPhone 上完成。" : "选一个项目，查看学习计划、练习安排、证据和复盘。"}</p>
        </div>
        <span className="read-only-note">新建项目请在 iPhone 上完成</span>
      </div>
      <label className="project-search">
        <span>查找学习项目</span>
        <input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="输入项目名称、领域或学习目标" />
        <small role="status">{filteredProjects.length} 个项目</small>
      </label>
      <div className="project-list">
        {filteredProjects.map((project) => (
          <button className="project-list-card" key={project.id} onClick={() => openProject(project.id)}>
            <span className="project-list-accent" style={{ background: project.accent }} />
            <div className="project-list-main">
              <span className="mini-label">{project.area} · {project.status === "Active" ? "进行中" : project.status === "Paused" ? "已暂停" : project.status === "Completed" ? "已完成" : "已停止"}</span>
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
              <span>项学习证据</span>
            </div>
            <span className="chevron" aria-hidden="true">›</span>
          </button>
        ))}
        {projectItems.length > 0 && filteredProjects.length === 0 && (
          <section className="empty-history"><h3>没有找到匹配的项目</h3><p>尝试其他关键词，或清空搜索查看全部项目。</p><button className="secondary-button" onClick={() => setQuery("")}>清空搜索</button></section>
        )}
        {projectItems.length === 0 && (
          <section className="empty-history"><span>□</span><h3>尚未读取到个人项目</h3><p>可切换到示例数据浏览，或到「数据与同步」检查连接。</p></section>
        )}
      </div>
    </div>
  );
}

function ProjectWorkspace({
  demo,
  openProjects,
  tab,
  setTab,
  showDraft,
  dataMode,
  canWrite,
  onUpdateNextStep,
}: {
  demo: ProjectDemo;
  openProjects: () => void;
  tab: ProjectTab;
  showDraft: () => void;
  dataMode: "demo" | "real";
  canWrite: boolean;
  onUpdateNextStep: (projectId: string, nextStep: string) => Promise<void>;
  setTab: (tab: ProjectTab) => void;
}) {
  const project = demo.project;
  return (
    <div className="project-page page-stack">
      <button className="back-link" onClick={openProjects}>← 返回学习项目</button>
      <section className="project-hero" style={{ "--project-accent": project.accent } as CSSProperties}>
        <div>
          <div className="project-identity">
            <span className="project-token" aria-hidden="true">{project.token}</span>
            <span className="status-pill">{project.status === "Active" ? "进行中" : project.status === "Paused" ? "已暂停" : project.status === "Completed" ? "已完成" : "已停止"}</span>
            <span className="project-phase-chip">{project.phase} · {project.phaseWindow}</span>
          </div>
          <h2>{project.name}</h2>
          <p>{project.goal}</p>
          <small className="demo-source">{demo.sourceLabel}</small>
        </div>
        <div className="project-hero-actions">
          <button className="secondary-button" onClick={showDraft}>调整计划</button>
          <small>先保存草稿，确认后才会生效</small>
        </div>
      </section>

      <div className="tab-list" role="tablist" aria-label="项目内容">
        {projectTabs.map((item) => (
          <button
            key={item.id}
            role="tab"
            id={`project-tab-${item.id}`}
            aria-controls="project-panel"
            tabIndex={tab === item.id ? 0 : -1}
            aria-selected={tab === item.id}
            onKeyDown={(event) => {
              const index = projectTabs.findIndex((entry) => entry.id === item.id);
              const next = event.key === "ArrowRight" ? (index + 1) % projectTabs.length
                : event.key === "ArrowLeft" ? (index + projectTabs.length - 1) % projectTabs.length
                  : event.key === "Home" ? 0 : event.key === "End" ? projectTabs.length - 1 : -1;
              if (next < 0) return;
              event.preventDefault();
              setTab(projectTabs[next].id);
              const buttons = event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>("[role=tab]");
              buttons?.[next].focus();
            }}
            className={tab === item.id ? "tab-button active" : "tab-button"}
            onClick={() => setTab(item.id)}
          >
            {item.label}
            {item.id === "reviews" && demo.review.ready && <span className="tab-alert" aria-label="有待复盘事项" />}
          </button>
        ))}
      </div>

      <section className="project-tab-panel" role="tabpanel" id="project-panel" aria-labelledby={`project-tab-${tab}`} tabIndex={0}>
      <p className="tab-intro">{projectTabs.find((item) => item.id === tab)?.intro}</p>
      {tab === "overview" && <ProjectOverview demo={demo} dataMode={dataMode} canWrite={canWrite} onUpdateNextStep={onUpdateNextStep} setTab={setTab} />}
      {tab === "plan" && <PlanPanel demo={demo} showDraft={showDraft} dataMode={dataMode} setTab={setTab} />}
      {tab === "practice" && <PracticePanel demo={demo} />}
      {tab === "proof" && <ProofPanel demo={demo} />}
      {tab === "trail" && <TrailPanel demo={demo} />}
      {tab === "reviews" && <ProjectReviews demo={demo} setTab={setTab} />}
      </section>
    </div>
  );
}

function ProjectOverview({
  demo,
  setTab,
  dataMode,
  canWrite,
  onUpdateNextStep,
}: {
  demo: ProjectDemo;
  dataMode: "demo" | "real";
  canWrite: boolean;
  onUpdateNextStep: (projectId: string, nextStep: string) => Promise<void>;
  setTab: (tab: ProjectTab) => void;
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
  const editable = dataMode === "real" && canWrite;
  const remainingEvidence = Math.max(0, project.evidenceTarget - project.evidenceCount);
  return (
    <div className="project-overview page-stack small-gap">
      <article className="next-step-card">
        <div className="next-step-copy">
          <span className="start-here-kicker"><b>下一步</b>在 iPhone 上练习时照着做</span>
          {editable ? (
            <textarea rows={3} aria-label="下一步学习行动" value={nextStep} onChange={(event) => setNextStep(event.target.value)} />
          ) : (
            <p className="next-step-text">{nextStep}</p>
          )}
        </div>
        <div className="next-step-actions">
          {editable ? (
            <button className="primary-button" disabled={isSaving} onClick={() => void saveNextStep()}>
              {isSaving ? "正在保存…" : "保存下一步"}
            </button>
          ) : (
            <small>{dataMode === "real" ? "连接个人记录并读取项目后可编辑。" : "示例数据仅供查看；切换到「个人记录」后可编辑。"}</small>
          )}
        </div>
      </article>
      <div className="project-content-grid">
        <article className="card phase-detail-card">
          <div className="section-heading compact">
            <div>
              <span className="mini-label">当前阶段 · {project.phaseWindow}</span>
              <h3>{project.phase}</h3>
            </div>
            <span className="soft-badge">计划版本 {demo.planRevision}</span>
          </div>
          <div className="phase-detail-grid">
            <div>
              <span className="mini-label">阶段目标</span>
              <p>{project.goal}</p>
            </div>
            <div>
              <span className="mini-label">完成标准（需要的学习证据）</span>
              <p>{project.expectedProof}</p>
            </div>
          </div>
          <div className="phase-progress-row">
            <span className="phase-number" aria-hidden="true">{project.evidenceCount}/{project.evidenceTarget}</span>
            <div>
              <strong>已收集 {project.evidenceCount} 项学习证据</strong>
              <span>{remainingEvidence > 0 ? `还差 ${remainingEvidence} 项，达到目标后再确认是否进入下一阶段。` : "已达到目标，可以复盘。"}</span>
            </div>
            <button className="text-button" onClick={() => setTab("proof")}>查看证据 →</button>
          </div>
        </article>
        <article className="card">
          <div className="section-heading compact">
            <div>
              <span className="mini-label">本阶段已安排</span>
              <h3>学习任务</h3>
            </div>
            <button className="text-button" onClick={() => setTab("plan")}>查看计划 →</button>
          </div>
          <SessionList sessions={demo.sessions} />
          <div className="routine-summary">
            <span className="mini-label">固定练习 · {demo.routineFrequency}</span>
            <strong>{demo.routineTitle} · {demo.routineTargetMinutes} 分钟</strong>
            <button className="text-button" onClick={() => setTab("practice")}>查看练习安排 →</button>
          </div>
        </article>
      </div>
    </div>
  );
}

function PlanPanel({ demo, showDraft, dataMode, setTab }: { demo: ProjectDemo; showDraft: () => void; dataMode: "demo" | "real"; setTab: (tab: ProjectTab) => void }) {
  return (
    <div className="panel-layout">
      <section className="card plan-timeline-card">
        <div className="section-heading">
          <div>
            <span className="mini-label">当前学习计划 · 版本 {demo.planRevision}</span>
            <h3>{demo.planTitle}</h3>
            <p>{demo.sourceLabel}</p>
          </div>
          <button className="primary-button" onClick={showDraft}>调整计划</button>
        </div>
        <div className="phase-timeline">
          {demo.planPhases.map((phase) => (
            <div className={`timeline-phase ${phase.status.toLowerCase()}`} key={phase.id}>
              <span className="timeline-marker">{phase.status === "Complete" ? "✓" : phase.order}</span>
              <div>
                <span className="mini-label">阶段 {phase.order} · {phase.status === "Active" ? "进行中" : phase.status === "Complete" ? "已完成" : "已计划"}</span>
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
          <span className="mini-label">时间安排检查</span>
          <strong>{formatMinutes(demo.capacity.plannedMinutes)} / {formatMinutes(demo.capacity.availableMinutes)}</strong>
          <div className="capacity-track"><span className="capacity-used" style={{ width: `${Math.min(100, demo.capacity.plannedMinutes / demo.capacity.availableMinutes * 100)}%` }} /></div>
          <p>{demo.capacity.note}</p>
        </article>
        <article className="card revision-card">
          <span className="mini-label">计划版本</span>
          <h3>{demo.planRevision} 个已发布版本</h3>
          <p>{dataMode === "real" ? "保存新版本前会检查云端版本，避免覆盖其他设备的修改。" : "示例计划，仅供浏览。"}</p>
          <button className="secondary-button" onClick={() => setTab("trail")}>查看学习记录</button>
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
            <span className="mini-label">当前练习安排 · {demo.routineFrequency}</span>
            <h3>{demo.routineTitle}</h3>
            <p>总目标 {demo.routineTargetMinutes} 分钟 · 各模块的时长可按实际练习调整。</p>
          </div>
          <span className="read-only-note">练习设置请在 iPhone 上调整</span>
        </div>
        <div className="block-table">
          {demo.practiceBlocks.map((block, index) => (
            <div className="block-row" key={block.id}>
              <span className="block-index">0{index + 1}</span>
              <span className={`large-block-dot ${block.tone}`} />
              <div className="block-main">
                <span className="mini-label">{block.name} · 目标 {block.targetMinutes} 分钟</span>
                <h4>{block.focus}</h4>
                <p>下次练习：{block.nextFocus}</p>
              </div>
              <div className="block-actual">
                <strong>{block.actualMinutes} 分钟</strong>
                <span>最近一次练习</span>
              </div>
            </div>
          ))}
        </div>
      </section>
      <aside className="page-stack small-gap">
        <article className="card">
          <span className="mini-label">最近一次练习</span>
          <div className="big-metric">{lastSessionMinutes} 分钟</div>
          <p>{demo.lastSessionLabel}</p>
          <div className="attention-callout">
            <span>!</span>
            {attentionBlock?.name ?? "练习分配"} 需要留意。
          </div>
        </article>
        <article className="card">
          <span className="mini-label">在 iPhone 上练习</span>
          <h3>按步骤开始练习</h3>
          <p>打开 iPhone 应用，按练习模块执行，结束后保存一次练习记录。</p>
          <span className="read-only-note">网页仅供查看</span>
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
          <div className="proof-footer"><span>{proof.date}</span><span className="read-only-note">证据摘要</span></div>
        </article>
      ))}
      <aside className="add-proof-card"><span aria-hidden="true">+</span><strong>在 iPhone 上添加学习证据</strong><small>录音、照片或笔记会随个人记录同步到这里。</small></aside>
    </div>
  );
}

function TrailPanel({ demo }: { demo: ProjectDemo }) {
  return (
    <section className="card wide-card">
      <div className="section-heading">
        <div><span className="mini-label">练习、证据与复盘的变化</span><h3>学习记录</h3></div>

      </div>
      <TrailList items={demo.trail} />
    </section>
  );
}

function ProjectReviews({ demo, setTab }: { demo: ProjectDemo; setTab: (tab: ProjectTab) => void }) {
  const project = demo.project;
  return (
    <div className="panel-layout">
      <section className="card review-workbench">
        <span className="mini-label">{demo.review.ready ? "可以进行阶段复盘" : "阶段复盘尚未就绪"}</span>
        <h3>{demo.review.headline}</h3>
        <p className="large-copy">{demo.review.summary}</p>
        <div className="review-facts">
          <div><strong>{project.evidenceCount}</strong><span>项学习证据</span></div>
          <div><strong>{demo.review.practiceSessions}</strong><span>次练习</span></div>
          <div><strong>{demo.review.carryovers}</strong><span>项未完成任务</span></div>
        </div>
        <button className="primary-button" onClick={() => setTab("proof")}>查看学习证据 →</button>
        <p className="read-only-note">网页可查看复盘依据；发布复盘决定请在 iPhone 上完成。</p>
      </section>
      <aside className="card">
        <span className="mini-label">决定何时生效</span>
        <h3>确认后才推进计划</h3>
        <p>先查看练习和证据，再在 iPhone 上发布复盘决定。只有明确确认后，计划才会推进或修订。</p>
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
        <div><span className="mini-label">{readyReviews.length} 项待复盘</span><h2>待复盘的项目</h2><p>{dataMode === "real" ? "这里展示个人记录中的复盘依据。发布决定请在 iPhone 上完成。" : "先查看学习证据，判断本阶段的目标是否达成，再决定下一步。"}</p></div>
        <span className="read-only-note">在 iPhone 上发起或发布复盘</span>
      </div>
      {readyReviews.map((demo) => (
        <article className="review-inbox-card" key={demo.project.id}>
          <span className="review-status-orb">◇</span>
          <div>
            <span className="mini-label">阶段复盘 · {demo.project.name}</span>
            <h3>{demo.review.headline}</h3>
            <p>已到阶段复盘时间 · {demo.project.evidenceCount} 项学习证据 · {demo.review.carryovers} 项待处理任务</p>
          </div>
          <div className="review-inbox-actions">
            <span>{demo.review.readySince}</span>
            <button className="primary-button" onClick={() => openProject(demo.project.id, "reviews")}>查看复盘依据</button>
          </div>
        </article>
      ))}
      <section className="empty-history"><span>◇</span><h3>复盘草稿请在 iPhone 上查看</h3><p>网页展示已读取的复盘依据，不创建或发布复盘决定。</p></section>
    </div>
  );
}

function RealJournalEmptyState({ mode }: { mode: "demo" | "real" }) {
  return (
    <div className="page-stack narrow-page">
      <section className="card portfolio-error-state" role="status">
        <span className="mini-label">{mode === "real" ? "个人记录" : "学习项目"}</span>
        <h3>{mode === "real" ? "尚未读取到个人项目" : "尚未选择项目"}</h3>
        <p>{mode === "real" ? "尚未读取到可查看的项目。请到「数据与同步」检查连接；这里不会用示例替代个人记录。" : "从「学习项目」中选择一个项目。"}</p>
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
          <span className="mini-label">连接 iPhone 的个人学习记录</span>
          <h2>数据与同步</h2>
          <p>{dataMode === "real" ? "这里与 iPhone 使用同一份 iCloud 私有记录。保存修改前会检查版本；如有冲突，需要选择保留哪个版本。" : "先检查连接，再切换到个人记录。示例数据仅用于浏览，不会保存到个人记录。"}</p>
        </div>
        <button className="primary-button" onClick={runCheck} disabled={isChecking}>
          {isChecking ? "正在检查…" : "检查连接"}
        </button>
      </div>

      <section className="diagnostic-grid">
        <article className="card cloud-status-card">
          <div className={`large-status-dot ${diagnostic.mode}`} />
          <div>
            <span className="mini-label">连接状态</span>
            <h3>{diagnostic.mode === "connected" ? "已连接个人记录" : diagnostic.mode === "demo" ? "正在使用示例数据" : diagnostic.mode === "blocked" ? "个人记录连接受阻" : diagnostic.mode.replace("-", " ")}</h3>
            <p>{diagnostic.message}</p>
          </div>
          <div id="apple-sign-in-button" className="apple-auth-slot" />
          <div id="apple-sign-out-button" className="apple-auth-slot" />
        </article>
        <article className="card config-card">
          <span className="mini-label">连接配置</span>
          <dl>
            <div><dt>容器</dt><dd>{cloudKitConfig.containerIdentifier}</dd></div>
            <div><dt>环境</dt><dd>{cloudKitConfig.environment}</dd></div>
            <div><dt>私有数据区域</dt><dd>{cloudKitConfig.zoneName}</dd></div>
            <div><dt>Web API token</dt><dd>{hasCloudKitConfiguration() ? "已配置" : "尚未配置"}</dd></div>
          </dl>
        </article>
      </section>

      {!hasCloudKitConfiguration() && (
        <section className="setup-callout">
          <span className="callout-number">01</span>
          <div>
            <span className="mini-label">需要完成 Apple 连接配置</span>
            <h3>配置个人记录连接</h3>
            <p>在 CloudKit Dashboard 中添加网站地址，再配置 Web API token。完成前无法登录 Apple 账户或读取个人记录。</p>
          </div>
          <code>NEXT_PUBLIC_CLOUDKIT_API_TOKEN</code>
        </section>
      )}

      {diagnostic.mode === "connected" && (
        <section className="card record-diagnostics">
          <div className="section-heading compact">
            <div><span className="mini-label">只读检查</span><h3>找到 {diagnostic.recordCount} 条记录</h3></div>
            <span className="soft-badge">已保留版本标记</span>
          </div>
          <div className="record-type-grid">
            {recordTypes.map(([type, count]) => <div key={type}><strong>{count}</strong><span>{type}</span></div>)}
          </div>
          {diagnostic.latestChangeTag && <p className="change-tag">最近的版本标记：<code>{diagnostic.latestChangeTag}</code></p>}
        </section>
      )}

      {drafts.length > 0 && (
        <section className="card recoverable-drafts-card">
          <div className="section-heading compact"><div><span className="mini-label">本地未发布草稿</span><h3>{drafts.length} 个未完成的编辑</h3></div><span className="soft-badge">仅保存在当前浏览器</span></div>
          <p>草稿保存在当前浏览器，重新打开后仍可查看。只有云端确认保存成功后才会清除。</p>
          <div className="draft-list">{drafts.map((draft) => <div className="draft-list-row" key={draft.id}><strong>{draft.kind}</strong><span>{draft.status}</span><small>{new Date(draft.updatedAt).toLocaleString()}</small></div>)}</div>
        </section>
      )}

      {conflicts.length > 0 ? conflicts.map((conflict) => (
        <section className="card sync-conflict-card" key={conflict.id}>
          <div className="section-heading compact"><div><span className="mini-label">{conflict.structural ? "计划结构冲突" : "同一内容存在冲突"} · {conflict.kind}</span><h3>选择要保留的修改</h3></div><span className="soft-badge">等待确认</span></div>
          <p>其他设备也修改了这份内容。先检查各个版本，再选择处理方式。</p>
          <details><summary>查看冲突版本详情</summary>
          <div className="conflict-columns">
            <div><span className="mini-label">修改前的版本</span><pre>{JSON.stringify(conflict.basePayload, null, 2)}</pre></div>
            <div><span className="mini-label">本次网页修改</span><pre>{JSON.stringify(conflict.localPayload, null, 2)}</pre></div>
            <div><span className="mini-label">当前云端版本</span><pre>{JSON.stringify(conflict.serverPayload, null, 2)}</pre></div>
          </div>
          <p className="conflict-fields">冲突字段：{conflict.conflictingFields.join(", ") || "计划结构"}</p>
          </details>
          <div className="conflict-actions">
            {(["keepRemote", "discardLocal", "rebaseLocal", "fork"] as SyncConflictResolution[]).map((resolution) => <button key={resolution} className={resolution === "keepRemote" ? "secondary-button" : "text-button"} onClick={() => onResolveConflict(conflict, resolution)}>{resolution === "keepRemote" ? "保留云端版本" : resolution === "discardLocal" ? "放弃本次网页修改" : resolution === "rebaseLocal" ? "按新版本重新应用修改" : "另存为新版本"}</button>)}
          </div>
        </section>
      )) : (
        <section className="card conflict-empty-state">
          <span className="conflict-icon">↻</span>
          <div><h3>{dataMode === "real" ? "当前没有未解决的冲突" : "尚未读取个人记录的冲突"}</h3><p>{dataMode === "real" ? "保存前会检查版本。如果多个设备修改同一内容，这里会提示需要选择的版本。" : "连接个人记录后，可检查各设备的修改是否冲突。"}</p></div>
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
  const dialogRef = useRef<HTMLElement>(null);
  useEffect(() => {
    const previousFocus = document.activeElement as HTMLElement | null;
    const dialog = dialogRef.current;
    const controls = () => Array.from(dialog?.querySelectorAll<HTMLElement>("button:not(:disabled), input, textarea, [tabindex='0']") ?? []);
    controls()[0]?.focus();
    function handleKey(event: KeyboardEvent) {
      if (event.key === "Escape") { event.preventDefault(); close(); }
      if (event.key !== "Tab") return;
      const items = controls();
      const first = items[0];
      const last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    }
    dialog?.addEventListener("keydown", handleKey);
    return () => { dialog?.removeEventListener("keydown", handleKey); previousFocus?.focus(); };
  }, [close]);
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
      <section ref={dialogRef} className="plan-sheet" role="dialog" aria-modal="true" aria-labelledby="draft-title" onMouseDown={(event) => event.stopPropagation()}>
        <header className="sheet-header">
          <div><span className="mini-label">计划草稿 · 尚未生效</span><h2 id="draft-title">调整学习计划</h2></div>
          <button className="close-button" onClick={close} aria-label="关闭计划草稿">×</button>
        </header>
        <div className="sheet-body">
          <label><span>本阶段的学习目标</span><textarea value={outcome} onChange={(event) => setOutcome(event.target.value)} /></label>
          <div className="field-row">
            <label><span>计划时间</span><input value={activePhase?.window ?? ""} readOnly /></label>
            <label><span>版本</span><input value={`版本 ${demo.planRevision + 1} 草稿`} readOnly /></label>
          </div>
          <label><span>需要的学习证据</span><textarea value={expectedProof} onChange={(event) => setExpectedProof(event.target.value)} /></label>
          <div className="draft-warning"><span>i</span><div><strong>时间安排检查</strong><p>已计划 {formatMinutes(demo.capacity.plannedMinutes)}，可用 {formatMinutes(demo.capacity.availableMinutes)}。{demo.capacity.note}</p></div></div>
          <div className="revision-note"><span className="mini-label">哪些改动会生成新版本？</span><p>修改学习目标、阶段日期、学习证据要求、阶段顺序或练习结构会生成新版本。完成学习任务和添加证据不会生成新计划版本。</p></div>
          <p className="read-only-note">{dataMode === "real" ? (canActivate ? "启用前会检查当前版本，确认后生成新计划版本。" : "当前无法启用新计划。请连接个人记录并读取现有计划。") : "示例模式仅保存当前浏览器的本地草稿，不会修改个人学习计划。"}</p>
        </div>
        <footer className="sheet-footer">
          <button className="secondary-button" onClick={() => void saveDraft()} disabled={isSaving}>保存本地草稿</button>
          <button className="primary-button" disabled={!canActivate || isSaving} onClick={() => void activateRevision()} title={canActivate ? "保存并启用新的学习计划版本" : "连接个人记录并读取现有计划后可启用"}>{isSaving ? "正在启用…" : "确认并启用新计划"}</button>
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
          <div><strong>{session.title}</strong><span>{session.window} · {session.duration} 分钟</span></div>
          <span className={`session-badge ${session.status.toLowerCase()}`}>{session.status === "Done" ? "已完成" : session.status === "Carryover" ? "待处理" : "已计划"}</span>
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
