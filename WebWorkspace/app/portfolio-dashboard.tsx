"use client";

import { useMemo, useState, type CSSProperties } from "react";
import {
  createDashboardSnapshot,
  derivePortfolioDashboard,
  type AttentionItem,
  type DashboardDestination,
  type DashboardPeriod,
  type DashboardSection,
  type DashboardSnapshot,
  type PortfolioDashboardDataModel,
  type ProjectDashboardState,
} from "../lib/dashboard";
import { projectDemos, type ProjectTab } from "../lib/journal";

type PortfolioDashboardProps = {
  openProject: (id: string, tab?: ProjectTab) => void;
  openProjects: () => void;
  openReviews: () => void;
  openSync: () => void;
  initialAsOf: string;
  initialTimeZone: string;
  snapshot?: DashboardSnapshot;
  provenance?: string;
};

const periods: Array<{ id: DashboardPeriod; label: string }> = [
  { id: "now", label: "本周" },
  { id: "4w", label: "近 4 周" },
  { id: "12w", label: "近 12 周" },
];

const unavailableLabels: Record<DashboardSection, string> = {
  evidence: "学习证据",
  activity: "学习活动",
  capacity: "时间安排",
};

function movementSummary(
  row: NonNullable<PortfolioDashboardDataModel["movement"]>[number],
) {
  return `${row.projectName} 每周学习记录：${row.buckets
    .map((bucket) => `${bucket.label} ${bucket.count} 条`)
    .join("；")}。`;
}

function openDestination(
  item: Pick<AttentionItem, "projectId" | "destination">,
  openProject: PortfolioDashboardProps["openProject"],
  openSync: PortfolioDashboardProps["openSync"],
) {
  if (item.destination.section === "sync") {
    openSync();
    return;
  }
  openProject(item.projectId, item.destination.tab);
}

function destinationActionLabel(destination: DashboardDestination, kind?: string) {
  if (destination.section === "sync") return "查看同步问题";
  if (kind === "review" || destination.tab === "reviews") return "查看复盘依据";
  if (destination.tab === "proof") return "查看学习证据";
  if (destination.tab === "practice") return "查看练习安排";
  if (destination.tab === "plan") return "查看计划";
  if (destination.tab === "trail") return "查看学习记录";
  return "查看下一步";
}

function statusLabel(status: ProjectDashboardState["status"]) {
  return status === "Active" ? "进行中" : status === "Paused" ? "已暂停" : status === "Completed" ? "已完成" : "已停止";
}

function PortfolioProjectCard({
  project,
  openProject,
  openSync,
}: {
  project: ProjectDashboardState;
  openProject: PortfolioDashboardProps["openProject"];
  openSync: PortfolioDashboardProps["openSync"];
}) {
  const evidencePercent =
    !project.evidence || project.evidence.expected === 0
      ? 0
      : Math.min(100, (project.evidence.ready / project.evidence.expected) * 100);

  return (
    <article
      className="portfolio-project-card"
      style={{ "--project-accent": project.accent } as CSSProperties}
    >
      <header>
        <div className="portfolio-project-identity">
          <span className="portfolio-token" aria-hidden="true">{project.token}</span>
          <div>
            <h3>{project.name}</h3>
            <p>{project.area} · {project.phaseWindow}</p>
          </div>
        </div>
        <span className={`portfolio-state${project.attention ? " attention" : ""}`}>
          {statusLabel(project.status)}
        </span>
      </header>
      <dl className="portfolio-project-facts">
        <div>
          <dt>当前阶段</dt>
          <dd>{project.activePhase?.title ?? "尚无进行中的阶段"}</dd>
        </div>
        <div>
          <dt>本阶段的完成标准</dt>
          <dd className="portfolio-expected-proof">{project.expectedProof}</dd>
        </div>
        <div>
          <dt>学习证据</dt>
          <dd>
            {project.evidence ? (
              <span className="portfolio-evidence">
                <strong>{project.evidence.ready} / {project.evidence.expected} 项</strong>
                <span
                  className="portfolio-evidence-track"
                  role="img"
                  aria-label={`已收集 ${project.evidence.ready} 项，本阶段需要 ${project.evidence.expected} 项`}
                >
                  <span style={{ width: `${evidencePercent}%` }} />
                </span>
              </span>
            ) : (
              <span className="portfolio-unavailable-note">学习证据暂不可用</span>
            )}
          </dd>
        </div>
      </dl>
      <footer>
        <div>
          <span className="mini-label">下一步</span>
          <strong>{attentionLabel(project.nextDecision.label)}</strong>
          <small>{project.nextDecision.detail}</small>
        </div>
        <button
          className="secondary-button"
          onClick={() =>
            openDestination(
              { projectId: project.id, destination: project.nextDecision.destination },
              openProject,
              openSync,
            )
          }
        >
          {destinationActionLabel(project.nextDecision.destination, project.nextDecision.kind)}
        </button>
      </footer>
    </article>
  );
}

