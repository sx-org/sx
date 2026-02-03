#!/bin/bash
# Guards the JIT's dlsym contract across optimize modes.
#
# `sx_trace_*` and `sx_jni_env_tl_*` are C runtime entry points that NOTHING in
# the Zig sources calls — the JIT resolves them dynamically via dlsym, and AOT
# output picks them up via an auto-injected c_import. A non-Debug build runs
# dead-strip, which removes any symbol with no static reference, so these vanish
# and every `#run` that needs a trace fails with "symbol not found via dlsym".
# Debug builds hide this: they don't dead-strip.
#
# Usage: ./tests/jit_symbols_retained.sh [optimize-mode ...]   (default: all)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR" || exit 1

REQUIRED=(
    sx_trace_push
    sx_trace_clear
    sx_trace_len
    sx_trace_frame_at
    sx_trace_truncated
    sx_trace_report_unhandled
    sx_jni_env_tl_get
    sx_jni_env_tl_set
)

MODES=("$@")
[ ${#MODES[@]} -eq 0 ] && MODES=(Debug ReleaseSafe ReleaseFast ReleaseSmall)

fail=0
for mode in "${MODES[@]}"; do
    echo "--- $mode ---"
    if ! zig build -Doptimize="$mode" >/dev/null 2>&1; then
        echo "FAIL: build failed for $mode"
        fail=1
        continue
    fi

    exported=$(nm -gU zig-out/bin/sx 2>/dev/null)
    missing=()
    for sym in "${REQUIRED[@]}"; do
        # macOS prefixes C symbols with an underscore.
        echo "$exported" | /usr/bin/grep -qE "\b_?${sym}$" || missing+=("$sym")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "FAIL: $mode dropped ${#missing[@]} JIT-resolved symbol(s): ${missing[*]}"
        fail=1
    else
        echo "ok: all ${#REQUIRED[@]} JIT-resolved symbols exported"
    fi
done

[ $fail -eq 0 ] && echo "PASS: JIT dlsym symbols retained in every optimize mode"
exit $fail
