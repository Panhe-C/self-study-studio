# Self Study Studio vNext 实施计划

> 实施前先阅读 [`docs/PRODUCT_VNEXT.md`](../../PRODUCT_VNEXT.md) 和 [`vNext Spec`](../specs/2026-08-10-ai-guided-learning-vnext-design.md)。本计划使用测试优先、小提交、可回滚的顺序；不得把自动化测试等同于真机、CloudKit、通知、附件或 VoiceOver 验收。

**目标：** 在保留现有 Journal、Plan Revision、CloudKit、Calendar 和 Proof 数据兼容性的前提下，把 iPhone 主体验收敛为“AI 草稿 → 用户确认 → Today 执行 → 完成检查 → 确认记录 → 动态调整”。

**架构：** 复用 `Project + LearningPlan + PlanPhase + PlannedSession + LearningSession`。未确认学习草稿进入设备本地 `PendingStudyCaptureStore`；确认后通过 `JournalService` 原子写入现有 Journal。新增记录 assessment、修正快照和调整建议，接入既有 repository、CloudKit 和 record contract。UI 以新 Study Flow 组合现有 timer、Proof 和 plan service，不在 `JournalViewModel` 中继续堆领域逻辑。

**技术栈：** Swift 6、SwiftUI、SwiftData、CloudKit、UserNotifications、XCTest / Swift Testing、iOS 17+、macOS 14+ package tests。

## 全局约束

- iPhone-first；Web 只做合同兼容，不在本计划重做完整界面。
- 不重命名持久化 `Project`、`CoursePlan` record type 或既有 CloudKit zone。
- 同一 Project 只有一个 active Learning Plan revision。
- AI 生成的内容默认均为 draft；用户确认前不改变计划和历史。
- “结束学习”不得直接创建 `LearningSession` 或完成 `PlannedSession`。
- 未确认草稿不进入 Journal、不上传 CloudKit。
- 已确认记录与计划完成必须在同一 repository transaction 中提交。
- 手动、确定性 fallback 必须覆盖 AI 失败。
- Calendar、Library、Reviews 从一级导航移除，不删除底层能力。
- 保留当前 worktree 中与本计划无关的修改。

## 目标文件结构

新增领域与服务：

- `Sources/PersonalLearningJournal/StudyFlow/StudyFlowDomain.swift`
- `Sources/PersonalLearningJournal/StudyFlow/PendingStudyCaptureStore.swift`
- `Sources/PersonalLearningJournal/StudyFlow/CompletionCheckProvider.swift`
- `Sources/PersonalLearningJournal/StudyFlow/LearningRecordDraftProvider.swift`
- `Sources/PersonalLearningJournal/StudyFlow/LearningRecordService.swift`
- `Sources/PersonalLearningJournal/Adjustments/LearningAdjustmentDomain.swift`
- `Sources/PersonalLearningJournal/Adjustments/LearningAdjustmentService.swift`
- `Sources/PersonalLearningJournal/Views/VNextTodayView.swift`
- `Sources/PersonalLearningJournal/Views/CoursesView.swift`
- `Sources/PersonalLearningJournal/Views/ActiveStudyView.swift`
- `Sources/PersonalLearningJournal/Views/CompletionCheckView.swift`
- `Sources/PersonalLearningJournal/Views/LearningRecordDraftView.swift`
- `Sources/PersonalLearningJournal/Views/LearningRecordDetailView.swift`
- `Sources/PersonalLearningJournal/Views/PlanRevisionDiffView.swift`

新增主要测试：

- `Tests/PersonalLearningJournalTests/VNextProductContractTests.swift`
- `Tests/PersonalLearningJournalTests/PendingStudyCaptureStoreTests.swift`
- `Tests/PersonalLearningJournalTests/CompletionCheckProviderTests.swift`
- `Tests/PersonalLearningJournalTests/LearningRecordServiceTests.swift`
- `Tests/PersonalLearningJournalTests/LearningAdjustmentServiceTests.swift`
- `Tests/PersonalLearningJournalTests/VNextEndToEndTests.swift`

---

## Task 1：建立 vNext 产品合同测试

