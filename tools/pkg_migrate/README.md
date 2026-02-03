# pkg_migrate — syntax-aware migration tool (PACKAGES P0.4)

Standalone Zig program for the sx PACKAGES migration
(`current/PLAN-PACKAGES.md`, unit P0.4). Deliberately **not** wired into
`build.zig` — it runs directly:

```sh
zig run tools/pkg_migrate/main.zig -- <subcommand> [options] <paths...>
```

It embeds a dedicated minimal scanner (`scanner.zig`) that mirrors the
compiler lexer's lexical surface (`src/lexer.zig`): `//` line comments,
`"..."` strings and `'...'` chars with `\` escapes, backtick raw identifiers,
the lexer's exact `#word` directive whitelist, `#string DELIM ... DELIM`
heredocs, and the lexer's numeric grammar. A word inside a comment, string,
char literal, or heredoc can never surface as an identifier — that is what
makes every subcommand syntax-aware rather than grep. Conversely, anything
the compiler would see as an identifier the scanner surfaces as one: an
unknown directive like `#private` lexes (as in the real lexer) as `#` plus
the ordinary identifier `private`, and `1package` as the number `1` plus the
identifier `package`. Per the
plan's hard rule, no subcommand performs blind global substitution: every
rewrite is an exact token span and every occurrence is reported.

## Subcommands

All mutating subcommands are **dry-run by default** (`--check` is an explicit
alias) and print a unified-diff-style preview; `--apply` writes the files.

### insert-package

```sh
zig run tools/pkg_migrate/main.zig -- insert-package --name demo [--apply] <files/dirs...>
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
zig run tools/pkg_migrate/main.zig -- rewrite-imports --map map.txt [--apply] <files/dirs...>
```

Rewrites `#import "old"` path strings per a mapping file with `old=new`
lines (`#` comments and blank lines allowed; a key mapped to two different
values is an error). Only the string operand of a real `#import` directive
token is touched — never comments, never other strings, never named-import
binders. Both `#import "p";` and `name :: #import "p";` forms match.

### qualify

```sh
zig run tools/pkg_migrate/main.zig -- qualify --map map.txt [--apply] <files/dirs...>
```

Converts flat uses of mapped names to qualified uses per `name=alias` lines
(`helper=util` rewrites `helper(3)` to `util.helper(3)`). Deliberately
conservative — it reports instead of guessing:

- **Ambiguous mapping** (same name mapped to two aliases): refuses to rewrite
  anything, lists the ambiguous names, exit 2.
- **Shadow guard**: if a file contains a mapped name in any declaration
  position (`name ::`, `name :=`, `name :`), no occurrence of that name is
  rewritten in that file; each is reported as a SKIP. A token scanner cannot
  scope-resolve, so a possible local shadow disables the whole file for that
  name.
- **Ambiguous positions** (`name =` — struct-literal field init or
  assignment) are skipped and reported.
- **Backticked identifiers** are skipped and reported.
- Already-qualified/member positions (`x.name`, `.name`) are left alone.

Only clear `call` and plain `use` positions are rewritten.

### to-package-dir (report-only in P0.4)

```sh
zig run tools/pkg_migrate/main.zig -- to-package-dir --name demo <files...>
```

Reports how a same-directory set of `.sx` files becomes a package directory:
verifies all files share one directory, which files would get the package
declaration inserted (and where), which already declare it, and which
conflict. `--apply` is intentionally rejected; apply the plan via
`insert-package --apply`.

### inventory (the D9 collision inventory)

```sh
zig run tools/pkg_migrate/main.zig -- inventory library examples issues tests
```

Scans for uses of `package`, `import`, `private`, and `intrinsic` as
**ordinary identifiers** — declarations, parameters, fields, locals, call
targets, member accesses — excluding comments/strings/heredocs, and reports
exact `file:line:col` spans, the source line, a positional category, plus
per-word and per-category summaries. Backtick-escaped occurrences are
flagged `(backticked)`. This report feeds the D9 decision
(`current/PLAN-PACKAGES.md` §D9); the reviewed 2026-07-11 run over
`library/ examples/ issues/ tests/` is committed as
`tools/pkg_migrate/d9-inventory-2026-07-11.txt`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | nothing to change (dry-run clean), apply succeeded, or inventory/report completed |
| 1 | dry-run found pending changes (also: to-package-dir plan has work to do) |
| 2 | error: usage, IO, ambiguous mapping, package-name conflict, cross-directory file set |

## Categories (qualify / inventory)

