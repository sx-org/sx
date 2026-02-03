#!/bin/bash
# tools/verify-step.sh
#
# Single-command verification gate run after every plan step.
# Per the mem.sx implementation plan, ~/projects/game must remain
# buildable + runnable on all 3 platforms (macOS host, iOS sim,
# Android device) at every step boundary.
#
# Exits 0 if all gates pass; non-zero on any failure.
# Screenshots saved to /tmp/sx-game-{macos,iossim,android}.png.

set -e

ROOT="/Users/agra/projects/sx"
GAME="/Users/agra/projects/game"
SX="$ROOT/zig-out/bin/sx"

cd "$ROOT"

echo "── 1/5 zig build ─────────────────────────────────────"
zig build

echo "── 2/4 zig build test ────────────────────────────────"
# Runs the unit tests AND the full example/issue regression corpus
# (src/corpus_run.test.zig) — a failing example fails the build.
zig build test

echo "── 3/4 chess: cross-build for all 3 platforms ────────"
# Builds must be serial — sx writes to .sx-tmp/ which would race in parallel.
cd "$GAME"
"$SX" build main.sx                        > /tmp/sx-game-macos-build.log 2>&1 \
    || { echo "macOS build failed:"; cat /tmp/sx-game-macos-build.log; exit 1; }
echo "  macOS    OK"
"$SX" build --target ios-sim main.sx       > /tmp/sx-game-iossim-build.log 2>&1 \
    || { echo "iOS sim build failed:"; cat /tmp/sx-game-iossim-build.log; exit 1; }
echo "  iOS sim  OK"
"$SX" build --target android main.sx       > /tmp/sx-game-android-build.log 2>&1 \
    || { echo "Android build failed:"; cat /tmp/sx-game-android-build.log; exit 1; }
echo "  Android  OK"

echo "── 4/4 chess: launch + screenshot on each platform ───"

# macOS — direct binary launch
./sx-out/macos/SxChess > /tmp/sx-game-macos-run.log 2>&1 &
PID=$!
sleep 5
if ps -p $PID > /dev/null; then
    screencapture -x /tmp/sx-game-macos.png
    kill $PID 2>/dev/null
    wait $PID 2>/dev/null
    echo "  macOS    screenshot saved: /tmp/sx-game-macos.png"
else
    echo "  macOS    process exited early; log:"
    cat /tmp/sx-game-macos-run.log
    exit 1
fi

# iOS sim — requires booted simulator
if xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
    xcrun simctl install booted "$GAME/sx-out/ios/SxChess.app" > /dev/null 2>&1
    xcrun simctl launch booted co.swipelab.sxchess > /dev/null 2>&1
    sleep 5
    xcrun simctl io booted screenshot /tmp/sx-game-iossim.png > /dev/null 2>&1
    echo "  iOS sim  screenshot saved: /tmp/sx-game-iossim.png"
else
    echo "  iOS sim  SKIPPED (no booted simulator)"
fi

# Android — requires connected device. Needs 6s+ for the side panel to render.
if adb devices 2>/dev/null | grep -q "device$"; then
    adb install -r "$GAME/sx-out/android/sxchess.apk" > /dev/null 2>&1
    adb shell am force-stop co.swipelab.sxchess > /dev/null 2>&1
    adb shell am start -n co.swipelab.sxchess/.SxApp > /dev/null 2>&1
    sleep 6
    adb exec-out screencap -p > /tmp/sx-game-android.png 2>/dev/null
    echo "  Android  screenshot saved: /tmp/sx-game-android.png"
else
    echo "  Android  SKIPPED (no connected device)"
fi

cd "$ROOT"
echo ""
echo "═══ all gates pass ═════════════════════════════════════"
echo "screenshots: /tmp/sx-game-{macos,iossim,android}.png"
