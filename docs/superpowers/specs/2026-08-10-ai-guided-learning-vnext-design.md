# Self Study Studio vNext：AI 引导式学习执行 Spec

日期：2026-08-10  
状态：Proposed  
平台：iPhone-first，iOS 17+  
上位产品定义：[`docs/PRODUCT_VNEXT.md`](../../PRODUCT_VNEXT.md)

## 1. 目的

本 Spec 将 vNext 产品定义收敛为可实现、可测试的产品行为。

目标闭环：

```text
课程条件
→ AI 计划草稿
→ 用户 Review 并启用
→ Today 唯一 Up Next
→ 学习过程
→ 完成检查
→ AI 学习记录草稿
→ 用户确认
→ 下一步建议或 Plan Revision Draft
```

实现必须让用户可以在不知道 Project、Plan Revision、Evidence Contract、Today Agenda 等内部概念的情况下完成主流程。

## 2. 范围

### 2.1 本阶段包含

- iPhone 主导航为 Today、Courses、Trail、AI：执行、管理、回看与咨询各自有明确入口；
- 课程条件输入与 AI / 手动计划草稿；
- 计划草稿逐项编辑、删除和单 Phase 重生成；
- 草稿 Review 与明确启用；
- Today 唯一主推荐和最多两个替代活动；
- 统一的学习开始、计时、结束流程；
- AI 生成的完成检查及确定性 fallback；
- AI 学习记录草稿、用户确认和后期修正；
- 普通下一步建议及结构化 Plan Revision Draft；
- 未确认草稿的本地恢复；
- 已确认记录、建议决策和版本历史的同步；
- 中英文、Dynamic Type、VoiceOver 基础语义；
- AI / 网络 / CloudKit 不可用时的手动闭环。

### 2.2 本阶段不包含

- Web Workspace 的完整 vNext 交互重做；
- 多人协作或共享课程；
- 课程市场和自动抓取完整课程内容；
- AI 自动启用、自动确认或后台自主改计划；
- 任意结构的 AI 表单生成器；
- 完整 Pomodoro、社交、排行榜或连续打卡；
- 删除现有 Calendar、Proof、Review、CloudKit 底层能力。

Web 本阶段只需保持合同兼容，能够读取新增的已确认记录和建议决策；不要求与 iPhone 同步交付完整新界面。

## 3. 架构决策

### 3.1 Course 是展示层名称

不新增与 `Project` 重复的持久化根对象。

```text
用户概念 Course
    = Project
    + 当前 Active LearningPlan
    + PlanPhase / PlannedSession
    + LearningSession 历史
```

没有计划的既有 Project 仍可在 Courses 中显示为“手动学习项目”。不做破坏性数据迁移，不修改既有 CloudKit record type。

### 3.2 Milestone 复用当前 Phase 契约

MVP 每个 Phase 只有一个 canonical Milestone：

- `PlanPhase.objective`：Milestone 目标；
- `PlanPhase.expectedProof`：完成标准 / 预期结果；
- `PlannedSession`：Milestone 下的活动。

如果用户需要多个 Milestone，计划生成器应拆成多个较小 Phase。MVP 不新增 `PlanMilestone` 持久化实体，避免与现有 Stage Review 和 Evidence Contract 形成两套完成模型。

### 3.3 Learning Record 复用 LearningSession

用户看到的“学习记录”由以下对象组成：

- `LearningSession`：时间、活动、用户确认后的摘要和 Next Step；
- `LearningRecordAssessment`：结构化完成情况；
- 可选 `Proof`：代码、截图、录音、文件或链接；
- `LearningRecordRevision`：后期修正前的快照。

`LearningRecordAssessment` 作为 `LearningSession` 的可选字段进行向后兼容编码。旧 Session 没有 assessment 时仍然有效。

### 3.4 未确认内容不是 Journal 事实

计时结束、AI 检查问题、用户尚未提交的答案、AI 记录草稿都保存在本地 `PendingStudyCaptureStore`，不进入 `JournalSnapshot`，不上传 CloudKit，也不影响 Today 和计划完成状态。

只有用户点击“确认记录”后，系统才在一个 Journal transaction 中：

1. 创建 `LearningSession`；
2. 写入 `LearningRecordAssessment`；
3. 将关联 `PlannedSession` 标记为 completed；
4. 应用用户确认的 Next Step；
5. 写入 Trail event；
6. 关联已成功保存的可选 Proof。

