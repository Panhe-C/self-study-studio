# Canva-Ready Product Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shared, evidence-backed product guide that exports as a 16:9 editable PPTX, an A4 editable PPTX and PDF, plus a living Markdown manual with real Simulator demo screenshots and the existing ten product flow diagrams.

**Architecture:** `docs/product-guide/content.json` is the shared release metadata and slide/page outline, while `docs/PRODUCT_GUIDE.md` remains the authoritative long-form product text. A single JavaScript generator built with `@oai/artifact-tool` consumes the content, diagrams, and screenshots to create both editable layouts. Static Simulator screenshots and Mermaid renders stay in stable asset directories, and a shell entry point repeats generation and verification.

**Tech Stack:** Swift 6 / SwiftUI app, iOS Simulator, Mermaid SVG/PNG assets, JavaScript ES modules, `@oai/artifact-tool`, LibreOffice PDF export, Poppler PDF rendering, presentation QA scripts.

## Global Constraints

- The 16:9 deck contains 18-22 slides and the A4 guide contains approximately 25-35 pages.
- Real Simulator screenshots take priority over concepts; missing screens must be disclosed instead of fabricated.
- Current product flows include only implemented behavior; CloudKit/iCloud sync, AI course planning, and Calendar remain labeled "已设计".
- Primary visual language: warm neutral background, dark gray copy, blue-purple accent, green for success, orange for reminder or fallback.
- Reuse the ten checked-in `diagrams/product-*.png` assets and keep their Mermaid sources authoritative.
- Visible copy is Chinese, with stable product terms Today, Project, Session, Proof, Trail, Review, and Next Step retained.
- All final artifacts must have no text overflow, unintended overlap, stretched images, broken glyphs, or unresolved placeholders.
- Preserve the user's unrelated changes in the main worktree; all implementation stays in `.worktrees/product-function-diagrams`.

---

### Task 1: Establish the shared product content and living Markdown guide

