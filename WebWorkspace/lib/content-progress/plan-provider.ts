export type PlanInput = {
  name: string;
  outlineText: string;
  courseURL: string | null;
};

export function validatePlanInput(value: unknown): PlanInput {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid plan request");
  const input = value as Record<string, unknown>;
  if (Object.keys(input).some((key) => !["name", "outlineText", "courseURL"].includes(key))) throw new Error("Unexpected plan request field");
  if (typeof input.name !== "string" ||
      (input.outlineText !== undefined && typeof input.outlineText !== "string")) throw new Error("Invalid plan request field");
  const name = typeof input.name === "string" ? input.name.trim() : "";
  const outlineText = typeof input.outlineText === "string" ? input.outlineText.trim() : "";
  const courseURL = input.courseURL === null || input.courseURL === undefined ? null : input.courseURL;
  if (!name || Array.from(name).length > 120) throw new Error("请先填写有效的项目名称");
  if (typeof courseURL !== "string" && courseURL !== null) throw new Error("Invalid course URL");
  if (new TextEncoder().encode(outlineText).length > 30_000) throw new Error("课程目录过长");
  if (!outlineText && courseURL?.trim()) throw new Error("当前无法安全读取课程链接。请粘贴目录，或清除链接后按主题生成。");
  return { name, outlineText, courseURL };
}

export function decodePlanUnits(value: unknown): string[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid plan response");
  const output = value as Record<string, unknown>;
  if (Object.keys(output).length !== 1 || !Array.isArray(output.units)) throw new Error("Invalid plan response shape");
  if (output.units.length === 0 || output.units.length > 300) throw new Error("AI 返回的单元数量无效");
  return output.units.map((unit: unknown) => {
    if (!unit || typeof unit !== "object" || Array.isArray(unit)) throw new Error("Invalid unit");
    const record = unit as Record<string, unknown>;
    if (Object.keys(record).length !== 1 || typeof record.title !== "string") throw new Error("Invalid unit shape");
    const title = record.title.trim();
    if (!title || Array.from(title).length > 200) throw new Error("AI 返回的单元标题无效");
    return title;
  });
}

export const planSystemPrompt = `You organize self-study content into a short ordered list. Return only JSON in this exact shape:
{"units":[{"title":"..."}]}
Use the supplied course outline when present; otherwise infer a sensible structure from the topic.
Generate content units only. Do not include dates, durations, daily tasks, check-ins,
notes, teaching, exercises, explanations, or any other fields.`;