### 3.5 计划结构仍由 Revision 保护

Phase 目标、完成标准、活动标题、活动顺序和基准时长属于计划结构。Active Plan 的这些字段不能原地修改。

结构变化继续使用现有 `PlanRevisionDraft`、revision guard 和 immutable history。日常执行建议只能影响：

- 当前 canonical Next Step；
- Today 的 day-scoped override；
- 既有 reschedule / carryover 操作；
- 下一次执行时的临时建议时长。

它们不能静默改写 Active Plan。

## 4. 领域模型

### 4.1 计划输入扩展

`CoursePlanningInput` 新增向后兼容字段：

```swift
public var studyPeriodWeeks: Int?
public var prerequisites: String
public var constraints: String
```

规则：

- `studyPeriodWeeks` 与 `deadline` 可互相推导，但 deadline 优先；
- `prerequisites` 为空合法；
- `constraints` 只接收用户明确输入的设备、时间或学习方式限制；
- 旧数据解码默认 `nil / "" / ""`。

### 4.2 活动完成标准

`CoursePlanDraftSession` 和 `PlannedSession` 新增：

```swift
public var completionCriteria: [String]
public var recommendationReason: String?
```

约束：

- 每个活动 1–5 条 completion criteria；
- 每条是用户可以判断的行为或结果；
- 不能写成“理解本章”这类不可观察表达；
- 旧 session 解码为空数组；为空时由 deterministic fallback 根据标题和 expectedProof 生成一条检查项。

### 4.3 PendingStudyCapture

```swift
public struct PendingStudyCapture: Codable, Equatable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var plannedSessionID: UUID?
    public var source: SessionSource
    public var startedAt: Date
    public var endedAt: Date?
    public var activeDurationSeconds: Int
    public var checkDraft: CompletionCheckDraft?
    public var answers: CompletionCheckAnswers
    public var recordDraft: LearningRecordDraft?
    public var stagedAttachments: [PendingAttachmentReference]
    public var updatedAt: Date
}
```

它是设备本地、可恢复、可删除的工作草稿。每个设备同一时间只允许一个 active capture；结束后可以保留多个 awaiting-confirmation capture。

### 4.4 CompletionCheckDraft

```swift
public struct CompletionCheckDraft: Codable, Equatable {
    public var activityTitle: String
    public var progressOptions: [CompletionProgress]
    public var criteria: [CompletionCriterion]
    public var asksUnderstanding: Bool
    public var asksBlocker: Bool
    public var source: DraftSource
}

public enum CompletionProgress: String, Codable {
    case notStarted
    case partial
    case mostlyCompleted
    case completed
}

public enum UnderstandingLevel: String, Codable {
    case unclear
    case needsReview
    case mostlyUnderstood
    case canExplainOrApply
}
```

问题结构由 App 控制，AI 只能提供文案和 criteria，不能生成任意控件或脚本。

所有选项初始均未选择。AI 不得依据计时、附件或历史自动选中答案。

### 4.5 LearningRecordAssessment

```swift
public struct LearningRecordAssessment: Codable, Equatable {
    public var progress: CompletionProgress
    public var completedCriterionIDs: [String]
    public var understanding: UnderstandingLevel?
    public var blocker: String?
    public var aiDraftedSummary: Bool
    public var userEditedSummary: Bool
    public var confirmedAt: Date
    public var revision: Int
}
```

`LearningSession.note` 保存最终确认后的可读摘要，assessment 保存结构化事实。AI 草稿原文不长期保存；只保存用户最终确认的结果和必要模型元数据。

### 4.6 LearningRecordRevision

用户修正已确认记录时，先追加旧值快照：

```swift
public struct LearningRecordRevision: Codable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var revision: Int
    public var previousNote: String
    public var previousAssessment: LearningRecordAssessment?
    public var revisedAt: Date
}
```

Revision 是同步实体。UI 默认显示最新值，并提供“查看修正历史”。

### 4.7 LearningAdjustmentSuggestion

