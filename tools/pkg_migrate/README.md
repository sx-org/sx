# pkg_migrate — syntax-aware migration tool

Zig program for the sx packages migration, wired into `build.zig`:

```sh
zig build pkg-migrate -- <subcommand> [options] <paths...>
```

It tokenizes through the compiler's own lexer (the `sxlex` module over
`src/lexer.zig`), so its lexical surface *is* the compiler's: `//` line
comments, `"..."` strings and `'...'` chars with `\` escapes, backtick raw
identifiers, the directive table, `@string DELIM ... DELIM` heredocs, and the
numeric grammar. A word inside a comment, string, char literal, or heredoc can
never surface as an identifier — that is what makes every subcommand
syntax-aware rather than grep. Conversely, anything the compiler sees as an
identifier the tool sees as one: an unrecognized directive like `#private`
lexes as `#` plus the ordinary identifier `private`, and `1package` as the
number `1` plus the identifier `package`. No subcommand performs blind global
substitution: every rewrite is an exact token span and every occurrence is
reported.

`zig build pkg-migrate` reports any non-zero tool exit as a build failure, so
the exit codes below are distinguishable only from the installed binary:

```sh
zig build && zig-out/bin/pkg-migrate <subcommand> [options] <paths...>
```

## Subcommands

All mutating subcommands are **dry-run by default** (`--check` is an explicit
alias) and print a unified-diff-style preview; `--apply` writes the files.

### insert-package

```sh
zig build pkg-migrate -- insert-package --name demo [--apply] <files/dirs...>
```

Inserts `package <name>;` after each file's leading comment block. The
insertion point is after the **last blank line** in the leading run of
blank/comment lines, so a comment block that directly abuts the first
declaration is treated as that declaration's doc comment and stays attached
to it (the package line goes above it). Files already declaring
`package <name>;` are skipped (idempotent); a file declaring a *different*
package name is a hard error (exit 2).

### rewrite-imports

```sh
zig build pkg-migrate -- rewrite-imports --map map.txt [--apply] <files/dirs...>
```

Rewrites `@import "old"` path strings per a mapping file with `old=new`
lines (`#` comments and blank lines allowed; a key mapped to two different
values is an error). Only the string operand of a real `@import` directive
token is touched — never comments, never other strings, never named-import
binders. Both `@import "p";` and `name :: @import "p";` forms match.

### qualify

```sh
zig build pkg-migrate -- qualify --map map.txt [--apply] <files/dirs...>
```

Converts flat uses of mapped names to qualified uses per `name=alias` lines
(`helper=util` rewrites `helper(3)` to `util.helper(3)`). It is conservative:
it reports instead of guessing.

- **Ambiguous mapping** (same name mapped to two aliases): refuses to rewrite
  anything, lists the ambiguous names, exit 2.
- **Shadow guard**: if a file contains a mapped name in any declaration
  position (`name ::`, `name :=`, `name :`), no occurrence of that name is
  rewritten in that file; each is reported as a SKIP. A token stream cannot
  scope-resolve, so a possible local shadow disables the whole file for that
  name.
- **Ambiguous positions** (`name =` — struct-literal field init or
  assignment) are skipped and reported.
- **Backticked identifiers** are skipped and reported.
- Already-qualified/member positions (`x.name`, `.name`) are left alone.

Only clear `call` and plain `use` positions are rewritten.

### to-package-dir (report-only)

```sh
zig build pkg-migrate -- to-package-dir --name demo <files...>
```

Reports how a same-directory set of `.sx` files becomes a package directory:
verifies all files share one directory, which files would get the package
declaration inserted (and where), which already declare it, and which
conflict. `--apply` is intentionally rejected; apply the plan via
`insert-package --apply`.

### inventory (the collision inventory)

```sh
zig build pkg-migrate -- inventory library examples issues tests
```

Scans for uses of `package`, `import`, `private`, and `intrinsic` as
**ordinary identifiers** — declarations, parameters, fields, locals, call
targets, member accesses — excluding comments/strings/heredocs, and reports
exact `file:line:col` spans, the source line, a positional category, plus
per-word and per-category summaries. Backtick-escaped occurrences are
flagged `(backticked)`. `private` and `intrinsic` are reserved words the
lexer tags as keywords; the inventory counts every spelling of the four words
regardless, which is the collision it exists to surface. The run over
`library/ examples/ issues/ tests/` is committed as
`tools/pkg_migrate/d9-inventory-2026-07-15.txt`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | nothing to change (dry-run clean), apply succeeded, or inventory/report completed |
| 1 | dry-run found pending changes (also: to-package-dir plan has work to do) |
| 2 | error: usage, IO, ambiguous mapping, package-name conflict, cross-directory file set |

