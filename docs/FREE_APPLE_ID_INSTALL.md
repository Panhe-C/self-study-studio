# 用免费 Apple ID 把 SelfStudyStudio 装到自己的 iPhone

本分支专为 **没有付费 Apple Developer Program、只用 Mac 当前登录的免费 Apple ID** 的用户准备。

## 这个分支做了什么

- 把 `SelfStudyStudio/SelfStudyStudio.entitlements` 清空成空 plist（保留文件，方便以后付费账号恢复）
- 移除了 iCloud / CloudKit / Push Notifications 三个免费账号签不了的 entitlement

代价：iCloud 多设备同步、Push 通知这两块功能在你装的这个版本里**不会工作**。其它核心学习循环（Today / Projects / Quick Log / Timer / Proof / Calendar / Review / AI 配置）都正常可用。

> 想恢复完整 iCloud 功能，参见本文末尾的"恢复 iCloud 同步"。

## 你需要准备

- 一台装了 Xcode 15+ 的 Mac
- 一台 iOS 17+ 的 iPhone，用数据线连到这台 Mac，手机上点"信任此电脑"
- Mac 上登录的免费 Apple ID（Xcode → Settings → Accounts 里能看到）

## 步骤

### 1. 拉这个分支到本地

```bash
git clone https://github.com/panhe-c/self-study-studio.git
cd self-study-studio
git checkout cursor/free-apple-id-signing-1b1e
open SelfStudyStudio.xcodeproj
```

### 2. 在 Xcode 设置签名

1. 项目导航器最顶层选中 `SelfStudyStudio` 项目
2. TARGETS 里选 `SelfStudyStudio`
3. 切到 **Signing & Capabilities** 标签
4. 勾选 **Automatically manage signing**
5. **Team** 下拉里选你的 **Personal Team**（就是你的免费 Apple ID，Xcode 会自动帮你建一个）
6. **Bundle Identifier** 保持 `com.local.selfstudystudio` 即可；如果 Xcode 提示这个 id 已被占用，改成你自己的反域名，例如 `com.<你的名字>.selfstudystudio`

> 如果 Team 下拉里没有你的 Apple ID，去 **Xcode → Settings → Accounts → +** 用 Apple ID 登录一次。

### 3. 选真机并运行

1. Xcode 顶部窗口中间的设备下拉里选你接上的 iPhone（不要选模拟器）
2. 第一次用 Personal Team 签名，Xcode 会在你按 Run 之后弹一个对话框，点 **Allow** 让它生成签名证书
3. iPhone 上：**设置 → 通用 → VPN与设备管理 → 点你的 Apple ID → 信任**
4. 回 Xcode 按 `Cmd + R`（或点左上角 ▶），等编译完成，App 自动装到手机并启动

### 4. 第一次启动后

- App 会进入两步入引导，让你建 1-3 个学习项目
- 在 **Library → AI Review Settings** 里填 OpenAI 兼容端点 + API Key 可以打开 AI 周复盘（Key 存在 Keychain，不会随 iCloud 同步）
- 想用日历写入：到 **系统设置 → 日历 → 学习记录 Full Access** 单独授权

## 免费账号的约束

- 装上的 App **7 天后签名过期**，需要回 Xcode 重新按 `Cmd + R` 装一次（数据保留在本地，不会丢）
- 每周最多 3 个 App 用 Personal Team 签名
- 不能上架 App Store、不能用 TestFlight、不能装到没连你 Mac 的设备
- iCloud 同步、Push Notifications 在这个分支里被禁用，相关 UI 入口可能显示"未配置"或不可用

## 恢复 iCloud 同步（需要付费 Apple Developer Program）

把 `SelfStudyStudio/SelfStudyStudio.entitlements` 改回：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>aps-environment</key>
    <string>$(APS_ENVIRONMENT)</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>$(ICLOUD_CONTAINER_IDENTIFIER)</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
</dict>
</plist>
```

然后在 Xcode 的 Signing & Capabilities 里：
- 选你的付费 Developer Team
- 加 iCloud capability，勾选 CloudKit，创建/关联 `iCloud.com.local.selfstudystudio` 容器
- 加 Push Notifications capability
- Build Settings 里确认 `APS_ENVIRONMENT` = `development`（Debug） / `production`（Release）、`ICLOUD_CONTAINER_IDENTIFIER` = `iCloud.com.local.selfstudystudio`

详细真机验收步骤见仓库根目录 `README.md` 的 "iCloud Device Acceptance" 一节。
