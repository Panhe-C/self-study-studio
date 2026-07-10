# Personal Learning Journal 产品设计文档

日期：2026-07-09  
阶段：v0.2 产品设计修订  
形态：iOS 原生个人工具  

## 1. 产品一句话

Personal Learning Journal 是一个帮助个人自学者看见「自己是否真的在推进」的学习轨迹 App。

它不只是记录「我学过什么」。它持续回答三个问题：

- 我现在该从哪里继续？
- 我留下了什么能证明自己真的学过？
- 这个项目应该继续、降频、暂停，还是调整方向？

第一版的产品核心不是完整学习管理，而是一个极小闭环：

```text
今天继续学习 -> 30 秒记录 -> 留下一个 Proof -> 7 天后得到一个真实判断
```

## 2. 产品定位

### 2.1 核心承诺

用户同时学习 LLM、CS336、吉他、剪辑、调色等多个长期兴趣时，最容易失去的不是资源，而是节奏感。

Personal Learning Journal 的承诺是：让用户用很轻的方式留下学习轨迹，并在一段时间后看清每个项目是否真的前进。

### 2.2 三个核心概念

#### Trail

Trail 是项目的学习轨迹。它把 session、录音、截图、notebook、链接、下一步串成一条时间线。

用户回看 Trail 时，不是在看一堆日志，而是在看「我如何一步步推进这个项目」。

#### Proof

Proof 是学习证据。它可以是一段吉他录音、一张调色 before/after、一个 notebook 链接、一段代码、一页手写笔记，或者一次口头复述。

Proof 不是附件。它必须回答：这份材料证明了我学到了什么，或者暴露了什么问题？

#### Next Step

Next Step 是每个项目的唯一下一步。产品不维护复杂任务树，只帮助用户知道下次打开时从哪里继续。

如果一个项目没有清晰 Next Step，它就不是 active 项目。

### 2.3 不是这些产品

Personal Learning Journal 不是：

- 课程平台
- 任务管理器
- 番茄钟
- 知识库
- 文件夹
- 打卡 App
- 全自动学习 agent

它是一个个人学习轨迹工具。

## 3. 目标用户与场景

### 3.1 目标用户

第一版只服务一个用户画像：有多个长期自学兴趣的个人用户。

典型特征：

- 同时学习多个领域，例如技术课程、乐器、创作技能和专业能力。
- 学习资源很多，但容易失去整体节奏。
- 不想每天维护复杂任务系统。
- 希望记录真实学习过程，而不是只记录课程完成百分比。
- 需要手机端随手记录录音、截图、文件和链接。
- 希望周末能判断哪些项目值得继续投入，哪些应该降频或暂停。

### 3.2 典型场景

- 看完一段 CS336 lecture 后，用 30 秒记录一句理解、时长和下一步。
- 正式练吉他前从 Today 点「继续」，结束后保存一段录音。
- 做完一次调色练习后，上传 before/after 截图，并写一句「这次证明了什么」。
- 周末打开 Review，看见本周某个项目只有输入没有输出，于是决定下周只做一个 notebook。
- 发现一个项目连续两周没有 Proof，主动把它降频，而不是继续制造心理负担。

## 4. 产品原则

### 4.1 继续优先，记录其次

首页不是仪表盘，而是遥控器。用户打开 App 时，第一件事应该是继续学习，而不是整理信息。

### 4.2 30 秒完成记录

日常记录必须比写长笔记轻。系统尽量使用上下文默认值，让用户只补一句话。

### 4.3 Proof 比进度百分比重要

课程进度只代表输入，不代表掌握。产品更关注用户是否留下了 notebook、录音、截图、作品、代码、解释笔记等 Proof。

### 4.4 复盘必须产生决定

Review 不输出泛泛总结。每次复盘至少给出一个事实、一个模式和一个决定。

### 4.5 AI 不进入日常主流程

AI 不打断日常记录。v0.1 只在周复盘中使用 AI，总结已有 session 和 Proof。AI 不自动创建大量任务，也不自动替用户改项目状态。

### 4.6 本地优先，长期可控

核心数据优先存在本地。第一版不做账号系统。用户可以导出基础 JSON 和附件目录，避免被产品锁死。

### 4.7 管理学习节奏，不制造学习焦虑

产品帮助用户看清哪些项目在推进、哪些项目应该降频或暂停。它不使用排行榜、连续打卡、过量提醒或惩罚性文案。