## Categories (qualify / inventory)

Positional, from token neighbors: `decl-const` (`name ::`), `decl-local`
(`name :=`), `typed-decl(param/field/local)` (`name :`), `call` (`name(`),
`member-access` (`.name` / `?.name` — also matches enum-literal position),
`assign-or-field-init` (`name =`), `use` (anything else).

## Caveats

- Tokens are lexical, not parsed. Categories are heuristics from neighboring
  tokens; scope resolution does not exist (hence qualify's per-file shadow
  guard). Always review the dry-run diff before `--apply`.
- Directory arguments are walked recursively for `.sx` files; `.git`,
  `zig-out`, `.zig-cache`, and `.sx-tmp` subtrees are skipped. Reports are
  sorted by path for determinism.
- Malformed fixtures (unterminated strings/heredocs, e.g. under `issues/`)
  scan as the compiler scans them — the rest of the file is consumed as the
  literal — and produce a `scan-warning` line instead of failing. Only the
  five malformed-literal spellings warn; an unrecognized `#word` produces a
  bare `#` and no warning.
- Numbers terminate by the numeric grammar (`0x`/`0b`/`0o` prefixes, decimal
  with an optional `.digits` fraction, `_` separators) — NOT by
  identifier-continue. There is no exponent syntax, so `1e9` lexes as the
  number `1` plus the identifier `e9`, and `1package` exposes the identifier
  `package`.
- `inventory` reports *every* identifier occurrence of the four words,
  including fixtures that use `package alpha;` as future syntax. What to
  migrate and what to preserve is the caller's decision, not the tool's.

## Checks

Unit tests over the word iteration, positional categories, the leading
package declaration, the malformed-literal warnings, the insertion point and
the line index run in the main gate:

```sh
zig build test
```

The command matrix — every form below, dry-run and `--apply`, a second apply
for idempotence, the conflict and ambiguous-map cases — is recorded under
`replay/` and replayed by:

```sh
zig build && tools/pkg_migrate/replay-check.sh "$PWD/zig-out/bin/pkg-migrate"
```

Fixture runs against `tools/pkg_migrate/testdata/` (expected exit codes in
parentheses; use a scratch copy of `testdata/` for `--apply` runs so the
committed fixtures stay pristine):

```sh
# insert-package: dry-run previews 3 insertions, skips already-declared (1)
zig build pkg-migrate -- insert-package --name demo tools/pkg_migrate/testdata/insert
# conflict with an existing different package name (2)
zig build pkg-migrate -- insert-package --name other tools/pkg_migrate/testdata/insert/has_package.sx

# rewrite-imports: rewrites 2 real imports; comment/string mentions untouched (1)
zig build pkg-migrate -- rewrite-imports --map tools/pkg_migrate/testdata/imports/map.txt tools/pkg_migrate/testdata/imports

# qualify: rewrites call+use, skips field-init, whole-file shadow skip (1)
zig build pkg-migrate -- qualify --map tools/pkg_migrate/testdata/qualify/map.txt tools/pkg_migrate/testdata/qualify
# ambiguous mapping refused (2)
zig build pkg-migrate -- qualify --map tools/pkg_migrate/testdata/qualify/ambiguous_map.txt tools/pkg_migrate/testdata/qualify

# to-package-dir: plan for one missing + one present decl (1); cross-dir (2)
zig build pkg-migrate -- to-package-dir --name demo tools/pkg_migrate/testdata/pkgdir/a.sx tools/pkg_migrate/testdata/pkgdir/b.sx

# inventory fixture: 8 hits (package 2, import 2, private 3, intrinsic 1);
# string/comment/heredoc occurrences excluded; backtick flagged (0)
zig build pkg-migrate -- inventory tools/pkg_migrate/testdata/inventory

# the committed inventory (0)
zig build pkg-migrate -- inventory library examples issues tests
```

`--apply` rewrites files byte-exactly as previewed for insert-package,
rewrite-imports and qualify, and each command is idempotent on a second run
(exit 0, no further changes).
