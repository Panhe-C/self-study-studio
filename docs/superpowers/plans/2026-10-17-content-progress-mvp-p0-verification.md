# 内容进度 MVP P0 验证记录

日期：2026-10-17
状态：保留既有检查证据。旧 P0-1 源码检查已完成；旧 P0-2～P0-5 云端在线验证移至新 P5，在两端 P4 独立功能验收通过后执行。旧 P0-6 AI 代理运行时验证移至新 P3/P4。尚未执行的在线检查仍未通过，但不再阻塞功能开发。

本文保留原文件名和旧 P0 编号以便追溯；执行顺序以最新版实施计划为准。
执行入口：[分阶段实施计划](2026-10-17-content-progress-mvp.md) 第 7 节（新 P5）
技术依据：[实现方案](../specs/2026-10-17-content-progress-mvp-design.md)

## 1. P0-1：可复用传输边界（已完成，本地源码检查）

结论：新 ContentProgress 模块不能直接复用旧 client 的发送路径——协议与 mutation 类型均绑定 `JournalEntity`；可复用的是实现模式、建区入口和账号协议。Web 端传输层本身无 Journal 耦合，可直接复用，但未证明独立建区能力。

### iPhone 端

| 检查项 | 结论 | 证据（`Sources/PersonalLearningJournal/`） |
| --- | --- | --- |
| 容器与 zone 可配置 | 可复用：init 接受 `containerIdentifier` 与 `zoneName`，默认 `LearningJournalZone` | `Sync/CKSyncEngineDatabaseClient.swift:14-35` |
| 建区入口 | 可直接复用：`ensureZone(named:)` 与业务无关，能创建 `ContentProgressZoneV1` | `Sync/CKSyncEngineDatabaseClient.swift:38-50` |
| 发送路径 | 不可复用：`CloudMutation` 携带 `JournalEntity` / `JournalEntityReference` | `Sync/CloudSyncCoordinator.swift:11-14, 144-152` |
| 记录编解码 | 不可复用：`CloudRecordMapper` 是 17 种旧实体的封闭 switch，未知 recordType 抛 `unsupportedRecordType` | `Sync/CloudRecordMapper.swift:19-77` |
| 下载路径 | 模式可复用：`fetchChanges` 返回裸 `CKRecord` 包装（`CloudRemoteChange`），client 内不做 Journal 解码；但类为 final 且构造依赖旧 mapper，新模块需自建 adapter | `Sync/CloudSyncCoordinator.swift:123-141`、`Sync/CKSyncEngineDatabaseClient.swift:119-145` |
| 账号协议 | 可复用：`CloudAccountProviding` 与业务无关 | `Sync/CloudAccountCoordinator.swift:5-8` |
| change tag 守卫模式 | 作为 `ProgressCloudAdapter` 参考：批内预检、`.ifServerRecordUnchanged` 原子写、retryable/terminal 错误分类 | `Sync/CKSyncEngineDatabaseClient.swift:58-117, 356-378` |

隔离确认：旧 mapper 对未知 recordType 直接抛错，新 `ContentProgressProject` 记录即使意外进入旧管线也会失败而不是被误读。这同时意味着新 adapter 必须经过自己的 mapper，不能仅改 zone 名就声称可用。

### Web 端

| 检查项 | 结论 | 证据（`WebWorkspace/lib/`） |
| --- | --- | --- |
| 传输层 | 可复用：`cloudkit.ts` 的类型、脚本加载与容器配置无 Journal 耦合；zone 按请求传入 | `cloudkit.ts:63-93, 130-158` |
| zone 配置 | 需隔离：全局 `cloudKitConfig.zoneName` 默认 `LearningJournalZone`；进度模块使用独立常量 `ContentProgressZoneV1`，不改写全局配置 | `cloudkit.ts:100-113` |
| 条件写入 | 类型已具备：`modifyRecords` 选项含 `atomic` 与 `ifServerRecordUnchanged` | `cloudkit.ts:38-41` |
| 建区能力 | 缺失：`CloudKitDatabase` 类型只暴露 `fetchRecordZoneChanges` / `modifyRecords` / `fetchRecords`，无任何建区方法；Web 独立建区未证明，是新 P5 的首要验证点 | `cloudkit.ts:63-75` |
| 写入白名单 | 不可复用：`WebWriteOperation` 是 7 种旧操作的封闭联合，payload 类型绑定 journal-contract | `journal-writer.ts:30-51` |
| change tag 守卫模式 | 作为 Web progress writer 参考：`GuardedWriteRecord` / `RevisionGuardExpectation` 与 Swift 侧同构 | `journal-writer.ts:22-42` |

## 2. 旧 P0-2～P0-6：在线验证清单（未执行，按新阶段安排）

以下项目必须有真实环境，不用 mock 代替结果。

| 验证项 | 需要的环境 |
| --- | --- |
| P0-2 双端各自创建 `ContentProgressZoneV1` | Apple 开发者账号与容器 `iCloud.com.local.selfstudystudio` 权限；已登录 iCloud 的 iPhone 或可登录模拟器；配置 API token 的可运行 Web 环境 |
| P0-3 `ContentProgressProject` 创建、读取、带 change tag 更新、过期 tag 拒绝 | 同上，development 环境 |
| P0-4 不同账号隔离 | 第二个 Apple 账号或第二台设备 |
| P0-5 单记录容量与请求上限 | development 环境与最大样例数据 |
| P0-6 Web 部署运行时承载同源 AI 代理与受限公网读取 | 目标部署运行时与 provider 端点允许列表 |

两端 P4 验收通过且环境就绪后，在新 P5 执行云端冒烟验证；旧 P0-6 的 AI 代理验证提前在新 P3/P4 执行。云端冒烟顺序：

1. iPhone：调试入口调用 `ensureZone(named: "ContentProgressZoneV1")`，随后创建、读取、带过期 tag 更新一条 `ContentProgressProject` 样例。
2. Web：先验证 CloudKit JS 能否在 private database 建区；不能建区则先修订设计（候选方向：服务端建区通道或调整 zone 策略），再重复第 1 步的双向读写。
3. 逐步放大 payload 至被拒，固定单元数、标题长度与字节上限，回写实现方案第 4.1 节。
4. 换第二个账号重复，确认数据互相不可见。

## 3. 本轮验证情况

- 已执行：第 1 节源码边界检查；Markdown 相对链接检查；`git diff --check`。
- 未执行：P0-2～P0-6 全部在线验证（缺开发账号、容器权限、API token、部署运行时）；应用构建与测试（本轮为文档与分支变更，未改动源码）。
