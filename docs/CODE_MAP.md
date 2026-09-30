# 代码与维护入口

本页用于定位 Self Study Studio 的实现、测试和维护流程。产品行为以 [vNext 产品定义](PRODUCT_VNEXT.md) 和当前实现为依据；历史设计与验收记录不代表当前版本已通过验证。

按功能查看实现范围与缺口，见 [产品功能树](FEATURE_TREE.md)。

## 仓库结构

| 路径 | 职责 |
| --- | --- |
| `Sources/PersonalLearningJournal/` | Swift 领域模型、业务服务、存储、同步和 SwiftUI 界面 |
| `Tests/PersonalLearningJournalTests/` | Swift 单元、集成与服务级验收测试 |
| `Package.swift` | Swift Package 的库、测试和资源声明 |
| `App/`、`SelfStudyStudio/` | iOS app 入口、图标和 entitlement |
| `SelfStudyStudio.xcodeproj/` | iOS app 工程；显式引用 Swift 源文件 |
| `WebWorkspace/` | Web 界面、Journal 投影、CloudKit 读写及测试 |
| `scripts/` | D1 验收、产品手册与图标、图表生成工具 |
| `docs/`、`diagrams/` | 产品定义、操作说明、历史方案与图表 |
| `skills/` | 随仓库维护的 skill 源文件；可按路径显式调用 |

`.build/`、`build/`、`.gstack/`、`.superpowers/` 是已忽略的构建或工具工作目录，不作为业务源码入口。`docs/superpowers/` 则保存版本化设计和实施文档。

## Swift 模块导航

下表中的路径相对于 `Sources/PersonalLearningJournal/`。

| 修改目标 | 优先查看 |
| --- | --- |
| 基础模型与应用协调 | `Domain.swift`、`JournalService.swift`、`JournalViewModel.swift`、`JournalStore.swift` |
| 课程计划、校验与修订 | `Planning/` |
| 计时结束、完成检查、记录确认与更正 | `StudyFlow/` |
| 学习调整建议 | `Adjustments/` |
| AI 请求与学习教练 | `AI/`、`AIReviewSettings.swift` |
| 今日待办与推荐 | `Recommendations/` |
| 周期练习与计时恢复 | `Practice/` |
| 排课、日历和 EventKit | `Calendar/` |
| 证据、阶段复盘与项目状态 | `Evidence/`、`Reviews/`、`Projects/` |
| 本地持久化与迁移 | `Persistence/`、`Migration/` |
| CloudKit 映射、合并与同步 | `Sync/` |
| 跨端记录契约与样例 | `Contracts/`、`Resources/JournalContract/` |
| 通知与待确认记录提醒 | `Notifications/` |
| 归档、安全与产品健康 | `Archive/`、`Security/`、`ProductHealth/` |
| SwiftUI 界面与会话装配 | `Views/` |
| 中英文文案 | `Resources/en.lproj/`、`Resources/zh-Hans.lproj/` |

引导式学习的主要阅读顺序是：`StudyFlowController` → `StudyFlowViewState` / `PendingStudyCaptureStore` → `JournalViewModel.confirmPendingCapture` → `LearningRecordService`。结束计时和编辑草稿仍属于设备本地状态，确认后才发布 Journal 记录。

## Web 与跨端修改

Web 业务代码集中在 `WebWorkspace/lib/`：

| 文件 | 职责 |
| --- | --- |
| `journal.ts`、`journal-contract.ts` | Journal 类型与记录契约 |
| `journal-reader.ts`、`journal-projector.ts` | 读取与界面投影 |
| `journal-writer.ts` | 受约束的写入 |
| `cloudkit.ts` | CloudKit 接入 |
| `sync-conflicts.ts`、`recoverable-drafts.ts` | 冲突与可恢复草稿 |

修改持久化字段或记录类型时，一起检查 Swift 模型、Repository、CloudKit mapper、合并逻辑、导出、共享 JSON 契约及 Web 编解码。对应测试分布在 Swift 测试目录和 `WebWorkspace/tests/`。Web 当前仅兼容 vNext 记录契约，不能据此认定已实现引导式学习界面。

## 验证入口

在仓库根目录运行 Swift 检查：

```bash
swift test
swift build
```

在 `WebWorkspace/` 中运行 Web 检查；先按其 [README](../WebWorkspace/README.md) 准备依赖：

```bash
npm test
npm run lint
```

`npm test` 已包含 Web build。Swift Package 通过后，涉及 app 源文件或 SwiftUI 的改动还需要检查 Xcode target：

```bash
xcodebuild -project SelfStudyStudio.xcodeproj -target SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

跨端验收使用现有入口：

```bash
node scripts/d1-release-check.mjs --report /tmp/self-study-studio-d1-report.json
```

该入口包含自动检查和人工门禁状态，详见 [D1 验收手册](d1-acceptance-runbook.md)。本地测试、模拟器构建、真机行为和在线 CloudKit 收敛应分别报告。

## Skill 入口

[self-study-maintenance](../skills/self-study-maintenance/SKILL.md) 汇总本项目维护时容易遗漏的跨端关联和验证边界。可明确要求「读取 `skills/self-study-maintenance/SKILL.md` 并按其流程修改」。此目录保存仓库内源文件，未安装到全局 skill 目录，也不假定客户端会自动发现。
