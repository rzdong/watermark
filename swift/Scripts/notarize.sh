#!/bin/bash
# 公证并钉票。需要 Apple Developer Program（$99/年）与 Developer ID 证书。
#
# 前置：
#   1. 到 appleid.apple.com 生成 App 专用密码
#   2. 用 Developer ID Application 证书签名（build-app.sh / make-dmg.sh 传入 SIGN_IDENTITY）
#
# 用法：
#   APPLE_ID="you@example.com" TEAM_ID="XXXXXXXXXX" APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#     ./Scripts/notarize.sh
#
# 也可以先把凭据存进钥匙串，之后就只需 --keychain-profile：
#   xcrun notarytool store-credentials "watermark-notary" \
#     --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD"
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$PROJECT_DIR/dist/Watermark.dmg"

if [ ! -f "$DMG" ]; then
    echo "找不到 $DMG，请先运行 Scripts/make-dmg.sh" >&2
    exit 1
fi

if [ -n "${KEYCHAIN_PROFILE:-}" ]; then
    echo "==> 提交公证（钥匙串配置：$KEYCHAIN_PROFILE）"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
elif [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ]; then
    echo "==> 提交公证"
    xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait
else
    echo "需要 KEYCHAIN_PROFILE，或同时提供 APPLE_ID / TEAM_ID / APP_PASSWORD" >&2
    exit 1
fi

echo "==> 钉票"
xcrun stapler staple "$DMG"

echo "==> 校验"
spctl -a -v "$PROJECT_DIR/dist/Watermark.app"
xcrun stapler validate "$DMG"

echo "==> 完成，可以分发了：$DMG"
