import assert from "node:assert/strict";
import test from "node:test";
import { decodePlanUnits, validatePlanInput } from "../lib/content-progress/plan-provider.ts";
import { GET, POST } from "../app/api/progress-plan/route.ts";

test("plan input uses pasted outline and rejects unread link-only requests", () => {
  assert.deepEqual(validatePlanInput({ name: " 学习 React ", outlineText: "组件目录", courseURL: "https://example.org" }), {
    name: "学习 React", outlineText: "组件目录", courseURL: "https://example.org",
  });
  assert.throws(() => validatePlanInput({ name: "学习 React", outlineText: "", courseURL: "https://example.org" }), /无法安全读取/);
  assert.throws(() => decodePlanUnits({ units: [{ title: "组件", duration: 30 }] }), /Invalid unit shape/);
  assert.deepEqual(decodePlanUnits({ units: [{ title: " 组件 " }] }), ["组件"]);
});

test("same-origin proxy keeps the key out of the provider payload and validates output", async () => {
  const priorEndpoint = process.env.PROGRESS_AI_ENDPOINT;
  const priorModels = process.env.PROGRESS_AI_MODELS;
  const priorFetch = globalThis.fetch;
  process.env.PROGRESS_AI_ENDPOINT = "https://provider.example/v1/chat/completions";
  process.env.PROGRESS_AI_MODELS = "allowed-model";
  let sent;
  globalThis.fetch = async (_url, options) => {
    sent = options;
    return Response.json({ choices: [{ message: { content: JSON.stringify({ units: [{ title: "组件" }] }) } }] });
  };
  try {
    const configuration = await (await GET()).json();
    assert.deepEqual(configuration, { models: ["allowed-model"] });
    const request = new Request("https://studio.example/api/progress-plan", {
      method: "POST",
      headers: { Origin: "https://studio.example", Authorization: "Bearer only-page-memory", "Content-Type": "application/json" },
      body: JSON.stringify({ model: "allowed-model", name: "学习 React", outlineText: "第一章 组件", courseURL: null }),
    });
    const response = await POST(request);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { units: [{ title: "组件" }] });
    assert.equal(sent.headers.Authorization, "Bearer only-page-memory");
    assert.match(sent.body, /第一章 组件/);
    assert.doesNotMatch(sent.body, /only-page-memory|sessions|proofs/);

    const foreign = new Request("https://studio.example/api/progress-plan", {
      method: "POST", headers: { Origin: "https://foreign.example", Authorization: "Bearer only-page-memory" }, body: "{}",
    });
    assert.equal((await POST(foreign)).status, 403);
  } finally {
    globalThis.fetch = priorFetch;
    if (priorEndpoint === undefined) delete process.env.PROGRESS_AI_ENDPOINT;
    else process.env.PROGRESS_AI_ENDPOINT = priorEndpoint;
    if (priorModels === undefined) delete process.env.PROGRESS_AI_MODELS;
    else process.env.PROGRESS_AI_MODELS = priorModels;
  }
});
