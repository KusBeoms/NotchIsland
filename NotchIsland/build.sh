#!/bin/bash
# Builds and signs build/NotchIsland.app, then packages build/NotchIsland-arm64-dev.zip (RELEASE=1: build/NotchIsland-arm64.zip, the release asset).
set -euo pipefail
cd "$(dirname "$0")"

# Single source of truth for the version: the VERSION file ("2.0"). The build number is the whole version, so it grows with every
# release (the updater compares CFBundleShortVersionString, never CFBundleVersion).
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){1,3}$ ]] || { echo "VERSION must be a dotted number (e.g. 2.0), got '$VERSION'" >&2; exit 1; }
BUILD_NUMBER="$VERSION"

APP=build/NotchIsland.app
# Only a RELEASE=1 build gets the name the updater looks for; a local build is named -dev so it cannot be uploaded as a release by mistake.
if [ "${RELEASE:-}" = "1" ]; then ARCHIVE=build/NotchIsland-arm64.zip; else ARCHIVE=build/NotchIsland-arm64-dev.zip; fi
ARCHIVE_TMP=build/NotchIsland-arm64.tmp.zip
trap 'rm -f "$ARCHIVE_TMP"' EXIT
rm -f "$ARCHIVE" "$ARCHIVE_TMP"
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
    <key>CFBundleShortVersionString</key><string>@VERSION@</string>
    <key>CFBundleVersion</key><string>@BUILD@</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>에어팟의 연결 및 연결 해제 상태를 표시합니다.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>곧 시작하는 일정을 노치에 표시합니다. 일정은 읽기만 하며 저장하거나 전송하지 않습니다.</string>
    <key>NSCalendarsUsageDescription</key><string>곧 시작하는 일정을 노치에 표시합니다. 일정은 읽기만 하며 저장하거나 전송하지 않습니다.</string>
    <key>NSAudioCaptureUsageDescription</key><string>노치의 이퀄라이저를 실제 재생 중인 소리에 맞춰 움직이기 위해 시스템 오디오를 분석합니다. 소리는 저장되거나 전송되지 않습니다.</string>
</dict>
</plist>
PLIST
sed -i '' -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Sign with the stable local identity when it exists (see make-signing-cert.sh): the Accessibility permission
# is tied to the signature, and an ad-hoc signature changes with every build.
# Hardened runtime with only the entitlements the app really uses (NotchIsland.entitlements), plus a secure
# timestamp. The timestamp needs network access, so an offline build retries without it.
SIGN_OPTS=(--force --options runtime --entitlements NotchIsland.entitlements)
KC="$HOME/Library/Keychains/notchisland-signing.keychain-db"
IDENTITY="NotchIsland Local Signing"
if [ -e "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p "" "$KC"
    if ! codesign "${SIGN_OPTS[@]}" --timestamp --sign "$IDENTITY" --keychain "$KC" "$APP"; then
        if [ "${RELEASE:-}" = "1" ]; then echo "RELEASE=1: the secure timestamp could not be obtained; refusing to sign without it" >&2; exit 1; fi
        echo "warning: no secure timestamp (offline?); signing without one. Do not publish this build (RELEASE=1 forbids it)." >&2
        codesign "${SIGN_OPTS[@]}" --timestamp=none --sign "$IDENTITY" --keychain "$KC" "$APP"
    fi
    echo "signed with '$IDENTITY' (stable identity: the Accessibility permission survives rebuilds)"
else
    if [ "${RELEASE:-}" = "1" ]; then echo "RELEASE=1: the signing identity '$IDENTITY' is missing; refusing to ship an ad-hoc build" >&2; exit 1; fi
    codesign "${SIGN_OPTS[@]}" --sign - "$APP"
    echo "warning: signed ad-hoc (not releasable: installed copies could not verify it); run ./make-signing-cert.sh once so the Accessibility permission survives rebuilds" >&2
fi
codesign --verify --strict "$APP"
echo "built $APP"

# Preserve the complete app bundle, resource forks and macOS metadata for distribution.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE_TMP"
mv "$ARCHIVE_TMP" "$ARCHIVE"
echo "packaged $ARCHIVE"
