#!/bin/bash
# Builds build/NotchIsland.app (ad-hoc signed, menu-bar-less "agent" app: no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/NotchIsland.app
rm -rf "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET=build/NotchIsland.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift Resources/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/NotchIsland.icns"

# Pin the deployment target. Without it the compiler targets the SDK's own version (here macOS 28.0), and
# Launch Services then refuses to open the app on an older macOS ("not compatible with this version of macOS").
TARGET=arm64-apple-macos14.0     # NSScreen.displayLink needs macOS 14

clang -O2 -target "$TARGET" -c als_bridge.c -o build/als_bridge.o
swiftc -O -target "$TARGET" ./*.swift build/als_bridge.o -import-objc-header als_bridge.h \
    -o "$APP/Contents/MacOS/NotchIsland"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NotchIsland</string>
    <key>CFBundleDisplayName</key><string>NotchIsland</string>
    <key>CFBundleIdentifier</key><string>com.kusbeoms.NotchIsland</string>
    <key>CFBundleExecutable</key><string>NotchIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>NotchIsland</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>ko</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableDescription</key><string>MacBook 노치에서 미디어와 타이머, 시스템 상태를 확인합니다.</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>에어팟의 연결 및 연결 해제 상태를 표시합니다.</string>
    <key>NSAudioCaptureUsageDescription</key><string>노치의 이퀄라이저를 실제 재생 중인 소리에 맞춰 움직이기 위해 시스템 오디오를 분석합니다. 소리는 저장되거나 전송되지 않습니다.</string>
</dict>
</plist>
PLIST

# Sign with the stable local identity when it exists (see make-signing-cert.sh): the Accessibility permission
# is tied to the signature, and an ad-hoc signature changes with every build.
KC="$HOME/Library/Keychains/notchisland-signing.keychain-db"
IDENTITY="NotchIsland Local Signing"
if [ -e "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p "" "$KC"
    codesign --force --sign "$IDENTITY" --keychain "$KC" "$APP"
    echo "signed with '$IDENTITY' (stable identity: the Accessibility permission survives rebuilds)"
else
    codesign --force --sign - "$APP"
    echo "signed ad-hoc; run ./make-signing-cert.sh once so the Accessibility permission survives rebuilds"
fi
codesign --verify --strict "$APP"
echo "built $APP"
