---
name: self-study-maintenance
description: 维护 Self Study Studio 的 Swift 与 Web 代码，定位引导式学习模块、检查跨端记录契约及选择验证范围。用于此仓库的功能修改、重构和回归检查。
---

# Self Study Studio 维护

从仓库根目录执行命令。先读 [代码导航](../../docs/CODE_MAP.md)，再按任务查看对应模块；产品行为变更时查看 [vNext 产品定义](../../docs/PRODUCT_VNEXT.md)。

## 修改路径

- 引导式学习：从 `StudyFlow/StudyFlowController.swift` 和 `StudyFlow/StudyFlowViewState.swift` 定位状态转换，再检查 `PendingStudyCaptureStore`、`JournalViewModel` 和 `LearningRecordService` 的确认提交。结束计时、完成检查和草稿编辑不应提前写入 Journal。
- 计划与建议：查看 `Planning/`、`Adjustments/` 和 `Recommendations/`。保留草稿激活、历史修订和显式确认的边界。
- 新增或修改持久化记录：沿领域模型 → `Persistence/` → `Sync/` → 导出 → `Resources/JournalContract/` → `WebWorkspace/lib/` 检查传播范围。保留旧记录读取兼容性；用共享 fixtures 和两端契约测试验证。
- 新增、移动或删除 Swift 文件：同步检查 `SelfStudyStudio.xcodeproj/project.pbxproj`。Swift Package 自动发现源码不代表 app target 已包含同一文件。
- 修改界面文案：检查中英文资源及 `LocalizationTests.swift`。用户可见流程改变时，按根 README 更新受影响的图表源和导出图。

## 验证选择

按改动运行相关 Swift 测试或 Web 测试。较广的业务修改运行 `swift test`；Web 的 `npm test` 已包含构建。SwiftUI 和 app target 的修改另运行代码导航中的模拟器构建命令。

跨端发布检查使用现有 `scripts/d1-release-check.mjs`，不另建重复的验收脚本。具体人工门禁见 [D1 验收手册](../../docs/d1-acceptance-runbook.md)。不要将静态清单检查、服务测试或模拟器结果表述为真机、在线 CloudKit、VoiceOver 或实际通知验收。

交付时说明实际修改、执行过的验证及剩余限制。README 中的历史测试数量不作为本次验证结果。
