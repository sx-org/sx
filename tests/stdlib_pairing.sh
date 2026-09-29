#!/usr/bin/env bash
# The corpus tests compile against this checkout's library whatever SX_STDLIB_PATH the invoking shell names.

set -euo pipefail

cd "$(dirname "$0")/.."

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/sx-stdlib-pairing.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
mkdir -p "$probe_dir/modules"
printf 'ShadowLibraryOnly :: 1;\n' > "$probe_dir/modules/std.sx"

SX_STDLIB_PATH="$probe_dir" zig build test \
    -Dname=examples/generics/0205-generics-generic-method-dot-call.sx
