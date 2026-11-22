#!/bin/bash
# Run model and App regression checks without starting the app or capturing system audio.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

SWIFTC=(swiftc -Onone)     # one flag set for the canary and every test build below, so they cannot drift apart

# The checks are plain assert()s: -O (or -Ounchecked) would silently compile them away. Every test binary below is built
# without optimisation; this canary proves a failing assert really aborts with those same flags, so a green run means something.
echo 'import Foundation
assert(Int(CommandLine.arguments.count) < 0, "canary")' > "$TEST_DIR/canary.swift"
"${SWIFTC[@]}" "$TEST_DIR/canary.swift" -o "$TEST_DIR/canary"
# The trap is the expected outcome: the braces keep the shell's own "Trace/BPT trap" report off the screen, so it does not look like a failure.
if { "$TEST_DIR/canary"; } >/dev/null 2>&1; then echo "assert() is disabled in test builds; refusing to run" >&2; exit 1; fi
echo "canary: assert() is active in test builds"

"${SWIFTC[@]}" Battery.swift Tests/BatteryTests.swift -o "$TEST_DIR/battery-tests"
"$TEST_DIR/battery-tests"
"${SWIFTC[@]}" AirPods.swift Tests/AirPodsTests.swift -o "$TEST_DIR/airpods-tests"
"$TEST_DIR/airpods-tests"

"${SWIFTC[@]}" Media.swift Tests/MediaTests.swift -o "$TEST_DIR/media-tests"
"$TEST_DIR/media-tests"

"${SWIFTC[@]}" Lyrics.swift Tests/LyricsTests.swift -o "$TEST_DIR/lyrics-tests"
"$TEST_DIR/lyrics-tests"

"${SWIFTC[@]}" TimerModel.swift Tests/TimerTests.swift -o "$TEST_DIR/timer-tests"
"$TEST_DIR/timer-tests"

"${SWIFTC[@]}" Privacy.swift Tests/PrivacyTests.swift -o "$TEST_DIR/privacy-tests"
"$TEST_DIR/privacy-tests"

"${SWIFTC[@]}" CalendarModel.swift Tests/CalendarTests.swift -o "$TEST_DIR/calendar-tests"
"$TEST_DIR/calendar-tests"

"${SWIFTC[@]}" TransferModel.swift TransferMonitor.swift Tests/TransferTests.swift -o "$TEST_DIR/transfer-tests"
"$TEST_DIR/transfer-tests"

"${SWIFTC[@]}" SensorGesture.swift Tests/SensorGestureTests.swift -o "$TEST_DIR/sensor-tests"
"$TEST_DIR/sensor-tests"

"${SWIFTC[@]}" StepRate.swift MirrorPolicy.swift LoginItem.swift TextClip.swift SensorGesture.swift Tests/StepRateTests.swift -o "$TEST_DIR/steprate-tests"
"$TEST_DIR/steprate-tests"

"${SWIFTC[@]}" Updater.swift Tests/UpdaterTests.swift -o "$TEST_DIR/updater-tests"
"$TEST_DIR/updater-tests"

# Reuse the actual configuration globals while omitting startup and its instance lock.
sed '/^\/\/ One island at a time:/,$d' main.swift > "$TEST_DIR/main.swift"
cat Tests/AppTests.swift Tests/FeatureTests.swift >> "$TEST_DIR/main.swift"
SOURCES=()
for source in ./*.swift; do
    if [ "$source" != "./main.swift" ]; then SOURCES+=("$source"); fi
done
clang -target arm64-apple-macos14.0 -c als_bridge.c -o "$TEST_DIR/als_bridge.o"
"${SWIFTC[@]}" -target arm64-apple-macos14.0 "${SOURCES[@]}" "$TEST_DIR/main.swift" "$TEST_DIR/als_bridge.o" \
    -import-objc-header als_bridge.h -o "$TEST_DIR/app-tests"
NI_NOAUDIO=1 NI_NOMEDIA=1 NI_NOSENSOR=1 NI_NOOVERLAY=1 "$TEST_DIR/app-tests"
