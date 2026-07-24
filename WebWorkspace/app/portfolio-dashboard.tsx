"use client";

import { useMemo, useState, type CSSProperties } from "react";
import {
  createDashboardSnapshot,
  derivePortfolioDashboard,
  formatDashboardDate,
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
};

const periods: Array<{ id: DashboardPeriod; label: string }> = [
  { id: "now", label: "Now" },
  { id: "4w", label: "4 weeks" },
  { id: "12w", label: "12 weeks" },
];

const unavailableLabels: Record<DashboardSection, string> = {
  evidence: "Proof readiness",
  activity: "Meaningful activity",
  capacity: "Capacity",
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
          {project.status}
        </span>
      </header>
      <div className="portfolio-project-body">
        <div>
          <span className="mini-label">Active Phase</span>
          <h5>{project.activePhase?.title ?? "No active Phase"}</h5>
          <p className="portfolio-outcome">{project.outcome}</p>
          <div className="portfolio-expected-proof">
            <span className="mini-label">Expected Proof</span>
            <p>{project.expectedProof}</p>
          </div>
          {project.evidence ? (
            <div className="portfolio-evidence">
              <div>
                <span>Proof readiness</span>
                <strong>
                  {project.evidence.ready} of {project.evidence.expected} signals
                  ready
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
              Proof readiness unavailable
            </p>
          )}
        </div>
        <div className="portfolio-activity">
          <span className="mini-label">Meaningful activity</span>
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
              Meaningful activity unavailable
            </p>
          )}
        </div>
      </div>
      <footer>
        <div>
          <span className="mini-label">Next decision</span>
          <strong>{project.nextDecision.label}</strong>
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
            ? "Open Sync & conflicts"
            : "Open Project"}
        </button>
      </footer>
    </article>
  );
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
        <small>{item.label}</small>
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
          <span className="mini-label">Meaningful events only</span>
          <h3>Portfolio movement</h3>
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
          <span className="mini-label">Planned allocation</span>
          <h3>Next 2 weeks capacity</h3>
        </div>
      </div>
      {capacity.warning && (
        <div className="capacity-warning" role="status">
          <strong>Capacity exceeds availability</strong>
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
        <p className="date-line">{formatDashboardDate(asOf, timeZone)}</p>
        <h2>Your learning portfolio</h2>
        <p>See where every active Project stands and what needs a decision.</p>
      </div>
      <div className="portfolio-period" aria-label="Dashboard period">
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
          <p className="date-line">{formatDashboardDate(asOf, timeZone)}</p>
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
      <span className="mini-label">Partial snapshot</span>
      <h3>{unavailableLabels[section]} data unavailable</h3>
      <p>Available Project state remains visible; this section is not estimated.</p>
    </article>
  );
}

function decisionActionLabel(item: AttentionItem) {
  if (item.destination.section === "sync") return "Open Sync & conflicts";
  if (item.kind === "review") return "Start Stage Review";
  return "Open Project";
}

export function PortfolioDashboard({
  openProject,
  openProjects,
  openReviews,
  openSync,
  initialAsOf,
  initialTimeZone,
  snapshot,
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
      <DashboardLoading asOf={model.asOf} timeZone={initialTimeZone} />
    );
  }

  if (model.loadState === "error") {
    return (
      <div className="portfolio-dashboard page-stack">
        <DashboardHeader
          asOf={model.asOf}
          timeZone={initialTimeZone}
          period={period}
          setPeriod={setPeriod}
        />
        <section className="card portfolio-error-state" role="alert">
          <span className="mini-label">Snapshot error</span>
          <h3>Dashboard unavailable</h3>
          <p>{model.errorMessage}</p>
          <button className="secondary-button" onClick={openSync}>
            Open Sync & conflicts
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
      <DashboardHeader
        asOf={model.asOf}
        timeZone={initialTimeZone}
        period={period}
        setPeriod={setPeriod}
      />
      {model.loadState === "partial" && (
        <section className="portfolio-state-banner partial" role="status">
          <strong>Some Dashboard data is unavailable</strong>
          <span>
            {model.unavailableSections
              .map((section) => unavailableLabels[section])
              .join(", ")}{" "}
            is shown as unavailable, not estimated.
          </span>
        </section>
      )}
      {model.loadState === "conflict" && (
        <section className="portfolio-state-banner conflict" role="alert">
          <div>
            <strong>{model.conflicts[0]?.label ?? "Sync conflict"}</strong>
            <span>
              Last trusted Project data remains visible until you choose the
              canonical state.
            </span>
          </div>
          <button className="secondary-button" onClick={openSync}>
            Open Sync & conflicts
          </button>
        </section>
      )}
      <section className="portfolio-pulse" aria-label="Portfolio pulse">
        <PulseCard
          label="Active Projects"
          value={`${model.pulse.activeProjects}`}
          detail="Projects with an active Phase"
        />
        <PulseCard
          label="Evidence ready"
          value={evidenceValue}
          detail="Expected Proof signals"
        />
        <PulseCard
          label="Reviews ready"
          value={`${model.pulse.reviewsReady}`}
          detail="Decisions waiting"
        />
        <PulseCard
          label="Needs attention"
          value={`${model.pulse.needsAttention}`}
          detail="Actionable items"
          attention
        />
      </section>
      <div className="portfolio-main-grid">
        <section aria-labelledby="portfolio-projects-heading">
          <div className="section-heading">
            <h3 id="portfolio-projects-heading">Active Projects</h3>
            {model.hasMoreProjects && (
              <button className="text-button" onClick={openProjects}>
                View all {model.totalActiveProjects}
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
              <h3>No active Projects</h3>
              <p>
                Paused, Completed, and Abandoned Projects remain in the archive.
              </p>
              <div className="portfolio-empty-actions">
                <button className="primary-button" onClick={openProjects}>
                  Create Project
                </button>
                <button className="secondary-button" onClick={openProjects}>
                  View archive
                </button>
              </div>
            </div>
          )}
        </section>
        <aside aria-labelledby="portfolio-decisions-heading">
          <div className="section-heading">
            <h3 id="portfolio-decisions-heading">Decisions</h3>
            <button className="text-button" onClick={openReviews}>
              Review inbox
            </button>
          </div>
          {primaryDecision ? (
            <article className="portfolio-decision-card">
              <span className="mini-label">
                {primaryDecision.kind === "review"
                  ? "Review ready"
                  : "Decision needed"}
              </span>
              <h3>{primaryDecision.projectName}</h3>
              <p>{primaryDecision.detail}</p>
              <button
                onClick={() =>
                  openDestination(primaryDecision, openProject, openSync)
                }
              >
                {decisionActionLabel(primaryDecision)}
              </button>
              <small>
                {primaryDecision.kind === "review"
                  ? "Nothing advances until you publish."
                  : "The Dashboard remains read-only."}
              </small>
            </article>
          ) : (
            <p className="portfolio-empty-note">
              No explicit decision is waiting.
            </p>
          )}
          <article className="portfolio-attention-card">
            <h3>Needs attention</h3>
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
                No additional attention items.
              </p>
            )}
          </article>
        </aside>
      </div>
      {model.loadState !== "empty" && (
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
      )}
    </div>
  );
}
