# 内容进度 MVP V0.1 实施计划

更新日期：2026-10-17
状态：P0 已完成；P1 本地存储核心已实现，故障注入和两端完整验收待做；P2 开发中
产品基线：[MVP V0.1 产品设计](../../PRODUCT_VNEXT.md)
技术依据：[实现方案](../specs/2026-10-17-content-progress-mvp-design.md)

## 1. 目标、顺序与交付规则

先把 Web 和 iOS 各自的功能改好、验证完成，再接入双端存储同步并做联合验收。最终仍交付 iPhone、Web、AI 初始内容生成与跨端同步；调整的是实施顺序，不缩减首版范围。

本地持久化是各端功能的一部分，必须先做，不能用内存样例代替。后置的是云端存储接入、账号归属、outbox、冲突处理与跨端同步验收。前置仅保留稳定 ID、版本化领域契约、repository 接口和两端同规则 fixtures，避免同步反过来绑定 UI。

```text
P0 共享领域契约与规则（无需 CloudKit）
  → P1 各端本地持久化与草稿
  → P2 Web / iOS 各自的手动两页流程
  → P3 Web / iOS 各自的 AI 初始化
  → P4 Web 与 iOS 分别完成全功能、本地恢复与旧数据验收
  → P5 云端存储技术验证
  → P6 双端存储同步接入与冲突恢复
  → P7 跨端同步联合验收与发布准备
```

**阶段门禁：** P4 必须分别记录 Web 和 iOS 的验收证据；任一端未完成，不进入 P5/P6 的同步实施。CloudKit 账号、token、权限或建区能力缺口不阻塞 P0–P4；真实 AI、浏览器和设备条件仍需在各自功能验收时满足。单端功能通过不等于跨端同步通过，也不等于最终 MVP 完成。

按上述依赖顺序推进一个主任务，不假定并行 Agent。每轮修改验证后更新 `STATUS.md`、显式暂存、commit、push 并核对远程；未完成如实用 wip 交接。当前产品文档 PR #6 已合并，实施在 `feat/content-progress-mvp` / PR #7 继续；不重建旧文档分支。

### 阶段编号调整与已有成果

| 旧阶段 | 新位置 |
| --- | --- |
| 旧 P0 云端技术验证 | P5；已完成的源码检查保留，在线验证尚未执行 |
| 旧 P1 领域规则 | P0 |
| 旧 P2 本地存储、账号和 outbox | 本地存储在 P1；账号、base、outbox 移到 P6 |
| 旧 P3 同步 | P6 |
| 旧 P4 页面、旧 P5 AI | P2、P3，各端先独立可用 |
| 旧 P6 兼容恢复 | 本地与旧数据部分在 P4；同步故障部分在 P6/P7 |
| 旧 P7 总验收 | P7，前置两端各自完成 P4 |

[既有验证记录](2026-10-17-content-progress-mvp-p0-verification.md)保留原文件名和旧检查编号，用于追溯，不再是功能开发前置门禁。以下新增类型、测试名与路径为计划，不代表已实现。

## 2. P0：共享领域契约与规则

**依赖：** 已确认的产品基线；无需云端在线验证。

**主要文件：** 拟建 `ContentProgress/ProgressDomain.swift`、`ProgressProjection.swift`、`ProgressService.swift`；Web `lib/content-progress/domain.ts`、`projection.ts`、`commands.ts`；共享 `Resources/ContentProgressContract/`。

- [x] 固定领域 schemaVersion、UUID、日期/null、长度算法与本地序列化；来源文本仅在初始化草稿中使用，P1 存储草稿；云端 recordType、recordName 和容量门禁留到 P5。容量暂按实现方案建议值作为本地上限，标注待云端验证。
- [x] 建立新 Project / LearningUnit 类型，避免与旧 Project 混用；保持旧 `Domain.swift`、Journal schema 与 CloudKit type 不变。
- [x] 实现纯投影：0/0、全部完成、当前/下一单元、x/y 和百分比。
- [x] 实现 create、setCompleted、rename、add、delete、reorder、setPaused 命令；clock 与 UUID 生成可注入。
- [x] 固定取消完成清空时间、重复完成保留时间、重排不重建 ID、增删重算进度等规则。
- [x] 为 Swift/TS 使用同一 valid/invalid fixtures，包含 Unicode 长度、未知版本、重复 ID、断裂顺序和状态时间不一致。