## 5. v0.1 范围

### 5.1 v0.1 必须包含

v0.1 只做「记录闭环 + 复盘闭环」。

- 首次启动与项目创建
- Today 继续学习入口
- 快捷记录
- 学习计时器
- Session log
- Proof 添加与查看
- 项目 Trail 时间线
- 项目状态管理
- 每周 Review
- AI 周复盘
- 本地数据库
- 本地附件存储
- 基础 JSON 导出和附件目录导出

### 5.2 v0.1 明确不包含

- AI 课程规划
- CloudKit/iCloud 同步
- 社交关系
- 排行榜
- 公开课程市场
- 账号系统
- 多人协作
- 复杂日历排程
- 完整番茄钟体系
- 全自动学习 agent
- 自动课程抓取
- 全文搜索
- 桌面端
- Web 端

### 5.3 为什么砍掉这些能力

v0.1 的成败不取决于功能多，而取决于用户 7 天后是否能看到一条真实学习轨迹。

AI 课程规划、CloudKit、搜索和桌面端都可能有价值，但它们不能早于核心闭环。第一版应该先证明：用户愿意记录，Proof 有回看价值，Review 能帮助用户做决定。

## 6. 信息架构

App 采用三个底部主入口：

1. Today
2. Projects
3. Library

Review 不作为常驻底部 Tab。它是周期性入口，在 Today 和 Project 详情中出现。

### 6.1 Today

Today 是默认首页，回答「我现在从哪里继续」。

第一屏只放最关键内容：

- 1-3 个 Continue 卡片
- Start 按钮
- Quick Log 按钮
- 本周 Review 提醒，仅在需要时出现

推荐布局：

```text
Today

Continue

[CS336]
Next: 整理 perplexity 和 loss 的关系
Last: Lecture 1 · 45 min · 1 个 notebook
[Start]

[吉他弹唱]
Next: 练 F -> C 切换
Last: 练习录音 · 18 min
[Start]

[Quick Log]
```

设计要求：

- 不在首页堆复杂统计。
- 今日总时长可以保留，但不能抢占主视觉。
- Continue 卡片优先展示 active 项目。
- 没有 Next Step 的项目不应出现在 Continue 顶部。
- Review 入口只在一周结束、证据足够或项目停滞时出现。

### 6.2 Projects

Projects 管理长期学习项目，而不是零散任务。

项目示例：

- CS336: Language Modeling from Scratch
- 吉他弹唱：完整弹唱 3 首歌
- DaVinci 调色：掌握基础调色工作流

项目列表展示：

- 项目名称
- 状态
- 当前 Next Step
- 最近一次 session
- 最近 Proof
- 本周是否有推进

项目详情核心模块：

- 项目目标
- 当前 Next Step
- Start / Quick Log
- Learning Trail
- Proof 列表
- 历史 Review

项目状态：

- active
- low-frequency
- paused
- archived

### 6.3 Library

Library 是 Proof 库，不是普通文件夹。

支持类型：

- 图片：调色截图、课程截图、手写笔记
- 录音：吉他片段、口头复述
- 文件：PDF、notebook、工程文件、导出片段
- 链接：GitHub、课程页、YouTube、B 站、文章

组织方式：

- 按项目查看
- 按时间查看
- 按类型查看
- 从 session 或 project 详情进入

每个 Proof 卡片必须展示：

- Proof 标题
- 所属项目
- 关联 session
- 一句话说明
- 创建时间
- 文件类型或预览

### 6.4 Review

Review 用于周复盘和阶段复盘，但不是每日主入口。

核心输出：

```text
Fact: 本周 CS336 有 3 次输入，但没有任何输出型 Proof。
Pattern: 你在继续看 lecture，但没有复现代码。
Decision: 下周 CS336 只做一个 notebook，不看新 lecture。
```

Review 必须帮助用户做出以下动作之一：

- 继续
- 降频
- 暂停
- 调整 Next Step

## 7. 首次使用流程

### 7.1 目标

首次使用必须在 2 分钟内让用户完成三件事：

1. 创建 1-3 个当前正在学习的项目。
2. 为每个项目写一个目标和一个 Next Step。
3. 完成第一条 session 或添加第一条 Proof。

### 7.2 流程

