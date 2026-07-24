# Final Dashboard Semantics Fix Report

## Result

Closed the Important 1–6 Dashboard review findings without changing CloudKit or
the native app. The Dashboard remains read-only and has no new runtime
dependencies.

The final implementation now:

- injects one `asOf`/clock value into derivation and rendering, formats the
  header date from that same instant, and derives the latest meaningful time
  from canonical Trail events;
- shows the active Phase description as the Phase outcome and the real Project
  lifecycle status;
- derives a Project's Next Decision from the same ordered attention items used
  by the portfolio, so Carryover is not overwritten by a generic Proof gap;
- introduces a discriminated `DashboardSnapshot` boundary with reachable
  `ready`, `empty`, `large`, `partial`, `conflict`, `loading`, and `error`
  states;
- keeps trusted Project data visible for conflicts, links conflicts to
  `Sync & conflicts`, labels partial sections instead of estimating them, and
  offers both `Create Project` and `View archive` in the empty state;
- derives conflict, Phase-boundary Proof, capacity, and Practice Marker
  attention only when the snapshot/domain model supplies enough evidence;
- selects the top eight active Projects by explicit decision, severity, age,
  and stable Project id;
- keeps additional ready Reviews visible after the primary decision is chosen;
- defines Needs Attention as the number of distinct involved Projects;
- makes `Now`, `4 weeks`, and `12 weeks` use 1, 4, and 12 activity buckets;
- normalizes movement intensity against the maximum count in the complete
  visible Project-by-period matrix;
- gives over-capacity and zero-availability states explicit summaries,
  a warning treatment, a visual overage segment, and a capacity attention item.

## Files changed

- `WebWorkspace/lib/dashboard.ts`
- `WebWorkspace/lib/journal.ts`
- `WebWorkspace/app/portfolio-dashboard.tsx`
- `WebWorkspace/app/workspace-app.tsx`
- `WebWorkspace/app/globals.css`
- `WebWorkspace/tests/dashboard.test.mjs`
- `WebWorkspace/tests/rendered-html.test.mjs`
- `.superpowers/sdd/final-dashboard-fix-report.md`

No CloudKit file was modified.

## Root causes

1. The original selector used a fixed `DASHBOARD_REFERENCE_TIME` and duplicated
   `lastMeaningfulActivityAt` outside the canonical Trail.
2. The card mapped the Project goal into the Phase outcome slot and replaced the
   Project lifecycle status with an inferred `Attention`/`On course` label.
3. Card decisions and portfolio attention were derived independently, allowing
   missing Proof to mask Carryover.
4. The component read `projectDemos` directly, so non-ready load states had no
   data boundary.
5. The first eight input Projects were sliced before priority ordering.
6. `Now` and `4 weeks` both produced four buckets, and matrix intensity used an
   absolute event-count clamp.
7. Over-capacity minutes were calculated but not represented in copy, a warning
   segment, or attention.
8. All Review items were removed from the attention list after only one Review
   was selected as the primary decision.

## TDD evidence

### RED — domain and selector behaviors

Command:

```bash
cd WebWorkspace
node --experimental-strip-types --test tests/dashboard.test.mjs
```

Observed before implementation:

```text
tests 10
pass 2
fail 8
```

Expected failures covered the Phase outcome/status, canonical meaningful time,
snapshot boundary, source-backed attention kinds, additional Reviews, top-eight
priority, distinct periods/relative intensity, and explicit capacity overload.

### RED — SSR states and overload

Command:

```bash
cd WebWorkspace
node --experimental-strip-types --test \
  --test-name-pattern='server-renders the injected clock|server-renders empty' \
  tests/rendered-html.test.mjs
```

Observed before implementation:

```text
tests 2
pass 0
fail 2
```

The rendered component still showed the fixed `Wednesday, July 23`, ignored the
injected snapshot, omitted overload treatment, and could not render empty,
partial, conflict, loading, or error states.

### RED — exact top-eight age comparator

Command:

```bash
cd WebWorkspace
node --experimental-strip-types --test \
  --test-name-pattern='highest-severity attention age' \
  tests/dashboard.test.mjs
```

Observed before the comparator correction:

```text
tests 1
pass 0
fail 1
```

An older unrelated Trail event incorrectly outranked the actual age of the
highest-severity Review decision.

### GREEN — focused Dashboard regression set

Command:

```bash
cd WebWorkspace
node --experimental-strip-types --test \
  tests/dashboard.test.mjs \
  tests/rendered-html.test.mjs \
  tests/demo-data.test.mjs \
  tests/workspace-navigation.test.mjs
```

Result:

```text
tests 26
pass 26
fail 0
```

### GREEN — complete Web validation

Command:

```bash
cd WebWorkspace
npm test
```

Result:

```text
tests 36
pass 36
fail 0
```

The command includes a fresh production build.

## Additional validation

- `npm run build` — passed.
- `npm run lint` — passed.
- `git diff --check` — passed.
- A scoped search found no CloudKit references in the Dashboard selector,
  component, or Dashboard behavior test.
- The fixed reference-time constant and production
  `lastMeaningfulActivityAt` field are removed.

## Known non-blocking baseline issue

`npx tsc --noEmit` reaches the new Dashboard code cleanly, then reports the two
existing Worker global-type errors below:

```text
worker/index.ts(6,11): error TS2304: Cannot find name 'Fetcher'.
worker/index.ts(7,7): error TS2552: Cannot find name 'D1Database'.
```

The repository's required `npm test` production build and ESLint validation do
not fail on these pre-existing Worker ambient-type declarations. Fixing Worker
types is outside this Dashboard-only scope.