**必要测试：** `ProgressDomainTests`、`ProgressProjectionTests`、Web `content-progress-domain.test.mjs`；两端读相同 fixture 产生相同投影与错误分类。

**完成条件：** 产品文档第 2 节规则能在两端一致运行，业务测试不依赖 UI、AI 或网络。

## 3. P1：各端本地事务与草稿

**依赖：** P0。

**主要文件：** 拟建 `ProgressRepository.swift`、`SwiftDataProgressRepository.swift`、`ProgressDraftStore.swift`；Web `repository.ts`、`draft-store.ts`。

- [x] 为新模型建立独立 SwiftData store 和 IndexedDB 数据库；保留旧 Journal 文件及缓存。
- [x] 单次本地事务保存项目及其单元；写入失败则整体回滚。repository 接口与业务层分离，本阶段不实现 serverBase、outbox、同步 token 或云端队列。
- [x] 创建确认固定 project/unit ID，支持重复点击、崩溃恢复与重试，不生成重复项目。
- [x] 保存初始化输入与预览草稿，重启后可恢复；取消创建只清理本草稿。
- [x] 草稿确认和正式项目提交以稳定 ID 对账：即使提交后、删除草稿前崩溃，再次确认也不创建重复记录。
- [x] 真实本地数据与 demo 数据使用独立命名空间；Web 无需 CloudKit 登录即可完成真实本地功能，不能把本地项目当演示数据。
- [x] 保留稳定项目/单元 ID 和存储 schema 版本，为 P6 接入同步提供可迁移基础；账号归属与上传预览在 P6 实施。
- [ ] 对磁盘满、数据库打开失败、浏览器存储被拒绝或配额不足显示错误；不以空库覆盖故障数据。

**必要测试：** `ProgressRepositoryTests`、`ProgressDraftStoreTests`；Web IndexedDB adapter 的事务中断、重启、真实本地/demo 隔离测试。内存 mock 用于服务测试，另需真实 IndexedDB 浏览器测试与 SwiftData 持久化重开测试。

**完成条件：** 两端本地确认后的状态重启不丢失，失败不留下半项目；页面明确显示「仅保存在此设备/浏览器」，不展示已同步状态。

## 4. P2：Web 与 iOS 各自的手动两页流程

**依赖：** P1；不依赖云端存储或登录。

**主要文件：** 拟建 `ContentProgress/Views/`、`ProgressApplicationSession.swift`、Web `app/progress-app.tsx`；修改 `App/SelfStudyStudioApp.swift`、Web `app/page.tsx`；核对库 app 入口与 Xcode target。

- [ ] 新首页展示项目名称、进度、当前/下一单元、暂停和本地保存状态；空态提供创建。
- [ ] 新详情展示完整列表，支持完成/取消、增加、修改、删除和排序。
- [ ] 用共享投影驱动两页，保存成功后定位首个未完成单元；失败保留编辑并提示原因。
- [ ] 用 sheet/dialog 承接手动创建与编辑，不加入独立时间、记录或教学页面。
- [ ] 暂停后保留内容，先恢复再继续完成操作；编辑内容仍可用。
- [ ] 排序提供拖动与上移/下移，覆盖键盘、触摸、VoiceOver；中文/英文资源齐全。
- [ ] 接入附属 AI 设置，区分演示与真实本地数据；登录、同步状态与冲突入口到 P6 再接入。
- [ ] 新入口按需装配旧模式，保留历史数据访问和已有 App Lock；不要启动旧计时、通知或迁移来服务新项目。
- [ ] 更新项目中的界面流程图及相应导出图，标注新版与历史模式。

**必要验证：** 两端 UI 流程测试、Web 桌面/窄屏浏览器验收、模拟器构建、真机完成与排序操作。App target 与 Swift Package 均要包含新文件。

**完成条件：** 两端均可独立手动创建、本地保存并重启恢复项目，通过一次操作完成单元；新主流程不要求目标、时间、笔记或证据。

## 5. P3：Web 与 iOS 各自的 AI 初始化

