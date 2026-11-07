#!/bin/zsh
# Builds "build/Phone Photo Backup.app" with Swift Package Manager (needs Xcode).
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
APP="build/Phone Photo Backup.app"

echo "▸ Compiling (release)…"
swift build -c release --product PhonePhotoBackup
BIN="$(swift build -c release --show-bin-path)/PhonePhotoBackup"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhonePhotoBackup"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

echo "▸ Rendering icon…"
rm -rf build/AppIcon.iconset
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Phone Photo Backup.app"
  cp -R "$APP" /Applications/
  echo "✔ Installed to /Applications/Phone Photo Backup.app"
else
  echo "✔ Built $ROOT/$APP"
fi
