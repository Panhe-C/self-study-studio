#!/bin/bash
#
# SelfStudyStudio · 免费 Apple ID 真机一键安装脚本
#
# 在你的 Mac 上跑这一行（不需要先 clone）：
#
#   curl -fsSL https://raw.githubusercontent.com/Panhe-C/self-study-studio/cursor/free-apple-id-signing-1b1e/scripts/setup-free-device-install.sh | bash
#
# 或者 clone 后本地跑：
#
#   bash scripts/setup-free-device-install.sh
#
# 脚本会：
#   1. 检查 macOS / Xcode / git
#   2. 检测通过数据线连到 Mac 的 iPhone 并打印 UDID
#   3. clone（或更新）本分支到 ~/self-study-studio
#   4. 打开 Xcode
#   5. 打印剩下需要在 Xcode GUI 里手动做的步骤
#
# 真正的签名 + 装机没法脚本化（Apple 强制要在 Xcode GUI 里点 + 在 iPhone 上信任证书），
# 但脚本会把所有能自动化的都做完。

set -e

BRANCH="cursor/free-apple-id-signing-1b1e"
REPO_URL="https://github.com/Panhe-C/self-study-studio.git"
PROJECT="SelfStudyStudio.xcodeproj"
DEFAULT_DEST="$HOME/self-study-studio"

if [[ -t 1 ]]; then
    BOLD=$(tput bold 2>/dev/null || echo "")
    RED=$(tput setaf 1 2>/dev/null || echo "")
    GREEN=$(tput setaf 2 2>/dev/null || echo "")
    YELLOW=$(tput setaf 3 2>/dev/null || echo "")
    RESET=$(tput sgr0 2>/dev/null || echo "")
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

echo "${BOLD}SelfStudyStudio · 免费 Apple ID 真机安装脚本${RESET}"
echo

# ---------- 1. macOS ----------
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "${RED}✗ 这个脚本只能在 macOS 上跑。当前系统: $(uname -s)${RESET}"
    echo "  请把这一行命令复制到你的 Mac 终端里运行。"
    exit 1
fi
echo "${GREEN}✓ macOS$(sw_vers -productVersion 2>/dev/null || echo)${RESET}"

# ---------- 2. Xcode ----------
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "${RED}✗ 没装 Xcode。请先：${RESET}"
    echo "  1. 从 Mac App Store 装 Xcode 15+"
    echo "  2. 装完后在终端跑：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi
XCODE_VER=$(xcodebuild -version 2>/dev/null | head -1 || echo "Xcode (version unknown)")
echo "${GREEN}✓ ${XCODE_VER}${RESET}"

# 检查 Xcode 是否登录了 Apple ID（Personal Team）
TEAMS=$(xcrun simctl help >/dev/null 2>&1; security find-internet-password -s "developer.apple.com" 2>/dev/null | grep -c "svce" || echo "0")
if [[ "$TEAMS" == "0" ]]; then
    echo "${YELLOW}⚠ 没检测到 Xcode 里登录的 Apple ID。${RESET}"
    echo "  请打开 Xcode → Settings (Cmd+,) → Accounts → + → 用你的 Apple ID 登录"
    echo "  登录后会出现一个 Personal Team，等会儿在 Signing 里选它"
else
    echo "${GREEN}✓ 检测到 Xcode 里至少有一个 Apple ID 账号${RESET}"
fi

# ---------- 3. git ----------
if ! command -v git >/dev/null 2>&1; then
    echo "${RED}✗ 没装 git。跑：xcode-select --install${RESET}"
    exit 1
fi
echo "${GREEN}✓ $(git --version)${RESET}"

# ---------- 4. 检测 iPhone ----------
echo
echo "${BOLD}检测通过数据线连接的 iPhone...${RESET}"
# xctrace list devices 输出形如：
#   iPhone 16 Pro (xxxxxxxx-xxxxxxxxxxxxxxxx) (2)
# 或老格式：
#   iPhone 16 Pro (UDID) (2)
IPHONE_LINES=$(xcrun xctrace list devices 2>/dev/null | grep -iE "^\s*iPhone" || true)
if [[ -z "$IPHONE_LINES" ]]; then
    echo "${YELLOW}⚠ 没检测到连接的 iPhone。请确认：${RESET}"
    echo "  - iPhone 用数据线连到 Mac（不是只充电）"
    echo "  - iPhone 已解锁"
    echo "  - iPhone 上点了'信任此电脑'"
    echo "  - 在 Finder 边栏能看到这台 iPhone"
    echo
    echo "  脚本继续往下跑，等你在 Xcode 里再选设备也行。"
else
    echo "${GREEN}✓ 检测到 iPhone：${RESET}"
    echo "$IPHONE_LINES" | sed 's/^/    /'
    echo
    UDID=$(echo "$IPHONE_LINES" | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{10,})\).*/\1/' || echo "")
    if [[ -n "$UDID" ]]; then
        echo "  第一台 iPhone 的 UDID: ${BOLD}${UDID}${RESET}"
        echo "  （Xcode 设备下拉里会显示同样的设备名，选它即可）"
    fi
fi

# ---------- 5. clone / update ----------
echo
echo "${BOLD}准备代码...${RESET}"
DEST="${1:-$DEFAULT_DEST}"
if [[ -d "$DEST/.git" ]]; then
    echo "  发现已有仓库 $DEST，更新到分支 ${BRANCH}"
    cd "$DEST"
    git fetch origin "$BRANCH"
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        git checkout "$BRANCH"
    else
        git checkout -b "$BRANCH" "origin/$BRANCH"
    fi
    git pull origin "$BRANCH" || true
else
    echo "  clone 到 $DEST"
    git clone --branch "$BRANCH" "$REPO_URL" "$DEST"
    cd "$DEST"
fi
echo "${GREEN}✓ 代码就绪: $DEST (分支 $(git rev-parse --abbrev-ref HEAD))${RESET}"

# ---------- 6. 打开 Xcode ----------
echo
echo "${BOLD}打开 Xcode...${RESET}"
open "$DEST/$PROJECT"
echo "${GREEN}✓ Xcode 已打开 $PROJECT${RESET}"

# ---------- 7. 打印剩余手动步骤 ----------
echo
echo "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo "${BOLD}剩下这几步在 Xcode GUI 里做（没法脚本化，Apple 强制）：${RESET}"
echo "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo
echo " 1. 左上项目导航器最顶层选 SelfStudyStudio 项目"
echo " 2. TARGETS 选 SelfStudyStudio"
echo " 3. 切到 Signing & Capabilities 标签"
echo " 4. 勾 Automatically manage signing"
echo " 5. Team 下拉选你的 Personal Team（免费 Apple ID）"
echo "    - 没有的话：Xcode → Settings → Accounts → + 用 Apple ID 登录"
echo " 6. Xcode 顶部窗口中间的设备下拉里选你刚才检测到的那台 iPhone"
echo " 7. 按 Cmd+R 编译并装机"
echo " 8. 第一次签名 Xcode 会弹框，点 Allow"
echo " 9. iPhone 上：设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID"
echo
echo "${BOLD}装上后 App 自动启动，进入两步入引导。${RESET}"
echo
echo "完整文档：$DEST/docs/FREE_APPLE_ID_INSTALL.md"
echo
echo "${YELLOW}提示：免费 Apple ID 签的 App 7 天后签名过期，重跑 Cmd+R 即可，本地数据不丢。${RESET}"
