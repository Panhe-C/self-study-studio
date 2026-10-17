# 内容进度 MVP V0.1 实施计划

日期：2026-10-17
状态：计划已编写，P0–P7 均未执行
产品基线：[MVP V0.1 产品设计](../../PRODUCT_VNEXT.md)
技术依据：[实现方案](../specs/2026-10-17-content-progress-mvp-design.md)

## 1. 目标、顺序与交付规则

首发同时交付 iPhone、Web、AI 初始内容生成与跨端同步。先验证跨端存储的可行性，再做共享规则和手动流程，然后接入 AI，最后完成真实环境验收。手动闭环是中间里程碑，不能替代最终 AI 与同步交付。

```text
P0 跨端技术验证
  → P1 共享契约与领域规则
  → P2 双端本地存储、草稿与 outbox
  → P3 CloudKit 同步与冲突
  → P4 双端手动两页流程
  → P5 AI 初始化与资料输入
  → P6 升级兼容与故障恢复
  → P7 集成验收与发布准备
```

按上述依赖顺序推进一个主任务，不假定并行 Agent。每一阶段拆成可独立说明的小轮次；每轮验证后更新 `STATUS.md`、显式暂存文件、commit、push 并核对远程。未完成用 wip 提交如实交接，不能将保存和推送延后到 P7。

当前 PR #6 包含产品与实施文档；代码实施时先确认其是否合并。已合并则从最新 main 建任务分支；尚未合并则从已确认的文档提交派生实现分支，在 PR 中说明依赖，避免从没有产品基线的 main 开始。默认交付可评审 PR，合并与生产发布按届时授权执行。

以下测试名和新增路径是计划，不表示仓库已经存在。既有入口相对于仓库根目录。

## 2. P0：验证新 zone、单记录容量和 Web 独立首次使用

**输入：** 已确认的双端范围、现有 CloudKit 容器配置、开发账号、可运行 Web 环境。

- [x] 检查 `Sync/CKSyncEngineDatabaseClient.swift` 和 `WebWorkspace/lib/cloudkit.ts` 的可复用传输边界，确认新 adapter 不经过旧 Journal decoder。（结果见 [P0 验证记录](2026-10-17-content-progress-mvp-p0-verification.md) 第 1 节）
- [ ] 在 development 环境验证 iPhone 与 Web 各自创建 `ContentProgressZoneV1`，新用户无需先打开另一端。
- [ ] 用同一 Apple 账号验证 `ContentProgressProject` 的创建、读取、带 change tag 更新，以及过期 tag 被拒绝。
- [ ] 验证不同账号隔离，记录容器、环境和 zone 的对应关系；不在文档保存凭据。
- [ ] 验证最大样例的记录大小和请求限制，确定单元数量、标题长度及 JSON 字节上限；不静默削减产品能力。
- [ ] 验证 Web 部署运行时能承载同源 AI 代理和受约束的公开资料读取，确认 provider 端点允许列表。
- [ ] 将结果、限制和可复现命令补入实现方案；没有在线条件时标记阻塞范围，不用 mock 代替结果。

**完成条件：** 双向读写、新账号 Web 首次使用、过期版本拒绝和记录容量都有真实证据。若单记录或 zone 方案不成立，先修订设计再进入 P1，不在界面完成后才换协议。

**交付：** 最小可重复的 development 冒烟工具/测试、验证报告与必要 adapter 接口；不创建新产品功能页面。

## 3. P1：共享契约与领域规则

**依赖：** P0 的记录与容量决策。

**主要文件：** 拟建 `ContentProgress/ProgressDomain.swift`、`ProgressProjection.swift`、`ProgressService.swift`；Web `lib/content-progress/domain.ts`、`projection.ts`、`commands.ts`；共享 `Resources/ContentProgressContract/`。

- [ ] 固定 schemaVersion、UUID、日期/null、来源字段、长度算法及 payload 编码；定义独立 recordType 与 recordName。
- [ ] 建立新 Project / LearningUnit 类型，避免与旧 Project 混用；保持旧 `Domain.swift`、Journal schema 与 CloudKit type 不变。
- [ ] 实现纯投影：0/0、全部完成、当前/下一单元、x/y 和百分比。
- [ ] 实现 create、setCompleted、rename、add、delete、reorder、setPaused 命令；clock 与 UUID 生成可注入。
- [ ] 固定取消完成清空时间、重复完成保留时间、重排不重建 ID、增删重算进度等规则。
- [ ] 为 Swift/TS 使用同一 valid/invalid fixtures，包含 Unicode 长度、未知版本、重复 ID、断裂顺序和状态时间不一致。

