import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import test from "node:test";

const run = promisify(execFile);
const repositoryRoot = fileURLToPath(new URL("../../", import.meta.url));

const requiredTrackedFiles = [
  "WebWorkspace/.env.example",
  "WebWorkspace/.gitignore",
  "WebWorkspace/.openai/hosting.json",
  "WebWorkspace/README.md",
  "WebWorkspace/app/globals.css",
  "WebWorkspace/app/layout.tsx",
  "WebWorkspace/app/page.tsx",
  "WebWorkspace/app/portfolio-dashboard.tsx",
  "WebWorkspace/app/workspace-app.tsx",
  "WebWorkspace/build/sites-vite-plugin.ts",
  "WebWorkspace/eslint.config.mjs",
  "WebWorkspace/lib/cloudkit.ts",
  "WebWorkspace/lib/dashboard.ts",
  "WebWorkspace/lib/journal.ts",
  "WebWorkspace/lib/workspace-navigation.ts",
  "WebWorkspace/next.config.ts",
  "WebWorkspace/package-lock.json",
  "WebWorkspace/package.json",
  "WebWorkspace/postcss.config.mjs",
  "WebWorkspace/public/app-icon.png",
  "WebWorkspace/tests/cloudkit-contract.test.mjs",
  "WebWorkspace/tests/dashboard.test.mjs",
  "WebWorkspace/tests/demo-data.test.mjs",
  "WebWorkspace/tests/rendered-html.test.mjs",
  "WebWorkspace/tests/webworkspace-foundation.test.mjs",
  "WebWorkspace/tests/workspace-navigation.test.mjs",
  "WebWorkspace/tsconfig.json",
  "WebWorkspace/vite.config.ts",
  "WebWorkspace/worker/index.ts",
];

test("tracks every source and asset required by the WebWorkspace build and tests", async () => {
  const { stdout } = await run(
    "git",
    ["ls-files", "--error-unmatch", ...requiredTrackedFiles],
    { cwd: repositoryRoot },
  );

  assert.deepEqual(
    stdout.trim().split("\n").sort(),
    [...requiredTrackedFiles].sort(),
  );
});
