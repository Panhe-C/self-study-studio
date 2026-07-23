import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

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

test("server-renders the learning workspace", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Self Study Studio — Learning Workspace<\/title>/i);
  assert.match(html, /Your learning portfolio/);
  assert.match(html, /Active Projects/);
  assert.match(html, /Electric guitar improvisation/);
  assert.match(html, /CS336 · Language Modeling from Scratch/);
  assert.match(html, /Stage Review is ready/);
  assert.match(html, /Portfolio movement/);
  assert.match(html, /Next 2 weeks capacity/);
  assert.match(html, /meaningful events across 4 weeks/i);
  assert.doesNotMatch(html, /completion percentage|streak|rank|grade/i);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/i);
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