```text
选择当前学习项目数量
-> 输入项目名称
-> 选择领域
-> 写一句目标
-> 写下一步
-> 进入 Today
-> 立刻开始或补记一次学习
```

设计要求：

- 不要求用户一次性建立完整学习计划。
- 不要求用户导入所有历史资料。
- 项目模板只做辅助，不作为必填。
- 首次完成后，Today 必须立即出现 Continue 卡片。

## 8. 核心流程

### 8.1 Continue 学习流程

用于从 Today 直接进入学习。

流程：

1. 用户打开 Today。
2. 看到最近 active 项目的 Continue 卡片。
3. 点击 Start。
4. App 进入计时界面，自动带入项目和上次动作类型。
5. 用户学习、暂停、继续或结束。
6. 结束后只需填写一句话记录。
7. 用户可选添加 Proof。
8. 用户填写或确认下一步。
9. 保存 session，更新项目 Trail。

设计要求：

- 项目必须自动带入。
- 动作类型默认沿用上次。
- 时长由计时器自动生成。
- 下一步默认沿用旧值，但鼓励用户在结束时更新。

### 8.2 快捷记录流程

用于补记和碎片学习。

入口：

- Today 的 Quick Log
- Project 详情页
- 最近项目卡片长按或更多菜单

表单字段：

```text
项目
动作类型
时长
一句话记录
下一步，可选
Proof，可选
```

设计要求：

- 从 Project 详情进入时，项目自动选中。
- 从 Today 进入时，默认选中最近使用项目。
- 动作类型默认沿用该项目上一次动作。
- 时长提供 15、30、45、60 min 快捷选项，也允许手动输入。
- 一句话记录是唯一必填文本。
- Proof 不强制。

### 8.3 学习计时器流程

计时器用于正式学习 session。

它不是番茄钟工具，不负责复杂专注统计。它的主要价值是自动生成准确 session 时长，并减少补记摩擦。

核心操作：

- 开始
- 暂停
- 继续
- 结束
- 放弃本次记录

结束页字段：

```text
一句话记录
Next Step
Add Proof
Save
```

### 8.4 添加 Proof 流程

入口：

- 计时器结束页
- 快捷记录结束页
- Session 详情页
- Project 详情页
- Library

支持操作：

- 拍照或选择图片
- 录音
- 选择文件
- 添加链接

Proof 必须挂靠到一个 session 或 project。优先挂靠 session，只有无法归属时才直接挂到 project。

每个 Proof 需要一个轻量说明：

```text
这证明了什么？
```

示例：

- 能完整弹完第一段，但 F -> C 仍然卡。
- 复现了 bigram baseline，loss 下降曲线还没理解。
- 这组 before/after 证明我能控制白平衡，但肤色偏红。

### 8.5 Learning Trail 流程

Learning Trail 是每个项目详情页的核心视图。

它按时间展示：

- session
- Proof
- Next Step 变化
- Review 决定
- 状态变化

示例：

```text
7/09  CS336 · 45 min · course
      看完 Lecture 1，理解了 tokenization 的基本位置
      Proof: Bigram notebook link
      Next: 整理 perplexity 和 loss 的关系

7/10  CS336 · 60 min · output
      写了第一版复现代码
      Proof: GitHub commit
      Next: 跑通训练 loop
```

Trail 的目标不是记录更多，而是让用户能在 10 秒内看见项目是否在推进。

### 8.6 周复盘流程

用于每周或更长阶段的复盘。

触发方式：

- 用户手动点击 Review
- 一周结束后 Today 出现 Review 卡片
- 某个项目连续 7 天没有 session 或 Proof 时，在项目详情中提示

输入：

- 指定时间范围
- 该周期内 session
- session 动作类型
- 时长
- note 和 nextStep
- Proof 元数据
- 项目状态

输出：

```text
本周期事实
学习模式
建议决定
每个 active 项目的下一步
建议降频或暂停的项目
```

AI 复盘必须遵守：

- 具体，不空泛鼓励。
- 每个判断都引用 session 或 Proof。
- 不生成超过 3 个建议。
- 不自动修改项目状态。
- 不制造连续打卡压力。

## 9. 数据模型

### 9.1 Project

```text
Project
- id
- name
- area
- goal
- status: active / low-frequency / paused / archived
- currentNextStep
- lastActionType
- defaultDurationMinutes
- createdAt
- updatedAt
- archivedAt
```