**必要测试：** `ProgressDomainTests`、`ProgressProjectionTests`、Web `content-progress-domain.test.mjs`；两端读相同 fixture 产生相同投影与错误分类。

**完成条件：** 产品文档第 2 节规则能在两端一致运行，业务测试不依赖 UI、AI 或网络。

## 4. P2：本地事务、草稿与账号 scope

**依赖：** P1。

**主要文件：** 拟建 `ProgressRepository.swift`、`SwiftDataProgressRepository.swift`、`ProgressDraftStore.swift`；Web `repository.ts`、`draft-store.ts`。

- [ ] 为新模型建立独立 SwiftData store 和 IndexedDB 数据库；保留旧 Journal 文件及缓存。
- [ ] 单次事务保存投影、base 和 outbox 命令；写入失败则整体回滚。
- [ ] 创建确认固定 project/unit ID，支持重复点击、崩溃恢复与重试，不生成重复项目。
- [ ] 保存初始化输入与预览草稿，重启后可恢复；取消创建只清理本草稿。
- [ ] 草稿确认和正式项目提交以稳定 ID 对账：即使提交后、删除草稿前崩溃，再次确认也不创建重复记录。
- [ ] 按容器/环境/账号/zone 隔离缓存和队列；guest 数据不自动并入登录账号。
- [ ] guest 复制到账号提供预览与幂等映射，源数据保留；Web demo 使用完全独立命名空间。
- [ ] 对磁盘满、数据库打开失败、浏览器存储被拒绝或配额不足显示错误；不以空库覆盖故障数据。

**必要测试：** `ProgressRepositoryTests`、`ProgressDraftStoreTests`；Web IndexedDB adapter 的事务中断、重启、账号隔离测试。内存 mock 用于服务测试，另需真实 IndexedDB 浏览器测试与 SwiftData 持久化重开测试。

**完成条件：** 两端本地确认后的状态重启不丢失，失败不留下半项目；页面清晰区分本地保存与云端同步。

## 5. P3：CloudKit 同步、并发与恢复

**依赖：** P2，且 P0 在线验证通过。

**主要文件：** 拟建 `ProgressCloudAdapter.swift`、`ProgressSyncCoordinator.swift`、Web `cloud-adapter.ts`、`sync.ts`、`conflicts.ts`；参考旧 `SyncMergeService.swift`、`journal-writer.ts` 和 `sync-conflicts.ts` 的实现模式。

- [ ] 新 zone bootstrap、payload 编解码、change tag 读取和条件更新接通。
- [ ] 每项目命令串行，上传成功后原子更新 base/tag 并确认 outbox；新命令不得被旧响应覆盖。
- [ ] 分页读取与 syncToken 一起提交；分页失败保留旧基线，token 失效支持全量重建后重放 pending 命令。
- [ ] 网络超时先按 recordName 和 lastMutationID 对账；无法证明结果时保留冲突，不盲目重复创建或覆盖。
- [ ] 实现三方合并矩阵，包括不同单元、不同字段、同值完成、删除与编辑、并发重排。
- [ ] 冲突提供本地/远端差异及确认后的结果；解决冲突也使用最新 change tag。
- [ ] 登录失效保留 pending；切换账号停止在途上传，校验响应 scope 后才允许落盘。
- [ ] App 前台、Web 标签返回、写入后及手动刷新触发同步；Web 活跃轮询可取消且不重叠。

**必要测试：** `ProgressSyncTests` 与共享冲突 fixtures；Web writer/merge 测试；development 账号真实双向写入、离线重连和版本冲突。

**完成条件：** 不同字段可收敛，冲突字段不被静默覆盖；未知版本不会被旧客户端重写；账号切换不会混入数据；两端独立首次建区可用。

## 6. P4：iPhone 与 Web 的手动两页流程

**依赖：** P3。

**主要文件：** 拟建 `ContentProgress/Views/`、`ProgressApplicationSession.swift`、Web `app/progress-app.tsx`；修改 `App/SelfStudyStudioApp.swift`、Web `app/page.tsx`；核对库 app 入口与 Xcode target。