function attentionLabel(label: string) {
  return label.replace("Stage Review is ready", "本阶段可以复盘了")
    .replace("Learning log needs attention", "有练习模块需要补充")
    .replace("Expected Proof gap at the Phase boundary", "阶段结束前仍需补充学习证据")
    .replace(/(\d+) Carryover awaiting a decision/, "$1 项未完成任务需要确认")
    .replace(/No meaningful activity for (\d+) days/, "已有 $1 天没有新的学习记录")
    .replace("Continue the canonical Next Step", "继续下一步学习行动")
    .replace("Resolve the sync conflict", "选择要保留的同步版本")
    .replace("Planned capacity needs a decision", "计划时间需要调整");
}

function AttentionRow({
  item,
  openProject,
  openSync,
}: {
  item: AttentionItem;
  openProject: PortfolioDashboardProps["openProject"];
  openSync: PortfolioDashboardProps["openSync"];
}) {
  return (
    <button
      className="portfolio-attention-row"
      onClick={() => openDestination(item, openProject, openSync)}
    >
      <span
        className={`attention-dot ${item.kind}`}
        aria-hidden="true"
      />
      <span>
        <strong>{item.projectName}</strong>
        <small>{attentionTitle(item)}</small>
      </span>
      <span aria-hidden="true">›</span>
    </button>
  );
}

function PortfolioMovementMatrix({
  movement,
}: {
  movement: NonNullable<PortfolioDashboardDataModel["movement"]>;
}) {
  return (
    <article className="card portfolio-viz-card">
      <div className="section-heading">
        <div>
          <span className="mini-label">颜色越深，当周的练习、证据和复盘记录越多</span>
          <h3>学习活动趋势</h3>
        </div>
      </div>
      <div className="movement-matrix">
        {movement.map((row) => (
          <div className="movement-row" key={row.projectId}>
            <strong>{row.projectName}</strong>
            <div>
              {row.buckets.map((bucket) => (
                <span
                  className={`movement-cell intensity-${bucket.intensity}`}
                  key={bucket.label}
                  aria-hidden="true"
                />
              ))}
            </div>
            <p className="sr-only">{movementSummary(row)}</p>
            <small>{row.accessibleSummary}</small>
          </div>
        ))}
      </div>
    </article>
  );
}

function CapacityAllocation({
  capacity,
}: {
  capacity: NonNullable<PortfolioDashboardDataModel["capacity"]>;
}) {
  return (
    <article
      className={`card portfolio-viz-card capacity-${capacity.status}`}
    >
      <div className="section-heading">
        <div>
          <span className="mini-label">计划时间分配</span>
          <h3>未来两周的时间安排</h3>
        </div>
      </div>
      {capacity.warning && (
        <div className="capacity-warning" role="status">
          <strong>计划时间超过可用时间</strong>
          <span>{capacity.warning}</span>
        </div>
      )}
      <div
        className="portfolio-capacity-bar"
        aria-label={capacity.accessibleSummary}
      >
        {capacity.segments.map((segment) => (
          <span
            key={segment.projectId}
            style={{
              width: `${segment.percent}%`,
              background: segment.color,
            }}
          />
        ))}
      </div>
      {capacity.warningSegment && (
        <div className="capacity-overage-track" aria-hidden="true">
          <span
            className="capacity-overage-segment"
            style={{ width: `${capacity.warningSegment.percent}%` }}
          />
        </div>
      )}
      <ul className="capacity-legend">
        {capacity.segments.map((segment) => (
          <li key={segment.projectId}>
            <i style={{ background: segment.color }} />
            <span>{segment.label}</span>
            <strong>{segment.minutes} 分钟</strong>
          </li>
        ))}
        {capacity.warningSegment && (
          <li className="capacity-overage-legend">
            <i />
            <span>{capacity.warningSegment.label}</span>
            <strong>超出 {capacity.warningSegment.minutes} 分钟</strong>
          </li>
        )}
      </ul>
      <p className="sr-only">{capacity.accessibleSummary}</p>
    </article>
  );
}

function formatDate(asOf: string, timeZone: string) {
  return Number.isFinite(Date.parse(asOf))
    ? new Intl.DateTimeFormat("zh-CN", { month: "long", day: "numeric", weekday: "long", timeZone }).format(new Date(asOf))
    : "日期暂不可用";
}

function DashboardHeader({ asOf, timeZone }: { asOf: string; timeZone: string }) {
  return (
    <header className="portfolio-header">
      <p className="date-line">{formatDate(asOf, timeZone)}</p>
      <h2>今天先做这一件事</h2>
    </header>
  );
}

