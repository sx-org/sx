#!/bin/sh
# Record the replay matrix with a runner and compare it against the recording
# under tools/pkg_migrate/replay/.
#
#   replay-check.sh '<runner>'
#
# Cases named by a file in replay/drift/ are compared against THAT file — they
# are the directive-table drift, where the tool's output is meant to change.
# Every other case must be byte-identical to replay/expected/.
#
# Exit 0 on a match, 1 on any difference (the diff goes to stdout).

set -eu

if [ $# -ne 1 ]; then
    echo "usage: replay-check.sh '<runner>'" >&2
    exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
RUNNER=$1
ACTUAL=$(mktemp -d)
trap 'rm -rf "$ACTUAL"' EXIT

"$HERE/replay.sh" "$ACTUAL" "$RUNNER" >/dev/null

set --
for f in "$HERE"/replay/drift/*; do
    set -- "$@" -x "${f##*/}"
done

status=0
diff -ru "$@" "$HERE/replay/expected" "$ACTUAL" || status=1
for f in "$HERE"/replay/drift/*; do
    diff -u "$f" "$ACTUAL/${f##*/}" || status=1
done
exit $status