**Files**

- Create: `Tests/PersonalLearningJournalTests/VNextProductContractTests.swift`
- Modify: `Sources/PersonalLearningJournal/Views/StudioPresentation.swift`
- Modify: `Tests/PersonalLearningJournalTests/StudioPresentationTests.swift`

### Steps

- [ ] 写失败测试，固定以下不可回退行为：两 Tab、一个 Up Next、最多两个 alternatives、draft 未启用不进入 Today、结束学习不等于确认记录。
- [ ] 为展示层增加小型 `StudioExperienceContract`，只表达导航和数量约束，不放领域行为。
- [ ] 运行 `swift test --filter VNextProductContractTests`，确认 RED → GREEN。
- [ ] 运行现有 `StudioPresentationTests`，确保没有破坏通用排版规则。
- [ ] Commit：`test: define vnext product contract`

验收重点：本任务只建立防回退边界，不改 RootView。

---

## Task 2：扩展课程输入和活动完成标准

**Files**

- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanningDomain.swift`
- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanningProvider.swift`
- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanValidator.swift`
- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanningService.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningDomainTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningProviderTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanValidatorTests.swift`

### Steps

- [ ] 为 `studyPeriodWeeks`、`prerequisites`、`constraints` 写旧 JSON / 新 JSON 解码测试。
- [ ] 为 `completionCriteria` 和 `recommendationReason` 写 draft → persisted PlannedSession round-trip 测试。
- [ ] 实现向后兼容字段；旧记录使用 nil / 空值默认。
- [ ] 更新 provider prompt 和 response schema，要求每个 activity 返回 1–5 个可观察 criteria。
- [ ] Validator 拒绝空白 criteria、超过 5 项和不可用 phase reference；允许旧 draft criteria 为空并添加 warning。
- [ ] 更新 `requestPreview` 测试，证明只包含用户输入和 request-scoped context。
- [ ] 运行：
  - `swift test --filter CoursePlanningDomainTests`
  - `swift test --filter CoursePlanningProviderTests`
  - `swift test --filter CoursePlanValidatorTests`
- [ ] Commit：`feat: add vnext planning inputs and completion criteria`

---

## Task 3：完善计划草稿的局部 Review 能力

**Files**

- Create: `Sources/PersonalLearningJournal/Planning/CoursePlanDraftEditingService.swift`
- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanningProvider.swift`
- Modify: `Sources/PersonalLearningJournal/Views/CoursePlanWizardView.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Create: `Tests/PersonalLearningJournalTests/CoursePlanDraftEditingTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CoursePlanningEndToEndTests.swift`

### Steps

- [ ] 写 reducer 测试：编辑、删除、插入、移动 activity，删除 Phase 时清理关联 sessions，undo 恢复最近一次编辑。
- [ ] 实现纯值类型 `CoursePlanDraftEditingService`，不在 View 内直接维护跨对象一致性。
- [ ] 为 provider 增加 `regeneratePhase(input:context:phase:)`；输出只能替换目标 Phase 及其 sessions。
- [ ] 写测试证明单 Phase 重生成不会改变其他 Phase 的 ID、文本和顺序。
- [ ] 重构 DraftEditor：显示 `AI 草稿 · 未生效`、canonical Milestone、criteria、assumptions、capacity warning。
- [ ] 保留 Create Manual Draft 和完整手动编辑路径。
- [ ] 运行 focused tests 和 `CoursePlanningEndToEndTests`。
- [ ] Commit：`feat: support reviewable plan draft editing`

---

## Task 4：建立未确认学习草稿与本地恢复

**Files**

- Create: `Sources/PersonalLearningJournal/StudyFlow/StudyFlowDomain.swift`
- Create: `Sources/PersonalLearningJournal/StudyFlow/PendingStudyCaptureStore.swift`
- Create: `Tests/PersonalLearningJournalTests/PendingStudyCaptureStoreTests.swift`
- Modify: `Sources/PersonalLearningJournal/Views/JournalApplicationSession.swift`

### Steps

