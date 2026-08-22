#!/bin/bash
# Guards a build-output invariant: `zig build test` must be SILENT when it passes.
#
# The Zig 0.16 build runner prints a step tree and `failed command: <cmd>` for a
# test binary that writes to stderr, even when every test passes and the build
# exits 0. Automated verifiers grep build output for failure words, so an
# unconditional `std.debug.print` in any `*.test.zig` turns every green build into
# a false failure. Keep test-time prints behind an env gate.
#
# The corpus runner's environment-conditional skip notes are the exception: a host
# lacking the Android SDK/JDK or the marker's required OS cannot run it, and saying
# so is success output. Those notes and the runner frame they induce are stripped;
# whatever survives is noise. The allowed reasons are enumerated, so a marker that
# skips for any other cause — a missing `.sx`, say — still fails this check.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR" || exit 1

out="$(zig build test 2>&1)"
code=$?

if [ $code -ne 0 ]; then
    echo "FAIL: 'zig build test' exited $code"
    echo "$out"
    exit 1
fi

RUNNER_FRAME='^(test|[[:space:]+|-]*run test.*|failed command: .*)$'
SKIP_REASON='no Android SDK/JDK|bundle smoke test — macOS host only|[a-z0-9_]+-host only'
SKIP_NOTE="^\\[corpus-run\\] (skip .+ \\(($SKIP_REASON)\\)|.+: [0-9]+ marker\\(s\\) skipped)$"

skips=$(printf '%s\n' "$out" | grep -E "$SKIP_NOTE")
noise=$(printf '%s\n' "$out" \
    | grep -vE "$RUNNER_FRAME" \
    | grep -vE "$SKIP_NOTE" \
    | grep -v '^[[:space:]]*$')

if [ -n "$noise" ]; then
    echo "FAIL: 'zig build test' passed but wrote output; verifiers read this as a failure:"
    echo "--- begin build output ---"
    echo "$out"
    echo "--- end build output ---"
    exit 1
fi

echo "PASS: 'zig build test' is silent on success"
[ -n "$skips" ] && printf 'tolerated environment skip(s):\n%s\n' "$skips"
exit 0
