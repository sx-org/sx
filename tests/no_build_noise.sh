#!/bin/bash
# Guards a build-output invariant: `zig build test` prints nothing when it passes.
#
# The Zig 0.16 build runner prints a step tree and `failed command: <cmd>` for a
# test binary that writes to stderr, even when every test passes and the build
# exits 0. Automated verifiers grep build output for failure words, so an
# unconditional `std.debug.print` in any `*.test.zig` turns every green build into
# a false failure. Test-time prints stay behind an env gate.

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

if [ -n "$out" ]; then
    echo "FAIL: 'zig build test' passed but wrote output; verifiers read this as a failure:"
    echo "--- begin build output ---"
    echo "$out"
    echo "--- end build output ---"
    exit 1
fi

echo "PASS: 'zig build test' is silent on success"
exit 0