- [ ] 定义 `PendingStudyCapture`、`CompletionCheckDraft`、answers、record draft 和 lifecycle state。
- [ ] 写测试：开始、暂停、恢复、结束、保存稍后、放弃；状态转换非法时抛出明确错误。
- [ ] 使用 Application Support 下单独 JSON 文件实现原子写入（临时文件 + replace）。
- [ ] 每次关键状态变化后保存；高频 timer tick 不每秒写盘，只保存累计 active seconds 和最近开始时间。
- [ ] 写 crash-recovery 测试：active timer、半填 check、待确认 record draft 均可恢复。
- [ ] 证明该 store 不进入 `JournalSnapshot`、export 和 CloudKit outbox。
- [ ] 接入 app session 生命周期，在 background / termination 前保存。
- [ ] Commit：`feat: add recoverable pending study captures`

---

## Task 5：实现完成检查 Provider 和确定性 fallback

**Files**

- Create: `Sources/PersonalLearningJournal/StudyFlow/CompletionCheckProvider.swift`
- Modify: `Sources/PersonalLearningJournal/AI/StructuredAIClient.swift`
- Create: `Tests/PersonalLearningJournalTests/CompletionCheckProviderTests.swift`
- Test: `Tests/PersonalLearningJournalTests/StructuredAIClientTests.swift`

### Steps

- [ ] 先写固定 schema 测试：progress 为必填，criteria 1–5 条，understanding / blocker 可选。
- [ ] 写安全测试：返回结果不能含 selected answer、completion verdict 或 plan mutation。
- [ ] 实现 `OpenAICompatibleCompletionCheckProvider`。
- [ ] 实现 `RuleBasedCompletionCheckProvider`：直接使用 activity criteria；旧 activity 无 criteria 时使用 expectedProof / title 生成一条本地检查项。
- [ ] 实现 adaptive provider：配置或解析失败时返回 fallback，并标记 `source = .ruleBased`。
- [ ] 验证 request package 不包含无关 Course、Calendar、联系人、位置和附件内容。
- [ ] Commit：`feat: generate safe completion checks`

---

## Task 6：生成可编辑的学习记录草稿

**Files**

- Create: `Sources/PersonalLearningJournal/StudyFlow/LearningRecordDraftProvider.swift`
- Create: `Tests/PersonalLearningJournalTests/LearningRecordDraftProviderTests.swift`
- Modify: `Sources/PersonalLearningJournal/AI/StructuredAIClient.swift`

### Steps

- [ ] 写输入输出 Codable 测试：summary、result、blockers、suggestedNextStep、adjustmentSignal。
- [ ] 写测试证明 provider 只接收 timer facts、用户答案、附件 metadata 和 current Next Step。
- [ ] 实现 OpenAI-compatible provider，本地校验空 summary 和无效 adjustment signal。
- [ ] 实现 deterministic fallback，把用户答案组合成可读摘要；不得推断未选择的完成项。
- [ ] 将草稿写回 `PendingStudyCaptureStore`，不写 Journal。
- [ ] 写测试：AI 失败、App 重启、用户编辑后草稿均完整保留。
- [ ] Commit：`feat: create editable learning record drafts`

---

## Task 7：持久化结构化 assessment 与修正历史

**Files**

- Modify: `Sources/PersonalLearningJournal/Domain.swift`
- Create: `Sources/PersonalLearningJournal/StudyFlow/LearningRecordRevision.swift`
- Modify: `Sources/PersonalLearningJournal/JournalStore.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/SwiftDataJournalRepository.swift`
- Modify: `Sources/PersonalLearningJournal/Contracts/JournalRecordContract.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/SyncMergeService.swift`
- Test: `Tests/PersonalLearningJournalTests/DomainTests.swift`
- Test: `Tests/PersonalLearningJournalTests/SwiftDataJournalRepositoryTests.swift`
- Test: `Tests/PersonalLearningJournalTests/CloudRecordMapperTests.swift`
- Test: `Tests/PersonalLearningJournalTests/SyncMergeServiceTests.swift`

### Steps

