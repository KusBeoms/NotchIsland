#!/bin/bash
# Run model and App regression checks without starting the app or capturing system audio.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc Battery.swift Tests/BatteryTests.swift -o "$TEST_DIR/battery-tests"
"$TEST_DIR/battery-tests"
swiftc AirPods.swift Tests/AirPodsTests.swift -o "$TEST_DIR/airpods-tests"
"$TEST_DIR/airpods-tests"

# Reuse the actual configuration globals while omitting startup and its instance lock.
sed '/^\/\/ One island at a time:/,$d' main.swift > "$TEST_DIR/main.swift"
cat Tests/AppTests.swift >> "$TEST_DIR/main.swift"
SOURCES=()
for source in ./*.swift; do
    if [ "$source" != "./main.swift" ]; then SOURCES+=("$source"); fi
done
clang -target arm64-apple-macos14.0 -c als_bridge.c -o "$TEST_DIR/als_bridge.o"
swiftc -target arm64-apple-macos14.0 "${SOURCES[@]}" "$TEST_DIR/main.swift" "$TEST_DIR/als_bridge.o" \
    -import-objc-header als_bridge.h -o "$TEST_DIR/app-tests"
NI_NOAUDIO=1 NI_NOMEDIA=1 NI_NOSENSOR=1 "$TEST_DIR/app-tests"
