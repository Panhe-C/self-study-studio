"use client";

import { useMemo, useState, type CSSProperties } from "react";
import {
  createDashboardSnapshot,
  derivePortfolioDashboard,
  type AttentionItem,
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

function weekLabel(index: number, bucketCount: number) {
  const weeksAgo = bucketCount - 1 - index;
  if (weeksAgo === 0) return "This week";
  return `${weeksAgo} week${weeksAgo === 1 ? "" : "s"} ago`;
}

function movementSummary(
  row: NonNullable<PortfolioDashboardDataModel["movement"]>[number],
) {
  return `${row.projectName} weekly movement: ${row.buckets
    .map((bucket) => `${bucket.label}: ${bucket.count}`)
    .join("; ")} meaningful events.`;
}

function PulseCard({
  label,
  value,
  detail,
  attention = false,
}: {
  label: string;
  value: string;
  detail: string;
  attention?: boolean;
}) {
  return (
    <article className={`portfolio-pulse-card${attention ? " attention" : ""}`}>
      <span>{label}</span>
      <strong>{value}</strong>
      <small>{detail}</small>
    </article>
  );
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

function PortfolioProjectCard({
  project,
  openProject,
  openSync,
}: {
  project: ProjectDashboardState;
  openProject: PortfolioDashboardProps["openProject"];
  openSync: PortfolioDashboardProps["openSync"];
}) {
  const maxActivity = Math.max(...(project.activity ?? []), 1);
  const activitySummary = project.activity
    ? `${project.name} meaningful activity over ${project.activity.length} weeks: ${project.activity
        .map(
          (count, index) =>
            `${weekLabel(index, project.activity?.length ?? 0)}: ${count}`,
        )
        .join("; ")} meaningful events.`
    : "";
  const evidencePercent =
    !project.evidence || project.evidence.expected === 0
      ? 0
      : Math.min(
          100,
          (project.evidence.ready / project.evidence.expected) * 100,
        );

  return (
    <article className="portfolio-project-card">
      <header>
        <div className="portfolio-project-identity">
          <span
            className="portfolio-token"
            style={{ "--project-accent": project.accent } as CSSProperties}
          >
            {project.token}
          </span>
          <div>
            <h4>{project.name}</h4>
            <p>
              {project.area} · {project.phaseWindow}
            </p>
          </div>
        </div>
        <span
          className={`portfolio-state${project.attention ? " attention" : ""}`}
        >
          {project.status === "Active" ? "进行中" : project.status === "Paused" ? "已暂停" : project.status === "Completed" ? "已完成" : "已停止"}
        </span>
      </header>
      <div className="portfolio-project-body">
        <div>
          <span className="mini-label">当前阶段</span>
          <h5>{project.activePhase?.title ?? "尚无进行中的阶段"}</h5>
          <p className="portfolio-outcome">{project.outcome}</p>
          <div className="portfolio-expected-proof">
            <span className="mini-label">本阶段需要的证据</span>
            <p>{project.expectedProof}</p>
          </div>
          {project.evidence ? (
            <div className="portfolio-evidence">
              <div>
                <span>学习证据</span>
                <strong>
                  {project.evidence.ready} / {project.evidence.expected} 项
                </strong>
              </div>
              <div
                className="portfolio-evidence-track"
                aria-label={`${project.evidence.ready} of ${project.evidence.expected} expected Proof signals ready`}
              >
                <span style={{ width: `${evidencePercent}%` }} />
              </div>
            </div>
          ) : (
            <p className="portfolio-unavailable-note">
              学习证据暂不可用
            </p>
          )}
        </div>
        <details className="portfolio-activity">
          <summary>近六周的学习活动</summary>
          {project.activity ? (
            <>
              <div className="portfolio-sparkline" aria-hidden="true">
                {project.activity.map((count, index) => (
                  <span
                    key={index}
                    data-activity-count={count}
                    style={{
                      height: `${count === 0 ? 0 : (count / maxActivity) * 100}%`,
                    }}
                  />
                ))}
              </div>
              <p className="sr-only">{activitySummary}</p>
              <small>
                {weekLabel(0, project.activity.length)}{" "}
                <span>This week</span>
              </small>
            </>
          ) : (
            <p className="portfolio-unavailable-note">
              学习活动暂不可用
            </p>
          )}
        </details>
      </div>
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
              {
                projectId: project.id,
                destination: project.nextDecision.destination,
              },
              openProject,
              openSync,
            )
          }
        >
          {project.nextDecision.destination.section === "sync"
            ? "查看同步问题"
            : project.nextDecision.destination.tab === "reviews" ? "查看复盘依据"
              : project.nextDecision.destination.tab === "proof" ? "查看学习证据"
                : project.nextDecision.destination.tab === "practice" ? "查看练习安排"
                  : project.nextDecision.destination.tab === "plan" ? "查看计划" : "查看下一步"}
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
        <small>{attentionLabel(item.label)}</small>
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
          <span className="mini-label">练习、证据与复盘记录</span>
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
            <strong>{segment.minutes}m</strong>
          </li>
        ))}
        {capacity.warningSegment && (
          <li className="capacity-overage-legend">
            <i />
            <span>{capacity.warningSegment.label}</span>
            <strong>Over capacity by {capacity.warningSegment.minutes}m</strong>
          </li>
        )}
      </ul>
      <p className="sr-only">{capacity.accessibleSummary}</p>
    </article>
  );
}