```swift
public enum LearningAdjustmentKind: String, Codable {
    case nextStep
    case dailyOrder
    case reschedule
    case temporaryDuration
    case structuralRevision
}

public enum SuggestionDecision: String, Codable {
    case pending
    case adopted
    case modified
    case ignored
}

public struct LearningAdjustmentSuggestion: Codable, Equatable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var sourceSessionIDs: [UUID]
    public var kind: LearningAdjustmentKind
    public var title: String
    public var rationale: String
    public var proposedValue: String
    public var decision: SuggestionDecision
    public var planRevisionDraftID: UUID?
    public var createdAt: Date
    public var decidedAt: Date?
}
```

建议可以同步，但不具有权威性。`decision == adopted` 也不等于它自身修改了任何对象；采用操作必须与目标变更在同一 transaction 中完成。

## 5. 状态机

### 5.1 学习过程

```text
idle
  → active
  → paused
  → active
  → awaitingCheck
  → awaitingRecordConfirmation
  → confirmed
```

辅助终态：

- `discarded`：用户明确放弃未确认草稿；
- `savedForLater`：结束学习但稍后确认；
- `recovered`：App 重启后恢复到最后一个未确认步骤。

关闭 App、系统杀进程、AI 失败都不能自动进入 `confirmed`。

### 5.2 计划

沿用现有：

```text
draft → active → archived
           ↓
      revision draft → active revision
```

同一 Project 只能有一个 active plan revision。

### 5.3 建议

```text
pending → adopted / modified / ignored
```

用户可撤销尚未造成不可逆外部写入的普通建议，但撤销应产生新的显式操作，不回写历史。

## 6. 导航 Spec

### 6.1 RootView

底部 Tab 固定为：

1. Today；
2. Courses。

右上角菜单包含：

- Calendar；
- Proof Library；
- Reviews；
- Sync & Conflicts；
- AI Settings；
- Export / Import；
- App Lock。

这些入口保留能力，但不与主闭环争夺一级导航。

### 6.2 Onboarding

首次启动不再要求用户一次创建 1–3 个完整 Project 和第一条 Session。

新流程：

1. 说明一句产品承诺；
2. 创建第一门 Course 或选择“先手动记录”；
3. 如果创建 Course，进入计划条件输入；
4. 计划仍为草稿时可以退出，Today 显示继续完成计划的单一卡片。

既有用户不重新进入 onboarding。

## 7. Today Screen Spec

### 7.1 页面结构

按顺序只显示：

1. 未确认记录恢复卡片（如存在）；
2. `Up Next` 主卡片；
3. 最多两个替代活动；
4. 一个低权重“查看全部 / 调整今天”入口。

Review、carryover、sync warning 和 capacity warning 以单行 contextual banner 呈现，不展开为多个首页模块。

### 7.2 Up Next 主卡片

必须展示：

- Course 名称；
- Phase 名称；
- 活动标题；
- 建议时长；
- 推荐原因；
- 完成标准摘要；
- 单一主按钮：开始或继续。

次级菜单：

- 换一个；
- 今天稍后；
- 跳过今天；
- 查看计划。

### 7.3 选择规则

继续使用 `TodayAgendaService` 的确定性排序和用户 override。AI 可以生成活动及解释文案，但运行时不能直接改变排序。

结果约束：

- exactly one `.upNext`；
- at most two visible alternatives；
- skipped item 不出现在主卡片；
- pending capture 优先于新活动。

## 8. Plan Creation & Review Spec

### 8.1 输入页

首屏必填：

- Course；
- 周期或截止日期；
- 每周时间；
- 目标。

折叠的可选项：

- 前置条件；
- 课程 outline；
- 资料链接；
- 预期结果；
- 每次偏好时长；
- 约束。

### 8.2 生成状态

生成时保留输入，可离开页面。失败时显示：

- 失败原因的用户可理解摘要；
- 重试；
- 创建手动草稿。

不显示空白结果页。

### 8.3 Draft Review

每个 Phase 展示：

- 标题；
- canonical Milestone；
- 完成标准；
- 时间窗口；
- 活动列表和预计时长。

支持：

- 行内编辑；
- 删除活动；
- 增加活动；
- 调整顺序；
- 重新生成单个 Phase；
- 撤销最近一次本地编辑；
- 查看 assumptions 和 capacity warning。

页面固定显示 `AI 草稿 · 未生效`。唯一发布动作是“启用计划”。

### 8.4 激活确认

确认页展示：

- Course、周期和每周预算；
- Phase 数、活动数；
- 第一个 Up Next；
- capacity warning；
- “启用不会写入系统 Calendar”的说明。

用户点击“启用计划”后才创建 active revision 和 Today 活动。

