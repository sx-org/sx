#!/usr/bin/env bash
# Debug-stepping smoke (ERR E3.0 slice 3e, rung 1: macOS native).
#
# Verifies the DWARF emitted by `sx build --emit-obj` actually drives
# source-level stepping in lldb — the deep-debug half of the trace story.
# NOT part of `run_examples.sh` (it needs `lldb`, and is macOS-specific via the
# debug-map → kept `.o`). Run manually:  bash tests/debug_stepping_smoke.sh
#
# Exit 0 = lldb resolved a file:line breakpoint + a source-mapped backtrace.

set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SX="$ROOT_DIR/zig-out/bin/sx"
TMP="$ROOT_DIR/.sx-tmp"
SRC="$TMP/dbg_smoke.sx"
BIN="$TMP/dbg_smoke"

if ! command -v lldb >/dev/null 2>&1; then
    echo "SKIP: lldb not found (macOS/Xcode tools required)"
    exit 0
fi

mkdir -p "$TMP"
cat > "$SRC" <<'EOF'
add :: (a: i32, b: i32) -> i32 {
    c := a + b;
    return c;
}
main :: () -> i32 {
    return add(40, 2);
}
EOF

"$SX" build --emit-obj "$SRC" -o "$BIN" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

# Breakpoint on the `return c;` line; expect lldb to resolve it + a backtrace
# mapping both frames to dbg_smoke.sx.
out=$(cd "$ROOT_DIR" && lldb --batch \
    -o "breakpoint set --file dbg_smoke.sx --line 3" \
    -o "run" -o "bt" -o "quit" "$BIN" 2>&1)

fail=0
echo "$out" | grep -q "dbg_smoke.sx:3" || { echo "FAIL[macos]: breakpoint did not resolve to dbg_smoke.sx:3"; fail=1; }
echo "$out" | grep -q "add at dbg_smoke.sx:3" || { echo "FAIL[macos]: stopped frame not source-mapped"; fail=1; }
echo "$out" | grep -q "main at dbg_smoke.sx:6" || { echo "FAIL[macos]: caller frame not source-mapped"; fail=1; }
[[ $fail -eq 0 ]] && echo "ok[macos]: lldb stepped sx source (debug map -> kept .o)"

# Rung 2 (iOS simulator) — runs ONLY against an ALREADY-booted simulator; it
# never boots one itself (use a single sim — boot one yourself if you want this
# rung). Builds for ios-sim, collects a .dSYM (the device-applicable artifact),
# and steps in the sim. Skipped if no booted sim / no ios-sim SDK.
sim_booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c Booted || true)
if [[ "${sim_booted:-0}" -gt 0 ]] && xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
    "$SX" build --target ios-sim --emit-obj "$SRC" -o "$BIN" >/dev/null 2>&1 || { echo "FAIL[ios-sim]: build"; fail=1; }
    dsymutil "$BIN" -o "$BIN.dSYM" >/dev/null 2>&1   # the .app ships a .dSYM, not the .o
    rm -f "$TMP/main.o"                               # force resolution via the .dSYM
    sout=$(cd "$ROOT_DIR" && timeout 120 lldb --batch \
        -o "breakpoint set --file dbg_smoke.sx --line 3" \
        -o "run" -o "bt" -o "quit" "$BIN" 2>&1)
    if echo "$sout" | grep -q "add at dbg_smoke.sx:3" && echo "$sout" | grep -q "main at dbg_smoke.sx:6"; then
        echo "ok[ios-sim]: lldb stepped sx source in the simulator (via .dSYM)"
    else
        echo "FAIL[ios-sim]: lldb did not resolve in the simulator"; fail=1
        echo "--- ios-sim lldb output ---"; echo "$sout"
    fi
    rm -rf "$BIN" "$BIN.dSYM"
else
    echo "skip[ios-sim]: no booted simulator (boot one to exercise this rung)"
fi

# Rung 3 (iOS device) is a documented manual checklist — see docs/debugger.md.

rm -f "$SRC" "$BIN" "$TMP/main.o"
[[ $fail -eq 0 ]] && exit 0
exit 1
