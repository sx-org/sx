#!/bin/bash
# Every check in one place — "is the baseline healthy?".
#
# Exists because the checks NOT wired into a routine command are exactly the ones
# that rot. All three of these were broken and nobody noticed:
#   - debug_stepping_smoke.sh sat behind a stale type name and never reached lldb;
#   - run_resolver_target.sh lost its sources in the corpus reorg and asserted
#     nothing (17 missing-source) while 9 cases had silently started passing;
#   - non-Debug builds could not link at all, because only Debug is ever built.
# A script nobody runs is not a test.
#
# Usage:
#   ./tests/run_all.sh            # everything that runs unattended
#   ./tests/run_all.sh --quick    # skip the multi-optimize-mode rebuilds
#
# NOT included (need an environment this can't assume): cross_compile.sh (cross
# toolchains) and stress-http.sh (long-running load). Run those by hand.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR" || exit 1

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

PASS=0
FAIL=0
FAILED_NAMES=""

run_check() {
    local name="$1"; shift
    printf '\n=== %s ===\n' "$name"
    if "$@"; then
        PASS=$((PASS + 1)); printf '  -> ok\n'
    else
        FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $name"; printf '  -> FAILED\n'
    fi
}

printf '=== build (Debug) ===\n'
if ! zig build; then
    echo "FATAL: zig build failed"
    exit 1
fi
echo "  -> ok"

# `zig build test` is the sole regression runner: unit tests + the example/issue
# corpus + the LSP sweep all live in it. no_build_noise.sh runs it and also
# asserts it stays silent on success.
run_check "tests + corpus (quiet on success)" ./tests/no_build_noise.sh
run_check "resolver-target xfail set"         ./tests/resolver-target/run_resolver_target.sh
run_check "wasm32 function values"            ./tests/wasm_function_values.sh

if [[ $QUICK -eq 0 ]]; then
    # Rebuilds in every optimize mode. Debug-only testing is how both the
    # UBSan link break and the dead-stripped dlsym symbols stayed invisible.
    run_check "JIT dlsym symbols retained" ./tests/jit_symbols_retained.sh
    # Skips itself cleanly when lldb is absent.
    run_check "debug stepping (lldb)"      ./tests/debug_stepping_smoke.sh
    zig build >/dev/null 2>&1   # leave the tree on the Debug binary
fi

printf '\n========================================\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -ne 0 ]] && printf 'failed:%s\n' "$FAILED_NAMES"
printf '========================================\n'

exit $(( FAIL != 0 ))
