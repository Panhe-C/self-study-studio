# Portfolio Dashboard Visualization Design

**Date:** 2026-07-23  
**Status:** Approved direction, pending written-spec review  
**Scope:** `WebWorkspace` Dashboard only

## 1. Goal

Redesign the Web Dashboard as a cross-project learning portfolio view that answers:

> Where does every active Project stand, and what needs my decision?

The Dashboard should make several active Projects easy to compare without turning learning into a score, streak, or generic productivity report. Project outcomes, expected Proof, Review readiness, and explicit decisions remain the primary signals. Time, frequency, and counts only explain those signals.

## 2. Current Problem

The current Dashboard already uses cards and small visualizations, but most of its content is derived from `projectDemos[0]`. It therefore reads as a detailed view of one Project rather than a portfolio-level Dashboard.

The redesign must:

- aggregate all active Projects;
- preserve each Project's independent Phase and outcome;
- expose Review and attention states across Projects;
- use compact charts to explain movement and capacity;
- keep detailed Plan, Practice, Proof, Trail, and Review work inside the Project Workspace.

## 3. Design Direction

Use a **portfolio card dashboard**, not a Kanban board or analytics wall.

The rejected alternatives are:

1. **Stage Kanban:** easy to scan, but implies that unrelated Project Phases share one workflow and invites drag-and-drop status changes that do not match the domain.
2. **Analytics-first dashboard:** visually dense, but lets time, counts, and streak-like measures displace Proof and decisions as the definition of progress.

## 4. Information Hierarchy

The Dashboard has four levels, in this order:

1. **Portfolio pulse:** a compact summary of current portfolio state.
2. **Active Project cards:** the main comparison surface.
3. **Decisions and attention:** items requiring learner judgment.
4. **Explanatory visualizations:** meaningful activity and upcoming capacity.

This order is stable on desktop and mobile. Responsive layouts may stack sections but must not reorder explanatory charts above Project status or decisions.

## 5. Portfolio Pulse

Show four compact cards:

- **Active Projects:** count of Projects with `Active` status.
- **Evidence Ready:** aggregate count of currently available Proof signals against currently expected Proof signals.
- **Reviews Ready:** count of Stage Reviews ready for inspection or already in draft.
- **Needs Attention:** count of distinct actionable attention items.

Counts summarize state; they are not progress scores. Do not show an overall completion percentage, streak, rank, or grade.

Selecting a pulse card filters or scrolls to the relevant section when that interaction can be implemented without creating a second navigation model. Otherwise the card remains an accessible summary.

## 6. Active Project Cards

Render one card for every active Project. Each card contains:

### Identity

- Project token or icon;
- Project name and area;
- Project status;
- active Phase title and target window.

### Outcome and evidence

- the active Phase outcome;
- the expected Proof summary;
- evidence readiness expressed as a concrete count and labeled track;
- no generic `percent complete`.

The evidence track represents inspectable candidate or accepted Proof signals relevant to the current expected Proof. It must not imply that all Proof automatically qualifies or that the Phase can advance without Review.

### Meaningful activity

Show a small six-week bar sparkline based only on meaningful Journal events:

- completed Learning Sessions;
- saved Practice Summaries;
- created or revised Proof;
- activated Plan revisions;
- published Reviews and Review Decisions;
- Project status decisions.

Exclude navigation, drafts, autosaves, Daily Overrides, sync retries, and other operational noise.

The sparkline shows presence and relative density of meaningful activity. It has no performance score and no “good” or “bad” color scale.

### Next decision

End each card with exactly one contextual line:

- Review ready;
- expected Proof still missing;
- attention marker to inspect;
- next canonical step;
- no current decision.

The primary action opens the relevant Project Workspace tab. The Dashboard does not perform structural Plan changes, accept Qualifying Proof, publish Reviews, or change Project status inline.

## 7. Decisions and Attention

### Decision card

The highest-priority decision appears as a visually prominent card. Stage Review readiness outranks ordinary activity reminders because it can change the Project's direction.

The card includes:

- Project identity;
- the decision being requested;
- source-backed readiness summary;
- action to open the Review Workspace;
- reminder that nothing advances until the learner publishes.

### Attention list

Show a short list of distinct attention items, ordered by consequence and age:

1. sync conflict blocking trusted state;
2. Stage Review ready or draft;
3. unresolved Carryover;
4. expected Proof gap near a Phase boundary;
5. capacity warning;
6. Practice imbalance or Attention Marker;
7. Project without recent meaningful activity.

Do not describe inactivity, imbalance, or Carryover as failure. Each item links to the narrowest relevant view.

## 8. Explanatory Visualizations

### Portfolio movement

Use a Project-by-week activity matrix for the last four weeks. Each cell represents the relative density of meaningful events for that Project during that week.

- Rows are Projects.
- Columns are weeks.
- Color intensity encodes relative event density within the visible portfolio.
- A distinct neutral warning treatment may indicate a quiet Project, but not failure.
- Accessible text must expose the Project, period, and event count.

### Upcoming capacity

Use a stacked horizontal bar for the next two weeks:

- one segment per active Project;
- one remaining-capacity segment;
- an over-capacity treatment only when planned load exceeds declared availability.

