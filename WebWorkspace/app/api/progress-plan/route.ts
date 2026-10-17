import { decodePlanUnits, planSystemPrompt, validatePlanInput } from "../../../lib/content-progress/plan-provider.ts";

const maxRequestBytes = 35_000;
const maxResponseBytes = 65_536;
const rateWindowMs = 60_000;
const maxRequestsPerWindow = 10;
const recentRequests = new Map<string, number[]>();

function configuration(): { endpoint: URL; models: string[] } | null {
  const endpointValue = process.env.PROGRESS_AI_ENDPOINT;
  const models = (process.env.PROGRESS_AI_MODELS ?? "").split(",").map((value) => value.trim()).filter(Boolean);
  if (!endpointValue || models.length === 0) return null;
  try {
    const endpoint = new URL(endpointValue);
    if (endpoint.protocol !== "https:" || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) return null;
    if (!endpoint.pathname.endsWith("/chat/completions")) return null;
    return { endpoint, models };
  } catch { return null; }
}

async function readLimited(stream: ReadableStream<Uint8Array> | null, limit: number): Promise<string> {
  if (!stream) return "";
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) throw new Error("Payload too large");
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel().catch(() => undefined);
    throw error;
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

function message(status: number, error: string): Response {
  return Response.json({ error }, { status, headers: { "Cache-Control": "no-store" } });
}

export async function GET(): Promise<Response> {
  const configured = configuration();
  return Response.json({ models: configured?.models ?? [] }, { headers: { "Cache-Control": "no-store" } });
}

export async function POST(request: Request): Promise<Response> {
  const configured = configuration();
  if (!configured) return message(503, "当前未配置 AI 服务，请手动建立学习单元。");
  if (request.headers.get("origin") !== new URL(request.url).origin) return message(403, "Invalid origin");
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || authorization.length <= 7 || authorization.length > 2_055) {
    return message(401, "请在此页面输入 API Key。");
  }
  const key = authorization.slice(7);
  const client = request.headers.get("cf-connecting-ip") ?? request.headers.get("x-forwarded-for") ?? "local";
  const now = Date.now();
  const previous = (recentRequests.get(client) ?? []).filter((instant) => now - instant < rateWindowMs);
  if (previous.length >= maxRequestsPerWindow) return message(429, "生成过于频繁，请稍后重试。");
  previous.push(now);
  recentRequests.set(client, previous);
  if (recentRequests.size > 2_000) recentRequests.clear();

  let payload: Record<string, unknown>;
  try {
    const raw = await readLimited(request.body, maxRequestBytes);
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("Invalid request");
    payload = parsed as Record<string, unknown>;
  } catch { return message(400, "AI 请求格式无效或内容过长。"); }
  const model = payload.model;
  if (typeof model !== "string" || !configured.models.includes(model)) return message(400, "模型不可用。");
  delete payload.model;
  let input;
  try { input = validatePlanInput(payload); }
  catch (error) { return message(422, error instanceof Error ? error.message : "输入无效"); }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    const upstream = await fetch(configured.endpoint, {
      method: "POST",
      redirect: "error",
      signal: controller.signal,
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify({
        model,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: planSystemPrompt },
          { role: "user", content: JSON.stringify({
            name: input.name,
            outlineText: input.outlineText || undefined,
            source: input.outlineText ? "pasted_outline" : "topic",
          }) },
        ],
      }),
    });
    if (upstream.status === 401) return message(401, "API Key 无效，请检查后重试。");
    if (upstream.status === 429) return message(429, "AI 服务繁忙，请稍后重试。");
    if (!upstream.ok) return message(502, "AI 服务暂不可用，请稍后重试。");
    const envelope: unknown = JSON.parse(await readLimited(upstream.body, maxResponseBytes));
    const content = (envelope as { choices?: Array<{ message?: { content?: unknown } }> })?.choices?.[0]?.message?.content;
    if (typeof content !== "string") return message(502, "AI 响应格式无效，请重试。");
    const units = decodePlanUnits(JSON.parse(content));
    return Response.json({ units: units.map((title) => ({ title })) }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (controller.signal.aborted) return message(504, "AI 请求超时，请重试。");
    return message(502, error instanceof SyntaxError ? "AI 响应格式无效，请重试。" : "AI 服务暂不可用，请重试。");
  } finally { clearTimeout(timeout); }
}