## 9. Study Flow Spec

### 9.1 Active Study

页面只显示：

- 活动标题；
- 推荐原因；
- 完成标准；
- 资料链接；
- 正计时或“无需计时”；
- 暂停；
- 结束学习。

“结束学习”只进入完成检查，不写入 Session。

### 9.2 Completion Check

默认 4 组：

1. 完成进度，必填；
2. 实际完成项，来自 criteria；
3. 理解程度，可选；
4. 卡点 / 补充，可选。

附件始终可选。用户可以选择“稍后填写”。

### 9.3 Record Draft

AI 输出字段：

- `summary`：本次实际推进；
- `result`：产出或验证结果；
- `blockers`：未解决问题；
- `suggestedNextStep`：下一步草稿；
- `adjustmentSignal`：none / ordinary / structural。

页面允许编辑摘要、卡点和 Next Step。底部动作：

- 确认记录；
- 返回修改检查；
- 保存稍后处理；
- 放弃草稿（需要确认）。

### 9.4 Confirm Record

确认成功后：

- 才将 activity 标记完成或部分完成；
- 返回 Today；
- 显示一条非阻塞成功反馈；
- 若有建议，只显示一张待 review 卡片，不自动打开复杂页面。

如果 transaction 失败，pending capture 继续保留，用户可以重试，不得出现一半完成的计划状态。

## 10. Record Correction Spec

从 Course 历史进入记录详情，用户可以修改：

- 摘要；
- 完成进度；
- 实际完成项；
- 理解程度；
- 卡点；
- Next Step 备注；
- 附件。

保存时：

- revision +1；
- 显示“已于某时修正”；
- 保留修正前快照；
- 不自动重跑历史上已经处理过的调整建议；
- 用户可显式点击“基于修正记录重新评估计划”。

## 11. Adjustment Spec

### 11.1 触发

只使用已确认记录。触发条件：

- 用户确认一条记录后主动请求；
- 同一活动多次 partial；
- 连续记录出现相同 blocker；
- Phase 预计窗口即将结束；
- 用户从 Course 详情主动请求。

### 11.2 普通建议

可执行动作限定为现有安全命令：

- 确认新的 canonical Next Step；
- 应用 Today override；
- reschedule 一个 PlannedSession；
- 下次执行时使用临时建议时长。

每条建议都有采用、修改、忽略。

### 11.3 结构调整

任何改变 Phase、完成标准、活动集合、计划基准时长或周期的建议必须：

1. 创建新的 Course Plan draft；
2. 关联 base revision；
3. 展示 source Session；
4. 展示字段级 diff；
5. 通过现有 revision guard；
6. 用户点击“启用修订”后才生效。

旧 revision 和已确认 Session 保留。

## 12. AI 接口契约

### 12.1 通用要求

- 继续使用 OpenAI-compatible structured JSON client；
- 每个请求都有 purpose-specific request package；
- 只发送当前 Course、active plan 相关片段和明确关联的已确认记录；
- 不发送 Calendar 标题、联系人、位置、未选择的附件；
- 输出先做 Codable 解码和本地 validation；
- provider 失败后进入 deterministic / manual fallback；
- 原始 provider response 不长期保存。

### 12.2 CompletionCheckProvider

输入：

- activity title；
- completion criteria；
- expected proof；
- phase objective；
- 用户前置条件摘要。

输出：

- criteria 的短文案；
- understanding prompt；
- blocker prompt。

禁止输出预选答案、完成判断或新计划。

### 12.3 LearningRecordDraftProvider

输入：

- timer facts；
- 用户完成检查答案；
- 附件 metadata，不含内容；
- current Next Step。

输出：

- 可编辑记录草稿；
- proposed next step；
- adjustment signal 和 rationale。

### 12.4 LearningAdjustmentProvider

输入最多包含：

- active plan revision；
- 当前 Phase；
- 最近 10 条相关 confirmed Session；
- unresolved blocker 摘要；
- 用户本次请求。

输出要么是普通建议命令草稿，要么是结构修订请求。客户端负责把结构修订请求交给 `CoursePlanningService.revise`，AI 不直接构造已启用 revision。

## 13. 通知与深链

新增通知类别：

- `pendingCompletionCheck`；
- `pendingRecordConfirmation`。

通知只在用户已经开始过真实 session 且仍有 pending capture 时出现。默认不为未开始活动发送催促。

