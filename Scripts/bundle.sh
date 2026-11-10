#!/usr/bin/env bash
# Builds .build/Lumaphase.app with a minimal Info.plist. No signing identity is
# required; ad-hoc signing is applied when codesign is available.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
VERSION="${LUMAPHASE_VERSION:-0.1.0}"
BUILD_NUMBER="${LUMAPHASE_BUILD:-1}"
cd "$ROOT"

swift build -c "$CONFIGURATION" --arch arm64 --product Lumaphase --jobs 4
BIN_PATH="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"
APP="${2:-$ROOT/.build/Lumaphase.app}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Lumaphase" "$APP/Contents/MacOS/Lumaphase"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/third_party/opencv-4.10.0/LICENSE" "$APP/Contents/Resources/OpenCV-LICENSE"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Lumaphase</string>
    <key>CFBundleDisplayName</key>
    <string>Lumaphase</string>
    <key>CFBundleIdentifier</key>
    <string>dev.lumaphase.Lumaphase</string>
    <key>CFBundleExecutable</key>
    <string>Lumaphase</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP"

echo "$APP"