The chart explains planned allocation. It does not suggest that more planned time means more progress.

## 9. Period Control

The header provides `Now`, `4 weeks`, and `12 weeks`.

- `Now` is the default and shows the complete decision-oriented Dashboard described above.
- `4 weeks` and `12 weeks` adjust the explanatory visualizations and meaningful-activity context.
- Changing the period must not alter canonical Project state or hide currently actionable Review, conflict, or Carryover items.

For the first implementation slice, period changes may update locally derived demo data, but the component interface must be ready for real CloudKit-backed selectors.

## 10. Component Boundaries

The Dashboard should be decomposed into focused presentation units:

- `PortfolioPulse`
- `ActiveProjectGrid`
- `PortfolioProjectCard`
- `DecisionPanel`
- `AttentionList`
- `PortfolioMovementMatrix`
- `CapacityAllocation`
- `DashboardPeriodControl`

Derivation logic belongs outside React markup:

- `derivePortfolioPulse`
- `deriveProjectDashboardState`
- `deriveAttentionItems`
- `deriveMeaningfulActivityBuckets`
- `deriveCapacityAllocation`

Each selector accepts Journal data and returns display-ready, domain-labeled state. Components must not independently reinterpret Project status, Proof qualification, Review readiness, or meaningful activity.

## 11. Data Flow

1. Load the Journal snapshot from demo data or the CloudKit adapter.
2. Select active Projects and their current Plans, Phases, Proof, Reviews, Sessions, Practice Summaries, conflicts, and capacity inputs.
3. Run pure Dashboard selectors.
4. Render the pulse, Project cards, decisions, attention items, and charts from one derived model.
5. Navigate to the relevant Project Workspace for consequential work.

The Dashboard is read-oriented. It does not introduce new canonical records or a stored Dashboard model.

## 12. Empty, Loading, and Error States

### No active Projects

Show a calm empty state explaining that Paused, Completed, and Abandoned Projects remain in the archive. Offer `Create Project` and `View archive`.

### Partial data

Render available Project cards and label unavailable derived sections. Never substitute fabricated Proof readiness, activity, or capacity data.

### Sync conflict

Keep last trusted local data visible, show conflict status prominently, and link to Sync & Conflicts. Do not silently merge or hide conflicting Projects.

### Loading

Use stable skeleton shapes matching the pulse and Project-card layout. Avoid replacing the full page with a spinner.

### Large portfolios

Show all active Projects up to a practical initial limit of eight cards. Above eight, preserve decision and attention summaries, show the eight highest-priority cards, and provide `View all active Projects`. Priority uses explicit decisions and attention severity, not opaque engagement scoring.

## 13. Responsive Behavior

### Wide desktop

- four-column pulse;
- Project cards in the main column;
- decisions and attention in a narrower right column;
- two explanatory visualizations below.

### Tablet

- two-column pulse;
- Project cards remain full-width;
- decision and attention sections move below the Project grid;
- explanatory charts stack as needed.

### Narrow viewport

- single-column reading order;
- no horizontally scrolling charts;
- activity matrix gains textual row summaries;
- Project-card evidence and next-decision content stays visible;
- secondary labels may shorten, but Project outcome and decision may not disappear.

## 14. Accessibility

- Every chart has an equivalent accessible label or text summary.
- Color is never the only carrier of status.
- Project cards use headings and links/buttons with explicit destinations.
- Focus order follows the visual hierarchy.
- Touch targets remain at least 44 points on touch devices.
- Reduced-motion preferences remove nonessential transitions.
- Status language remains descriptive: `Review ready`, `5 days since meaningful activity`, or `Capacity exceeds availability`, not `behind`, `failed`, or `unproductive`.

## 15. Testing

### Selector tests

- aggregates multiple active Projects instead of selecting the first Project;
- excludes archived Projects from active cards while retaining them in global counts only where explicitly intended;
- counts attention items without duplicate Project warnings;
- buckets only meaningful events;
- preserves Review readiness and Proof qualification semantics;
- handles zero availability and over-capacity safely;
- produces stable priority ordering.

### Render tests

- renders one card per selected active Project;
- shows the correct destination for each card action;
- renders empty, partial-data, loading, conflict, and large-portfolio states;
- exposes accessible chart summaries;
- maintains information order across responsive breakpoints.

### Regression checks

- Dashboard navigation to Project Workspace tabs still works;
- Projects, Reviews, and Sync sections remain unchanged;
- no Dashboard action directly publishes a Review, changes status, or activates a Plan;
- existing demo-data and rendered-HTML tests continue to pass.

## 16. Acceptance Criteria

The redesign is accepted when:

1. the Dashboard derives its main content from all active Projects rather than `projectDemos[0]`;
2. every visible Project card explains its active Phase, outcome, evidence readiness, recent meaningful activity, and next decision;
3. Review and attention items are visible without opening each Project;
4. portfolio movement and capacity are visually comparable without becoming progress scores;
5. time, counts, and frequency remain supporting signals;
6. desktop and narrow layouts preserve the same decision-first hierarchy;
7. automated selector and render tests cover aggregation, semantics, states, navigation, and accessibility.