深链打开对应 pending capture，而不是泛化 Today 首页。用户关闭通知不会改变数据状态。

## 14. 错误与恢复

| 场景 | 必须行为 |
| --- | --- |
| AI 计划失败 | 保留输入，允许重试或手动草稿 |
| AI 完成检查失败 | 使用固定问题和本地 criteria |
| AI 记录草稿失败 | 根据答案生成确定性摘要，仍可编辑确认 |
| AI 调整失败 | 保持当前计划和 Next Step，不创建建议 |
| App 在计时中退出 | 恢复 active timer 和活动上下文 |
| App 在检查中退出 | 恢复已填写答案 |
| 确认 transaction 失败 | 保留 pending capture，不完成 activity |
| 附件保存失败 | 明确指出失败附件，记录其他内容前要求用户选择重试或移除 |
| CloudKit 不可用 | 本地确认成功，写入 outbox，显示 sync 状态 |
| Active Plan 冲突 | 不覆盖，进入既有 conflict review |

## 15. 隐私与安全

- API key 继续只存在 Keychain；
- pending capture 只存在设备本地 Application Support；
- pending capture 不包含原始附件二进制，只存 staged local reference；
- AI 请求预览可查看将发送的文本范围；
- Proof 内容只有用户显式选择时才发送；
- 本地导出包含 confirmed records，不默认包含未确认 drafts；
- App Lock 和 background privacy cover 继续覆盖新增页面。

## 16. 可访问性与本地化

- 所有主按钮使用标准 SwiftUI Button；
- 进度选项提供文字 label，不以颜色作为唯一信息；
- Dynamic Type 到 accessibility sizes 时卡片改为纵向布局；
- VoiceOver 顺序为状态 → Course → 活动 → 时长 → 原因 → 主动作；
- Timer 每秒视觉更新，但 VoiceOver 不每秒播报；
- `AI 草稿 / 用户已确认 / 未生效` 必须可被 VoiceOver 读出；
- 中英文字符串进入现有 Localizable.strings；
- 用户输入永远不自动翻译。

## 17. 验收场景

### A. 新课程

1. 用户输入 CS336、8 周、每周 6 小时、目标和前置条件；
2. AI 返回合法草稿；
3. 用户编辑一个活动并重生成一个 Phase；
4. 草稿未启用时 Today 不出现活动；
5. 用户启用后 Today 出现唯一 Up Next。

### B. 完成一次学习

1. 用户从 Up Next 开始并结束计时；
2. Journal 仍无新 Session，PlannedSession 仍未 completed；
3. 完成检查没有任何预选答案；
4. 用户回答后得到可编辑 record draft；
5. 点击确认后 Session、assessment、planned-session completion 和 Trail 一次性写入。

### C. 稍后填写与恢复

1. 用户结束学习后选择稍后填写；
2. App 重启；
3. Today 首卡恢复该检查；
4. 在用户确认前，它不影响计划进度。

### D. 后期修正

1. 用户打开历史记录并修正 progress 和 summary；
2. 最新记录显示 revision 2；
3. revision 1 可查看；
4. 修正不静默重写旧 Plan Revision。

### E. 动态调整

1. 普通建议修改 Next Step，用户可采用、修改或忽略；
2. 结构建议生成 v2 draft；
3. v1 在启用 v2 前保持 active；
4. 启用 v2 后 v1 仍可查看。

### F. 降级

1. 无 AI 配置时可手动创建计划；
2. AI 在完成检查或记录阶段失败时，确定性 fallback 仍走完整闭环；
3. 无网络和无 Calendar 权限时可完成学习并确认记录。

## 18. Definition of Done

只有同时满足以下条件，vNext MVP 才算完成：

- 17 节产品行为全部有代码或明确的 out-of-scope 标记；
- 上述 A–F 场景有确定性自动化测试；
- 旧数据、旧 Course Plan 和旧 Session 可无损读取；
- `swift test`、`swift build` 和 unsigned iOS Simulator build 通过；
- iPhone 尺寸下完成主流程的手动视觉验收；
- VoiceOver 和最大 Dynamic Type 完成基础验收；
- 真机、CloudKit、通知和附件恢复结果分别记录，不用模拟器或单元测试替代；
- 产品主流程不要求进入 Calendar、Library、Review Inbox 或 Dashboard。