### 9.2 Session

```text
Session
- id
- projectId
- source: quickLog / timer
- actionType: course / practice / output / reading / experiment / review
- startedAt
- endedAt
- durationMinutes
- note
- nextStepBefore
- nextStepAfter
- createdAt
- updatedAt
```

### 9.3 Proof

```text
Proof
- id
- projectId
- sessionId, optional
- type: image / audio / file / link
- title
- statement
- localPath
- url
- mimeType
- fileSize
- createdAt
- updatedAt
```

### 9.4 Review

```text
Review
- id
- periodStart
- periodEnd
- facts
- patterns
- decisions
- projectRecommendations
- nextSteps
- aiSourceSummary
- createdAt
- updatedAt
```

### 9.5 TrailEvent

TrailEvent 可以由 session、proof、review 和 project status change 派生，不一定需要独立存储。

```text
TrailEvent
- id
- projectId
- type: session / proof / review / statusChange / nextStepChange
- sourceId
- occurredAt
```

## 10. 技术设计

### 10.1 平台

第一版为 iOS 原生 App。

推荐技术：

- SwiftUI：界面开发
- SwiftData 或 Core Data：结构化数据
- FileManager：本地附件管理
- AVFoundation：录音
- PhotosPicker：图片选择
- UIDocumentPicker：文件选择
- URLSession：AI 请求

### 10.2 本地优先

数据策略：

- 结构化数据存在本地数据库。
- 附件存在 App 文件目录。
- 无网络时所有核心记录功能可用。
- AI 不可用时，用户仍可手动创建 Review。
- v0.1 不做 CloudKit 同步，但数据模型不应阻碍后续同步。

附件保存策略：

```text
LearningJournal/
  Attachments/
    project-id/
      session-id/
        proof-id.ext
```

Proof 数据表只保存元数据和路径，不把大文件直接塞进结构化数据库。

### 10.3 导出

v0.1 支持基础导出：

- JSON：projects、sessions、proofs、reviews
- 附件目录：按 project/session/proof 组织

Markdown 导出可以延后。第一版只需要保证用户能拿回原始数据。

### 10.4 AI 能力

v0.1 只包含 AI 周复盘。

AI 输入：

- session 列表
- actionType
- duration
- note
- nextStepBefore / nextStepAfter
- Proof 元数据和 statement
- 项目状态

AI 输出必须限制为：

```text
Facts
Patterns
Decisions
Next Steps
```

AI 不包含：

- 实时聊天主界面
- AI 课程规划
- 自动创建大量任务
- 自动替用户调整项目状态
- 自动分析音频或图片内容
- 全自动课程抓取和学习路径生成

AI 结果必须可编辑，并展示它基于哪些 session 和 Proof 做出判断。

## 11. UI 设计方向

### 11.1 视觉气质

产品应该像一个安静、可信、轻量的个人工具。它应避免游戏化打卡、过度激励和社交压力。

关键词：

- calm
- focused
- personal
- proof-based
- low-friction

### 11.2 交互原则

- 首页优先展示 Continue，而不是复杂统计。
- 手机端所有核心动作应单手可完成。
- Bottom sheet 用于快捷记录。
- 按钮和选项比自由输入更优先。
- 文本输入只保留必要的一句话记录和 Proof statement。
- Proof 添加是可选动作，但产品应温和鼓励。
- AI 结果必须可编辑。
- Review 的语气应像一个清醒的个人教练，而不是热血打卡教练。

### 11.3 关键界面

v0.1 最重要的界面不是设置页或统计页，而是：

1. Today Continue 卡片
2. Quick Log bottom sheet
3. Timer 结束页
4. Project Learning Trail
5. Weekly Review

这些界面必须优先打磨。

## 12. 成功指标

由于第一版是个人工具，成功指标不以增长或留存为主，而以个人真实使用价值为主。

建议指标：

- 用户是否能在 30 秒内完成快捷记录。
- 用户首次使用是否能在 2 分钟内创建项目并完成第一条记录。
- 一周内是否能持续记录 3 个以上 session。
- 每个 active 项目是否有明确 Next Step。
- 每个 active 项目一周内是否至少留下 1 个 Proof。
- 用户是否能从 Trail 看见项目推进。
- 每周 Review 是否能产生一个具体决定。
- 用户是否能根据 Review 主动暂停或降频项目。