- [ ] 给 `LearningSession` 增加 optional `assessment`，写旧 fixture 解码测试。
- [ ] 新增 `LearningRecordRevision` entity kind、snapshot array、repository payload 和 contract mapping。
- [ ] 写 repository / JSON / contract / CloudKit round-trip 测试。
- [ ] 合并策略：Session 最新 confirmed revision 发生并发冲突时进入 conflict review；revision snapshots 以 append-only 合并。
- [ ] 更新 fixture version 和跨端合同测试，但保持既有 record type 命名不变。
- [ ] 运行 repository、contract、Cloud mapping、merge focused suites。
- [ ] Commit：`feat: persist structured learning records`

---

## Task 8：实现原子确认和后期修正服务

**Files**

- Create: `Sources/PersonalLearningJournal/StudyFlow/LearningRecordService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Create: `Tests/PersonalLearningJournalTests/LearningRecordServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/JournalServiceTests.swift`

### Steps

- [ ] 写失败测试：结束 timer 后 Journal 不变；confirm 后才创建 Session 和完成 PlannedSession。
- [ ] 写原子性测试：repository commit 失败时 Session、Project、PlannedSession、Trail 全部不变，pending capture 保留。
- [ ] 实现 `confirm(capture:)`，复用 Journal transaction，而不是依次调用现有 `quickLog` 和 `addProof`。
- [ ] 将附件 staging、正式移动和失败清理接入现有 AttachmentStore / cleanup queue。
- [ ] 确认成功后才删除 pending capture。
- [ ] 实现 `amend(sessionID:...)`：先追加 previous revision，再更新 Session；不自动触发历史 plan mutation。
- [ ] 保留旧 Quick Log API 作为手动 / legacy 路径，并明确不经过 AI。
- [ ] Commit：`feat: confirm and amend learning records atomically`

---

## Task 9：构建统一 Study Flow UI

**Files**

- Create: `Sources/PersonalLearningJournal/Views/ActiveStudyView.swift`
- Create: `Sources/PersonalLearningJournal/Views/CompletionCheckView.swift`
- Create: `Sources/PersonalLearningJournal/Views/LearningRecordDraftView.swift`
- Create: `Sources/PersonalLearningJournal/Views/LearningRecordDetailView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/TimerSessionView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/QuickLogView.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Create: `Tests/PersonalLearningJournalTests/StudyFlowViewStateTests.swift`

### Steps

- [ ] 抽出 `StudyFlowViewState` 和 reducer，先对状态转换写单测。
- [ ] `ActiveStudyView` 复用现有 timer 计算，结束时只写 pending capture。
- [ ] `CompletionCheckView` 使用标准 Picker / Toggle / TextField，不渲染 AI 任意 UI。
- [ ] `LearningRecordDraftView` 支持编辑、返回、稍后、放弃和确认。
- [ ] `LearningRecordDetailView` 显示 confirmed / amended 状态和 revision history。
- [ ] 计划活动的 Start 全部进入新 flow；legacy Quick Log 留在 overflow 作为手动补录。
- [ ] 写最大 Dynamic Type 布局状态测试和关键 accessibility label 测试。
- [ ] Commit：`feat: add guided study completion flow`

---

## Task 10：实现动态调整建议

**Files**

- Create: `Sources/PersonalLearningJournal/Adjustments/LearningAdjustmentDomain.swift`
- Create: `Sources/PersonalLearningJournal/Adjustments/LearningAdjustmentService.swift`
- Modify: `Sources/PersonalLearningJournal/Persistence/JournalEntity.swift`
- Modify: `Sources/PersonalLearningJournal/JournalStore.swift`
- Modify: `Sources/PersonalLearningJournal/Contracts/JournalRecordContract.swift`
- Modify: `Sources/PersonalLearningJournal/Sync/CloudRecordMapper.swift`
- Modify: `Sources/PersonalLearningJournal/Planning/CoursePlanningService.swift`
- Create: `Sources/PersonalLearningJournal/Views/PlanRevisionDiffView.swift`
- Create: `Tests/PersonalLearningJournalTests/LearningAdjustmentServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/PlanLifecycleGuardTests.swift`

### Steps