- [ ] 新首页展示项目名称、进度、当前/下一单元、暂停和同步状态；空态提供创建。
- [ ] 新详情展示完整列表，支持完成/取消、增加、修改、删除和排序。
- [ ] 用共享投影驱动两页，保存成功后定位首个未完成单元；失败保留编辑并提示原因。
- [ ] 用 sheet/dialog 承接手动创建与编辑，不加入独立时间、记录或教学页面。
- [ ] 暂停后保留内容，先恢复再继续完成操作；编辑内容仍可用。
- [ ] 排序提供拖动与上移/下移，覆盖键盘、触摸、VoiceOver；中文/英文资源齐全。
- [ ] 接入附属登录、AI 设置和同步冲突入口；演示状态与真实登录状态不混淆。
- [ ] 新入口按需装配旧模式，保留历史数据访问和已有 App Lock；不要启动旧计时、通知或迁移来服务新项目。
- [ ] 更新项目中的界面流程图及相应导出图，标注新版与历史模式。

**必要验证：** 两端 UI 流程测试、Web 桌面/窄屏浏览器验收、模拟器构建、真机完成与排序操作。App target 与 Swift Package 均要包含新文件。

**完成条件：** 两端均可手动创建并同步项目，通过一次操作完成单元；新主流程不要求目标、时间、笔记或证据。

## 7. P5：AI 初始化、资料输入与预览

**依赖：** P4；P0 已确认代理部署与 provider 可达。

**主要文件：** 拟建 `ProgressPlanProvider.swift`、Web `plan-provider.ts`、`app/api/progress-plan/route.ts`、`app/api/course-outline/route.ts`；复用 iPhone `AIReviewSettingsStore`、`OpenAICompatibleStructuredClient`。

- [ ] 固定只含标题列表的响应 schema 与两端 validator；AI 无 repository 写权限。
- [ ] 名称必填、目录和链接可选；不要求目标、周期、每日时长。
- [ ] 实现公开资料读取的超时、体积、目标地址和重定向限制；来源失败必须显式反馈。
- [ ] Web 同源 AI 代理使用用户 key、允许端点、大小与速率限制；key 不持久化、不写日志、不进入 CloudKit。
- [ ] 实现 generationID、取消、过期响应丢弃与重生成替换确认。
- [ ] 草稿预览支持增删改排序；确认后原子创建正式项目并进入同步，AI 不再自动修改它。
- [ ] 配置缺失、401、429、超时、非法 JSON、空列表、超限及资料不可读均保留输入和旧草稿。
- [ ] 对比发送给 provider 的请求，确认没有旧 Journal 或其他项目上下文。

**必要测试：** fake transport 的请求/响应契约、取消竞态和错误路径；两端真实 provider 各至少跑主题、粘贴目录和读取失败回退场景；公开页面成功读取需独立验收。

**完成条件：** AI 生成→编辑→确认→双端读取全链路通过；密钥配置在两端分别完成，不误称密钥已同步；日常进度操作不发送 AI 请求。

## 8. P6：旧数据、升级与异常恢复

**依赖：** P5。

- [ ] 用含 Project、Session、Proof、计划和附件的旧库样例升级，核对原始文件/记录数量与关键内容未改写。
- [ ] 验证新模式不触发旧迁移；历史模式仍能读取旧数据，不混排新项目。
- [ ] 验证旧客户端仅访问旧 zone，新客户端未知 schema 停止写入；回滚后新数据仍保留但旧版不可见。
- [ ] 注入本地提交失败、远端成功后本地确认失败、下载分页失败、账号中途切换和浏览器重载。
- [ ] 验证 pending 与冲突不会被错误标为已同步；正常项目不因另一项目冲突而阻塞。
- [ ] 检查所有网络与错误日志不含 key、账号敏感字段、原始课程正文。

**完成条件：** 有可复现的恢复路径；没有自动清库、删除旧 zone、覆盖历史记录或强制云端覆盖行为。

## 9. P7：完整验收与发布准备

**依赖：** P0–P6 全部达到完成条件。

### 9.1 自动检查

在仓库根目录运行并记录真实结果：

