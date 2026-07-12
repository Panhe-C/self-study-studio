# Product Function Diagrams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a maintainable visual suite that explains Self Study Studio's current product structure, core learning loop, detailed user flows, failure paths, and standard demo sequence.

**Architecture:** Mermaid `.mmd` files are the editable sources of truth. Each source is rendered to SVG for Markdown and PNG for presentation compatibility; `diagrams/PRODUCT_FUNCTION_DIAGRAMS.md` provides the ordered visual index and explicitly separates implemented behavior from designed-only capabilities.

**Tech Stack:** Mermaid flowcharts, Mermaid CLI through bundled `pnpm`, SVG, PNG, Markdown, shell validation.

## Global Constraints

- Describe only behavior verified in the current SwiftUI source and tests.
- Mark CloudKit/iCloud sync, AI course planning, and Calendar as designed-only; never place them inside current product flows.
- Use the stable terms Project, Next Step, Session, Proof, Trail, Review, Quick Log, and Timer.
- Use Chinese product copy and keep internal Swift type names out of user-facing diagrams.
- Never overwrite the user's untracked `app-feature-modules.*` or `app-user-journey*.{mmd,svg,png,excalidraw}` files.
- Every new diagram has one `.mmd` source, one `.svg`, and one `.png` with the same basename.
- Use neutral structure plus semantic labels; color may reinforce meaning but cannot be the only encoding.
- Keep each detailed flow focused on one user goal and fewer than 16 visible nodes.

---

## File Structure

- Create `diagrams/product-learning-loop.mmd`: core Project-to-Review product loop.
- Create `diagrams/product-information-architecture.mmd`: current screen and navigation map.
- Create `diagrams/product-functional-modules.mmd`: current UI, application rules, local storage, and optional AI boundary.
- Create `diagrams/product-demo-storyboard.mmd`: 5–10 minute demo sequence.
- Create `diagrams/product-onboarding-flow.mmd`: first-use project and first Session gate.
- Create `diagrams/product-session-flow.mmd`: Continue, Quick Log, Timer, Session, and Next Step flow.
- Create `diagrams/product-proof-flow.mmd`: Proof type, required statement, storage, and browsing flow.
- Create `diagrams/product-review-flow.mmd`: prompt, generation, edit, and explicit-apply flow.
- Create `diagrams/product-ai-fallback-flow.mmd`: AI configuration and local fallback decisions.
- Create `diagrams/product-export-flow.mmd`: JSON, attachments, and complete bundle flow.
- Create matching `.svg` and `.png` exports beside every source.
- Create `diagrams/PRODUCT_FUNCTION_DIAGRAMS.md`: visual index, captions, scope notes, and maintenance rule.
- Create `scripts/render-product-diagrams.sh`: deterministic rendering and export validation.

---

### Task 1: Core Product Overview Diagrams

**Files:**
- Create: `diagrams/product-learning-loop.mmd`
- Create: `diagrams/product-information-architecture.mmd`
- Create: `diagrams/product-functional-modules.mmd`
- Create: `diagrams/product-demo-storyboard.mmd`

**Interfaces:**
- Consumes: Current navigation and the domain chain `Project -> Session -> Proof -> Review`.
- Produces: Four overview sources used by the visual index and final product guide.

- [ ] **Step 1: Create the learning-loop source**

Write `diagrams/product-learning-loop.mmd` with this exact structure:

```mermaid
flowchart LR
  P[选择学习项目] --> N[明确唯一 Next Step]
  N --> C{选择记录方式}
  C -->|30 秒补记| Q[Quick Log]
  C -->|专注学习| T[Timer]
  Q --> S[生成 Session]
  T --> S
  S --> E{是否留下学习证据}
  E -->|是| F[添加 Proof\n图片·录音·文件·链接]
  E -->|暂不| L[写入 Learning Trail]
  F --> L
  L --> R[Weekly Review\nFacts·Patterns·Decisions]
  R --> A{用户明确确认}
  A -->|应用建议| N
  A -->|降频或暂停| P
```

- [ ] **Step 2: Create the information-architecture source**

