#!/bin/bash
# `sx ir-dump --target` lowers target-selected code for that target.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SX="$ROOT_DIR/zig-out/bin/sx"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/target.sx" <<'SX'
@import "modules/build.sx";
main :: () { inline if @host.os == .linux { x: i64 = "bad"; } }
SX

if "$SX" ir-dump --target x86_64-linux "$TMP/target.sx" >/dev/null 2>&1; then
    echo "ir-dump --target x86_64-linux did not lower the linux branch"
    exit 1
fi
"$SX" ir-dump --target macos "$TMP/target.sx" >/dev/null 2>&1 || {
    echo "ir-dump --target macos lowered the pruned linux branch"
    exit 1
}