**依赖：** P2；在本阶段验证 Web 同源 AI 代理运行时和真实 provider 可达，不等待 CloudKit 环境。

**主要文件：** 拟建 `ProgressPlanProvider.swift`、Web `plan-provider.ts`、`app/api/progress-plan/route.ts`、`app/api/course-outline/route.ts`；复用 iPhone `AIReviewSettingsStore`、`OpenAICompatibleStructuredClient`。

- [ ] 固定只含标题列表的响应 schema 与两端 validator；AI 无 repository 写权限。
- [ ] 名称必填、目录和链接可选；不要求目标、周期、每日时长。
- [ ] 实现公开资料读取的超时、体积、目标地址和重定向限制；来源失败必须显式反馈。
- [ ] Web 同源 AI 代理使用用户 key、允许端点、大小与速率限制；key 不持久化、不写日志、不进入 CloudKit。
- [ ] 实现 generationID、取消、过期响应丢弃与重生成替换确认。
- [ ] 草稿预览支持增删改排序；确认后原子创建本端正式项目并本地保存，AI 不再自动修改它。
- [ ] 配置缺失、401、429、超时、非法 JSON、空列表、超限及资料不可读均保留输入和旧草稿。
- [ ] 对比发送给 provider 的请求，确认没有旧 Journal 或其他项目上下文。

**必要测试：** fake transport 的请求/响应契约、取消竞态和错误路径；两端真实 provider 各至少跑主题、粘贴目录和读取失败回退场景；公开页面成功读取需独立验收。

**完成条件：** Web 与 iOS 分别通过 AI 生成→编辑→确认→本端读取/重启恢复全链路；密钥配置在两端分别完成，不误称密钥已同步；日常进度操作不发送 AI 请求。

## 6. P4：Web 与 iOS 分别完成全功能验收

**依赖：** P0–P3；Web 和 iOS 分别记录结果，两端均通过后才进入 P5。

- [ ] Web：真实浏览器桌面/窄屏完成名称输入、AI 生成、预览编辑、重生成、确认创建、标记/取消完成、当前/下一单元、增删改排序、暂停恢复。
- [ ] iOS：在实际 app target 中完成相同全流程；模拟器用于自动检查，真实设备验证触摸、焦点、键盘、VoiceOver 与重启恢复。
- [ ] 各端使用真实 provider 验证主题、目录及链接失败回退；公开页面读取成功单独记录。mock 或手动创建不能替代 AI 验收。
- [ ] 各端验证 0/0、1/4、全部完成、乱序完成、增删重算和重复完成时间；同一 fixtures 的两端结果一致。
- [ ] 各端验证草稿与正式项目持久化：关闭重开不丢内容，重复确认不重复创建，失败不显示保存成功。
- [ ] 注入磁盘/浏览器配额错误、数据库打开失败、写入中断和过期 AI 响应，不清库、不覆盖已有草稿。
- [ ] 验证断网时已有项目仍能查看、完成和编辑；AI 不可用只影响初始化，错误保留输入。
- [ ] 用含旧 Project、Session、Proof、计划和附件的样例检查升级与历史模式；旧数据不改写、不换算进度。
- [ ] 验证新模式不启动旧迁移或绕过 App Lock；Web 本地数据与 demo 隔离，无需 CloudKit 登录。
- [ ] 界面明确说明当前仅本地保存，无虚假的 pending 上传或已同步状态；日志不含 key 或原始课程正文。

**必要验证：** Swift tests/build、app 模拟器构建、Web test/lint，以及上述浏览器、真机、真实 AI 验收。命令见第 9.1 节；此阶段不执行云端存储验收。

| 验收对象 | 记录内容 | 当前状态 |
| --- | --- | --- |
| Web 独立功能 | 版本、浏览器/视口、数据样例、操作、结果、截图与未通过项 | 未执行 |
| iOS 独立功能 | 版本、设备/系统、同一业务样例、操作、结果与未通过项 | 未执行 |

**完成条件：** Web 和 iOS 的全部首版功能分别可用并验证通过，本地恢复和旧数据保留有证据。任一项待验收时按实际状态保留，不用另一端成功代替。

## 7. P5：云端存储技术验证（功能验收后）

