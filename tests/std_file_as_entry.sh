#!/bin/bash
# A std module that core's imports reach lowers as the entry file.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

"$ROOT_DIR/zig-out/bin/sx" ir-dump library/modules/std/c.sx >/dev/null
