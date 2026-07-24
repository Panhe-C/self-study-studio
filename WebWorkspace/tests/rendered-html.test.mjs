import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import test from "node:test";
import { createRunnableDevEnvironment, createServer } from "vite";
import { projectDemos } from "../lib/journal.ts";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

let dashboardServerPromise;

async function dashboardServer() {
  dashboardServerPromise ??= createServer({
    configFile: false,
    root: new URL("..", import.meta.url).pathname,
    appType: "custom",
    server: { middlewareMode: true, hmr: false },
    environments: {
      client: {
        dev: {
          createEnvironment: (name, config) =>
            createRunnableDevEnvironment(name, config, { hot: false }),
        },
      },
    },
  });
  return dashboardServerPromise;
}

async function renderDashboard(props) {
  const server = await dashboardServer();
  const { PortfolioDashboard } = await server.ssrLoadModule(
    "/app/portfolio-dashboard.tsx",
  );
  return renderToStaticMarkup(
    createElement(PortfolioDashboard, {
      openProject() {},
      openProjects() {},
      openReviews() {},
      openSync() {},
      ...props,
    }),
  );
}

test.after(async () => {
  if (dashboardServerPromise) {
    await (await dashboardServerPromise).close();
  }
});

function assertInOrder(input, values) {
  let previousIndex = -1;
  for (const value of values) {
    const currentIndex = input.indexOf(value);
    assert.ok(
      currentIndex > previousIndex,
      `${JSON.stringify(value)} should appear after the previous hierarchy marker`,
    );
    previousIndex = currentIndex;
  }
}

function contrastRatio(foreground, background) {
  const luminance = (hex) => {
    const channels = hex
      .slice(1)
      .match(/.{2}/g)
      .map((channel) => Number.parseInt(channel, 16) / 255)
      .map((channel) =>
        channel <= 0.04045
          ? channel / 12.92
          : ((channel + 0.055) / 1.055) ** 2.4,
      );
    return (
      0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    );
  };

  const foregroundLuminance = luminance(foreground);
  const backgroundLuminance = luminance(background);
  return (
    (Math.max(foregroundLuminance, backgroundLuminance) + 0.05) /
    (Math.min(foregroundLuminance, backgroundLuminance) + 0.05)
  );
}

function cssHexVariable(css, name) {
  const match = css.match(
    new RegExp(`--${name}:\\s*(#[0-9a-f]{6})\\b`, "i"),
  );
  assert.ok(match, `Expected --${name} to be a six-digit hex color`);
  return match[1];
}

test("server-renders the learning workspace", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /aria-label="Portfolio pulse"/);
  assert.match(html, /aria-label="Dashboard period"/);
  assert.match(html, /aria-pressed="true"/);
  assert.match(html, /meaningful activity over 6 weeks/i);
  assert.match(html, /planned minutes of .* available/i);
  assert.match(html, /<title>Self Study Studio — Learning Workspace<\/title>/i);
  assert.match(html, /Your learning portfolio/);
  assert.match(html, /Active Projects/);
  assert.match(html, /Electric guitar improvisation/);
  assert.match(html, /CS336 · Language Modeling from Scratch/);
  assert.match(
    html,
    /A one-minute recording with steady time, 3–5 note phrases, intentional rests, and a natural resolution to A\./,
  );
  assert.match(
    html,
    /A reversible tokenizer with passing fixtures, benchmark notes, and a short explanation of vocabulary tradeoffs\./,
  );
  assert.match(html, /Stage Review is ready/);
  assert.match(html, /Portfolio movement/);
  assert.match(html, /Next 2 weeks capacity/);
  assert.match(html, /meaningful events across 1 week/i);
  assert.doesNotMatch(html, /completion percentage|streak|rank|grade/i);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/i);
});

