# 开发交接

更新时间：2026-10-17 22:13（Asia/Shanghai）
任务状态：进行中（P0 已完成；P1–P3 核心链路已接入，真实验收与同步未完成）
当前任务：内容进度 MVP 开发，先完成 Web 与 iOS 各自功能和验证，再接入跨端同步
工作分支：feat/content-progress-mvp
关联 PR：https://github.com/Panhe-C/self-study-studio/pull/7

## 已完成
- PR #6 产品与技术文档已合并至 main；当前继续已有实施分支和 PR #7。
- 旧 P0-1 传输边界源码检查已完成，证据保留在 `docs/superpowers/plans/2026-10-17-content-progress-mvp-p0-verification.md`；不表示在线验收通过。
- 本轮按用户要求重排实施计划：P0 领域、P1 本地存储、P2 页面、P3 AI、P4 两端分别验收、P5 云端验证、P6 同步、P7 联合验收。
- 同步更新实现方案、产品文档和旧验证记录；拆出后置的账号归属、outbox 和冲突处理，补充已有本地项目接入同步的保留与幂等规则。

- P0 新增 Swift `ContentProgress` 与 Web `content-progress` 领域模块：版本化模型、等权投影、完成时间、增删改排序、暂停恢复和严格解码；两端共用契约与有效/无效样例。
- iOS Xcode target 已引用新 Swift 文件和共享资源；旧 Journal 模型未修改。
- P1 新增独立 SwiftData 与 IndexedDB 项目/草稿 repository；确认草稿与删除草稿为同一事务，稳定 ID 支持重试幂等。旧 Journal 存储未改。
- P2 iPhone 主入口改为内容进度首页/详情和本地草稿创建；旧 Journal 仅从历史入口按需初始化，并保留旧迁移检查与 App Lock。
- P2 Web 主入口改为本地项目；旧 Workspace 在 `/legacy`。浏览器已验证创建、完成进度、排序、暂停/恢复、刷新后项目及显式保存草稿的恢复。
- P3 iPhone 新增严格标题列表 provider，使用已有 Keychain AI 配置；Web 增加仅接受配置端点/模型的同源代理，API Key 只存当前页面内存。双端草稿可主题/粘贴目录生成、取消和重生成，未经读取的链接明确报错，不伪称已使用。
- P4 初步手动验收：iPhone 16 Pro 模拟器（iOS 18.3）创建项目、完成与取消完成、暂停恢复、增加单元、排序、重启恢复；首页 1/2 正确显示 50%。新版菜单可进入旧版记录并返回，旧课程 Cs336/Guitar 可见。本轮将历史入口改为显式导航状态，避免把菜单内的 NavigationLink 直接作为历史页面入口。
- P1 故障注入新增 Swift 会话测试：草稿写入与草稿确认发生 repository 错误时，既有项目/草稿仍保持在界面与存储中，错误可见；重试成功后清除错误。尚未覆盖真实磁盘写入失败。
- Web 390px 窄屏首页与详情通过浏览器检查，无横向溢出；修正详情“添加”按钮折行和进度数字间距，截图见 `docs/assets/content-progress-web-390.png`。

## 下次从这里继续
1. 完成 P2/P3 剩余项：双语资源、界面图、安全课程链接读取或明确禁用、Web 代理可部署的限流/运行时验证；配置真实 provider 分别测试两端主题、目录、错误与重生成。
2. 在真机验证 iPhone 触摸排序、焦点、键盘、VoiceOver、重启恢复和旧数据迁移；补 P1 浏览器配额/SwiftData 写入失败等故障注入，再分别完成 P4。
3. 两端 P4 均通过后再准备 P5 云端环境、执行 P6 同步接入及 P7 联合验收。

## 验证情况
- 已执行：Swift 全量 `swift test` 738 项通过（含 `ProgressPlanProviderTests` 2 项）；Web `npm test` 73 项、`npm run lint` 通过；iOS 无签名 Simulator build、`plutil -lint`、`git diff --check` 通过。浏览器手动创建 2 单元，完成 1 单元为 50%，重排、暂停/恢复，刷新后状态保留；显式保存草稿后重开恢复；`/legacy` 页面可打开。Web AI 无配置错误可见并保留草稿。
- 本轮新增：Swift 全量 `swift test` 740 项通过，含 2 项新增 repository 错误注入；无签名 iOS Simulator build 通过。最新 Xcode 构建产物安装到 iPhone 16 Pro 模拟器，旧版记录入口、旧课程可见与返回均已通过界面验证。Web `npm test` 73 项和 `npm run lint` 通过，390px 视口首页/详情 `scrollWidth=innerWidth=390`。前述 iPhone 进度与排序为模拟器结果，不等于真机触摸或 VoiceOver 验收。CoreSimulator CLI 偶发连接失败，重试后可继续。
- 未执行：P1 真实磁盘/浏览器配额故障注入、P2 iPhone 真机/VoiceOver、P3 真实 provider 与链接读取、CloudKit 在线验证。静态构建、模拟 provider 和模拟器交互不等于真机或真实 AI 验收。
- `npx tsc --noEmit` 未通过：既有 `worker/index.ts` 缺少 `Fetcher`、`D1Database` 类型；本轮 Web 构建、测试及 ESLint 均通过，未把全局类型检查宣称为通过。

## 已知问题 / 待决定
- CloudKit 独立建区、容量与账号隔离尚未在线验证，后置到 P5，不阻塞 P0–P4。
- P4 仍需真实 AI、浏览器和设备验收；各自功能通过不代表跨端同步通过。
- Web 草稿自动保存有短延时，立即刷新可能丢最后一次未提交的输入；已提供“保存草稿并返回”的确定保存操作，P4 再验收异常退出场景。
- Git SSH `push` 返回成功；`git ls-remote` 偶发 github.com DNS 解析失败，但 GitHub 连接器比较远程任务分支与本地提交 `6aa2eaf` 返回 identical。Draft PR #7 标题和说明已按当前 P0–P4 进度更新。
- Web AI 代理的限流目前为单实例内存窗口，部署时需验证或改为共享限流；课程链接读取保持禁用，直至能验证目标地址与重定向安全约束。

## 恢复开发所需信息
- 最新任务顺序见 `docs/superpowers/plans/2026-10-17-content-progress-mvp.md`；旧验证文件名和旧检查编号仅供追溯。
- 本地存储必须先做；后置的是云端存储和同步链路，不能以临时内存数据代替各端持久化。
- 原视频任务 `docs/product-demo-video` / PR #5 与本任务无关；本轮未修改源码、依赖或云端配置。