**Files:**
- Create: `docs/product-guide/content.json`
- Create: `docs/PRODUCT_GUIDE.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `diagrams/PRODUCT_FUNCTION_DIAGRAMS.md`, current Swift sources, tests, README verification baseline.
- Produces: `content.json` with `release`, `deckSections`, `featureStatus`, `demoSteps`, and `limitations`; `PRODUCT_GUIDE.md` with the same product facts in long-form form.

- [ ] **Step 1: Audit current product behavior against source and tests**

Run:

```bash
rg -n "navigationTitle|TabView|Quick Log|Timer|Proof|Weekly Review|Export|Keychain|SwiftData" Sources Tests README.md
```

Expected: every claimed current capability has a source or test reference; CloudKit, course planning, and Calendar do not appear as current navigation features.

- [ ] **Step 2: Write the shared content manifest**

Create `docs/product-guide/content.json` with these required top-level keys and stable section IDs:

```json
{
  "release": {
    "product": "Self Study Studio",
    "documentVersion": "1.0",
    "verifiedOn": "2026-07-13",
    "gitCommit": "GENERATED_AT_BUILD",
    "productStage": "v0.1 learning loop"
  },
  "deckSections": [
    { "id": "positioning", "title": "学习记录的目的，是决定下一步" },
    { "id": "loop", "title": "Session 与 Proof 把行动变成可复盘的轨迹" },
    { "id": "demo", "title": "一次演示讲清完整学习闭环" },
    { "id": "status", "title": "当前能力与规划能力保持清晰边界" }
  ],
  "featureStatus": [],
  "demoSteps": [],
  "limitations": []
}
```

Populate the arrays with the exact implemented features, ten diagram paths, screenshot paths, AI fallback, export behavior, current 50/49/1 test baseline, and designed-only capabilities.

- [ ] **Step 3: Write the long-form product guide**

Create `docs/PRODUCT_GUIDE.md` with: release metadata; positioning; concepts; information architecture; 15 detailed feature sections; five end-to-end flows; the 5-10 minute demo script; status matrix; limitations; roadmap; maintenance checklist; changelog. Embed the relevant `../diagrams/product-*.svg` next to each flow and `assets/product-guide/demo-*.png` next to available Demo steps.

- [ ] **Step 4: Add stable documentation entry points**

Update README Product Documentation with links to:

```markdown
- [产品功能手册](docs/PRODUCT_GUIDE.md)
- [Canva 可导入演示稿](docs/product-guide/self-study-studio-product-deck.pptx)
- [Canva 可导入 A4 手册](docs/product-guide/self-study-studio-product-guide-a4.pdf)
- [产品功能说明图](diagrams/PRODUCT_FUNCTION_DIAGRAMS.md)
```

- [ ] **Step 5: Validate content structure and commit**

Run:

```bash
node -e "const c=require('./docs/product-guide/content.json'); if(!c.release||!c.deckSections||!c.featureStatus||!c.demoSteps||!c.limitations) process.exit(1)"
rg -n "DRAFT_MARKER|INCOMPLETE_MARKER" docs/PRODUCT_GUIDE.md docs/product-guide/content.json
git diff --check
```

Expected: JSON validation succeeds, placeholder search returns no matches, and `git diff --check` returns no output.

Commit:

```bash
git add README.md docs/PRODUCT_GUIDE.md docs/product-guide/content.json
git commit -m "docs: publish living product guide content"
```

---

### Task 2: Capture a coherent set of real Simulator demo screens

**Files:**
- Create: `docs/assets/product-guide/demo-journal.json`
- Create: `docs/assets/product-guide/demo-01-today.png`
- Create: `docs/assets/product-guide/demo-02-quick-log.png`
- Create: `docs/assets/product-guide/demo-03-timer.png`
- Create: `docs/assets/product-guide/demo-04-session.png`
- Create: `docs/assets/product-guide/demo-05-proof-add.png`
- Create: `docs/assets/product-guide/demo-06-proof-detail.png`
- Create: `docs/assets/product-guide/demo-07-trail.png`
- Create: `docs/assets/product-guide/demo-08-review.png`
- Create: `docs/assets/product-guide/demo-09-library.png`
- Create: `docs/assets/product-guide/demo-10-export.png`
- Create: `docs/assets/product-guide/SCREENSHOTS.md`

**Interfaces:**
- Consumes: `JournalSnapshot` Codable schema, bundle ID `com.local.selfstudystudio`, iPhone Simulator runtime.
- Produces: privacy-safe 1179x2556-or-equivalent portrait PNG screenshots and a provenance record listing device, OS, app commit, seed data, and capture date.

- [ ] **Step 1: Create deterministic demo data**

Write `demo-journal.json` with three fixed Projects (`CS336`, `吉他弹唱`, `DaVinci 调色`), completed onboarding, representative Quick Log and Timer Sessions, image/link Proof records, Trail events, and a local-rule Review. Use fixed UUIDs and ISO-8601 timestamps so repeated imports show the same story.

- [ ] **Step 2: Verify the app and demo data build path**

Run:

```bash
swift test --skip-build
xcodebuild -project SelfStudyStudio.xcodeproj -scheme SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/self-study-studio-product-guide build
```

Expected: the app build succeeds; the test suite executes 50 tests with the pre-existing ReviewService failure documented if still present.

- [ ] **Step 3: Install and seed the booted iPhone Simulator**

Run:

```bash
xcrun simctl bootstatus booted -b
xcrun simctl uninstall booted com.local.selfstudystudio || true
xcrun simctl install booted /tmp/self-study-studio-product-guide/Build/Products/Debug-iphonesimulator/SelfStudyStudio.app
APP_DATA="$(xcrun simctl get_app_container booted com.local.selfstudystudio data)"
mkdir -p "$APP_DATA/Documents/LearningJournal"
cp docs/assets/product-guide/demo-journal.json "$APP_DATA/Documents/LearningJournal/journal.json"
xcrun simctl launch booted com.local.selfstudystudio
```

Expected: Today opens with the CS336, guitar, and DaVinci demo story; no onboarding or personal data appears.

- [ ] **Step 4: Capture each real UI state**

Navigate the Simulator through Today, Quick Log, Timer, Project detail, Proof, Trail, Review, Library, and Export. For each state run:

```bash
xcrun simctl io booted screenshot docs/assets/product-guide/demo-01-today.png
```

Repeat with the corresponding stable filename. If a target screen cannot be reproduced, omit that PNG and record the reason in `SCREENSHOTS.md`; never synthesize a replacement screenshot.

- [ ] **Step 5: Inspect screenshot quality and provenance**

Check all screenshots for matching device dimensions, no secrets, no system notification overlays, readable copy, and coherent data. Record device name, iOS version, capture date, branch commit, and omitted states in `SCREENSHOTS.md`.

- [ ] **Step 6: Commit real demo assets**

Run:

```bash
file docs/assets/product-guide/demo-*.png
git diff --check
git add docs/assets/product-guide
git commit -m "docs: add real product demo screenshots"
```

Expected: every captured asset is a valid PNG and the screenshot ledger matches the files present.

---

### Task 3: Build the shared Canva-ready presentation generator

**Files:**
- Create: `scripts/generate-product-guide.mjs`
- Create: `scripts/generate-product-guide.sh`
- Create: `docs/product-guide/README.md`
- Create: `docs/product-guide/self-study-studio-product-deck.pptx`
- Create: `docs/product-guide/self-study-studio-product-guide-a4.pptx`

**Interfaces:**
- Consumes: `docs/product-guide/content.json`, `docs/PRODUCT_GUIDE.md`, `diagrams/product-*.png`, `docs/assets/product-guide/demo-*.png`.
- Produces: `buildWideDeck(content, assets) -> Presentation`, `buildA4Guide(content, assets) -> Presentation`, final PPTX files, preview PNGs and layout JSON in external scratch space.

- [ ] **Step 1: Initialize the artifact-tool scratch workspace**

Run:

```bash
SCRATCH_ROOT="$(node -p "require('node:os').tmpdir()")"
WORKSPACE="$SCRATCH_ROOT/codex-presentations/${CODEX_THREAD_ID:-manual-20260713}/self-study-studio-product-guide"
mkdir -p "$WORKSPACE/tmp"
node "/Users/bytedance/.codex/plugins/cache/openai-primary-runtime/presentations/26.709.11516/skills/presentations/container_tools/setup_artifact_tool_workspace.mjs" --workspace "$WORKSPACE/tmp"
```

Expected: `$WORKSPACE/tmp/node_modules/@oai/artifact-tool` resolves from Node.

- [ ] **Step 2: Implement stable content and asset loading**

In `generate-product-guide.mjs`, implement:

```js
async function loadProductGuide(repoRoot) {
  const content = JSON.parse(await fs.readFile(path.join(repoRoot, "docs/product-guide/content.json"), "utf8"));
  content.release.gitCommit = execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: repoRoot, encoding: "utf8" }).trim();
  return { content, assets: await resolveAssets(repoRoot, content) };
}
```

`resolveAssets` must fail with a path-specific error for every required diagram and include only screenshot files that actually exist.

- [ ] **Step 3: Implement reusable editable slide primitives**

Implement `addTitle`, `addBody`, `addImage`, `addFooter`, `addSectionMarker`, and `addStatusTable`. Use 1280x720 pixels for wide slides and 794x1123 pixels for A4 pages. Fonts must meet 50/35/24/16 pt-equivalent minimums in the wide deck; A4 body text must remain at least 16 px and readable at 100%.

- [ ] **Step 4: Build the 16:9 narrative deck**

Implement `buildWideDeck(content, assets)` with 18-22 slides following:

```text
problem -> product loop -> concepts -> information architecture -> module boundaries
-> onboarding -> Today -> Quick Log -> Timer -> Proof -> Trail -> Review
-> AI fallback -> Library/export -> Demo storyboard -> status -> limitations -> close
```

Each slide has one takeaway title, one dominant diagram or screenshot, and at most one concise supporting text block. Do not reuse a screenshot or diagram on multiple slides unless it is a background.

- [ ] **Step 5: Build the A4 editable guide**

Implement `buildA4Guide(content, assets)` with 25-35 portrait pages. Reuse the same content facts and assets but allow more explanatory text, Demo instructions, feature rules, validation evidence, and maintenance guidance. Do not merely scale down wide slides.

- [ ] **Step 6: Export editable decks and QA evidence**

Export both presentations with `PresentationFile.exportPptx`. Also export every slide/page to PNG, every layout to JSON, and one montage per output under the external scratch workspace. Ensure the output directory exists before saving.

- [ ] **Step 7: Add the repeatable shell entry point**

`scripts/generate-product-guide.sh` must use `set -eu`, resolve the repository root, initialize the artifact workspace if missing, run the generator, then run presentation overflow checks on both PPTX files. Document the exact command and Canva import workflow in `docs/product-guide/README.md`.

- [ ] **Step 8: Generate, validate, and commit the editable decks**

Run:

```bash
scripts/generate-product-guide.sh
python3 "/Users/bytedance/.codex/plugins/cache/openai-primary-runtime/presentations/26.709.11516/skills/presentations/container_tools/slides_test.py" docs/product-guide/self-study-studio-product-deck.pptx
python3 "/Users/bytedance/.codex/plugins/cache/openai-primary-runtime/presentations/26.709.11516/skills/presentations/container_tools/slides_test.py" docs/product-guide/self-study-studio-product-guide-a4.pptx
```

Expected: both decks export, slide counts are within bounds, and overflow checks report no out-of-bounds elements.

Commit:

```bash
git add scripts/generate-product-guide.mjs scripts/generate-product-guide.sh docs/product-guide
git commit -m "docs: generate Canva-ready product guide decks"
```

---

### Task 4: Export and verify the A4 PDF

**Files:**
- Create: `docs/product-guide/self-study-studio-product-guide-a4.pdf`

**Interfaces:**
- Consumes: `self-study-studio-product-guide-a4.pptx`.
- Produces: A4 portrait PDF with the same page count and readable embedded Chinese text/images.

- [ ] **Step 1: Export the A4 PPTX to PDF**

Run:

```bash
mkdir -p /tmp/self-study-studio-product-guide-pdf
soffice --headless --convert-to pdf --outdir /tmp/self-study-studio-product-guide-pdf docs/product-guide/self-study-studio-product-guide-a4.pptx
cp /tmp/self-study-studio-product-guide-pdf/self-study-studio-product-guide-a4.pdf docs/product-guide/self-study-studio-product-guide-a4.pdf
```

Expected: LibreOffice exits successfully and produces a non-empty PDF.

- [ ] **Step 2: Verify PDF geometry, page count, and extractable text**

Run:

```bash
pdfinfo docs/product-guide/self-study-studio-product-guide-a4.pdf
pdftotext docs/product-guide/self-study-studio-product-guide-a4.pdf - | rg "Self Study Studio|学习轨迹|Weekly Review|已设计"
```

Expected: A4 page size, 25-35 pages, and all four text checks match.

- [ ] **Step 3: Render every PDF page for visual inspection**

Run:

```bash
mkdir -p /tmp/self-study-studio-product-guide-pdf/pages
pdftoppm -png -r 120 docs/product-guide/self-study-studio-product-guide-a4.pdf /tmp/self-study-studio-product-guide-pdf/pages/page
```

Inspect every rendered page at full size for clipping, overlap, broken glyphs, image distortion, poor page breaks, and unreadable annotations. Fix the generator and regenerate both PPTX and PDF if any issue appears.

- [ ] **Step 4: Commit the verified PDF**

Run:

```bash
git add docs/product-guide/self-study-studio-product-guide-a4.pdf
git commit -m "docs: export A4 product guide PDF"
```

---

### Task 5: Run final visual, content, and maintenance verification

**Files:**
- Modify: `docs/PRODUCT_GUIDE.md`
- Modify: `docs/product-guide/content.json`
- Modify: `docs/product-guide/README.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: all final outputs, latest Git commit, test/build results.
- Produces: consistent release metadata, final QA evidence, and a clean feature branch ready for review.