const usageSteps = [
  { title: "看下一步", detail: "在网页上确认今天要做什么" },
  { title: "去 iPhone 练习", detail: "练习、录音、拍照或记笔记" },
  { title: "回来复盘", detail: "对照证据，决定下一阶段" },
];

function UsageSteps() {
  return (
    <section className="usage-steps" aria-labelledby="usage-steps-heading">
      <h3 id="usage-steps-heading" className="sr-only">使用方法</h3>
      <ol>
        {usageSteps.map((step, index) => (
          <li key={step.title}>
            <span aria-hidden="true">{index + 1}</span>
            <div><strong>{step.title}</strong><small>{step.detail}</small></div>
          </li>
        ))}
      </ol>
    </section>
  );
}

function PeriodSwitch({ period, setPeriod }: { period: DashboardPeriod; setPeriod: (period: DashboardPeriod) => void }) {
  return (
    <div className="portfolio-period" role="group" aria-label="Dashboard period">
      <span className="period-label">统计范围</span>
      {periods.map((item) => (
        <button
          className={period === item.id ? "active" : ""}
          aria-pressed={period === item.id}
          key={item.id}
          onClick={() => setPeriod(item.id)}
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}

function DashboardLoading({ asOf, timeZone }: { asOf: string; timeZone: string }) {
  return (
    <div className="portfolio-dashboard page-stack" aria-busy="true" aria-label="正在读取学习总览">
      <header className="portfolio-header portfolio-skeleton">
        <p className="date-line">{formatDate(asOf, timeZone)}</p>
        <span className="skeleton-line wide" />
      </header>
      <section className="start-here portfolio-skeleton" aria-hidden="true">
        <span className="skeleton-line wide" />
        <span className="skeleton-line" />
      </section>
      <section className="portfolio-project-card portfolio-skeleton" aria-hidden="true">
        <span className="skeleton-line wide" />
        <span className="skeleton-block" />
      </section>
      <p className="sr-only">正在读取学习总览。</p>
    </div>
  );
}

function UnavailableVisualization({ section }: { section: DashboardSection }) {
  return (
    <article className="card portfolio-viz-card portfolio-unavailable-card">
      <span className="mini-label">部分数据缺失</span>
      <h3>{unavailableLabels[section]}暂不可用</h3>
      <p>已读取的项目仍可查看。此处缺少数据，暂不显示估算结果。</p>
    </article>
  );
}

const attentionTitles: Partial<Record<AttentionItem["kind"], string>> = {
  conflict: "选择要保留的同步版本",
  review: "本阶段可以复盘了",
  proof: "阶段结束前仍需补充学习证据",
  capacity: "计划时间超出可用时间",
  practice: "有练习模块需要补充",
};

function attentionTitle(item: AttentionItem) {
  return attentionTitles[item.kind] ?? attentionLabel(item.label);
}

export function PortfolioDashboard({
  openProject,
  openProjects,
  openReviews,
  openSync,
  initialAsOf,
  initialTimeZone,
  snapshot,
  provenance = "示例数据 · 可浏览，不会写入个人记录",
}: PortfolioDashboardProps) {
  const [period, setPeriod] = useState<DashboardPeriod>("now");
  const currentSnapshot = useMemo(
    () => snapshot ?? createDashboardSnapshot({ asOf: initialAsOf, demos: projectDemos }),
    [initialAsOf, snapshot],
  );
  const model = useMemo(
    () => derivePortfolioDashboard(currentSnapshot, period),
    [currentSnapshot, period],
  );

  if (model.loadState === "loading") {
    return (
      <div>
        {provenance && <div className="portfolio-provenance" role="status">{provenance}</div>}
        <DashboardLoading asOf={model.asOf} timeZone={initialTimeZone} />
      </div>
    );
  }

  if (model.loadState === "error") {
    return (
      <div className="portfolio-dashboard page-stack">
        {provenance && <div className="portfolio-provenance" role="status">{provenance}</div>}
        <DashboardHeader asOf={model.asOf} timeZone={initialTimeZone} />
        <section className="card portfolio-error-state" role="alert">
          <span className="mini-label">数据读取失败</span>
          <h3>学习总览加载失败</h3>
          <p>{model.errorMessage}</p>
          <button className="primary-button" onClick={openSync}>查看同步问题</button>
        </section>
      </div>
    );
  }

  const primaryDecision = model.decisions[0];
  const fallbackProject = model.projects[0];
  const evidenceSummary =
    model.pulse.evidenceReady === null || model.pulse.evidenceExpected === null
      ? "学习证据暂不可用"
      : `学习证据 ${model.pulse.evidenceReady} / ${model.pulse.evidenceExpected} 项`;

  return (
    <div className="portfolio-dashboard page-stack">
      {provenance && <div className="portfolio-provenance" role="status">{provenance}</div>}
      <DashboardHeader asOf={model.asOf} timeZone={initialTimeZone} />
      {model.loadState === "partial" && (
        <section className="portfolio-state-banner partial" role="status">
          <strong>部分数据暂不可用</strong>
          <span>
            {model.unavailableSections.map((section) => unavailableLabels[section]).join("、")}
            暂不可用，已读取的项目仍可查看。
          </span>
        </section>
      )}
      {model.loadState === "conflict" && (
        <section className="portfolio-state-banner conflict" role="alert">
          <div>
            <strong>{model.conflicts[0]?.label ?? "同步冲突"}</strong>
            <span>这里保留最近可信的数据。打开同步页面，选择要保留的版本。</span>
          </div>
          <button className="secondary-button" onClick={openSync}>查看同步问题</button>
        </section>
      )}
      {fallbackProject ? (
        <section className="start-here" aria-labelledby="start-here-heading">
          <div className="start-here-copy">
            <span className="start-here-kicker">
              <b>推荐</b>
              {primaryDecision?.projectName ?? fallbackProject.name}
            </span>
            <h3 id="start-here-heading">
              {primaryDecision ? attentionTitle(primaryDecision) : "继续下一步学习行动"}
            </h3>
            <p>{primaryDecision?.detail ?? fallbackProject.nextDecision.detail}</p>
          </div>
          <div className="start-here-action">
            <button
              className="primary-button"
              onClick={() =>
                primaryDecision
                  ? openDestination(primaryDecision, openProject, openSync)
                  : openProject(fallbackProject.id, fallbackProject.nextDecision.tab)
              }
            >
              {primaryDecision
                ? destinationActionLabel(primaryDecision.destination, primaryDecision.kind)
                : "查看下一步"}
              <span aria-hidden="true"> →</span>
            </button>
            <small>先查看依据，决定前不会修改计划。</small>
          </div>
        </section>
      ) : (
        <section className="portfolio-empty-state">
          <h3>还没有进行中的项目</h3>
          <p>可先查看已有项目，或在 iPhone 上创建第一个学习项目。</p>
          <div className="portfolio-empty-actions">
            <button className="primary-button" onClick={openProjects}>查看项目</button>
            <button className="secondary-button" onClick={openSync}>检查数据连接</button>
          </div>
        </section>
      )}
      <UsageSteps />
      {model.projects.length > 0 && (
        <div className="portfolio-main-grid">
          <section aria-labelledby="portfolio-projects-heading">
            <div className="section-heading">
              <div>
                <h2 id="portfolio-projects-heading">进行中的项目</h2>
                <p className="section-summary" aria-label="Portfolio pulse">
                  {model.pulse.activeProjects} 个进行中 · {evidenceSummary} · {model.pulse.reviewsReady} 项待复盘
                </p>
              </div>
              <button className="text-button" onClick={openProjects}>
                查看全部 {model.totalActiveProjects} 个项目
              </button>
            </div>
            <div className="portfolio-project-list">
              {model.projects.map((project) => (
                <PortfolioProjectCard project={project} openProject={openProject} openSync={openSync} key={project.id} />
              ))}
            </div>
          </section>
          <aside aria-labelledby="portfolio-decisions-heading">
            <div className="section-heading">
              <h2 id="portfolio-decisions-heading">
                其他待处理 <span className="heading-count">{model.attention.length}</span>
              </h2>
              <button className="text-button" onClick={openReviews}>全部复盘</button>
            </div>
            <div className="portfolio-attention-card">
              {model.attention.length > 0 ? (
                model.attention.map((item) => (
                  <AttentionRow item={item} openProject={openProject} openSync={openSync} key={item.id} />
                ))
              ) : (
                <p className="portfolio-empty-note">目前没有其他待处理事项。</p>
              )}
            </div>
          </aside>
        </div>
      )}
      {model.loadState !== "empty" && (
        <details className="portfolio-insights">
          <summary>查看学习趋势与时间安排<span>可选：判断投入是否均衡</span></summary>
          <div className="portfolio-insights-body">
            <PeriodSwitch period={period} setPeriod={setPeriod} />
            <section className="portfolio-lower-grid">
              {model.movement ? <PortfolioMovementMatrix movement={model.movement} /> : <UnavailableVisualization section="activity" />}
              {model.capacity ? <CapacityAllocation capacity={model.capacity} /> : <UnavailableVisualization section="capacity" />}
            </section>
          </div>
        </details>
      )}
    </div>
  );
}
