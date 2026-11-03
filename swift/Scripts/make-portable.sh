#!/bin/bash
# 生成「可以直接发给朋友」的分发包（DMG 内置一键安装脚本）
#
# 背景（务必先读）：
#   Apple 信任的签名 = Developer ID 证书，只发给 Apple Developer Program 付费会员
#   （$99/年）。没有任何开源工具能生成它——声称能的都是骗局或夹带私货，别用。
#   没有 Developer ID 时，收件人第一次打开一定会被 Gatekeeper 拦一次，
#   这是 macOS 的设计，绕不过去。本脚本做的是把「放行」这一步压缩到最简单。
#
# 用法：
#   ./Scripts/make-portable.sh
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/make-portable.sh
set -euo pipefail

APP_NAME="Watermark"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
STAGING="$DIST_DIR/dmg-staging"
OUTPUT="$DIST_DIR/$APP_NAME-便携版.dmg"

"$PROJECT_DIR/Scripts/build-app.sh"

if [ ! -d "$APP_DIR" ]; then
    echo "找不到 $APP_DIR" >&2
    exit 1
fi

rm -rf "$STAGING" "$OUTPUT"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# ---- 一键安装脚本：拷贝到 Applications 并移除隔离属性 ----
# 说明：Gatekeeper 只检查带 com.apple.quarantine 的文件。app 从 DMG 拖出来时
# 会继承这个属性，去掉之后系统不再弹「身份不明的开发者」，之后每次打开都正常。
cat > "$STAGING/安装到应用程序.command" <<'SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"

SOURCE="Watermark.app"
if [ ! -d "$SOURCE" ]; then
    echo "找不到 Watermark.app，请确认它在和本脚本同一个目录里。"
    read -r -p "按回车键关闭…"
    exit 1
fi

# 优先装进系统级 Applications，没权限就退回用户目录（同样能被 Launchpad 找到）
TARGET_DIR="/Applications"
if [ ! -w "$TARGET_DIR" ]; then
    TARGET_DIR="$HOME/Applications"
    mkdir -p "$TARGET_DIR"
fi

echo "==> 安装到 $TARGET_DIR"
if [ -d "$TARGET_DIR/Watermark.app" ]; then
    echo "    已存在旧版本，先移除"
    rm -rf "$TARGET_DIR/Watermark.app"
fi
cp -R "$SOURCE" "$TARGET_DIR/Watermark.app"

# 关键一步：去掉隔离属性，此后双击直接打开，不再被 Gatekeeper 拦。
# provenance 是较新 macOS 额外记录的来源标记，一并清掉更稳妥（清不掉也无妨）。
xattr -dr com.apple.quarantine "$TARGET_DIR/Watermark.app" 2>/dev/null || true
xattr -dr com.apple.provenance  "$TARGET_DIR/Watermark.app" 2>/dev/null || true

echo "==> 完成，正在启动"
open "$TARGET_DIR/Watermark.app"

echo
echo "安装位置：$TARGET_DIR/Watermark.app"
echo "以后从「启动台」或「应用程序」文件夹打开即可。"
read -r -p "按回车键关闭…"
SCRIPT
chmod +x "$STAGING/安装到应用程序.command"

# ---- 使用说明 ----
cat > "$STAGING/先看我.txt" <<'DOC'
水印 Watermark —— 安装说明
================================

【安装】
双击「安装到应用程序.command」，一次搞定：拷贝到应用程序文件夹、放行、启动。

如果系统提示「无法打开，因为它来自身份不明的开发者」：
  1. 打开「系统设置 → 隐私与安全性」
  2. 滚到「安全性」一栏，会看到本应用的提示
  3. 点「仍要打开」，输入密码确认
  （macOS Sequoia 起，右键「打开」这个老办法已经失效，只能走上面这条路径。）

【为什么需要这一步】
本应用没有 Apple 的 Developer ID 签名（那需要 $99/年的开发者账号）。
macOS 对没有 Apple 签名的应用都会拦一次，这是系统安全机制，不是应用有问题。
执行上面的放行之后，之后每次打开都正常，不会再提示。

【应用本身】
纯本地运行，不联网、不上传任何文件。
只支持 PDF 与常见图片格式，原文件只读，一律生成新文件，不会覆盖你的原始文件。
DOC

echo "==> 生成便携版 DMG"
hdiutil create \
    -volname "水印 Watermark" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$OUTPUT"

rm -rf "$STAGING"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> 签名 DMG"
    codesign --force --sign "$SIGN_IDENTITY" "$OUTPUT"
fi

echo "==> 完成：$OUTPUT"
echo "    把这个 DMG 发给朋友，让他双击里面的「安装到应用程序.command」即可。"