- [ ] 新增 suggestion entity、status 和 source Session references 的 round-trip tests。
- [ ] 实现 rule-based detection：重复 partial、重复 blocker、phase window risk；只读取 confirmed sessions。
- [ ] 实现 AI provider 的 request-scoped context 和结构校验。
- [ ] 普通建议采用时，调用现有 canonical Next Step / Today override / reschedule 命令，并与 suggestion decision 同 transaction。
- [ ] 结构建议调用 `CoursePlanningService.revise` 创建 draft，绝不直接 active。
- [ ] `PlanRevisionDiffView` 展示 Phase、criteria、activity、周期和预算差异，以及 source Sessions。
- [ ] 写 guard 测试：v2 激活前 v1 active；v2 激活后 v1 archived 且可读。
- [ ] Commit：`feat: add reviewable learning adjustments`

---

## Task 11：收敛 Today

**Files**

- Create: `Sources/PersonalLearningJournal/Views/VNextTodayView.swift`
- Modify: `Sources/PersonalLearningJournal/Recommendations/TodayAgendaService.swift`
- Modify: `Sources/PersonalLearningJournal/JournalViewModel.swift`
- Test: `Tests/PersonalLearningJournalTests/TodayAgendaServiceTests.swift`
- Test: `Tests/PersonalLearningJournalTests/VNextProductContractTests.swift`

### Steps

- [ ] 写 projection 测试：pending capture 优先、exactly one Up Next、最多两个 visible alternatives。
- [ ] 保留 agenda 的完整 items 供“查看全部 / 调整今天”使用，首屏只投影前三个。
- [ ] 主卡显示 recommendation reason 和 criteria 摘要。
- [ ] carryover / review / sync / capacity 改为单行 banner，不在首页生成平级大模块。
- [ ] Start / Continue 接到 Task 9 的 unified flow。
- [ ] 验证 daily override 仍为 local-only，不错误写入 Trail 或 active plan。
- [ ] Commit：`feat: focus today on one learning action`

---

## Task 12：收敛导航与 Courses

**Files**