- [ ] **Step 1: Inspect every slide and page individually**

Render both PPTX files with `render_slides.py`, create montages for deck-level consistency, and inspect each full-size PNG. Fix every unintended overlap, wrapped one-line title, clipped label, stretched screenshot, unreadable connector, or inconsistent footer.

- [ ] **Step 2: Re-run content accuracy checks**

Compare the status matrix and limitations in Markdown, `content.json`, PPTX, and PDF. Confirm the test baseline and current commit are consistent. Confirm planned CloudKit, course planning, and Calendar features never appear as current flows.

- [ ] **Step 3: Run final automated checks**

Run:

```bash
sh -n scripts/generate-product-guide.sh
scripts/generate-product-guide.sh
python3 "/Users/bytedance/.codex/plugins/cache/openai-primary-runtime/presentations/26.709.11516/skills/presentations/container_tools/slides_test.py" docs/product-guide/self-study-studio-product-deck.pptx
python3 "/Users/bytedance/.codex/plugins/cache/openai-primary-runtime/presentations/26.709.11516/skills/presentations/container_tools/slides_test.py" docs/product-guide/self-study-studio-product-guide-a4.pptx
pdfinfo docs/product-guide/self-study-studio-product-guide-a4.pdf
swift test --skip-build
git diff --check
git status --short
```

Expected: generation is repeatable, both presentation checks pass, PDF is valid A4, the known test baseline is accurately reported, diff check returns no output, and only intended files are staged or committed.

- [ ] **Step 4: Commit release metadata corrections**

If generation or verification changed metadata or documentation, commit only those changes:

```bash
git add README.md docs/PRODUCT_GUIDE.md docs/product-guide/content.json docs/product-guide/README.md
git commit -m "docs: finalize product guide release metadata"
```

- [ ] **Step 5: Request independent review**

Use `superpowers:requesting-code-review` to review content accuracy, visual QA evidence, reproducibility, and repository hygiene before any merge decision.
