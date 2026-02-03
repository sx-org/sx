#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXAMPLE="$ROOT_DIR/examples/platform/1668-platform-wasm-function-values.sx"

"$ROOT_DIR/zig-out/bin/sx" ir "$EXAMPLE" --target wasm --opt 0 >/dev/null
"$ROOT_DIR/zig-out/bin/sx" ir "$EXAMPLE" --target wasm --opt 3 >/dev/null

echo "PASS: wasm32 bare function values compile at opt 0 and opt 3"