Write `diagrams/product-information-architecture.mmd` with three primary tabs and Settings reachable only from conditional Review areas:

```mermaid
flowchart TD
  APP[Self Study Studio] --> O[首次启动 Onboarding]
  O --> F[完成首条 Session]
  F --> ROOT[主界面]
  ROOT --> TODAY[Today]
  ROOT --> PROJECTS[Projects]
  ROOT --> LIBRARY[Library]
  TODAY --> CONTINUE[Continue 卡片]
  CONTINUE --> QUICK[Quick Log]
  CONTINUE --> TIMER[Timer]
  TODAY --> REVIEW[Weekly Review 提醒]
  PROJECTS --> DETAIL[Project Detail]
  DETAIL --> QUICK
  DETAIL --> TIMER
  DETAIL --> PROOF[Add Proof]
  DETAIL --> TRAIL[Learning Trail]
  DETAIL --> HISTORY[历史 Review]
  DETAIL --> PROJECTREVIEW[按条件出现的 Review 区域]
  LIBRARY --> PROOFDETAIL[Proof Detail]
  LIBRARY --> EXPORT[Export]
  REVIEW -.配置入口.-> SETTINGS[AI Review Settings]
  PROJECTREVIEW -.配置入口.-> SETTINGS
```

- [ ] **Step 3: Create the functional-module source**

Write `diagrams/product-functional-modules.mmd` with three explicit layers:

```mermaid
flowchart TD
  subgraph UI[用户功能]
    O[Onboarding]
    T[Today 与 Projects]
    S[Quick Log 与 Timer]
    P[Proof 与 Library]
    R[Weekly Review]
  end
  subgraph CORE[应用协调与规则]
    VM[界面状态协调]
    J[项目·Session·Proof·Trail 规则]
    RV[复盘生成与显式应用]
    A[附件管理]
    E[完整 Bundle 导出]
  end
  subgraph DATA[本地数据与外部边界]
    DB[(SwiftData 本地库)]
    FILES[(本地附件)]
    PREFS[(偏好设置与 Keychain)]
    EXPORTS[(Exports 目录)]
    AI[可选 OpenAI-compatible 服务]
  end
  O --> VM
  T --> VM
  S --> VM
  P --> VM
  R --> VM
  VM --> J
  VM --> RV
  VM --> A
  VM --> E
  J --> DB
  RV --> J
  RV --> PREFS
  RV -.配置完整时.-> AI
  A --> FILES
  E --> DB
  E --> FILES
  E --> EXPORTS
```

- [ ] **Step 4: Create the demo-storyboard source**

Write `diagrams/product-demo-storyboard.mmd` as a seven-step horizontal story:

```mermaid
flowchart LR
  D1[1 Today\n从 Next Step 继续] --> D2[2 Timer\n完成一次专注学习]
  D2 --> D3[3 保存 Session\n写一句学习记录]
  D3 --> D4[4 添加 Proof\n说明这证明了什么]
  D4 --> D5[5 Project Trail\n查看真实推进轨迹]
  D5 --> D6[6 Weekly Review\n查看事实与模式]
  D6 --> D7[7 明确应用决定\n继续·降频·暂停]
```

- [ ] **Step 5: Validate overview scope and terminology**

Run:

```bash
rg -n "CloudKit|Calendar|Course Plan|成员|排行榜" diagrams/product-learning-loop.mmd diagrams/product-information-architecture.mmd diagrams/product-functional-modules.mmd diagrams/product-demo-storyboard.mmd
rg -n "Project|Next Step|Session|Proof|Review" diagrams/product-learning-loop.mmd diagrams/product-information-architecture.mmd diagrams/product-functional-modules.mmd diagrams/product-demo-storyboard.mmd
```

Expected: the first command returns no matches; the second finds all five stable concepts across the overview set.

- [ ] **Step 6: Commit the overview sources**

```bash
git add diagrams/product-learning-loop.mmd diagrams/product-information-architecture.mmd diagrams/product-functional-modules.mmd diagrams/product-demo-storyboard.mmd
git commit -m "docs: add product overview diagram sources"
```

---

