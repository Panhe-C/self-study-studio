# Task 2 Report: Portfolio Dashboard UI and Navigation

## Result

Implemented the Task 1 portfolio selector model in the Web dashboard, replaced the old inline single-project Dashboard, connected portfolio actions to workspace navigation, and kept the Dashboard read-only.

Commit:

- `b2bd16242fd809c35bd732afd12209c02f25c50b` — `feat(web): render portfolio dashboard cards`

## Files changed

- `WebWorkspace/app/portfolio-dashboard.tsx`
  - Added the focused `PortfolioDashboard` client component.
  - Added portfolio pulse cards, active Project cards, decision and attention panels, movement matrix, capacity allocation, and period controls.
  - Consumes `derivePortfolioDashboard(projectDemos, period)` without mutating journal data.
- `WebWorkspace/app/workspace-app.tsx`
  - Mounted `PortfolioDashboard` for the Dashboard section.
  - Removed the old inline `Dashboard` implementation.
  - Connected Project, Projects, and Reviews actions to existing workspace sections.
  - Made `openProject` one atomic state update so the selected Project and requested tab are not discarded by batched React state replacements.
  - Retained `formatMinutes` because Plan and draft views still use it.
- `WebWorkspace/tests/demo-data.test.mjs`
  - Added the required focused-module boundary assertions.
  - Added a regression assertion for atomic Project/tab navigation.
- `WebWorkspace/tests/rendered-html.test.mjs`
  - Replaced the legacy Dashboard copy checks with portfolio hierarchy, Project, decision, movement, capacity, meaningful-event, and anti-gamification assertions.

No Task 3 visual styling was added.

## TDD evidence

### RED 1: focused dashboard boundary and rendered output

Command:

```bash
cd WebWorkspace
node --experimental-strip-types --test tests/demo-data.test.mjs tests/rendered-html.test.mjs
```

Result: exit `1`.

```text
tests 5
pass 3
fail 2
```

Expected failures observed:

- `portfolio-dashboard.tsx` did not exist (`ENOENT`).
- The legacy server render did not contain `Your learning portfolio`.

### GREEN 1: focused dashboard boundary and rendered output

Commands:

```bash
cd WebWorkspace
npm run build
node --experimental-strip-types --test tests/demo-data.test.mjs tests/rendered-html.test.mjs
```

Results:

```text
Build complete.
tests 5
pass 5
fail 0
```

### RED 2: navigation regression found during self-review

Command:

```bash
cd WebWorkspace
node --experimental-strip-types --test tests/demo-data.test.mjs
```

Result: exit `1`.

```text
tests 4
pass 3
fail 1
```

Expected failure observed: `openProject` still used three independent state replacements instead of preserving the requested Project and tab in one navigation update.

### GREEN 2: atomic Project/tab navigation

Command:

```bash
cd WebWorkspace
node --experimental-strip-types --test tests/demo-data.test.mjs
```

Result:

```text
tests 4
pass 4
fail 0
```

## Final verification

Command:

```bash
cd WebWorkspace
npm test
```

Result: exit `0`; the Vinext production build completed and all tests passed.

```text
tests 15
pass 15
fail 0
```

Command:

```bash
cd WebWorkspace
npm run lint
```

Result: exit `0`; ESLint reported no errors or warnings.

Command:

```bash
git diff --cached --check
```

Result: exit `0`; no whitespace errors.

The committed path list contained exactly:

```text
WebWorkspace/app/portfolio-dashboard.tsx
WebWorkspace/app/workspace-app.tsx
WebWorkspace/tests/demo-data.test.mjs
WebWorkspace/tests/rendered-html.test.mjs
```

## Self-review

- The component boundary matches the plan: selectors remain in `lib/dashboard.ts`, presentation is in `app/portfolio-dashboard.tsx`, and workspace navigation stays in `app/workspace-app.tsx`.
- The approved hierarchy is present in the server-rendered HTML: portfolio header and period, pulse, active Projects, decisions and attention, movement, then capacity.
- Dashboard controls only navigate or change the local reporting period; none writes journal, plan, practice, Proof, Review, or CloudKit state.
- Project actions preserve the target Project and the selector-provided tab through one React state update.
- Empty active-portfolio markup and optional “View all” behavior are retained from the plan.
- Accessible summaries from the Task 1 model are exposed on movement and capacity visualizations.
- Structural class names were added only to support the later styling task; `globals.css` was not changed.
- No unrelated staged file entered the commit.

## Concerns

- The new structural classes intentionally have no Task 3 portfolio-specific visual polish yet; the markup is functional and server-rendered, but final layout and responsive styling remain for Task 3.
- The repository still contains unrelated pre-existing modified and untracked files. They were preserved and were not included in this commit.

---

## Task 2 Review Revision

### Result

Resolved every blocking Task 2 review finding in:

- `293664cfa14d3c04a5de96a10a02009dd9596916` — `fix(web): complete dashboard review contracts`