```bash
swift test
swift build
xcodebuild -project SelfStudyStudio.xcodeproj -target SelfStudyStudio -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

在 `WebWorkspace/` 中运行：

```bash
npm test
npm run lint
```

扩展现有验收入口以覆盖新 zone、契约与人工门禁，旧 Journal 检查保留但不替代新版检查：

```bash
node scripts/d1-release-check.mjs --report /tmp/self-study-studio-progress-report.json
```

新增测试验证状态不变量、失败恢复与跨端契约，避免仅复述实现。旧测试失败先判断是受影响的界面契约还是无关回归，不能批量删断言来获得通过。

### 9.2 产品要求到验收的映射

| 产品要求 | 关键验收 | 所属阶段 |
| --- | --- | --- |
| 名称即可生成，资料可选 | 双端真实 AI；不出现时间/目标必填字段 | P5 |
| 优先资料，无法读取时如实反馈 | 目录与公开页面来源验证、失败不伪称已读 | P5 |
| 预览、修改、重生成、确认后保存 | 草稿不进云端，过期响应不覆盖，重复确认不重复建 | P2、P5 |
| 确认后 AI 不自动修改 | 完成/编辑流程没有 AI 请求与后台修订 | P4、P5 |
| 一键完成与时间自动记录 | 重复设置、取消完成、离线重试保留首次时间 | P1、P3、P4 |
| 等权进度及当前/下一单元 | 4 单元完成 1 个为 25%，两端一致；乱序/空态正确 | P1、P4 |
| 增删改排序、暂停恢复 | 稳定 ID、重排不丢完成状态、暂停无数据丢失 | P1、P4 |
| 首页与详情两页主流程 | iPhone、Web 桌面/窄屏实测；键盘和 VoiceOver | P4、P7 |
| 双端同期和跨端同步 | 两方向创建/更新，离线收敛，并发冲突明确解决 | P0、P3、P7 |
| 旧数据保留 | 升级与历史模式回归，不把 Proof 换算进度 | P6 |

### 9.3 真实发布门禁

- [ ] iPhone 创建并完成一项 → Web 正确显示；Web 改名、排序和暂停 → iPhone 收敛。
- [ ] 全新账号分别从 Web 和 iPhone 开始，均可创建并同步。
- [ ] 两端同时编辑同一项目，验证无冲突合并、同字段冲突及删除冲突。
- [ ] 断网编辑、重启、重新登录、账号切换分别验证，不丢 pending 数据。
- [ ] development 验收后，核对生产 CloudKit schema、容器、环境、Web origin/token 与 AI 代理配置。
- [ ] 按授权部署并在真实 iPhone 与生产 Web 验收，记录构建版本和结果；未部署时明确「待部署」。
- [ ] 更新 README、FEATURE_TREE、CODE_MAP、产品指南与 STATUS，分别标记已实现、自动验证、真实验收和未完成。

**最终完成条件：** 首版四项功能在两端可用，真实同步与 AI 验收通过，历史数据保持可访问；部署完成与否单独标记。仅 P4 的本地流程通过，不能标记 MVP 完成。

## 10. 风险、阻塞与回退动作

| 风险 | 处理方式 | 不允许的替代结论 |
| --- | --- | --- |
| 无 CloudKit 权限、Web token 或真机 | 先执行可独立的契约工作，在线门禁保持未通过 | 不用 mock 声称已同步 |
| 单项目聚合超容量 | P0 固定合理上限；若不满足需求，重新设计协议 | 不截断或分批保存半项目 |
| Web 首次建区不可用 | 在 P0 补足 adapter 或修订平台方案 | 不暗中要求先用 iPhone |
| 同项目冲突较多 | 展示差异并保留两方数据；后续再评估细粒度记录 | 不用最新设备时间覆盖 |
| 资料网站不可读取 | 粘贴目录或明确按主题生成 | 不声称读取成功 |
| Web AI 代理或真实 provider 不可用 | 手动路径继续可用，AI 门禁保留未通过 | 不把固定样例当 AI 生成 |
| 新版发生严重问题 | 停止新模式写入，保留 store/zone/outbox，恢复旧入口 | 不删除新数据或强制回迁 |

本计划不估算未经验证的固定工期。每阶段以入口、交付物和完成条件控制范围；遇到阻塞时只暂停受影响步骤，并在交接记录中写明恢复命令与所需环境。
