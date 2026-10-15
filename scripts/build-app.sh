#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Logstream.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/MobileLogTools" "$APP/Contents/MacOS/MobileLogTools"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/MobileLogTools"
codesign --force --sign - "$APP"

echo "已生成 $APP"