### Task 2: First-Use, Session, and Proof Flow Diagrams

**Files:**
- Create: `diagrams/product-onboarding-flow.mmd`
- Create: `diagrams/product-session-flow.mmd`
- Create: `diagrams/product-proof-flow.mmd`

**Interfaces:**
- Consumes: `OnboardingView`, `QuickLogView`, `TimerSessionView`, `AddProofView`, and the implemented validation rules.
- Produces: Three focused flow sources explaining daily product use.

- [ ] **Step 1: Create the onboarding flow**

```mermaid
flowchart TD
  A[首次打开 App] --> B[填写 1–3 个当前学习项目]
  B --> C{每个项目是否完整}
  C -->|否| D[提示补充名称·领域·目标·Next Step]
  D --> B
  C -->|是| E[一次性创建全部项目]
  E --> F[选择第一个项目]
  F --> G[记录第一条 Quick Log Session]
  G --> H{Session 保存成功}
  H -->|否| G
  H -->|是| I[Onboarding 完成]
  I --> J[进入 Today Continue]
```

- [ ] **Step 2: Create the Session flow**

```mermaid
flowchart TD
  A[从 Today 或 Project Detail 开始] --> B{选择方式}
  B -->|快速补记| C[Quick Log]
  B -->|现场学习| D[Timer]
  C --> E[使用项目默认类型与时长]
  E --> F[填写一句记录和新的 Next Step]
  D --> G[开始计时]
  G --> H{学习过程}
  H -->|暂停| I[暂停计时]
  I -->|继续| G
  H -->|舍弃| J[不保存并退出]
  H -->|结束| K[计算实际活动时长]
  F --> L[保存 Session]
  K --> L
  L --> M[更新 Project 与 Trail]
  M --> N{现在添加 Proof}
  N -->|是| O[进入 Add Proof]
  N -->|否| P[返回原页面]
```

- [ ] **Step 3: Create the Proof flow**

```mermaid
flowchart TD
  A[从 Session·Project·Library 添加 Proof] --> B{选择类型}
  B --> C[图片\n相机或照片库]
  B --> D[录音\n本地音频]
  B --> E[文件\n系统文件选择器]
  B --> F[链接\n外部 URL]
  C --> G[准备附件]
  D --> G
  E --> G
  F --> H[填写链接]
  G --> I[填写标题]
  H --> I
  I --> J[填写“这证明了什么”]
  J --> K{证明说明是否有效}
  K -->|否| L[提示补充具体学习证据]
  L --> J
  K -->|是| M[保存附件与 Proof]
  M --> N[写入 Learning Trail]
  N --> O[可在 Library 与 Proof Detail 查看]
```

- [ ] **Step 4: Save the three sources and validate node limits**

Run:

```bash
for file in diagrams/product-onboarding-flow.mmd diagrams/product-session-flow.mmd diagrams/product-proof-flow.mmd; do rg -o "[A-Z][A-Z0-9]*\[|[A-Z][A-Z0-9]*\{" "$file" | wc -l; done
```

Expected: onboarding and Proof have no more than 16 nodes; Session may use up to 17 because pause/resume/discard are independently meaningful user states.

- [ ] **Step 5: Commit the daily-use sources**

```bash
git add diagrams/product-onboarding-flow.mmd diagrams/product-session-flow.mmd diagrams/product-proof-flow.mmd
git commit -m "docs: add onboarding session and proof flows"
```

---

### Task 3: Review, AI Fallback, and Export Flow Diagrams

**Files:**
- Create: `diagrams/product-review-flow.mmd`
- Create: `diagrams/product-ai-fallback-flow.mmd`
- Create: `diagrams/product-export-flow.mmd`

**Interfaces:**
- Consumes: current Review prompt rules, provider fallback behavior, explicit apply actions, and `ExportService` output types.
- Produces: Three decision-oriented flow sources used in product explanation and Demo backup paths.

- [ ] **Step 1: Create the Weekly Review flow**