**依赖：** P4 两端各自验收通过。

**输入：** 已有可用的本地功能、现有 CloudKit 容器配置、开发账号与 Web token。

- [x] 检查 `Sync/CKSyncEngineDatabaseClient.swift` 和 `WebWorkspace/lib/cloudkit.ts` 的可复用传输边界，确认新 adapter 不经过旧 Journal decoder。（结果见 [既有云端验证记录](2026-10-17-content-progress-mvp-p0-verification.md) 第 1 节）
- [ ] 在 development 环境验证 iPhone 与 Web 各自创建 `ContentProgressZoneV1`，新用户无需先打开另一端。
- [ ] 用同一 Apple 账号验证 `ContentProgressProject` 的创建、读取、带 change tag 更新，以及过期 tag 被拒绝。
- [ ] 验证不同账号隔离，记录容器、环境和 zone 的对应关系；不在文档保存凭据。
- [ ] 验证最大样例的记录大小和请求限制，确定单元数量、标题长度及 JSON 字节上限；不静默削减产品能力。
- [ ] 核对 P3/P4 已完成的 Web AI 代理验证记录，不重复把 AI 配置列为 CloudKit 前置条件。
- [ ] 将结果、限制和可复现命令补入实现方案；没有在线条件时标记阻塞范围，不用 mock 代替结果。

**完成条件：** 双向读写、新账号 Web 首次使用、过期版本拒绝和记录容量都有真实证据。若单记录或 zone 方案不成立，修订云端 adapter/存储映射后再进入 P6；保留 P0 领域契约和已验收的页面。若必须改变领域字段，提供无损本地迁移并重跑受影响的 P4 验收。

**交付：** 最小可重复的 development 冒烟工具/测试、验证报告与必要 adapter 接口；不创建新产品功能页面。

## 8. P6：双端存储同步接入、并发与恢复

**依赖：** P4 两端验收与 P5 在线验证均通过。

**主要文件：** 拟建 `ProgressCloudAdapter.swift`、`ProgressSyncCoordinator.swift`、Web `cloud-adapter.ts`、`sync.ts`、`conflicts.ts`；参考旧 `SyncMergeService.swift`、`journal-writer.ts` 和 `sync-conflicts.ts` 的实现模式。

- [ ] 为两端本地库增加 serverBase、outbox、syncToken 与冲突存储，提供版本迁移；新投影与 outbox 同事务落盘，失败整体回滚。
- [ ] 把两端已有真实本地项目显式复制到选定 Apple 账号：展示上传预览、保留源数据和 ID；重复迁移幂等，同 ID 已有不同云端内容时进入冲突，不直接覆盖。
- [ ] 按容器/环境/账号/zone 隔离缓存和队列；demo 不上传，切换账号不发送前一账号的命令。
- [ ] 接入登录、同步状态与冲突面板；未登录仍可用独立本地模式，账号退出不把缓存自动变为公共本地数据。
- [ ] 新 zone bootstrap、payload 编解码、change tag 读取和条件更新接通。
- [ ] 每项目命令串行，上传成功后原子更新 base/tag 并确认 outbox；新命令不得被旧响应覆盖。
- [ ] 分页读取与 syncToken 一起提交；分页失败保留旧基线，token 失效支持全量重建后重放 pending 命令。
- [ ] 网络超时先按 recordName 和 lastMutationID 对账；无法证明结果时保留冲突，不盲目重复创建或覆盖。
- [ ] 实现三方合并矩阵，包括不同单元、不同字段、同值完成、删除与编辑、并发重排。
- [ ] 冲突提供本地/远端差异及确认后的结果；解决冲突也使用最新 change tag。
- [ ] 登录失效保留 pending；切换账号停止在途上传，校验响应 scope 后才允许落盘。
- [ ] App 前台、Web 标签返回、写入后及手动刷新触发同步；Web 活跃轮询可取消且不重叠。

**必要测试：** `ProgressSyncTests` 与共享冲突 fixtures；Web writer/merge 测试；development 账号真实双向写入、离线重连和版本冲突。

- [ ] 注入远端成功但本地确认失败、分页中断、账号切换；回滚保留旧本地库、新同步数据和未确认命令。

