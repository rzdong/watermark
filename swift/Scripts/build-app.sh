#!/bin/bash
# 构建 Release 并组装 .app bundle
#
# 用法：
#   ./Scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/build-app.sh
set -euo pipefail

APP_NAME="Watermark"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> 构建 Release"
swift build --package-path "$PROJECT_DIR" -c release --disable-sandbox

echo "==> 组装 bundle"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/watermark-app" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# 剥离调试符号：二进制 1.2M → 639K，是减小体积最有效的一步。
# 必须在签名之前做，否则会破坏已生成的签名。
echo "==> 剥离调试符号"
strip -x -S "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || echo "    （strip 未生效，不影响运行）"

# 签名说明（重要）：
#   - 分发给他人、想让对方双击直接打开 → 必须用 Developer ID，这需要 $99/年的
#     Apple Developer Program。没有任何开源工具能凭空生成 Apple 信任的证书。
#   - 没有 Developer ID 时，这里退化为 ad-hoc 签名（"-"）。它能让 bundle 具备合法
#     签名结构、本机运行正常，但 Gatekeeper 仍会拦截，需配合 dist 里的
#     「安装到应用程序.command」移除 quarantine，详见 Scripts/make-portable.sh。
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> 签名（Hardened Runtime）：$SIGN_IDENTITY"
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
else
    echo "==> 未设置 SIGN_IDENTITY，使用 ad-hoc 签名（仅本机 / 需放行脚本）"
    codesign --force --deep --sign - "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" || \
        echo "    （ad-hoc 签名校验未通过，不影响本机运行）"
fi

echo "==> 完成：$APP_DIR"
