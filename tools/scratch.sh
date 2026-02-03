#!/bin/bash
# tools/scratch.sh
#
# Quick interp/codegen parity test for a snippet.
# Reads sx source from stdin, runs it under both `sx run` (interp)
# and `sx build` + spawn (codegen), diffs the stdout output.
#
# Usage:
#   echo 'main :: () { print("hello\n"); }' | tools/scratch.sh
#   cat my_test.sx | tools/scratch.sh

set -u

SX="/Users/agra/projects/sx/zig-out/bin/sx"
SRC=/tmp/scratch.sx
BIN=/tmp/scratch-bin
RUN_LOG=/tmp/scratch-run.log
BUILD_LOG=/tmp/scratch-build.log

cat > "$SRC"

# Interp path
"$SX" run "$SRC" > "$RUN_LOG" 2>&1
RUN_EXIT=$?

# Codegen path
if "$SX" build "$SRC" -o "$BIN" >> "$BUILD_LOG" 2>&1; then
    "$BIN" > "$BUILD_LOG" 2>&1
    BUILD_EXIT=$?
else
    BUILD_EXIT=255
fi

echo "── interp (sx run) exit=$RUN_EXIT ───────────────────────"
cat "$RUN_LOG"
echo ""
echo "── codegen (sx build + spawn) exit=$BUILD_EXIT ─────────"
cat "$BUILD_LOG"
echo ""

if [[ "$RUN_EXIT" -ne "$BUILD_EXIT" ]]; then
    echo "DIVERGENCE: exit codes differ (run=$RUN_EXIT build=$BUILD_EXIT)"
    exit 1
fi

if diff -q "$RUN_LOG" "$BUILD_LOG" > /dev/null; then
    echo "PARITY: interp and codegen agree (exit $RUN_EXIT)"
    exit 0
else
    echo "DIVERGENCE: stdout differs"
    diff "$RUN_LOG" "$BUILD_LOG" || true
    exit 1
fi
