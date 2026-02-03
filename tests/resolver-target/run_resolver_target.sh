#!/bin/bash
# Resolver-target xfail harness (Fork C S0.2).
#
# NOT part of the baseline gate. The baseline gate is `zig build && zig build test
# && bash tests/run_examples.sh` over the BASELINE-GREEN corpus only; this harness
# is a separate, listed diagnostic so the resolver-target corpus is never silently
# dropped between S0 and S3.9.
#
# Contract (S0 -> S3.8): every case below currently FAILS to match its TARGET
# golden on wt-stdlib-base (the old selector is known-wrong for it). This script
# runs each case and asserts the MISMATCH. It exits 0 when ALL cases still xfail
# (as expected today), and exits 1 if any case unexpectedly MATCHES its target —
# which means that case is actually baseline-green and must be re-classified
# (moved to examples/expected/ with an active marker), not silently left here.
#
# At S3.9 the Fork C resolver makes these pass; the flip is then performed by
# moving each golden to examples/expected/ and this harness goes empty.
#
# Usage: bash tests/resolver-target/run_resolver_target.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SX="$ROOT_DIR/zig-out/bin/sx"
EXP_DIR="$SCRIPT_DIR/expected"
TIMEOUT=10

normalize() {
    sed -E \
        -e 's/0x[0-9a-f]{4,}/0xADDR/g' \
        -e 's#(/[^[:space:]]*)?/(examples|issues)/#\2/#g'
}

if [[ ! -x "$SX" ]]; then
    echo "error: $SX not built — run 'zig build' first" >&2
    exit 2
fi

TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_ERR"' EXIT

XFAIL=0      # currently-failing as expected
LEAKED=0     # unexpectedly matches target -> must be reclassified baseline-green
MISSING=0

for exit_file in "$EXP_DIR"/*.exit; do
    [[ -e "$exit_file" ]] || continue
    name=$(basename "$exit_file" .exit)

    # Source tree: harvested 08xx live under examples/ — flat before the corpus
    # was reorganized into category subdirs (examples/<cat>/<name>.sx), so look
    # in both. e6br5 lives under cases/.
    sx_file=""
    if [[ -f "$ROOT_DIR/examples/${name}.sx" ]]; then
        sx_file="$ROOT_DIR/examples/${name}.sx"
    elif [[ -f "$SCRIPT_DIR/cases/${name}.sx" ]]; then
        sx_file="$SCRIPT_DIR/cases/${name}.sx"
    else
        for cand in "$ROOT_DIR"/examples/*/"${name}.sx"; do
            [[ -f "$cand" ]] || continue
            sx_file="$cand"
            break
        done
    fi
    if [[ -z "$sx_file" ]]; then
        printf '  %-55s MISSING-SOURCE\n' "$name"
        MISSING=$((MISSING + 1))
        continue
    fi

    actual_out=$(timeout "$TIMEOUT" "$SX" run "$sx_file" 2>"$TMP_ERR" | normalize)
    actual_exit=${PIPESTATUS[0]}
    actual_err=$(normalize < "$TMP_ERR")

    target_exit=$(cat "$exit_file")
    if [[ -f "$EXP_DIR/${name}.stdout" ]]; then
        target_out=$(normalize < "$EXP_DIR/${name}.stdout")
        target_err=$(normalize < "$EXP_DIR/${name}.stderr")
        if [[ "$actual_exit" == "$target_exit" && "$actual_out" == "$target_out" && "$actual_err" == "$target_err" ]]; then
            matches=1
        else
            matches=0
        fi
    else
        # A spec-only target (e6br5) has no exact bytes to diff — its target is
        # prose in `<name>.target.md`. Exit alone is far too weak a match: this
        # case exits 1 for its diagnosed form AND for any unrelated compile
        # error, so a bit-rotted source scored LEAKED while never reaching the
        # behaviour under test. Require the spec's signature in stderr too;
        # `<name>.target.grep` holds that substring.
        matches=0
        if [[ "$actual_exit" == "$target_exit" ]]; then
            grep_file="$EXP_DIR/${name}.target.grep"
            if [[ -f "$grep_file" ]]; then
                pat=$(cat "$grep_file")
                if printf '%s' "$actual_err" | grep -qF "$pat"; then matches=1; fi
            else
                printf '  %-55s SPEC-NO-GREP (add %s.target.grep)\n' "$name" "$name"
                MISSING=$((MISSING + 1))
                continue
            fi
        fi
    fi

    if [[ $matches -eq 1 ]]; then
        printf '  %-55s LEAKED (matches target on base -> reclassify baseline-green)\n' "$name"
        LEAKED=$((LEAKED + 1))
    else
        printf '  %-55s xfail (base exit=%s, target exit=%s)\n' "$name" "$actual_exit" "$target_exit"
        XFAIL=$((XFAIL + 1))
    fi
done

echo "$XFAIL xfail (expected), $LEAKED leaked, $MISSING missing-source"
[[ $LEAKED -eq 0 && $MISSING -eq 0 ]]
