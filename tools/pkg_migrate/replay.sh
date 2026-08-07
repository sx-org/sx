#!/bin/sh
# Replay the pkg_migrate command matrix against a fixed input tree and record,
# per case, the exit code, stdout, stderr and — for --apply runs — every byte
# of the resulting tree.
#
#   replay.sh <record-dir> '<runner>'
#
# <runner> is one shell word-expanded command prefix, e.g.
#   replay.sh rec 'zig run /abs/repo/tools/pkg_migrate/main.zig --'
#   replay.sh rec '/abs/repo/zig-out/bin/pkg-migrate'
#
# Every case runs with the scratch tree as cwd, so the recorded paths are the
# relative ones the tool was handed and two recordings compare byte-for-byte.

set -eu

if [ $# -ne 2 ]; then
    echo "usage: replay.sh <record-dir> '<runner>'" >&2
    exit 2
fi

REPO=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$1"
REC=$(cd "$1" && pwd)
RUNNER=$2

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# The fixed input tree: the tool's own fixtures, the stdlib modules (heredoc
# opacity, real-world volume) and the issues/ fixtures.
seed_tree() {
    dest=$1
    mkdir -p "$dest"
    cp -R "$REPO/tools/pkg_migrate/testdata" "$dest/testdata"
    if [ "${2-}" = "full" ]; then
        mkdir -p "$dest/library" "$dest/issues"
        cp -R "$REPO/library/modules" "$dest/library/modules"
        cp "$REPO"/issues/*.sx "$dest/issues/"
    fi
}

# `$RUNNER <args>` in $WORK, capturing exit/stdout/stderr under $REC/<case>.
run_case() {
    name=$1
    shift
    st=0
    (cd "$WORK" && sh -c "$RUNNER \"\$@\"" sh "$@") \
        >"$REC/$name.out" 2>"$REC/$name.err" || st=$?
    echo "$st" >"$REC/$name.exit"
}

# Every file under $WORK/testdata, path-sorted, headed by its path.
record_tree() {
    name=$1
    (
        cd "$WORK"
        find testdata -type f | LC_ALL=C sort | while read -r f; do
            echo "===== $f"
            cat "$f"
        done
    ) >"$REC/$name.tree"
}

# --- dry-run matrix (no writes; one shared tree) ----------------------------

WORK="$SCRATCH/check"
seed_tree "$WORK" full

run_case 01-insert-dry insert-package --name demo testdata/insert
run_case 02-insert-conflict insert-package --name other testdata/insert/has_package.sx
run_case 03-rewrite-dry rewrite-imports --map testdata/imports/map.txt testdata/imports
run_case 04-qualify-dry qualify --map testdata/qualify/map.txt testdata/qualify
run_case 05-qualify-ambiguous qualify --map testdata/qualify/ambiguous_map.txt testdata/qualify
run_case 06-to-package-dir to-package-dir --name demo testdata/pkgdir/a.sx testdata/pkgdir/b.sx
run_case 07-to-package-dir-crossdir to-package-dir --name demo testdata/pkgdir/a.sx testdata/insert/plain.sx
run_case 08-inventory-fixture inventory testdata/inventory
run_case 09-inventory-corpus inventory library issues
run_case 10-inventory-warnings inventory testdata/lexical/warnings
run_case 11-insert-warnings insert-package --name demo testdata/lexical/warnings
run_case 12-inventory-drift inventory testdata/lexical/drift
run_case 13-qualify-drift qualify --map testdata/lexical/drift/map.txt testdata/lexical/drift
run_case 14-usage --help
run_case 15-unknown-subcommand frobnicate testdata/insert

# --- apply matrix (each on its own tree, applied twice for idempotence) -----

WORK="$SCRATCH/apply-insert"
seed_tree "$WORK"
run_case 20-insert-apply insert-package --name demo --apply testdata/insert
run_case 21-insert-apply-again insert-package --name demo --apply testdata/insert
record_tree 22-insert-apply

WORK="$SCRATCH/apply-rewrite"
seed_tree "$WORK"
run_case 30-rewrite-apply rewrite-imports --map testdata/imports/map.txt --apply testdata/imports
run_case 31-rewrite-apply-again rewrite-imports --map testdata/imports/map.txt --apply testdata/imports
record_tree 32-rewrite-apply

WORK="$SCRATCH/apply-qualify"
seed_tree "$WORK"
run_case 40-qualify-apply qualify --map testdata/qualify/map.txt --apply testdata/qualify
run_case 41-qualify-apply-again qualify --map testdata/qualify/map.txt --apply testdata/qualify
record_tree 42-qualify-apply

WORK="$SCRATCH/apply-drift"
seed_tree "$WORK"
run_case 50-qualify-drift-apply qualify --map testdata/lexical/drift/map.txt --apply testdata/lexical/drift
run_case 51-qualify-drift-apply-again qualify --map testdata/lexical/drift/map.txt --apply testdata/lexical/drift
record_tree 52-qualify-drift-apply

echo "recorded $(find "$REC" -type f | wc -l | tr -d ' ') files in $REC"
