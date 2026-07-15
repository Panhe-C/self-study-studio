# 产品手册演示截图

最近采集：2026-07-13

## 采集环境

- 设备：iPhone 16 Pro Simulator
- 系统：iOS 18.3.1
- 图片尺寸：1206 x 2622 px
- App Bundle：`com.local.selfstudystudio`
- 采集分支：`codex/product-function-diagrams`
- 演示数据：固定 UUID 与 ISO-8601 时间的匿名种子数据

## 数据

- 演示种子：`demo-journal.json`
- 演示项目：CS336、吉他弹唱、DaVinci 调色
- 数据仅用于文档截图，不包含 API Key 或真实个人文件路径。

## 采集规则

- 使用当前可用的 iPhone Simulator。
- 所有图片直接来自运行中的 `com.local.selfstudystudio`。
- 文件名使用稳定步骤编号；Project Detail 使用 `demo-07-project-detail.png`。
- 无法稳定复现的页面必须记录原因，不使用概念图替代。

## 已采集

1. `demo-01-today.png`：Today Continue 与 Latest Review。
2. `demo-02-quick-log.png`：Quick Log 表单。
3. `demo-03-timer.png`：Timer Running 状态。
4. `demo-04-session.png`：Session Detail 与 Next Step 前后变化。
5. `demo-05-proof-add.png`：Proof 类型、说明与附件入口。
6. `demo-06-proof-detail.png`：链接 Proof 的内容、来源和附件。
7. `demo-07-project-detail.png`：Project Detail 的 Goal、Actions、Status 与 Sessions 上下文。
8. `demo-08-review.png`：Weekly Review 的 Facts、引用与 Patterns。
9. `demo-09-library.png`：Library 的分组与 Proof 列表。

## 未采集

- 完整 Learning Trail 区域：Project Detail 的下方滚动区域无法在本轮 macOS Simulator 自动化中稳定定位；文档使用真实 Project Detail 截图与已核对的 Trail 流程图共同说明，不伪造页面。
- Export Ready 弹窗：Library 顶部无文字图标在当前 Simulator 可访问性树中没有稳定按钮标识，坐标点击未能可靠触发；文档使用真实 Library 截图与数据导出流程图说明，不用重复截图冒充成功弹窗。
