# 免费 Apple ID 真机安装

主分支保留完整 CloudKit 和推送权限。免费签名使用独立的 `SelfStudyStudio/FreePersonalTeam.entitlements`，不覆盖默认权限文件；该安装方式不提供 CloudKit 同步和远程推送。

## 准备代码

在装有 Xcode 的 Mac 上运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Panhe-C/self-study-studio/main/scripts/setup-free-device-install.sh | bash
```

脚本默认克隆 main 到 `~/self-study-studio` 并打开 Xcode。已有目录必须属于本仓库、位于 main 且工作区干净，更新只允许快进；否则停止并保留现场。可下载脚本后传入其他目录：

```bash
bash scripts/setup-free-device-install.sh "$HOME/self-study-studio-device"
```

## 配置本地免费签名

1. 在 Xcode → Settings → Accounts 中登录 Apple ID。
2. 选择 SelfStudyStudio target，在 Signing & Capabilities 中启用自动签名并选择 Personal Team；必要时设置自己的唯一 Bundle Identifier。
3. 在 Build Settings 中搜索 Code Signing Entitlements，将 Debug 和 Release 的值改为 `SelfStudyStudio/FreePersonalTeam.entitlements`。此改动只用于本地安装副本，不要提交回 main。
4. 连接并信任 iPhone，按设备提示启用开发者模式，在 Xcode 中选择设备并运行。按系统提示完成签名信任。

免费签名的有效期、设备限制及可用能力以 Xcode 和 Apple 账号提示为准。此流程尚未经过本次真机验收。

## 恢复完整同步配置

将 Code Signing Entitlements 改回 `SelfStudyStudio/SelfStudyStudio.entitlements`，选择具备对应能力的开发者团队，配置 CloudKit 容器和推送权限。验证步骤见 README.md 与 `docs/d1-acceptance-runbook.md`。