test("keeps portfolio visualizations responsive and text-equivalent", async () => {
  const [css, dashboard] = await Promise.all([
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../app/portfolio-dashboard.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(css, /\.portfolio-main-grid/);
  assert.match(css, /\.portfolio-lower-grid/);
  assert.match(css, /@media \(max-width: 820px\)[\s\S]*\.portfolio-main-grid/);
  assert.match(css, /\.sr-only/);
  assert.match(dashboard, /accessibleSummary/);
  const forbiddenMovementScroll =
    /\.movement-matrix\s*\{[^}]*overflow-x:\s*(?:auto|scroll)\b/;
  assert.match(
    ".movement-matrix { overflow-x: auto; }",
    forbiddenMovementScroll,
  );
  assert.doesNotMatch(css, forbiddenMovementScroll);
});

test("keeps every narrow Dashboard action at least 44 pixels", async () => {
  const css = await readFile(
    new URL("../app/globals.css", import.meta.url),
    "utf8",
  );
  const narrowRules = css.match(
    /@media \(max-width: 540px\) \{([\s\S]*?)\n\}/,
  )?.[1];

  assert.ok(narrowRules, "Expected the 540px responsive rules");
  assert.match(
    narrowRules,
    /\.portfolio-period button\s*\{[^}]*min-height:\s*44px/,
  );
  assert.match(
    narrowRules,
    /\.portfolio-dashboard \.text-button\s*\{[^}]*min-height:\s*44px/,
  );
  assert.match(
    narrowRules,
    /\.portfolio-dashboard \.portfolio-empty-state \.secondary-button\s*\{[^}]*min-height:\s*44px/,
  );
  assert.match(
    narrowRules,
    /\.portfolio-decision-card button\s*\{[^}]*min-height:\s*44px/,
  );
  assert.match(
    narrowRules,
    /\.portfolio-project-card > footer \.secondary-button\s*\{[^}]*min-height:\s*44px/,
  );
  assert.match(
    css,
    /\.portfolio-attention-row\s*\{[^}]*min-height:\s*52px/,
  );
  assert.match(
    narrowRules,
    /\.workspace-shell:has\(\.portfolio-dashboard\) \.topbar-actions button\s*\{[^}]*min-width:\s*44px;[^}]*min-height:\s*44px/,
  );
});

test("uses readable Portfolio status colors for small text", async () => {
  const css = await readFile(
    new URL("../app/globals.css", import.meta.url),
    "utf8",
  );
  const faintText = cssHexVariable(css, "portfolio-faint-text");
  const greenText = cssHexVariable(css, "portfolio-green-text");
  const amberText = cssHexVariable(css, "portfolio-amber-text");

  assert.ok(contrastRatio(faintText, "#ffffff") >= 4.5);
  assert.ok(contrastRatio(greenText, "#e6f1ec") >= 4.5);
  assert.ok(contrastRatio(amberText, "#fbf1df") >= 4.5);
  assert.match(
    css,
    /\.portfolio-pulse-card > span\s*\{[^}]*color:\s*var\(--portfolio-faint-text\)/,
  );
  assert.match(
    css,
    /\.portfolio-activity > small\s*\{[^}]*color:\s*var\(--portfolio-faint-text\)/,
  );
  assert.match(
    css,
    /\.portfolio-state\s*\{[^}]*color:\s*var\(--portfolio-green-text\)/,
  );
  assert.match(
    css,
    /\.portfolio-state\.attention\s*\{[^}]*color:\s*var\(--portfolio-amber-text\)/,
  );
});

test("gives Dashboard controls a high-contrast focus indicator", async () => {
  const css = await readFile(
    new URL("../app/globals.css", import.meta.url),
    "utf8",
  );

  assert.match(
    css,
    /\.portfolio-dashboard button:focus-visible,[\s\S]*?\.workspace-shell:has\(\.portfolio-dashboard\) \.topbar-actions button:focus-visible\s*\{[^}]*outline:\s*3px solid #1d4ed8;[^}]*outline-offset:\s*3px;[^}]*box-shadow:\s*0 0 0 2px #fff/,
  );
  assert.ok(contrastRatio("#1d4ed8", "#ffffff") >= 3);
});

test("server-renders complete accessible activity sequences in hierarchy order", async () => {
  const html = await renderDashboard({
    clock: () => new Date("2026-07-24T12:00:00Z"),
  });

  assert.match(
    html,
    /Electric guitar improvisation meaningful activity over 6 weeks: 5 weeks ago: 0; 4 weeks ago: 0; 3 weeks ago: 0; 2 weeks ago: 0; 1 week ago: 1; This week: 3 meaningful events\./,
  );
  assert.match(
    html,
    /CS336 · Language Modeling from Scratch meaningful activity over 6 weeks: 5 weeks ago: 0; 4 weeks ago: 0; 3 weeks ago: 1; 2 weeks ago: 0; 1 week ago: 1; This week: 2 meaningful events\./,
  );
  assert.match(
    html,
    /Electric guitar improvisation weekly movement: This week: 3 meaningful events\./,
  );
  assert.match(
    html,
    /CS336 · Language Modeling from Scratch weekly movement: This week: 2 meaningful events\./,
  );
  assert.doesNotMatch(html, /title="(?:This week|\d+ weeks? ago): \d+ meaningful events"/);

  assertInOrder(html, [
    'aria-label="Portfolio pulse"',
    'id="portfolio-projects-heading"',
    'id="portfolio-decisions-heading"',
    ">Portfolio movement<",
    ">Next 2 weeks capacity<",
  ]);
});

test("server-renders zero activity buckets at zero height", async () => {
  const html = await (await render()).text();

  assert.match(html, /data-activity-count="0" style="height:0%"/);
  assert.doesNotMatch(html, /data-activity-count="0" style="height:(?!0%)[^"]+"/);
});

test("server-renders the injected clock, overload warning segment, and capacity attention", async () => {
  const demos = structuredClone(projectDemos);
  demos[1].capacity.plannedMinutes = 600;
  demos[1].capacity.availableMinutes = 300;
  const clockHtml = await renderDashboard({
    clock: () => new Date("2026-07-24T12:00:00Z"),
  });
  const html = await renderDashboard({
    snapshot: {
      loadState: "ready",
      asOf: "2026-07-24T12:00:00Z",
      demos,
      unavailableSections: [],
      conflicts: [],
    },
  });

  assert.match(clockHtml, /Friday, July 24/);
  assert.match(html, /Capacity exceeds availability/);
  assert.match(html, /class="capacity-overage-segment"/);
  assert.match(html, /Over capacity by 270m/);
  assert.match(html, /Planned capacity needs a decision/);
});

test("server-renders empty, partial, conflict, loading, and error snapshot states", async () => {
  const base = {
    asOf: "2026-07-24T12:00:00Z",
    unavailableSections: [],
    conflicts: [],
  };
  const [empty, partial, conflict, loading, error] = await Promise.all([
    renderDashboard({
      snapshot: { ...base, loadState: "empty", demos: [] },
    }),
    renderDashboard({
      snapshot: {
        ...base,
        loadState: "partial",
        demos: projectDemos,
        unavailableSections: ["capacity"],
      },
    }),
    renderDashboard({
      snapshot: {
        ...base,
        loadState: "conflict",
        demos: projectDemos,
        conflicts: [
          {
            id: "conflict-1",
            projectId: projectDemos[0].project.id,
            label: "Plan revision conflict",
            detail: "Choose the canonical revision.",
            detectedAt: "2026-07-24T10:00:00Z",
          },
        ],
      },
    }),
    renderDashboard({
      snapshot: {
        loadState: "loading",
        asOf: "2026-07-24T12:00:00Z",
      },
    }),
    renderDashboard({
      snapshot: {
        loadState: "error",
        asOf: "2026-07-24T12:00:00Z",
        message: "Snapshot unavailable",
      },
    }),
  ]);

  assert.match(empty, /Create Project/);
  assert.match(empty, /View archive/);
  assert.match(partial, /Some Dashboard data is unavailable/);
  assert.match(partial, /Capacity data unavailable/);
  assert.match(conflict, /Plan revision conflict/);
  assert.match(conflict, /Open Sync &amp; conflicts/);
  assert.match(loading, /aria-busy="true"/);
  assert.match(loading, /portfolio-skeleton/);
  assert.match(error, /Dashboard unavailable/);
  assert.match(error, /Snapshot unavailable/);
});

test("removes disposable starter UI and keeps CloudKit explicit", async () => {
  const [page, layout, packageJson, cloudKit, hosting] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
    readFile(new URL("../lib/cloudkit.ts", import.meta.url), "utf8"),
    readFile(new URL("../.openai/hosting.json", import.meta.url), "utf8"),
  ]);

  await assert.rejects(access(new URL("../app/_sites-preview", import.meta.url)));
  assert.doesNotMatch(page, /_sites-preview|SkeletonPreview/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.match(layout, /cdn\.apple-cloudkit\.com\/ck\/2\/CloudKit\.js/);
  assert.match(cloudKit, /iCloud\.com\.local\.selfstudystudio/);
  assert.match(cloudKit, /LearningJournalZone/);
  assert.match(cloudKit, /privateCloudDatabase\.fetchRecordZoneChanges/);
  assert.match(cloudKit, /recordChangeTag/);
  assert.doesNotMatch(cloudKit, /localStorage|sessionStorage/);
  assert.deepEqual(JSON.parse(hosting), {
    project_id: "appgprj_6a608f56ab788191bb01c63223d30116",
    d1: null,
    r2: null,
  });
  assert.match(layout, /app-icon\.png/);
  assert.match(packageJson, /"name": "self-study-studio-web"/);
  assert.match(page, /WorkspaceApp/);
  assert.match(await readFile(new URL("../.env.example", import.meta.url), "utf8"), /NEXT_PUBLIC_CLOUDKIT_API_TOKEN=/);
  assert.ok((await access(new URL("../public/app-icon.png", import.meta.url))) === undefined);
  assert.match(
    await readFile(new URL("../README.md", import.meta.url), "utf8"),
    /Self Study Studio Web Workspace/,
  );
});
