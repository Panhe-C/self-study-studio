import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const journalUrl = new URL("../lib/journal.ts", import.meta.url);
const workspaceUrl = new URL("../app/workspace-app.tsx", import.meta.url);

test("includes both user-provided learning plans as structured demo projects", async () => {
  const journal = await readFile(journalUrl, "utf8");

  assert.match(journal, /CS336 20-week Online Self-study Plan/);
  assert.match(journal, /Electric Guitar Improvisation Learning Guide/);
  assert.equal(journal.match(/id: "cs-phase-\d+"/g)?.length, 8);
  assert.equal(journal.match(/id: "guitar-\d+"/g)?.length, 6);
});

test("keeps project-specific plans, routines, proof, trails, and reviews connected", async () => {
  const workspace = await readFile(workspaceUrl, "utf8");

  assert.match(workspace, /<PlanPanel demo=\{demo\}/);
  assert.match(workspace, /<PracticePanel demo=\{demo\}/);
  assert.match(workspace, /<ProofPanel demo=\{demo\}/);
  assert.match(workspace, /<TrailPanel demo=\{demo\}/);
  assert.match(workspace, /<ProjectReviews demo=\{demo\}/);
});

test("keeps portfolio derivation and dashboard presentation in focused modules", async () => {
  const [workspace, dashboard, selectors] = await Promise.all([
    readFile(workspaceUrl, "utf8"),
    readFile(new URL("../app/portfolio-dashboard.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/dashboard.ts", import.meta.url), "utf8"),
  ]);

  assert.match(workspace, /<PortfolioDashboard/);
  assert.doesNotMatch(workspace, /const demo = projectDemos\[0\]/);
  assert.match(dashboard, /derivePortfolioDashboard/);
  assert.match(dashboard, /PortfolioProjectCard/);
  assert.match(dashboard, /PortfolioMovementMatrix/);
  assert.match(selectors, /deriveAttentionItems/);
  assert.match(selectors, /deriveCapacityAllocation/);
});

test("opens a portfolio project and its requested tab in one navigation update", async () => {
  const workspace = await readFile(workspaceUrl, "utf8");

  assert.match(
    workspace,
    /function openProject\(projectId: string, tab: ProjectTab = "overview"\) \{\s+setLocalState\(\{ section: "project", projectId, tab \}\);\s+\}/,
  );
});
