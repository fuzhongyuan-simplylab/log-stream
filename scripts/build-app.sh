#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Android 日志.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/AndroidLogTools" "$APP/Contents/MacOS/AndroidLogTools"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/AndroidLogTools"
codesign --force --sign - "$APP"

echo "已生成 $APP"