Positional, from token neighbors: `decl-const` (`name ::`), `decl-local`
(`name :=`), `typed-decl(param/field/local)` (`name :`), `call` (`name(`),
`member-access` (`.name` — also matches enum-literal position),
`assign-or-field-init` (`name =`), `use` (anything else).

## Caveats

- The scanner is lexical, not a parser. Categories are heuristics from
  neighboring tokens; scope resolution does not exist (hence qualify's
  per-file shadow guard). Always review the dry-run diff before `--apply`.
- Directory arguments are walked recursively for `.sx` files; `.git`,
  `zig-out`, `.zig-cache`, and `.sx-tmp` subtrees are skipped. Reports are
  sorted by path for determinism.
- Malformed fixtures (unterminated strings/heredocs, e.g. under `issues/`)
  scan like the real lexer scans them — the rest of the file is consumed as
  the literal — and produce a `scan-warning` line instead of failing.
- `#word` directives are recognized against the real lexer's whitelist
  (copied verbatim into `scanner.zig` from `src/lexer.zig` — keep in sync
  when the compiler adds a directive). A non-whitelisted `#word` mirrors the
  lexer: the `#` is emitted alone (as a punct token; the real lexer tags it
  invalid) and `word` counts as an ordinary identifier — so `#private` /
  `#package` in source are visible to the inventory, exactly as the compiler
  would see them.
- Numbers terminate by the real lexer's numeric grammar (`0x`/`0b`/`0o`
  prefixes, decimal with an optional `.digits` fraction, `_` separators) —
  NOT by identifier-continue. The real lexer has no exponent syntax, so
  `1e9` lexes as the number `1` plus the identifier `e9`, and `1package`
  exposes the identifier `package`; the scanner deliberately matches both.
- `inventory` reports *every* identifier occurrence of the four words,
  including deliberate future-syntax fixtures (e.g.
  `issues/0288-directory-import-cascade-wording/bad.sx` uses `package
  alpha;` on purpose). Deciding what to migrate vs preserve is D9's call,
  not the tool's.

## Verification (all run 2026-07-11, all green)

Scanner unit tests (19 tests — comment/string/char/heredoc opacity, escapes,
backticks, numeric-grammar termination (`1package`/`1e9`/`0xg` expose their
identifier tails; plain numbers unchanged), directive whitelist (`#import` /
`#run` stay directives; `#private`/`#package`/`#importing` expose ordinary
identifiers; heredoc unaffected), multi-byte punct, unterminated-literal
warnings, line/col math):

```sh
zig test tools/pkg_migrate/scanner.test.zig
```

Fixture runs against `tools/pkg_migrate/testdata/` (expected exit codes in
parentheses; use a scratch copy of `testdata/` for `--apply` runs so the
committed fixtures stay pristine):

```sh
# insert-package: dry-run previews 3 insertions, skips already-declared (1)
zig run tools/pkg_migrate/main.zig -- insert-package --name demo tools/pkg_migrate/testdata/insert
# conflict with an existing different package name (2)
zig run tools/pkg_migrate/main.zig -- insert-package --name other tools/pkg_migrate/testdata/insert/has_package.sx

# rewrite-imports: rewrites 2 real imports; comment/string mentions untouched (1)
zig run tools/pkg_migrate/main.zig -- rewrite-imports --map tools/pkg_migrate/testdata/imports/map.txt tools/pkg_migrate/testdata/imports

# qualify: rewrites call+use, skips field-init, whole-file shadow skip (1)
zig run tools/pkg_migrate/main.zig -- qualify --map tools/pkg_migrate/testdata/qualify/map.txt tools/pkg_migrate/testdata/qualify
# ambiguous mapping refused (2)
zig run tools/pkg_migrate/main.zig -- qualify --map tools/pkg_migrate/testdata/qualify/ambiguous_map.txt tools/pkg_migrate/testdata/qualify

# to-package-dir: plan for one missing + one present decl (1); cross-dir (2)
zig run tools/pkg_migrate/main.zig -- to-package-dir --name demo tools/pkg_migrate/testdata/pkgdir/a.sx tools/pkg_migrate/testdata/pkgdir/b.sx

# inventory fixture: 8 hits (package 2, import 2, private 3, intrinsic 1);
# string/comment/heredoc occurrences excluded; backtick flagged (0)
zig run tools/pkg_migrate/main.zig -- inventory tools/pkg_migrate/testdata/inventory

# the real D9 inventory (0)
zig run tools/pkg_migrate/main.zig -- inventory library examples issues tests
```

`--apply` was additionally verified on a scratch copy for insert-package,
rewrite-imports, and qualify: files rewritten byte-exactly as previewed, and
each command is idempotent on a second run (exit 0, no further changes).
