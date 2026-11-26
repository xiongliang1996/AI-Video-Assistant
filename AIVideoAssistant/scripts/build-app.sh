#!/usr/bin/env bash
#
# 打包 .app 应用包
# 用法: ./scripts/build-app.sh [release|debug]
#
# 环境变量:
#   UNIVERSAL=1  同时编 arm64 + x86_64，用 lipo 合成通用二进制（CI 默认开）
#
# 为什么要分开编再 lipo：SwiftPM 的 `--arch a --arch b` 走的是 Xcode 构建系统，
# 只装了命令行工具（没有完整 Xcode）的机器上会报 xcbuild 不存在。
# 分两次单架构编译再合并，纯 SwiftPM 就能跑。
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="AI视频助手"
EXEC_NAME="AIVideoAssistant"
UNIVERSAL="${UNIVERSAL:-0}"

echo "==> 编译 (${CONFIG}${UNIVERSAL:+, universal=$UNIVERSAL})"

if [ "$UNIVERSAL" = "1" ]; then
  swift build -c "$CONFIG" --arch arm64 --disable-sandbox
  swift build -c "$CONFIG" --arch x86_64 --disable-sandbox

  ARM_DIR="$(swift build -c "$CONFIG" --arch arm64 --disable-sandbox --show-bin-path)"
  X86_DIR="$(swift build -c "$CONFIG" --arch x86_64 --disable-sandbox --show-bin-path)"
  BIN_DIR="$ARM_DIR"
  BIN="$BIN_DIR/$EXEC_NAME"

  echo "==> 合成通用二进制"
  lipo -create "$ARM_DIR/$EXEC_NAME" "$X86_DIR/$EXEC_NAME" -output "$BIN.universal"
  mv "$BIN.universal" "$BIN"
  lipo -info "$BIN"
else
  swift build -c "$CONFIG" --disable-sandbox
  BIN_DIR="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)"
  BIN="$BIN_DIR/$EXEC_NAME"
fi

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
file "$APP/Contents/MacOS/$EXEC_NAME" | sed 's/^/   /'
du -sh "$APP" "$ZIP" 2>/dev/null || true
