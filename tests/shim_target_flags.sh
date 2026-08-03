#!/bin/bash
# The clang_shim.cpp compile must carry the build's target.
#
# It is a standalone `zig c++` command rather than a module source, so no
# target reaches it implicitly: without an explicit `-target`/`-mcpu` it
# native-detects, and the object stops matching the module it links into. On a
# Rosetta-emulated linux/amd64 host that detection yields a CPU clang rejects
# outright.
#
# Usage: ./tests/shim_target_flags.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR" || exit 1

TARGET="x86_64-linux-gnu"
CPU="baseline"

# An empty LLVM prefix keeps the compile out of the build cache, so the command
# is issued — and printed — on every run. It then fails for want of the clang
# headers, which also stops the dependent link; the command line is what this
# asserts, not the build's outcome.
PREFIX="$(mktemp -d)"
trap 'rm -rf "$PREFIX"' EXIT

cmd=$(zig build -Dtarget="$TARGET" -Dcpu="$CPU" -Dllvm-prefix="$PREFIX" --verbose 2>&1 \
    | /usr/bin/grep -m1 'clang_shim\.cpp')

if [ -z "$cmd" ]; then
    echo "FAIL: the build issued no clang_shim.cpp compile"
    exit 1
fi

fail=0
for flag in "-target $TARGET" "-mcpu=$CPU"; do
    case "$cmd" in
        *"$flag"*) echo "ok: shim compile carries '$flag'" ;;
        *)
            echo "FAIL: shim compile is missing '$flag'"
            fail=1
            ;;
    esac
done

if [ $fail -ne 0 ]; then
    echo "  command: $cmd"
else
    echo "PASS: shim compile carries the configured target"
fi
exit $fail
