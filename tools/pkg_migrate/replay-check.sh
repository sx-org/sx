#!/bin/sh
# Record the replay matrix with a runner and byte-compare it against
# tools/pkg_migrate/replay/expected/.
#
#   replay-check.sh '<runner>'
#
# Exit 0 on byte parity, 1 on any difference (the diff goes to stdout).

set -eu

if [ $# -ne 1 ]; then
    echo "usage: replay-check.sh '<runner>'" >&2
    exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
ACTUAL=$(mktemp -d)
trap 'rm -rf "$ACTUAL"' EXIT

"$HERE/replay.sh" "$ACTUAL" "$1" >/dev/null
diff -ru "$HERE/replay/expected" "$ACTUAL"
