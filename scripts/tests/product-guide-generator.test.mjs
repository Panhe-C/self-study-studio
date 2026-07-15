import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import test from "node:test";

const repoRoot = path.resolve(import.meta.dirname, "../..");
const generator = path.join(repoRoot, "scripts/generate-product-guide.mjs");

test("validates the shared content and planned output counts", () => {
  const result = spawnSync(
    process.execPath,
    [generator, "--repo-root", repoRoot, "--validate-only"],
    { encoding: "utf8" },
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  const summary = JSON.parse(result.stdout);
  assert.equal(summary.wideSlideCount, 20);
  assert.equal(summary.a4PageCount, 28);
  assert.equal(summary.diagramCount, 10);
  assert.equal(summary.screenshotCount, 9);
  assert.deepEqual(summary.missingOptionalScreenshots, ["export"]);
});

test("reports a path-specific error when a required diagram is missing", () => {
  const result = spawnSync(
    process.execPath,
    [
      generator,
      "--repo-root",
      repoRoot,
      "--validate-only",
      "--simulate-missing",
      "diagrams/product-learning-loop.png",
    ],
    { encoding: "utf8" },
  );

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Missing required asset: diagrams\/product-learning-loop\.png/);
});
