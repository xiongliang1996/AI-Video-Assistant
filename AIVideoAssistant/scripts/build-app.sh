#!/usr/bin/env bash
#
# 打包 .app 应用包
# 用法: ./scripts/build-app.sh [release|debug]
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="AI视频助手"
EXEC_NAME="AIVideoAssistant"

echo "==> 编译 (${CONFIG})"
swift build -c "$CONFIG" --disable-sandbox

BIN_DIR="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)"
BIN="$BIN_DIR/$EXEC_NAME"

if [ ! -f "$BIN" ]; then
  echo "!! 找不到可执行文件: $BIN"
  exit 1
fi

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> 组装 app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 复制 SwiftPM 资源 bundle（如果有）
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

echo "==> 代码签名 (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   codesign 不可用，跳过"

echo "==> 打包 zip"
ZIP="$DIST/AIVideoAssistant-macOS.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo ""
echo "✅ 构建完成"
echo "   App: $APP"
echo "   Zip: $ZIP"
du -sh "$APP" "$ZIP" 2>/dev/null || true