```mermaid
flowchart TD
  A[活跃项目 7 天无记录\n或近期证据足够] --> B[Today 显示 Review 提醒]
  B --> C[聚合本周期 Session 与 Proof]
  C --> D[生成 Facts·Patterns·Decisions·Next Steps]
  D --> E[显示来源引用]
  E --> F[用户编辑复盘内容]
  F --> G[保存 Review]
  G --> H{是否应用项目建议}
  H -->|应用状态| I[明确修改 active·low-frequency·paused]
  H -->|应用 Next Step| J[明确更新唯一下一步]
  H -->|暂不应用| K[只保留 Review 记录]
  I --> L[写入 Project Trail]
  J --> L
  K --> L
```

- [ ] **Step 2: Create the AI fallback flow**

```mermaid
flowchart TD
  A[开始 Weekly Review] --> B{AI Endpoint·Model·API Key 是否齐全}
  B -->|否| C[使用本地规则复盘]
  B -->|是| D[请求 OpenAI-compatible Chat Completions]
  D --> E{请求与 JSON 解析是否成功}
  E -->|否| C
  E -->|是| F[使用 AI Review 草稿]
  C --> G[生成可编辑 Review]
  F --> G
  G --> H[用户检查来源与结论]
  H --> I[保存或显式应用建议]
```

- [ ] **Step 3: Create the export flow**

```mermaid
flowchart TD
  A[进入 Library Export] --> B{选择导出方式}
  B -->|仅结构化数据| C[生成带版本号的 journal.json]
  B -->|仅学习附件| D[按 Project·Session·Proof 复制附件]
  B -->|完整备份| E[创建 Export Bundle]
  E --> C
  E --> D
  C --> F[写入本地 Exports 目录]
  D --> F
  F --> G{导出是否成功}
  G -->|否| H[显示错误并保留原始数据]
  G -->|是| I[通过系统分享或文件管理取用]
```

- [ ] **Step 4: Validate explicit user control and fallback coverage**

Run:

```bash
rg -n "用户|明确|暂不应用" diagrams/product-review-flow.mmd
rg -n "本地规则复盘|请求与 JSON 解析是否成功" diagrams/product-ai-fallback-flow.mmd
rg -n "journal.json|附件|完整备份|错误" diagrams/product-export-flow.mmd
```

Expected: every command finds all listed terms.

- [ ] **Step 5: Commit the decision flows**

```bash
git add diagrams/product-review-flow.mmd diagrams/product-ai-fallback-flow.mmd diagrams/product-export-flow.mmd
git commit -m "docs: add review fallback and export flows"
```

---

### Task 4: Rendering Pipeline and Static Image Exports

**Files:**
- Create: `scripts/render-product-diagrams.sh`
- Create: `diagrams/product-*.svg`
- Create: `diagrams/product-*.png`

**Interfaces:**
- Consumes: all ten `diagrams/product-*.mmd` sources.
- Produces: reproducible SVG and PNG images suitable for Markdown and presentations.

- [ ] **Step 1: Create the rendering script**

Write a POSIX-compatible script that resolves repo root, accepts `PNPM_BIN`, and renders every `product-*.mmd`:

```bash
#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNPM_BIN="${PNPM_BIN:-pnpm}"
MERMAID_CLI_PACKAGE="${MERMAID_CLI_PACKAGE:-@mermaid-js/mermaid-cli@11.16.0}"

if [ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ] && \
  [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  export PUPPETEER_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi

render_format() {
  format="$1"
  for source in "$ROOT"/diagrams/product-*.mmd; do
    base="${source%.mmd}"
    "$PNPM_BIN" dlx "$MERMAID_CLI_PACKAGE" \
      --input "$source" \
      --output "${base}.${format}" \
      --theme neutral \
      --backgroundColor white \
      --width 1800
  done
}

render_format svg &
svg_pid=$!
render_format png &
png_pid=$!
wait "$svg_pid"
wait "$png_pid"
```

- [ ] **Step 2: Make the script executable and run it**

Run:

```bash
chmod +x scripts/render-product-diagrams.sh
PNPM_BIN=/Users/bytedance/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback/pnpm scripts/render-product-diagrams.sh
```

Expected: ten SVG files and ten PNG files are created without Mermaid parse errors.