## 13. 风险与应对

### 13.1 记录负担过重

风险：字段太多会让用户放弃记录。

应对：从 Today 或 Project 进入时自动带入项目、动作类型和默认时长。日常只强制一句话记录。

### 13.2 Proof 变成文件夹

风险：用户只上传附件，回看时不知道这些材料证明了什么。

应对：Proof 需要轻量 statement。文案不是「备注」，而是「这证明了什么」。

### 13.3 AI 输出空泛

风险：AI 只生成鼓励性废话。

应对：AI 复盘限制为 Fact、Pattern、Decision、Next Step，并要求引用 session 或 Proof。

### 13.4 产品滑向任务管理器

风险：加入太多计划、提醒和任务后，产品失去学习日志核心。

应对：v0.1 不做复杂日历和任务系统。项目只维护 currentNextStep，不展开成完整 todo tree。

### 13.5 v0.1 范围再次膨胀

风险：CloudKit、AI 课程规划、搜索和桌面端会把第一版拖重。

应对：v0.1 只验收记录闭环和复盘闭环。其他能力进入后续方向。

## 14. v0.1 开发范围

### 14.1 必须完成

- 首次启动项目创建
- Project 创建、编辑、归档和状态切换
- Today Continue 卡片
- 快捷记录
- 学习计时器
- Session 列表和详情
- Proof 添加和查看
- Project Learning Trail
- Weekly Review
- AI 周复盘
- 本地数据库
- 本地附件存储
- 基础 JSON 和附件导出

### 14.2 可以延后

- AI 课程规划
- CloudKit/iCloud 同步
- Markdown 导出
- 全文搜索
- 多维统计图表
- 复杂标签系统
- 音频转文字
- 图片内容识别
- 自动课程抓取
- 桌面端
- Web 端
- Widget
- Shortcut 集成

## 15. 验收标准

v0.1 可以被认为完成，当以下场景跑通：

1. 用户首次打开 App，在 2 分钟内创建 `CS336`、`吉他弹唱`、`DaVinci 调色` 三个项目中的至少 1 个。
2. 用户为每个 active 项目设置一个目标和一个 Next Step。
3. Today 显示 Continue 卡片，并能直接开始学习。
4. 用户用快捷记录补记一次 20 分钟学习。
5. 用户用计时器完成一次正式 session。
6. 用户给吉他 session 添加一段录音 Proof，并写一句「这证明了什么」。
7. 用户给调色 session 添加一张 before/after 截图 Proof。
8. 用户在 Project 详情页查看 Learning Trail，能看到 session、Proof 和 Next Step 变化。
9. 用户查看本周 Review，AI 生成 Fact、Pattern、Decision 和 Next Steps。
10. 用户根据 Review 手动把一个项目设为 low-frequency 或 paused。
11. 用户导出 JSON 和附件目录。
12. 关闭网络后，用户仍能创建 session 和添加本地 Proof。

### 15.1 实施验收映射

当前实现按以下方式覆盖验收场景：

- 首次创建项目后保持在引导状态，直到用户完成第一条 Session；已有 JSON 数据升级时会被识别为已完成引导。
- Today、Quick Log、计时器、Trail、状态切换、附件目录与 JSON 导出均由 JournalService 和 ViewModel 测试覆盖。
- 图片、录音、文件和链接 Proof 分别提供预览、播放、Quick Look 与跳转入口；设备能力由 iOS Simulator/真机验收。
- Weekly Review 保留每条生成结论的来源引用；状态和 Next Step 只在用户点击应用后改变项目。
- AI Review 使用可选的 OpenAI-compatible Chat Completions endpoint，未配置、离线或请求失败时使用本地规则复盘。
- 运行时结构化数据使用 SwiftData；旧 `journal.json` 仅在空库首次启动时导入，附件继续保留在 App 文件目录。

## 16. 后续方向

如果 v0.1 被持续使用，后续可以考虑：

- CloudKit/iCloud 私有同步
- AI 课程规划
- Markdown 导出
- Shortcuts 快捷记录
- Widget 显示当前 Next Step
- 更强的课程大纲解析
- 音频转文字和练习对比
- 图片内容识别
- 项目健康度评分
- 学习领域年度回顾
- 桌面端或 Mac companion

但这些都不应早于 v0.1 的记录闭环和复盘闭环。