function DashboardHeader({
  asOf,
  timeZone,
  period,
  setPeriod,
}: {
  asOf: string;
  timeZone: string;
  period: DashboardPeriod;
  setPeriod: (period: DashboardPeriod) => void;
}) {
  return (
    <header className="portfolio-header">
      <div>
        <p className="date-line">{Number.isFinite(Date.parse(asOf)) ? new Intl.DateTimeFormat("zh-CN", { month: "long", day: "numeric", weekday: "long", timeZone }).format(new Date(asOf)) : "日期暂不可用"}</p>
        <h2>学习总览</h2>
        <p>查看项目的下一步，在 iPhone 上练习，再回来整理计划与复盘。</p>
      </div>
      <div className="portfolio-period" aria-label="Dashboard period">
        <span className="period-label">统计范围</span>
        {periods.map((item) => (
          <button
            className={period === item.id ? "active" : ""}
            aria-pressed={period === item.id}
            key={item.id}
            onClick={() => setPeriod(item.id)}
          >
            {attentionLabel(item.label)}
          </button>
        ))}
      </div>
    </header>
  );
}

function DashboardLoading({
  asOf,
  timeZone,
}: {
  asOf: string;
  timeZone: string;
}) {
  return (
    <div
      className="portfolio-dashboard page-stack"
      aria-busy="true"
      aria-label="Loading Dashboard"
    >
      <header className="portfolio-header portfolio-skeleton">
        <div>
          <p className="date-line">{Number.isFinite(Date.parse(asOf)) ? new Intl.DateTimeFormat("zh-CN", { month: "long", day: "numeric", weekday: "long", timeZone }).format(new Date(asOf)) : "日期暂不可用"}</p>
          <span className="skeleton-line wide" />
          <span className="skeleton-line" />
        </div>
      </header>
      <section className="portfolio-pulse portfolio-skeleton" aria-hidden="true">
        {Array.from({ length: 4 }, (_, index) => (
          <div className="portfolio-pulse-card" key={index} />
        ))}
      </section>
      <section
        className="portfolio-project-card portfolio-skeleton"
        aria-hidden="true"
      >
        <span className="skeleton-line wide" />
        <span className="skeleton-block" />
      </section>
      <p className="sr-only">Loading portfolio snapshot.</p>
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

function decisionActionLabel(item: AttentionItem) {
  if (item.destination.section === "sync") return "查看同步问题";
  if (item.kind === "review") return "查看复盘依据";
  return "查看下一步";
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
    () =>
      snapshot ??
      createDashboardSnapshot({
        asOf: initialAsOf,
        demos: projectDemos,
      }),
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
        <DashboardHeader
          asOf={model.asOf}
          timeZone={initialTimeZone}
          period={period}
          setPeriod={setPeriod}
        />
        <section className="card portfolio-error-state" role="alert">
          <span className="mini-label">数据读取失败</span>
          <h3>学习总览加载失败</h3>
          <p>{model.errorMessage}</p>
          <button className="secondary-button" onClick={openSync}>
            查看同步问题
          </button>
        </section>
      </div>
    );
  }

  const primaryDecision = model.decisions[0];
  const evidenceValue =
    model.pulse.evidenceReady === null ||
    model.pulse.evidenceExpected === null
      ? "Unavailable"
      : `${model.pulse.evidenceReady} / ${model.pulse.evidenceExpected}`;

  return (
    <div className="portfolio-dashboard page-stack">
      {provenance && <div className="portfolio-provenance" role="status">{provenance}</div>}
      <DashboardHeader
        asOf={model.asOf}
        timeZone={initialTimeZone}
        period={period}
        setPeriod={setPeriod}
      />
      {model.loadState === "partial" && (
        <section className="portfolio-state-banner partial" role="status">
          <strong>部分数据暂不可用</strong>
          <span>
            {model.unavailableSections
              .map((section) => unavailableLabels[section])
              .join(", ")}{" "}
            暂不可用，已读取的项目仍可查看。
          </span>
        </section>
      )}
      {model.loadState === "conflict" && (
        <section className="portfolio-state-banner conflict" role="alert">
          <div>
            <strong>{model.conflicts[0]?.label ?? "Sync conflict"}</strong>
            <span>
              这里保留最近可信的数据。打开同步页面，选择要保留的版本。
            </span>
          </div>
          <button className="secondary-button" onClick={openSync}>
            查看同步问题
          </button>
        </section>
      )}
      {model.projects.length > 0 && (
        <section className="start-here" aria-labelledby="start-here-heading">
          <div>
            <span className="mini-label">从这里开始</span>
            <h3 id="start-here-heading">{primaryDecision ? "有一项学习决定等你确认" : "继续推进一个学习项目"}</h3>
            <p>{primaryDecision?.projectName ?? model.projects[0].name}</p>
            <small>{primaryDecision?.detail ?? model.projects[0].nextDecision.detail}</small>
          </div>
          <button className="primary-button" onClick={() => primaryDecision
            ? openDestination(primaryDecision, openProject, openSync)
            : openProject(model.projects[0].id, model.projects[0].nextDecision.tab)}>
            {primaryDecision ? decisionActionLabel(primaryDecision) : "查看下一步"}<span aria-hidden="true"> →</span>
          </button>
        </section>
      )}
      <section className="portfolio-pulse" aria-label="Portfolio pulse">
        <PulseCard
          label="进行中的项目"
          value={`${model.pulse.activeProjects}`}
          detail="正在推进的学习项目"
        />
        <PulseCard
          label="已收集证据"
          value={evidenceValue}
          detail="已收集 / 本阶段目标"
        />
        <PulseCard
          label="待复盘"
          value={`${model.pulse.reviewsReady}`}
          detail="查看依据后再做决定"
        />
        <PulseCard
          label="待处理"
          value={`${model.pulse.needsAttention}`}
          detail="含上方待确认事项"
          attention
        />
      </section>
      <div className="portfolio-main-grid">
        <section aria-labelledby="portfolio-projects-heading">
          <div className="section-heading">
            <h3 id="portfolio-projects-heading">进行中的项目</h3>
            {model.totalActiveProjects > 0 && (
              <button className="text-button" onClick={openProjects}>
                查看全部 {model.totalActiveProjects} 个项目
              </button>
            )}
          </div>
          {model.projects.length > 0 ? (
            <div className="portfolio-project-list">
              {model.projects.map((project) => (
                <PortfolioProjectCard
                  project={project}
                  openProject={openProject}
                  openSync={openSync}
                  key={project.id}
                />
              ))}
            </div>
          ) : (
            <div className="portfolio-empty-state">
              <h3>还没有进行中的项目</h3>
              <p>
                可先查看已有项目，或在 iPhone 上创建第一个学习项目。
              </p>
              <div className="portfolio-empty-actions">
                <button className="primary-button" onClick={openProjects}>
                  查看项目
                </button>
                <button className="secondary-button" onClick={openProjects}>
                  查看全部项目
                </button>
              </div>
            </div>
          )}
        </section>
        <aside aria-labelledby="portfolio-decisions-heading">
          <div className="section-heading">
            <h3 id="portfolio-decisions-heading">待处理事项</h3>
            <button className="text-button" onClick={openReviews}>
              全部复盘
            </button>
          </div>
          <p className="section-description">打开一项，查看原因和可采取的行动。</p>
          <article className="portfolio-attention-card">
            <span className="sr-only">待处理</span>
            {model.attention.length > 0 ? (
              model.attention.map((item) => (
                <AttentionRow
                  item={item}
                  openProject={openProject}
                  openSync={openSync}
                  key={item.id}
                />
              ))
            ) : (
              <p className="portfolio-empty-note">
                目前没有其他待处理事项。
              </p>
            )}
          </article>
        </aside>
      </div>
      {model.loadState !== "empty" && (
        <details className="portfolio-insights">
          <summary>查看学习趋势与时间安排<span>按当前统计范围展示</span></summary>
          <section className="portfolio-lower-grid">
          {model.movement ? (
            <PortfolioMovementMatrix movement={model.movement} />
          ) : (
            <UnavailableVisualization section="activity" />
          )}
          {model.capacity ? (
            <CapacityAllocation capacity={model.capacity} />
          ) : (
            <UnavailableVisualization section="capacity" />
          )}
          </section>
        </details>
      )}
    </div>
  );
}