The revision:

- tracks every WebWorkspace source, configuration file, build plugin, lockfile, test prerequisite, hosting configuration, and required public asset;
- continues to exclude `node_modules`, `dist`, `.next`, `.vinext`, `.wrangler`, secrets, and local `.env` files;
- renders each Project's actual Expected Proof statement beside its Proof readiness;
- exposes complete six-week sparkline sequences and per-week movement labels/counts to screen readers without relying on `title` tooltips;
- renders zero-activity sparkline buckets at exactly `0%` height;
- replaces the formatting-sensitive navigation assertion with a behavioral test of a focused navigation-state helper; and
- asserts the rendered Dashboard hierarchy order.

### Revision RED

Regression assertions were added before the implementation changes.

Command:

```bash
cd WebWorkspace
node --experimental-strip-types --test \
  tests/demo-data.test.mjs \
  tests/rendered-html.test.mjs \
  tests/workspace-navigation.test.mjs \
  tests/webworkspace-foundation.test.mjs
```

Result: exit `1`.

```text
tests 10
pass 4
fail 6
```

The six expected failures covered:

1. `workspace-app.tsx` had not delegated navigation to the focused state helper.
2. The requested `workspace-navigation.ts` module did not exist.
3. Actual Expected Proof statements were absent from the rendered Project cards.
4. Complete accessible sparkline and movement sequences plus hierarchy markers were absent.
5. Zero activity still rendered with the prior `8%` visual floor instead of `0%`.
6. WebWorkspace runtime/test prerequisites were not known to Git.

### Revision GREEN

After the minimal implementation and exact prerequisite staging, the first focused run reached `9/10`; the remaining failure showed that React SSR inserted comment separators between movement text fragments. The movement description was then emitted as one complete string.

Final focused command:

```bash
cd WebWorkspace
npm run build
node --experimental-strip-types --test \
  tests/demo-data.test.mjs \
  tests/rendered-html.test.mjs \
  tests/workspace-navigation.test.mjs \
  tests/webworkspace-foundation.test.mjs
```

Result: exit `0`.

```text
Build complete.
tests 10
pass 10
fail 0
```

### Full revision verification

Command:

```bash
cd WebWorkspace
npm test
```

Result: exit `0`; the Vinext production build completed and the entire test suite passed.

```text
tests 19
pass 19
fail 0
```

Command:

```bash
cd WebWorkspace
npm run lint
```

Result: exit `0`; ESLint reported no errors or warnings.

Command:

```bash
git diff --cached --check
```

Result: exit `0`; no whitespace errors.

The staged-path audit found no `node_modules`, `dist`, `.next`, `.vinext`, `.wrangler`, or local `.env` path. All staged paths were under `WebWorkspace/`.

### Clean-HEAD reproducibility verification

A detached worktree was created from revision commit `293664c`, so it contained only committed files and no local WebWorkspace artifacts.

Commands:

```bash
cd /private/tmp/self-study-task2-clean.T250lT/WebWorkspace
npm ci --offline
npm test
npm run lint
```

Results:

```text
added 496 packages, and audited 497 packages
found 0 vulnerabilities
Build complete.
tests 19
pass 19
fail 0
```

ESLint also exited `0` without errors or warnings. This verifies that the exact committed WebWorkspace foundation installs, builds, renders, tests, and lints from a clean Git worktree.

### Revision self-review

- The Expected Proof copy comes from `ProjectDashboardState.expectedProof`; it is not substituted with an outcome or readiness count.
- Proof readiness remains visible alongside the actual statement and keeps the existing `ready / expected` model.
- Each six-week sparkline has one complete screen-reader sentence mapping all six week labels to counts.
- Each movement row has one complete screen-reader sentence mapping every displayed period bucket to its count.
- Movement cells are visual-only and no longer depend on `title` tooltips for their meaning.
- Zero-count sparkline buckets emit `data-activity-count="0"` and `height:0%`; positive buckets retain proportional heights.
- Portfolio pulse, active Projects, Decisions, movement, and capacity have a rendered order contract using semantic output markers.
- `projectNavigationState` is tested by return value, while the component-boundary test only verifies delegation rather than exact source formatting.
- The tracked-foundation contract enumerates the runtime, build, asset, and test prerequisites and passed both in the working checkout and clean worktree.
- The nested `.gitignore` keeps generated and secret-bearing paths excluded while explicitly allowing the source Vite plugin hidden by the repository-root `build/` rule.
- No root, iOS, documentation, Task 3 styling, generated output, or secret file was included in revision commit `293664c`.

### Remaining concerns

- Task 3 portfolio-specific visual polish remains intentionally unimplemented.
- The tracked-foundation contract intentionally requires a Git checkout because its purpose is to prevent required WebWorkspace prerequisites from becoming untracked again.
- Unrelated pre-existing root and iOS working-tree changes remain untouched.