**完成条件：** 不同字段可收敛，冲突字段不被静默覆盖；未知版本不会被旧客户端重写；账号切换不会混入数据；两端独立首次建区可用。

## 9. P7：跨端同步联合验收与发布准备

**依赖：** P0–P6 全部达到完成条件，P4 的 Web/iOS 验收证据均已记录。

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
| 名称即可生成，资料可选 | 双端真实 AI；不出现时间/目标必填字段 | P3 |
| 优先资料，无法读取时如实反馈 | 目录与公开页面来源验证、失败不伪称已读 | P3 |
| 预览、修改、重生成、确认后保存 | 草稿不进云端，过期响应不覆盖，重复确认不重复建 | P1、P3 |
| 确认后 AI 不自动修改 | 完成/编辑流程没有 AI 请求与后台修订 | P2、P3 |
| 一键完成与时间自动记录 | 重复设置、取消完成、离线重试保留首次时间 | P0、P6、P2 |
| 等权进度及当前/下一单元 | 4 单元完成 1 个为 25%，两端一致；乱序/空态正确 | P0、P2 |
| 增删改排序、暂停恢复 | 稳定 ID、重排不丢完成状态、暂停无数据丢失 | P0、P2 |
| 首页与详情两页主流程 | iPhone、Web 桌面/窄屏实测；键盘和 VoiceOver | P2、P4 |
| 双端同期和跨端同步 | 两方向创建/更新，离线收敛，并发冲突明确解决 | P5、P6、P7 |
| 旧数据保留 | 升级与历史模式回归，不把 Proof 换算进度 | P4、P6 |

### 9.3 真实发布门禁

- [ ] iPhone 创建并完成一项 → Web 正确显示；Web 改名、排序和暂停 → iPhone 收敛。
- [ ] 全新账号分别从 Web 和 iPhone 开始，均可创建并同步。
- [ ] 两端同时编辑同一项目，验证无冲突合并、同字段冲突及删除冲突。
- [ ] 验证 P1–P4 创建的两端真实本地项目经 P6 归属账号后正确同步，不重复、不丢失；断网编辑、重启、重新登录、账号切换不丢 pending 数据。
- [ ] development 验收后，核对生产 CloudKit schema、容器、环境、Web origin/token 与 AI 代理配置。
- [ ] 按授权部署并在真实 iPhone 与生产 Web 验收，记录构建版本和结果；未部署时明确「待部署」。
- [ ] 更新 README、FEATURE_TREE、CODE_MAP、产品指南与 STATUS，分别标记已实现、自动验证、真实验收和未完成。

**最终完成条件：** 首版四项功能在两端可用，真实同步与 AI 验收通过，历史数据保持可访问；部署完成与否单独标记。仅 P4 的两端独立功能通过，不能标记 MVP 完成。

## 10. 风险、阻塞与回退动作

| 风险 | 处理方式 | 不允许的替代结论 |
| --- | --- | --- |
| 无 CloudKit 权限或 Web token | 不阻塞 P0–P4 独立功能；P5–P7 在线门禁保持未通过 | 不用 mock 声称已同步 |
| 无真机或真实 AI 环境 | 可继续独立开发，但 P4 对应验收保持未通过 | 不用模拟器或 fake provider 代替真实验收 |
| 单项目聚合超容量 | P5 固定合理上限；若不满足需求，重新设计协议 | 不截断或分批保存半项目 |
| Web 首次建区不可用 | 在 P5 补足 adapter 或修订平台方案 | 不暗中要求先用 iPhone |
| 同项目冲突较多 | 展示差异并保留两方数据；后续再评估细粒度记录 | 不用最新设备时间覆盖 |
| 资料网站不可读取 | 粘贴目录或明确按主题生成 | 不声称读取成功 |
| Web AI 代理或真实 provider 不可用 | 手动路径继续可用，AI 门禁保留未通过 | 不把固定样例当 AI 生成 |
| 新版发生严重问题 | 停止新模式写入，保留 store/zone/outbox，恢复旧入口 | 不删除新数据或强制回迁 |

本计划不估算未经验证的固定工期。每阶段以入口、交付物和完成条件控制范围；遇到阻塞时只暂停受影响步骤，并在交接记录中写明恢复命令与所需环境。
