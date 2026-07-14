import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const WIDE_PLAN = [
  "cover",
  "problem",
  "learning-loop",
  "principles",
  "concepts",
  "information-architecture",
  "functional-modules",
  "onboarding",
  "today",
  "quick-log",
  "timer",
  "proof-flow",
  "proof-demo",
  "project-trail",
  "review",
  "ai-fallback",
  "library-export",
  "demo-storyboard",
  "status",
  "close",
];

const A4_PLAN = [
  "cover",
  "reading-guide",
  "positioning",
  "learning-loop",
  "principles",
  "concepts",
  "information-architecture",
  "functional-modules",
  "onboarding",
  "today",
  "project-management",
  "quick-log",
  "timer",
  "session-detail",
  "proof-flow",
  "proof-add",
  "proof-detail",
  "trail",
  "review-flow",
  "review-demo",
  "ai-fallback",
  "library",
  "export",
  "demo-storyboard",
  "demo-script",
  "status",
  "limitations",
  "maintenance",
];

const COLORS = {
  paper: "#F4F1EB",
  paperAlt: "#ECE8E1",
  ink: "#25242B",
  muted: "#6F6C76",
  line: "#D9D4CB",
  white: "#FFFFFF",
  violet: "#6657D9",
  violetSoft: "#E7E2FA",
  green: "#34866B",
  greenSoft: "#DDEFE8",
  orange: "#C77932",
  orangeSoft: "#F6E7D7",
  red: "#B54C52",
};

const FONT = "PingFang SC";

