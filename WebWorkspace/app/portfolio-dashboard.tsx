"use client";

import { useMemo, useState, type CSSProperties } from "react";
import {
  derivePortfolioDashboard,
  type AttentionItem,
  type DashboardPeriod,
  type ProjectDashboardState,
} from "../lib/dashboard";
import { projectDemos, type ProjectTab } from "../lib/journal";

type PortfolioDashboardProps = {
  openProject: (id: string, tab?: ProjectTab) => void;
  openProjects: () => void;
  openReviews: () => void;
};

const periods: Array<{ id: DashboardPeriod; label: string }> = [
  { id: "now", label: "Now" },
  { id: "4w", label: "4 weeks" },
  { id: "12w", label: "12 weeks" },
];

function weekLabel(index: number, bucketCount: number) {
  const weeksAgo = bucketCount - 1 - index;
  if (weeksAgo === 0) return "This week";
  return `${weeksAgo} week${weeksAgo === 1 ? "" : "s"} ago`;
}

function movementSummary(
  row: ReturnType<typeof derivePortfolioDashboard>["movement"][number],
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

function PortfolioProjectCard({
  project,
  openProject,
}: {
  project: ProjectDashboardState;
  openProject: PortfolioDashboardProps["openProject"];
}) {
  const maxActivity = Math.max(...project.activity, 1);
  const activitySummary = `${project.name} meaningful activity over ${project.activity.length} weeks: ${project.activity
    .map(
      (count, index) =>
        `${weekLabel(index, project.activity.length)}: ${count}`,
    )
    .join("; ")} meaningful events.`;
  const evidencePercent =
    project.evidence.expected === 0
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
          {project.attention ? "Attention" : "On course"}
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
        </div>
        <div className="portfolio-activity">
          <span className="mini-label">Meaningful activity</span>
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
            {weekLabel(0, project.activity.length)} <span>This week</span>
          </small>
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
          onClick={() => openProject(project.id, project.nextDecision.tab)}
        >
          Open Project
        </button>
      </footer>
    </article>
  );
}

function AttentionRow({
  item,
  openProject,
}: {
  item: AttentionItem;
  openProject: PortfolioDashboardProps["openProject"];
}) {
  return (
    <button
      className="portfolio-attention-row"
      onClick={() => openProject(item.projectId, item.tab)}
    >
      <span className="attention-dot" aria-hidden="true" />
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
  movement: ReturnType<typeof derivePortfolioDashboard>["movement"];
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
          <div
            className="movement-row"
            key={row.projectId}
          >
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
  capacity: ReturnType<typeof derivePortfolioDashboard>["capacity"];
}) {
  return (
    <article className="card portfolio-viz-card">
      <div className="section-heading">
        <div>
          <span className="mini-label">Planned allocation</span>
          <h3>Next 2 weeks capacity</h3>
        </div>
      </div>
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
      <ul className="capacity-legend">
        {capacity.segments.map((segment) => (
          <li key={segment.projectId}>
            <i style={{ background: segment.color }} />
            <span>{segment.label}</span>
            <strong>{segment.minutes}m</strong>
          </li>
        ))}
      </ul>
      <p className="sr-only">{capacity.accessibleSummary}</p>
    </article>
  );
}

export function PortfolioDashboard({
  openProject,
  openProjects,
  openReviews,
}: PortfolioDashboardProps) {
  const [period, setPeriod] = useState<DashboardPeriod>("now");
  const model = useMemo(
    () => derivePortfolioDashboard(projectDemos, period),
    [period],
  );
  const primaryDecision = model.decisions[0];

  return (
    <div className="portfolio-dashboard page-stack">
      <header className="portfolio-header">
        <div>
          <p className="date-line">Wednesday, July 23</p>
          <h2>Your learning portfolio</h2>
          <p>
            See where every active Project stands and what needs a decision.
          </p>
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
      <section className="portfolio-pulse" aria-label="Portfolio pulse">
        <PulseCard
          label="Active Projects"
          value={`${model.pulse.activeProjects}`}
          detail="Projects with an active Phase"
        />
        <PulseCard
          label="Evidence ready"
          value={`${model.pulse.evidenceReady} / ${model.pulse.evidenceExpected}`}
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
          detail="Distinct Projects"
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
              <button className="secondary-button" onClick={openProjects}>
                View Projects and archive
              </button>
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
              <span className="mini-label">Review ready</span>
              <h3>{primaryDecision.projectName}</h3>
              <p>{primaryDecision.detail}</p>
              <button
                onClick={() =>
                  openProject(primaryDecision.projectId, "reviews")
                }
              >
                Start Stage Review
              </button>
              <small>Nothing advances until you publish.</small>
            </article>
          ) : (
            <p className="portfolio-empty-note">
              No Stage Review is waiting.
            </p>
          )}
          <article className="portfolio-attention-card">
            <h3>Needs attention</h3>
            {model.attention.map((item) => (
              <AttentionRow
                item={item}
                openProject={openProject}
                key={item.id}
              />
            ))}
          </article>
        </aside>
      </div>
      <section className="portfolio-lower-grid">
        <PortfolioMovementMatrix movement={model.movement} />
        <CapacityAllocation capacity={model.capacity} />
      </section>
    </div>
  );
}
