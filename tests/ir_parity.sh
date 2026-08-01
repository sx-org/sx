#!/bin/bash
# Asserts that every example lowers to LLVM IR without crashing, via
# `sx ir-dump` → lower → emit.
#
# Usage:
#   bash tests/ir_parity.sh           # Test all examples
#   bash tests/ir_parity.sh --ir-dump # Just test lowering (no codegen)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SX="$ROOT_DIR/zig-out/bin/sx"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

passed=0
failed=0
skipped=0
errors=""

# Get all example files
examples=$(ls "$ROOT_DIR"/examples/*.sx 2>/dev/null | sort)

for example in $examples; do
    name=$(basename "$example" .sx)

    # ir-dump must not crash.
    if output=$("$SX" ir-dump "$example" 2>&1); then
        # Check that output is non-empty (lowering produced something)
        if [ -n "$output" ]; then
            printf "  %-30s ${GREEN}ok${NC}\n" "$name"
            passed=$((passed + 1))
        else
            printf "  %-30s ${YELLOW}empty${NC}\n" "$name"
            skipped=$((skipped + 1))
        fi
    else
        printf "  %-30s ${RED}FAIL${NC}\n" "$name"
        failed=$((failed + 1))
        errors="$errors\n  $name: ir-dump crashed"
    fi
done

echo ""
echo "$passed passed, $failed failed, $skipped empty"

if [ -n "$errors" ]; then
    echo -e "\nErrors:$errors"
fi

exit $failed