function parseArgs(argv) {
  const options = {
    repoRoot: process.cwd(),
    outputDir: null,
    scratchDir: null,
    validateOnly: false,
    simulateMissing: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--repo-root") options.repoRoot = path.resolve(argv[++index]);
    else if (value === "--output-dir") options.outputDir = path.resolve(argv[++index]);
    else if (value === "--scratch-dir") options.scratchDir = path.resolve(argv[++index]);
    else if (value === "--validate-only") options.validateOnly = true;
    else if (value === "--simulate-missing") options.simulateMissing = argv[++index];
  }
  return options;
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function loadProductGuide(repoRoot) {
  const contentPath = path.join(repoRoot, "docs/product-guide/content.json");
  const content = JSON.parse(await fs.readFile(contentPath, "utf8"));
  content.release.gitCommit = execFileSync("git", ["rev-parse", "--short", "HEAD"], {
    cwd: repoRoot,
    encoding: "utf8",
  }).trim();
  return content;
}

async function validateAssets(repoRoot, content, simulateMissing) {
  for (const diagram of content.diagrams) {
    const relativePath = diagram.path;
    const missing = relativePath === simulateMissing || !(await fileExists(path.join(repoRoot, relativePath)));
    if (missing) throw new Error(`Missing required asset: ${relativePath}`);
  }

  const screenshots = [];
  const missingOptionalScreenshots = [];
  for (const step of content.demoSteps) {
    if (!step.screenshot) {
      missingOptionalScreenshots.push(step.id);
      continue;
    }
    const exists = step.screenshot !== simulateMissing && await fileExists(path.join(repoRoot, step.screenshot));
    if (exists) screenshots.push(step.screenshot);
    else missingOptionalScreenshots.push(step.id);
  }
  return { screenshots, missingOptionalScreenshots };
}

async function resolveAssets(repoRoot, content, simulateMissing) {
  const validation = await validateAssets(repoRoot, content, simulateMissing);
  return {
    diagrams: new Map(content.diagrams.map((item) => [item.id, path.join(repoRoot, item.path)])),
    screenshots: new Map(
      content.demoSteps
        .filter((item) => item.screenshot && validation.screenshots.includes(item.screenshot))
        .map((item) => [item.id, path.join(repoRoot, item.screenshot)]),
    ),
    missingOptionalScreenshots: validation.missingOptionalScreenshots,
  };
}

async function validationSummary(options) {
  const content = await loadProductGuide(options.repoRoot);
  const assets = await validateAssets(options.repoRoot, content, options.simulateMissing);
  return {
    wideSlideCount: WIDE_PLAN.length,
    a4PageCount: A4_PLAN.length,
    diagramCount: content.diagrams.length,
    screenshotCount: assets.screenshots.length,
    missingOptionalScreenshots: assets.missingOptionalScreenshots,
  };
}

function addShape(slide, position, { fill = "none", lineFill = "none", lineWidth = 0, radius = false } = {}) {
  return slide.shapes.add({
    geometry: radius ? "roundRect" : "rect",
    position,
    fill,
    line: { style: "solid", fill: lineFill, width: lineWidth },
    ...(radius ? { borderRadius: "rounded-xl" } : {}),
  });
}

function addText(
  slide,
  text,
  position,
  {
    fontSize = 22,
    color = COLORS.ink,
    bold = false,
    alignment = "left",
    verticalAlignment = "top",
    name,
  } = {},
) {
  const shape = slide.shapes.add({
    geometry: "textbox",
    name,
    position,
    fill: "none",
    line: { style: "solid", fill: "none", width: 0 },
  });
  shape.text = text;
  shape.text.style = {
    fontFamily: FONT,
    fontSize,
    color,
    bold,
    alignment,
    verticalAlignment,
  };
  return shape;
}

function addWideChrome(slide, title, section, page) {
  addText(slide, section.toUpperCase(), { left: 72, top: 44, width: 300, height: 28 }, {
    fontSize: 16,
    color: COLORS.violet,
    bold: true,
  });
  addText(slide, title, { left: 72, top: 80, width: 1136, height: 70 }, {
    fontSize: 40,
    bold: true,
    name: `wide-title-${page}`,
  });
  addText(slide, `SELF STUDY STUDIO  ·  ${String(page).padStart(2, "0")}`, {
    left: 72,
    top: 682,
    width: 1136,
    height: 20,
  }, { fontSize: 14, color: COLORS.muted });
}

function addA4Chrome(slide, title, section, page) {
  addText(slide, section.toUpperCase(), { left: 58, top: 42, width: 260, height: 22 }, {
    fontSize: 14,
    color: COLORS.violet,
    bold: true,
  });
  addText(slide, title, { left: 58, top: 72, width: 678, height: 76 }, {
    fontSize: 31,
    bold: true,
    name: `a4-title-${page}`,
  });
  addShape(slide, { left: 58, top: 1082, width: 678, height: 1 }, {
    fill: COLORS.line,
  });
  addText(slide, `SELF STUDY STUDIO  ·  ${String(page).padStart(2, "0")}`, {
    left: 58,
    top: 1092,
    width: 678,
    height: 18,
  }, { fontSize: 12, color: COLORS.muted });
}

async function readImageBlob(imagePath) {
  const bytes = await fs.readFile(imagePath);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

async function addImage(slide, imagePath, position, alt, { fit = "contain", radius = true } = {}) {
  const ext = path.extname(imagePath).toLowerCase();
  const contentType = ext === ".jpg" || ext === ".jpeg" ? "image/jpeg" : "image/png";
  return slide.images.add({
    blob: await readImageBlob(imagePath),
    contentType,
    alt,
    fit,
    position,
    geometry: radius ? "roundRect" : "rect",
    ...(radius ? { borderRadius: "rounded-xl" } : {}),
  });
}

function addBulletList(slide, items, position, { fontSize = 22, gap = 14, bulletColor = COLORS.violet } = {}) {
  const itemHeight = (position.height - gap * (items.length - 1)) / items.length;
  for (const [index, item] of items.entries()) {
    const top = position.top + index * (itemHeight + gap);
    addShape(slide, { left: position.left, top: top + 8, width: 10, height: 10 }, { fill: bulletColor, radius: true });
    addText(slide, item, {
      left: position.left + 26,
      top,
      width: position.width - 26,
      height: itemHeight,
    }, { fontSize });
  }
}

function addQuote(slide, text, position, { fontSize = 28 } = {}) {
  addShape(slide, { left: position.left, top: position.top, width: 6, height: position.height }, { fill: COLORS.violet });
  addText(slide, text, {
    left: position.left + 30,
    top: position.top,
    width: position.width - 30,
    height: position.height,
  }, { fontSize, bold: true });
}

async function addWideDiagramSlide(presentation, title, section, imagePath, alt, page, caption) {
  const slide = presentation.slides.add();
  slide.background.fill = COLORS.paper;
  addWideChrome(slide, title, section, page);
  addShape(slide, { left: 72, top: 158, width: 1136, height: 500 }, {
    fill: COLORS.white,
    lineFill: COLORS.line,
    lineWidth: 1,
    radius: true,
  });
  await addImage(slide, imagePath, { left: 98, top: 178, width: 1084, height: 420 }, alt, { radius: false });
  if (caption) addText(slide, caption, { left: 98, top: 612, width: 1084, height: 28 }, { fontSize: 16, color: COLORS.muted });
}

async function addWideScreenshotSlide(
  presentation,
  title,
  section,
  screenshotPath,
  page,
  { lead, bullets = [], accent = COLORS.violet } = {},
) {
  const slide = presentation.slides.add();
  slide.background.fill = COLORS.paper;
  addWideChrome(slide, title, section, page);
  addShape(slide, { left: 824, top: 156, width: 280, height: 504 }, {
    fill: COLORS.white,
    lineFill: COLORS.line,
    lineWidth: 1,
    radius: true,
  });
  await addImage(slide, screenshotPath, { left: 850, top: 170, width: 228, height: 476 }, title, { fit: "contain", radius: true });
  addQuote(slide, lead, { left: 86, top: 194, width: 654, height: 112 }, { fontSize: 30 });
  addBulletList(slide, bullets, { left: 92, top: 350, width: 636, height: 220 }, { fontSize: 21, bulletColor: accent });
}

function addStatusRows(slide, rows, position, { fontSize = 17, rowGap = 8 } = {}) {
  const rowHeight = (position.height - rowGap * (rows.length - 1)) / rows.length;
  const statusColors = {
    "已实现": [COLORS.greenSoft, COLORS.green],
    "部分实现": [COLORS.orangeSoft, COLORS.orange],
    "已设计": [COLORS.violetSoft, COLORS.violet],
    "未规划": [COLORS.paperAlt, COLORS.muted],
  };
  for (const [index, row] of rows.entries()) {
    const top = position.top + index * (rowHeight + rowGap);
    addShape(slide, { left: position.left, top, width: position.width, height: rowHeight }, {
      fill: COLORS.white,
      lineFill: COLORS.line,
      lineWidth: 1,
      radius: true,
    });
    const [fill, color] = statusColors[row.status] ?? statusColors["未规划"];
    addShape(slide, { left: position.left + 16, top: top + 12, width: 104, height: rowHeight - 24 }, { fill, radius: true });
    addText(slide, row.status, { left: position.left + 22, top: top + 14, width: 92, height: rowHeight - 28 }, {
      fontSize: fontSize - 1,
      bold: true,
      color,
      alignment: "center",
      verticalAlignment: "middle",
    });
    addText(slide, row.feature, { left: position.left + 140, top: top + 14, width: 260, height: rowHeight - 28 }, {
      fontSize,
      bold: true,
      verticalAlignment: "middle",
    });
    addText(slide, row.visibleResult, { left: position.left + 420, top: top + 14, width: position.width - 440, height: rowHeight - 28 }, {
      fontSize: fontSize - 1,
      color: COLORS.muted,
      verticalAlignment: "middle",
    });
  }
}

async function buildWideDeck(Presentation, content, assets) {
  const presentation = Presentation.create({ slideSize: { width: 1280, height: 720 } });

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addText(slide, "SELF STUDY STUDIO", { left: 76, top: 68, width: 420, height: 34 }, {
      fontSize: 18,
      color: COLORS.violet,
      bold: true,
    });
    addText(slide, "学习记录的目的，\n是决定下一步", { left: 76, top: 162, width: 760, height: 190 }, {
      fontSize: 62,
      bold: true,
      name: "cover-title",
    });
    addText(slide, content.positioning.oneLiner, { left: 80, top: 386, width: 700, height: 90 }, {
      fontSize: 26,
      color: COLORS.muted,
    });
    addShape(slide, { left: 900, top: 110, width: 250, height: 450 }, { fill: COLORS.violetSoft, radius: true });
    addText(slide, "Project\n↓\nSession\n↓\nProof\n↓\nReview", {
      left: 928,
      top: 148,
      width: 194,
      height: 360,
    }, { fontSize: 29, bold: true, alignment: "center", verticalAlignment: "middle", color: COLORS.violet });
    addText(slide, `产品功能说明 · v${content.release.documentVersion} · ${content.release.verifiedOn}`, {
      left: 80,
      top: 642,
      width: 700,
      height: 24,
    }, { fontSize: 16, color: COLORS.muted });
  }

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "零散记录无法自动变成下一步", "WHY", 2);
    addQuote(slide, "真正缺少的不是更多笔记，而是能支持下一次行动的学习轨迹。", {
      left: 82,
      top: 168,
      width: 780,
      height: 96,
    }, { fontSize: 30 });
    const questions = [
      ["01", "这周真正做了什么？"],
      ["02", "哪些结果能证明学习发生了？"],
      ["03", "下一次打开项目时应该做什么？"],
    ];
    for (const [index, [number, text]] of questions.entries()) {
      const top = 306 + index * 94;
      addText(slide, number, { left: 92, top, width: 72, height: 48 }, { fontSize: 24, bold: true, color: COLORS.violet });
      addText(slide, text, { left: 180, top, width: 760, height: 52 }, { fontSize: 28, bold: true });
    }
    addText(slide, "产品回答：Next Step → Session → Proof → Review", {
      left: 882,
      top: 344,
      width: 260,
      height: 150,
    }, { fontSize: 25, bold: true, color: COLORS.violet, alignment: "center", verticalAlignment: "middle" });
  }

  await addWideDiagramSlide(presentation, "行动、证据和复盘形成一个闭环", "CORE LOOP", assets.diagrams.get("learning-loop"), "学习轨迹核心闭环", 3, "Quick Log 与 Timer 都生成 Session；Review 只有在用户确认后才改变 Project。" );

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "六条原则让记录保持低摩擦", "PRINCIPLES", 4);
    const left = ["手机优先，入口少而短", "继续学习优先于整理", "Proof 比完成百分比更重要"];
    const right = ["日常记录与阶段判断分离", "AI 不进入日常主流程", "本地优先，数据可以带走"];
    addBulletList(slide, left, { left: 92, top: 204, width: 520, height: 300 }, { fontSize: 25 });
    addShape(slide, { left: 638, top: 194, width: 2, height: 330 }, { fill: COLORS.line });
    addBulletList(slide, right, { left: 690, top: 204, width: 490, height: 300 }, { fontSize: 25, bulletColor: COLORS.green });
    addText(slide, "减少维护负担，保留决策价值。", { left: 92, top: 566, width: 980, height: 44 }, { fontSize: 28, bold: true, color: COLORS.violet });
  }

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "六个概念各自承担一种产品责任", "LANGUAGE", 5);
    const widths = [170, 184, 170, 170, 170, 170];
    let left = 68;
    for (const [index, concept] of content.concepts.entries()) {
      const width = widths[index];
      addText(slide, concept.term, { left, top: 226, width, height: 46 }, {
        fontSize: 24,
        bold: true,
        color: index === 1 ? COLORS.violet : COLORS.ink,
        alignment: "center",
      });
      addText(slide, concept.meaning, { left: left + 8, top: 288, width: width - 16, height: 150 }, {
        fontSize: 18,
        color: COLORS.muted,
        alignment: "center",
      });
      if (index < content.concepts.length - 1) addText(slide, "→", { left: left + width - 4, top: 230, width: 28, height: 36 }, { fontSize: 24, color: COLORS.line, alignment: "center" });
      left += width + 18;
    }
    addQuote(slide, "Session 负责事实，Proof 负责证据，Review 负责决定。", { left: 220, top: 520, width: 840, height: 80 }, { fontSize: 28 });
  }

  await addWideDiagramSlide(presentation, "三个主入口覆盖完整 v0.1 路径", "INFORMATION ARCHITECTURE", assets.diagrams.get("information-architecture"), "当前 App 信息架构", 6, "AI Review Settings 是条件性入口；Calendar、Course Plan 和 Cloud Sync 不在当前导航。" );
  await addWideDiagramSlide(presentation, "本地优先不等于封闭：数据和 AI 都有边界", "MODULES", assets.diagrams.get("functional-modules"), "当前功能模块关系", 7, "SwiftData 失败时降级到 JSON Store；Export 读取内存 Snapshot，不直接访问数据库。" );
  await addWideDiagramSlide(presentation, "首次设置必须落下一条真实 Session", "ONBOARDING", assets.diagrams.get("onboarding"), "首次使用与首条记录流程", 8, "创建 1–3 个 Project 后，完成首条 Quick Log 才进入 Today。" );

  await addWideScreenshotSlide(presentation, "Today 直接给出可以执行的下一步", "DEMO · TODAY", assets.screenshots.get("today"), 9, {
    lead: "首页不是任务清单，而是“继续学习”的最短路径。",
    bullets: ["仅显示 active 且有 Next Step 的 Project", "同时带出最近 Session 与 Proof 上下文", "Start 与 Quick Log 服务不同记录时机"],
  });

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "Quick Log 和 Timer 最终进入同一种 Session", "DEMO · SESSION", 10);
    addShape(slide, { left: 72, top: 164, width: 500, height: 484 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
    await addImage(slide, assets.screenshots.get("quick-log"), { left: 92, top: 176, width: 192, height: 456 }, "Quick Log 表单", { fit: "contain" });
    await addImage(slide, assets.screenshots.get("session"), { left: 320, top: 176, width: 192, height: 456 }, "Session Detail", { fit: "contain" });
    addShape(slide, { left: 612, top: 164, width: 596, height: 484 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
    await addImage(slide, assets.diagrams.get("session"), { left: 636, top: 190, width: 548, height: 356 }, "日常 Session 记录流程", { radius: false });
    addText(slide, "同一份 Session 同时保留行动、时长、内容和 Next Step 的前后变化。", {
      left: 646,
      top: 562,
      width: 528,
      height: 62,
    }, { fontSize: 20, bold: true, color: COLORS.violet });
  }

  await addWideScreenshotSlide(presentation, "Timer 只统计真正投入的活动时间", "DEMO · TIMER", assets.screenshots.get("timer"), 11, {
    lead: "暂停不累计时间，舍弃不产生 Session。",
    bullets: ["Running、Paused 状态明确", "End 后补充学习内容和新的 Next Step", "演示时间不足时可切换 Quick Log 完成闭环"],
    accent: COLORS.green,
  });

  await addWideDiagramSlide(presentation, "附件只有配上解释，才成为学习证据", "PROOF", assets.diagrams.get("proof"), "Proof 学习证据流程", 12, "图片、录音、文件和链接都必须补充“这证明了什么”。" );

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "Proof 同时保留内容、意义和来源", "DEMO · PROOF", 13);
    addShape(slide, { left: 74, top: 158, width: 1132, height: 500 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
    await addImage(slide, assets.screenshots.get("proof-add"), { left: 122, top: 174, width: 216, height: 468 }, "Add Proof", { fit: "contain" });
    await addImage(slide, assets.screenshots.get("proof-detail"), { left: 384, top: 174, width: 216, height: 468 }, "Proof Detail", { fit: "contain" });
    addQuote(slide, "“What does this prove?” 是证据模型的关键约束。", { left: 684, top: 220, width: 450, height: 104 }, { fontSize: 27 });
    addBulletList(slide, ["可关联具体 Session，也可只关联 Project", "Library 提供 Time、Project、Type 三种回看方式", "本地附件缺失时显示不可用，不伪造预览"], {
      left: 690,
      top: 368,
      width: 430,
      height: 190,
    }, { fontSize: 19 });
  }

  await addWideScreenshotSlide(presentation, "Project Detail 把行动、证据和状态放在一起", "DEMO · TRAIL", assets.screenshots.get("trail"), 14, {
    lead: "Trail 的价值不在“完成了多少”，而在“项目如何变化”。",
    bullets: ["Goal、Next Step、Actions 和 Status 共处一页", "Sessions、Proofs、Reviews 与 Trail 使用同一 Project 上下文", "完整 Trail 结构由产品流程图维护"],
  });

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "Review 先保存判断，再由用户应用建议", "REVIEW", 15);
    addShape(slide, { left: 72, top: 158, width: 760, height: 500 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
    await addImage(slide, assets.diagrams.get("review"), { left: 94, top: 178, width: 716, height: 440 }, "Weekly Review 流程", { radius: false });
    addShape(slide, { left: 872, top: 158, width: 260, height: 500 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
    await addImage(slide, assets.screenshots.get("review"), { left: 892, top: 174, width: 220, height: 468 }, "Weekly Review 页面", { fit: "contain" });
  }

  await addWideDiagramSlide(presentation, "AI 不可用时，Review 仍然可以完成", "AI FALLBACK", assets.diagrams.get("ai-fallback"), "AI Review 降级流程", 16, "未配置、请求失败或解析失败都会回到本地证据规则，结果仍可编辑。" );

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "Library 负责回看证据，Export 负责把数据带走", "LIBRARY & EXPORT", 17);
    addShape(slide, { left: 72, top: 158, width: 328, height: 500 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
    await addImage(slide, assets.screenshots.get("library"), { left: 100, top: 174, width: 272, height: 468 }, "Library 页面", { fit: "contain" });
    addShape(slide, { left: 438, top: 158, width: 770, height: 500 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
    await addImage(slide, assets.diagrams.get("export"), { left: 462, top: 186, width: 722, height: 380 }, "数据导出流程", { radius: false });
    addText(slide, "一次 Export 生成版本化 journal.json 与附件目录；失败不修改原始数据。", {
      left: 474,
      top: 574,
      width: 698,
      height: 58,
    }, { fontSize: 20, bold: true, color: COLORS.violet });
  }

  await addWideDiagramSlide(presentation, "一条 CS336 故事可以讲完完整产品闭环", "5–10 MIN DEMO", assets.diagrams.get("demo-storyboard"), "标准 Demo 故事板", 18, "Today → Timer/Quick Log → Proof → Trail → Weekly Review。" );

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "v0.1 闭环可运行，规划能力不冒充已实现", "STATUS", 19);
    const rows = [
      content.featureStatus[1],
      content.featureStatus[3],
      content.featureStatus[4],
      content.featureStatus[5],
      content.featureStatus[7],
      content.featureStatus[9],
      content.featureStatus[13],
    ];
    addStatusRows(slide, rows, { left: 74, top: 164, width: 1132, height: 470 });
  }

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addWideChrome(slide, "让每次学习都留下一个可以继续的方向", "CLOSE", 20);
    addQuote(slide, "Project → Session → Proof → Review → Next Step", { left: 140, top: 210, width: 1000, height: 94 }, { fontSize: 38 });
    addText(slide, "维护规则", { left: 146, top: 360, width: 220, height: 40 }, { fontSize: 26, bold: true, color: COLORS.violet });
    addBulletList(slide, ["产品事实先更新 Markdown 手册", "导航和规则变化同步更新 Mermaid", "界面变化重新采集真实 Simulator 图", "重新生成 PPTX 与 A4 PDF，并逐页检查"], {
      left: 150,
      top: 420,
      width: 900,
      height: 170,
    }, { fontSize: 21 });
    addText(slide, `${content.release.testBaseline} · commit ${content.release.gitCommit}`, {
      left: 150,
      top: 620,
      width: 900,
      height: 28,
    }, { fontSize: 16, color: COLORS.muted });
  }

  return presentation;
}

async function addA4DiagramPage(presentation, title, section, imagePath, alt, page, caption) {
  const slide = presentation.slides.add();
  slide.background.fill = COLORS.paper;
  addA4Chrome(slide, title, section, page);
  addShape(slide, { left: 58, top: 170, width: 678, height: 820 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
  await addImage(slide, imagePath, { left: 82, top: 194, width: 630, height: 700 }, alt, { radius: false });
  addText(slide, caption, { left: 84, top: 920, width: 626, height: 54 }, { fontSize: 17, color: COLORS.muted });
}

async function addA4ScreenshotPage(presentation, title, section, screenshotPath, page, lead, bullets) {
  const slide = presentation.slides.add();
  slide.background.fill = COLORS.paper;
  addA4Chrome(slide, title, section, page);
  addShape(slide, { left: 58, top: 168, width: 312, height: 820 }, { fill: COLORS.white, lineFill: COLORS.line, lineWidth: 1, radius: true });
  await addImage(slide, screenshotPath, { left: 80, top: 186, width: 268, height: 784 }, title, { fit: "contain" });
  addQuote(slide, lead, { left: 414, top: 214, width: 320, height: 156 }, { fontSize: 24 });
  addBulletList(slide, bullets, { left: 416, top: 420, width: 314, height: 340 }, { fontSize: 18, gap: 20 });
}

function addA4TextPage(presentation, title, section, page, lead, blocks) {
  const slide = presentation.slides.add();
  slide.background.fill = COLORS.paper;
  addA4Chrome(slide, title, section, page);
  addQuote(slide, lead, { left: 74, top: 176, width: 644, height: 118 }, { fontSize: 25 });
  let top = 342;
  for (const block of blocks) {
    addText(slide, block.title, { left: 82, top, width: 620, height: 34 }, { fontSize: 21, bold: true, color: block.color ?? COLORS.violet });
    addText(slide, block.body, { left: 82, top: top + 46, width: 620, height: block.height ?? 112 }, { fontSize: 18, color: COLORS.ink });
    top += (block.height ?? 112) + 88;
  }
}

async function buildA4Guide(Presentation, content, assets) {
  const presentation = Presentation.create({ slideSize: { width: 794, height: 1123 } });

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addText(slide, "SELF STUDY STUDIO", { left: 62, top: 70, width: 420, height: 28 }, { fontSize: 16, bold: true, color: COLORS.violet });
    addText(slide, "产品功能手册", { left: 62, top: 182, width: 670, height: 82 }, { fontSize: 48, bold: true });
    addText(slide, "行动 · 证据 · 复盘 · 下一步", { left: 64, top: 292, width: 620, height: 52 }, { fontSize: 26, color: COLORS.muted });
    addShape(slide, { left: 62, top: 414, width: 670, height: 326 }, { fill: COLORS.violetSoft, radius: true });
    addText(slide, "Project\n↓\nSession\n↓\nProof\n↓\nReview\n↓\nNext Step", { left: 170, top: 458, width: 454, height: 244 }, {
      fontSize: 29,
      bold: true,
      color: COLORS.violet,
      alignment: "center",
      verticalAlignment: "middle",
    });
    addText(slide, `文档版本 ${content.release.documentVersion}\n最近核对 ${content.release.verifiedOn}\ncommit ${content.release.gitCommit}`, {
      left: 64,
      top: 902,
      width: 640,
      height: 100,
    }, { fontSize: 17, color: COLORS.muted });
  }

  addA4TextPage(presentation, "如何阅读这份手册", "READING GUIDE", 2, "先理解闭环，再按真实 Demo 顺序查看每个功能。", [
    { title: "面向演示", body: "第 3–24 页解释产品价值、流程与真实界面；第 25 页提供 5–10 分钟演示脚本。", height: 90 },
    { title: "面向维护", body: "第 26–28 页记录功能状态、已知限制与更新规则。产品事实以 docs/PRODUCT_GUIDE.md 为权威来源。", height: 110 },
    { title: "状态语言", body: "已实现：代码与验证证据存在。部分实现：主流程存在但仍有关键缺口。已设计：只有规格或计划。", height: 140 },
  ]);

  addA4TextPage(presentation, "学习记录的目的，是决定下一步", "POSITIONING", 3, content.positioning.oneLiner, [
    { title: "目标用户", body: content.positioning.audience, height: 100 },
    { title: "用户问题", body: content.positioning.problem, height: 120 },
    { title: "产品承诺", body: content.positioning.promise, height: 110 },
    { title: "产品边界", body: content.positioning.boundary, height: 110, color: COLORS.orange },
  ]);

  await addA4DiagramPage(presentation, "核心闭环从 Next Step 回到 Next Step", "CORE LOOP", assets.diagrams.get("learning-loop"), "学习轨迹核心闭环", 4, "Quick Log 与 Timer 都生成 Session；Proof 与 Review 再把记录转化为下一步决定。" );

  addA4TextPage(presentation, "六条原则控制产品复杂度", "PRINCIPLES", 5, "记录越轻，复盘越可信；自动化越靠后，用户控制越清楚。", [
    { title: "记录", body: "手机优先；继续学习优先于整理；Quick Log 与 Timer 共享 Session 模型。", height: 120 },
    { title: "证据", body: "Proof 比完成百分比更重要；附件必须解释“这证明了什么”。", height: 110 },
    { title: "判断", body: "日常记录与阶段判断分离；AI 不进入日常记录主流程。", height: 110 },
    { title: "数据", body: "本地优先，同时提供结构化记录与附件的完整导出。", height: 100 },
  ]);

  addA4TextPage(presentation, "六个概念各自承担一种责任", "LANGUAGE", 6, "稳定的产品语言让界面、数据和文档保持一致。", content.concepts.slice(0, 4).map((concept) => ({
    title: concept.term,
    body: concept.meaning,
    height: 74,
  })));

  await addA4DiagramPage(presentation, "三个 Tab 覆盖当前产品范围", "INFORMATION ARCHITECTURE", assets.diagrams.get("information-architecture"), "当前 App 信息架构", 7, "Review 和 AI Settings 是条件性入口；Calendar、Course Plan、Cloud Sync 尚未进入导航。" );
  await addA4DiagramPage(presentation, "界面、业务规则与存储边界清晰分层", "MODULES", assets.diagrams.get("functional-modules"), "当前功能模块关系", 8, "SwiftData 正常持久化；JSON Store 是初始化失败时的降级。" );
  await addA4DiagramPage(presentation, "首次设置以第一条真实 Session 收尾", "ONBOARDING", assets.diagrams.get("onboarding"), "首次使用流程", 9, "名称、Goal、Next Step 必填；Area 可选；创建 1–3 个 Project 后完成首条 Quick Log。" );

  await addA4ScreenshotPage(presentation, "Today 把可执行的 Next Step 放在首页", "DEMO · TODAY", assets.screenshots.get("today"), 10, "打开 App 后，用户先看到“下一步做什么”。", ["仅 active 且有 Next Step 的 Project 出现", "最近 Session 与 Proof 提供上下文", "Start 进入 Timer，Quick Log 用于补记"]);

  addA4TextPage(presentation, "Project 管理目标、节奏与状态", "PROJECTS", 11, "Project 不是文件夹，而是一个持续学习目标的当前状态。", [
    { title: "字段", body: "Project、Area、Goal、Next Step；名称、Goal、Next Step 必填。", height: 100 },
    { title: "状态", body: "active、low-frequency、paused、archived。归档项目不进入 Today Continue。", height: 110 },
    { title: "详情页", body: "集中提供 Start、Quick Log、Add Proof、Sessions、Proofs、Reviews 与 Learning Trail。", height: 110 },
    { title: "Trail 规则", body: "状态和 Next Step 的变化会形成可回看的 Trail 事件。", height: 96 },
  ]);

  await addA4ScreenshotPage(presentation, "Quick Log 在 30 秒内补记一次学习", "DEMO · QUICK LOG", assets.screenshots.get("quick-log"), 12, "补记与现场计时进入同一种 Session。", ["选择 Action Type 和预设/自定义时长", "填写一句学习内容", "可同时更新新的 Next Step"]);
  await addA4ScreenshotPage(presentation, "Timer 只累计活动时间", "DEMO · TIMER", assets.screenshots.get("timer"), 13, "Pause 不计时，Discard 不保存。", ["Running 与 Paused 状态明确", "End 后补充内容与 Next Step", "保存结果与 Quick Log 完全一致"]);
  await addA4ScreenshotPage(presentation, "Session 同时保留行动与 Next Step 变化", "DEMO · SESSION", assets.screenshots.get("session"), 14, "一条 Session 说明做了什么，也说明项目接下来怎么走。", ["Action 与 Duration 是事实", "Before / After 记录 Next Step 变化", "可以从 Session 继续添加 Proof"]);

  await addA4DiagramPage(presentation, "Proof 把附件变成可以解释的学习证据", "PROOF", assets.diagrams.get("proof"), "Proof 学习证据流程", 15, "图片、录音、文件和链接都必须补充 statement；证据可关联 Session 或仅关联 Project。" );
  await addA4ScreenshotPage(presentation, "Add Proof 明确区分类型、说明和附件", "DEMO · PROOF", assets.screenshots.get("proof-add"), 16, "“What does this prove?” 是必填项。", ["图片：相机或照片库", "音频：本地录音", "文件：系统文件选择", "链接：无权限时的稳定备用路径"]);
  await addA4ScreenshotPage(presentation, "Proof Detail 保留证据的上下文", "DEMO · PROOF DETAIL", assets.screenshots.get("proof-detail"), 17, "回看时既能看到内容，也能知道它来自哪个 Project 与 Session。", ["图片、音频、文件、链接使用不同预览", "statement 解释证据意义", "附件缺失时显示不可用状态"]);
  await addA4ScreenshotPage(presentation, "Project Detail 是 Trail 的项目上下文", "DEMO · PROJECT DETAIL", assets.screenshots.get("trail"), 18, "行为、证据、状态与 Review 都回到同一个 Project。", ["Goal 与 Next Step 说明方向", "Actions 连接 Timer、Quick Log、Proof", "Sessions、Proofs、Reviews 与 Trail 在同页延伸"]);

  await addA4DiagramPage(presentation, "Review 保存判断，但不自动应用建议", "REVIEW", assets.diagrams.get("review"), "Weekly Review 流程", 19, "Facts、Patterns、Decisions 和 Next Steps 都可编辑；状态与 Next Step 必须分别显式应用。" );
  await addA4ScreenshotPage(presentation, "来源引用让 Review 可以被追溯", "DEMO · REVIEW", assets.screenshots.get("review"), 20, "复盘不是黑盒总结，而是带来源的阶段判断。", ["Facts、Patterns、Decisions 可继续编辑", "来源显示具体 Session 或 Proof", "Save 与 Apply Status / Next Step 分离"]);
  await addA4DiagramPage(presentation, "AI 失败不会阻断 Weekly Review", "AI FALLBACK", assets.diagrams.get("ai-fallback"), "AI Review 降级流程", 21, "未配置、请求失败或响应不可解析时使用本地证据规则；输出仍可编辑、保存和应用。" );
  await addA4ScreenshotPage(presentation, "Library 从证据角度回看所有项目", "DEMO · LIBRARY", assets.screenshots.get("library"), 22, "同一批 Proof 可以按 Time、Project 或 Type 重组。", ["每条显示 Project、Session、时间与附件", "可从 Library 选择 Project 新增 Proof", "v0.1 尚无全文搜索"]);
  await addA4DiagramPage(presentation, "一次 Export 生成完整本地 Bundle", "EXPORT", assets.diagrams.get("export"), "数据导出流程", 23, "输出版本化 journal.json 和附件目录，保存到 Documents/LearningJournal/Exports；失败不改动原始数据。" );
  await addA4DiagramPage(presentation, "5–10 分钟讲完一条学习故事", "DEMO STORYBOARD", assets.diagrams.get("demo-storyboard"), "标准 Demo 故事板", 24, "建议用 CS336 贯穿 Today、Timer/Quick Log、Proof、Project Detail 和 Weekly Review。" );

  addA4TextPage(presentation, "标准 Demo 的讲解顺序", "DEMO SCRIPT", 25, "每一步都回答一个产品问题，不需要展示所有字段。", [
    { title: "1 · Today", body: "Next Step 为什么比任务清单更接近行动？", height: 70 },
    { title: "2 · Session", body: "Quick Log 与 Timer 如何共享同一种记录？", height: 70 },
    { title: "3 · Proof", body: "为什么附件必须解释“这证明了什么”？", height: 70 },
    { title: "4 · Review", body: "AI 或本地规则如何提出建议，但不替用户做决定？", height: 88 },
    { title: "5 · Export", body: "用户如何把结构化记录与附件一起带走？", height: 74 },
  ]);

  {
    const slide = presentation.slides.add();
    slide.background.fill = COLORS.paper;
    addA4Chrome(slide, "当前能力与规划能力保持清晰边界", "STATUS", 26);
    addStatusRows(slide, [
      content.featureStatus[0],
      content.featureStatus[3],
      content.featureStatus[5],
      content.featureStatus[7],
      content.featureStatus[9],
      content.featureStatus[11],
      content.featureStatus[13],
      content.featureStatus[14],
    ], { left: 58, top: 174, width: 678, height: 824 }, { fontSize: 14, rowGap: 8 });
  }

  addA4TextPage(presentation, "当前限制必须和已实现能力一起说明", "LIMITATIONS", 27, "可信的产品文档既说明能做什么，也说明还没有验证什么。", content.limitations.slice(0, 4).map((item) => ({
    title: item.category,
    body: item.detail,
    height: 112,
    color: item.category === "测试" ? COLORS.orange : COLORS.violet,
  })));

  addA4TextPage(presentation, "一套内容源，持续更新三种输出", "MAINTENANCE", 28, "Markdown 维护产品事实，Mermaid 维护流程，生成器维护 PPTX 与 PDF。", [
    { title: "产品变化", body: "先更新 docs/PRODUCT_GUIDE.md 与 content.json；再更新受影响的 Mermaid 和真实截图。", height: 120 },
    { title: "重新生成", body: "运行 scripts/generate-product-guide.sh，生成 16:9 PPTX、A4 PPTX 与 A4 PDF。", height: 110 },
    { title: "发布前检查", body: "逐页检查溢出、遮挡、图片拉伸、断开的流程连接、状态与测试基线。", height: 120 },
    { title: "当前基线", body: `${content.release.testBaseline}\ncommit ${content.release.gitCommit}`, height: 92, color: COLORS.orange },
  ]);

  return presentation;
}

async function writeBlob(filePath, blob) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, new Uint8Array(await blob.arrayBuffer()));
}

async function exportPresentation(PresentationFile, presentation, outputPath, previewDir, prefix) {
  await fs.mkdir(previewDir, { recursive: true });
  for (const [index, slide] of presentation.slides.items.entries()) {
    const stem = `${prefix}-${String(index + 1).padStart(2, "0")}`;
    await writeBlob(path.join(previewDir, `${stem}.png`), await presentation.export({ slide, format: "png", scale: 1 }));
    const layout = await slide.export({ format: "layout" });
    await fs.writeFile(path.join(previewDir, `${stem}.layout.json`), await layout.text());
  }
  await writeBlob(
    path.join(previewDir, `${prefix}-montage.webp`),
    await presentation.export({ format: "webp", montage: true, scale: 1 }),
  );
  const pptx = await PresentationFile.exportPptx(presentation);
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await pptx.save(outputPath);
  await fs.rm(`${outputPath}.inspect.ndjson`, { force: true });
}

async function generatePresentations(options) {
  const content = await loadProductGuide(options.repoRoot);
  const assets = await resolveAssets(options.repoRoot, content, options.simulateMissing);
  const { Presentation, PresentationFile } = await import("@oai/artifact-tool");
  const outputDir = options.outputDir ?? path.join(options.repoRoot, "docs/product-guide");
  const scratchDir = options.scratchDir ?? path.join(options.repoRoot, ".product-guide-preview");
  const wide = await buildWideDeck(Presentation, content, assets);
  const a4 = await buildA4Guide(Presentation, content, assets);
  if (wide.slides.items.length !== WIDE_PLAN.length) throw new Error(`Wide slide count mismatch: ${wide.slides.items.length}`);
  if (a4.slides.items.length !== A4_PLAN.length) throw new Error(`A4 page count mismatch: ${a4.slides.items.length}`);
  await exportPresentation(
    PresentationFile,
    wide,
    path.join(outputDir, "self-study-studio-product-deck.pptx"),
    path.join(scratchDir, "wide"),
    "wide",
  );
  await exportPresentation(
    PresentationFile,
    a4,
    path.join(outputDir, "self-study-studio-product-guide-a4.pptx"),
    path.join(scratchDir, "a4"),
    "a4",
  );
  return {
    wideSlideCount: wide.slides.items.length,
    a4PageCount: a4.slides.items.length,
    outputDir,
    scratchDir,
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const summary = await validationSummary(options);
  if (options.validateOnly) {
    process.stdout.write(`${JSON.stringify(summary)}\n`);
    return;
  }
  const result = await generatePresentations(options);
  process.stdout.write(`${JSON.stringify({ ...summary, ...result })}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