- [ ] **Step 3: Validate file count and image integrity**

Run:

```bash
find diagrams -maxdepth 1 -name 'product-*.mmd' | wc -l
find diagrams -maxdepth 1 -name 'product-*.svg' | wc -l
find diagrams -maxdepth 1 -name 'product-*.png' | wc -l
file diagrams/product-*.svg diagrams/product-*.png
```

Expected: each count is `10`; `file` identifies every export as SVG or PNG image data.

- [ ] **Step 4: Visually inspect every PNG**

Open each PNG with the local image viewer and verify:

- no clipped node labels;
- no overlapping edges and labels;
- Chinese glyphs render correctly;
- the longest flow remains readable at full width;
- opaque white backgrounds preserve connector and label contrast;
- current and fallback paths are visually distinguishable by labels and shapes.

If a diagram fails, edit only its `.mmd` source, rerun the rendering script, and inspect again.

- [ ] **Step 5: Commit the pipeline and exports**

```bash
git add scripts/render-product-diagrams.sh diagrams/product-*.svg diagrams/product-*.png
git commit -m "docs: render product function diagrams"
```

---

### Task 5: Visual Index and Documentation Integration

**Files:**
- Create: `diagrams/PRODUCT_FUNCTION_DIAGRAMS.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: all sources and rendered assets from Tasks 1–4.
- Produces: one discoverable visual guide and a repository entry point.

- [ ] **Step 1: Create the visual index**

Write `diagrams/PRODUCT_FUNCTION_DIAGRAMS.md` in this order:

1. Product learning loop
2. Current information architecture
3. Functional module relationships
4. Standard Demo storyboard
5. First-use onboarding
6. Daily Session recording
7. Proof creation
8. Weekly Review
9. AI fallback
10. Export

For each section embed the SVG with relative Markdown such as:

```markdown
![学习轨迹核心闭环](./product-learning-loop.svg)

图注：Quick Log 与 Timer 都生成同一种 Session；Review 只有在用户确认后才修改项目状态或 Next Step。
```

Add a final “尚未进入当前产品流程” section listing CloudKit/iCloud sync, AI course planning, and Calendar as designed-only.

- [ ] **Step 2: Add the README entry**

Immediately after the README introduction, add:

```markdown
## Product Documentation

- [产品功能说明图](diagrams/PRODUCT_FUNCTION_DIAGRAMS.md)
- [产品功能手册设计](docs/superpowers/specs/2026-07-12-product-guide-design.md)

When user-visible behavior changes, update the affected diagram source and regenerate its SVG and PNG exports.
```

- [ ] **Step 3: Validate links and maintenance metadata**

Run:

```bash
rg -n "product-.*\.svg" diagrams/PRODUCT_FUNCTION_DIAGRAMS.md
rg -n "产品功能说明图|user-visible behavior" README.md
git diff --check
```

Expected: the index contains ten SVG links, README contains both required maintenance lines, and `git diff --check` prints no errors.

- [ ] **Step 4: Re-run the current test baseline without changing product code**

Run:

```bash
swift test
```

Expected: 50 tests execute; the known `testOpenAICompatibleProviderParsesJSONContentFromChatCompletion` source-reference assertion may remain the single failure. Any additional failure blocks completion.

- [ ] **Step 5: Commit the visual index and README entry**

```bash
git add diagrams/PRODUCT_FUNCTION_DIAGRAMS.md README.md
git commit -m "docs: publish product function diagram guide"
```

---

## Final Verification

Run:

```bash
git status --short
find diagrams -maxdepth 1 -name 'product-*' | sort
rg -n "CloudKit|iCloud|Calendar|Course Plan" diagrams/product-*.mmd diagrams/PRODUCT_FUNCTION_DIAGRAMS.md
```

Expected:

- Only the user's pre-existing `.gitignore` and untracked legacy diagram files remain outside this plan's commits.
- Ten `.mmd`, ten `.svg`, and ten `.png` product diagram files exist.
- Designed-only features appear only in the visual index scope note, not inside current product flows.
- Every PNG has passed visual inspection.