- Create: `Sources/PersonalLearningJournal/Views/CoursesView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/RootView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/ProjectsView.swift`
- Modify: `Sources/PersonalLearningJournal/Views/OnboardingView.swift`
- Modify: `Sources/PersonalLearningJournal/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/PersonalLearningJournal/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `Tests/PersonalLearningJournalTests/LocalizationTests.swift`
- Test: `Tests/PersonalLearningJournalTests/VNextProductContractTests.swift`

### Steps

- [x] RootView 先收敛为 Today / Courses，随后按产品修订扩展为 Today / Courses / Trail / AI 四个固定 Tab。
- [ ] Courses 复用 Project 数据，展示 current Phase、Milestone、Next Step、last confirmed record 和 pending suggestion。
- [ ] Calendar、Library、Review、Sync、AI Settings、Export、App Lock 移入 toolbar menu 和 contextual routes。
- [ ] 新 onboarding 允许“创建第一门课程”或“先手动记录”，不强制假 Session。
- [ ] 既有用户和手动 Project 无需迁移即可显示。
- [ ] 补齐中英文字符串并运行 localization tests。
- [ ] Commit：`feat: simplify navigation around today and courses`

---

## Task 13：通知、深链和恢复入口

**Files**

- Modify: `Sources/PersonalLearningJournal/Notifications/LearningNotificationPolicy.swift`
- Create: `Sources/PersonalLearningJournal/Notifications/PendingCaptureNotificationCoordinator.swift`
- Modify: `Sources/PersonalLearningJournal/Views/PersonalLearningJournalApp.swift`
- Test: `Tests/PersonalLearningJournalTests/LearningNotificationPolicyTests.swift`
- Create: `Tests/PersonalLearningJournalTests/PendingCaptureNotificationTests.swift`

### Steps

- [ ] 新增 pending check / pending record 两类通知 payload。
- [ ] 只有真实开始过且仍 pending 的 capture 可调度通知。
- [ ] 通知文案不使用 streak、羞辱或未经确认的完成结论。
- [ ] 深链直接打开 capture 对应步骤；capture 已确认或删除时回到 Today。
- [ ] 通知权限拒绝不影响本地恢复卡片。
- [ ] Commit：`feat: resume pending learning records from notifications`

---

## Task 14：跨端合同、导出和同步兼容

**Files**

- Modify: `Sources/PersonalLearningJournal/Resources/JournalContract/contract-v1.json`
- Modify: `Sources/PersonalLearningJournal/Resources/JournalContract/fixtures-v1.json`
- Modify: `WebWorkspace/lib/journal-contract.ts`
- Modify: `WebWorkspace/lib/journal-projector.ts`
- Modify: `WebWorkspace/tests/journal-contract.test.mjs`
- Modify: `WebWorkspace/tests/journal-reader-projector.test.mjs`
- Modify: `Sources/PersonalLearningJournal/ExportService.swift`
- Test: `Tests/PersonalLearningJournalTests/ExportServiceTests.swift`

### Steps

- [ ] Swift 合同 fixture 增加 assessment、record revision、adjustment suggestion。
- [ ] Web projector 能读取并展示最新 confirmed summary；未知新增字段继续向后兼容。
- [ ] pending captures 不进入 Journal contract 和默认 export。
- [ ] export/import round-trip 保留 confirmed record revision 和 suggestion decision。
- [ ] 运行：
  - `swift test --filter JournalRecordContractTests`
  - `swift test --filter ExportServiceTests`
  - `cd WebWorkspace && npm test`
- [ ] Commit：`feat: extend journal contract for vnext records`

---

## Task 15：端到端验收与发布门禁

**Files**

- Create: `Tests/PersonalLearningJournalTests/VNextEndToEndTests.swift`
- Modify: `scripts/d1-release-check.mjs`
- Modify: `docs/d1-acceptance-runbook.md`
- Modify: `README.md`

### Steps

- [ ] 实现 Spec A–F 的确定性端到端测试。
- [ ] 加入旧 Journal fixture，验证旧 Session / Plan 无损读取且不伪造 assessment。
- [ ] 运行完整 Swift tests 和 build：

```bash
swift test
swift build
xcodebuild -project SelfStudyStudio.xcodeproj \
  -target SelfStudyStudio \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

- [ ] 运行 Web 合同测试：

```bash
cd WebWorkspace
npm test
npm run lint
```

- [ ] 更新 D1 检查，新增 vNext 自动化证据，但保留以下独立门禁：
  - iPhone 真机；
  - live CloudKit 双端收敛；
  - pending capture 的系统杀进程恢复；
  - 本地通知与深链；
  - 图片、音频、文件附件；
  - 最大 Dynamic Type；
  - VoiceOver；
  - AI 未配置与 provider 失败。
- [ ] 在 iPhone Simulator 走 CS336 全流程并保存截图；不得将其表述为真机或 CloudKit 验收。
- [ ] 更新 README 当前能力与限制。
- [ ] Commit：`test: validate vnext learning loop`

## 实施顺序与依赖

```text
Task 1 产品合同
  ↓
Task 2–3 计划输入与 Review
  ↓
Task 4 Pending Capture
  ↓
Task 5–6 AI 检查与记录草稿
  ↓
Task 7–8 持久化与原子确认
  ↓
Task 9 Study Flow UI
  ↓
Task 10 动态调整
  ↓
Task 11–12 Today 与导航收敛
  ↓
Task 13 通知恢复
  ↓
Task 14 跨端兼容
  ↓
Task 15 全量验收
```

Task 2 与 Task 4 可并行；Task 5 与 Task 7 可在领域接口冻结后并行。Task 9 必须等待 Task 4–8 的服务接口稳定。Task 11–12 最后切换默认 UI，避免中途出现不可用主流程。

## 完成后的用户体验

实施完成后，新用户不需要理解当前 App 的全部能力：

1. 输入一门课程；
2. review AI 计划草稿；
3. 从 Today 开始唯一 Up Next；
4. 结束后回答几个问题；
5. 确认 AI 整理的记录；
6. 选择是否采用调整建议。

Calendar、Proof、Review、同步和版本管理继续存在，但只在需要时出现。
