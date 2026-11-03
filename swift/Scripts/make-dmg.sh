#!/bin/bash
# 把 .app 打成 DMG
#
# 用法：
#   ./Scripts/make-dmg.sh
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/make-dmg.sh
set -euo pipefail

APP_NAME="Watermark"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
STAGING="$DIST_DIR/dmg-staging"
OUTPUT="$DIST_DIR/$APP_NAME.dmg"

if [ ! -d "$APP_DIR" ]; then
    echo "找不到 $APP_DIR，请先运行 Scripts/build-app.sh" >&2
    exit 1
fi

rm -rf "$STAGING" "$OUTPUT"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> 生成 DMG"
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
