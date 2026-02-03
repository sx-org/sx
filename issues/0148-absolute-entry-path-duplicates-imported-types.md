# 0148 — absolute entry path duplicates transitively-imported types

> **RESOLVED (2026-07-03).** Root cause: import resolution keyed the module
> cache + flat-import graph on the literal resolved-path string — an absolute
> entry made direct imports key absolutely while a sibling's transitive import
> of the same file fell back to a cwd-relative spelling → two cache keys → two
> type identities. Fix: LEXICAL canonicalization (`canonicalizePath` in
> `src/imports.zig` — strip `./`, collapse `seg/..`, re-relativize an absolute
> path against the CWD — physical `getcwd` + logical `$PWD` — when the file
> lives under it) applied at the single `resolveImportPath` chokepoint plus the
> directory-import per-file join, and to the CLI entry path in `main.zig` (so
> the entry file's own diagnostics also display cwd-relative under an absolute
> invocation). A respelling is accepted only when a symlink-following
> stat-identity check (st_dev + st_ino) proves it names the same file —
> otherwise the probed spelling is kept (guards `link/../other.sx`-style
> symlinked `..` collapses and stale `$PWD`). No realpath churn; diagnostics
> stay cwd-relative. Regression tests:
> `examples/modules/1619-modules-multichain-import-identity.sx` (pins the
> diamond + directory-import shape; the corpus runs relative entries only) and
> the `canonicalizePath` unit test in `src/imports.test.zig` (abs +
> cwd-relative + `./` + `..` spellings unify — carries the abs-entry case).

## Summary
When `sx build` is given an **absolute** path to the entry `.sx` file, a type
declared in a module that is reached by two different `#import` chains can be
duplicated into two distinct type identities. A later use of that type then
fails with `type 'T' is not visible; #import the module that declares it`, even
though the importing file does `#import` the declaring module. Building the same
entry by a **cwd-relative** path (from the same directory) resolves every import
to a single module instance and compiles cleanly.

## Repro (photo project)
From the project root `/Users/agra/projects/photo`:

```
# RELATIVE entry — OK
sx build main.sx -o /tmp/m            # RC=0, bundles + compiles

# ABSOLUTE entry — FAILS
sx build /Users/agra/projects/photo/main.sx -o /tmp/m
#   error: type 'Layer' is not visible; #import the module that declares it
#     --> ui/toolbar.sx:133:8   (a plain `hover_tool: i64;` field line)
```

`main.sx` imports `doc/document.sx` (which re-exports `Layer` from
`doc/layer.sx`) directly, AND via `ui/toolbar.sx` / `ui/canvas_view.sx`, AND it
also does the directory-module import `#import "modules/ui"`. Under the absolute
entry path, `doc/layer.sx`'s `Layer` ends up with two identities, so
`layer_at()`'s return type seen inside `ui/toolbar.sx` no longer matches and the
struct that uses it fails to typecheck (the error points at an unrelated field
line in the struct, the first member checked).

A test that imports BOTH `ui/toolbar.sx` and `ui/canvas_view.sx`
(`tests/canvas_select.sx`) builds fine by absolute path — so the trigger is not
the two-chain overlap alone; it requires the additional directory-module import
(`modules/ui`) present in `main.sx`. The duplication is therefore in how the
entry's absolute path is normalized/keyed against the module-search-path
resolution of a directory import.

## Expected
Import resolution must canonicalize paths so the same source file is one module
instance regardless of whether the entry was named by an absolute or a
relative path. An absolute entry should compile identically to the relative one.

## Workaround (in repo)
`tools/sx_build.sh` (the lock wrapper) now rewrites an entry path that lives
under the project root into a root-relative path and runs the compiler from the
root, so both `main.sx` and `/abs/.../main.sx` build to the same green result.
Non-entry arguments (e.g. `-o /tmp/out`) are left untouched.

## Investigation findings (attempted fix, reverted — STILL OPEN)

Confirmed the root cause and a working mechanism, but the straightforward
implementation has too broad a blast radius to land safely in one pass:

- **Root cause confirmed.** Import resolution keys the module cache *and* the
  flat-import graph on the literal resolved-path string with no canonicalization.
  An absolute entry makes `main`'s direct imports key absolutely while a sibling's
  transitive import of the same file falls back to a cwd-relative spelling
  (`root_path` is passed `null` in the import walk) → two cache keys → two type
  identities → "not visible".
- **Minimal repro (no photo project):** a deeper type is required — `doc/layer.sx`
  defines a type, `doc/document.sx` imports it and references it, and `main`
  reaches `document.sx` BOTH directly and transitively (via `ui/toolbar.sx`).
  Per the report the *directory-module* import in `main` is also needed to trip
  the duplication. (Plain `Layer` defined directly in `document.sx`, used as
  `doc.Layer`, does NOT reproduce.)
- **Mechanism that works:** a `canonicalizePath` (libc `realpath`) applied to
  every resolved import path unifies the spellings. To avoid leaking absolute,
  machine-specific paths into diagnostics (which would break ~160 `.stderr`
  snapshots), re-relativize the realpath result against CWD when the file lives
  under it — yielding ONE canonical spelling that is also the cwd-relative
  display form. This was verified to fix the end-to-end repro (absolute and
  relative entries both compile) while keeping diagnostics relative.
- **Why it was reverted:** canonicalizing the resolved path changes the path
  *identity* used as a KEY across the whole import subsystem — module cache,
  `flat_import_graph`, `module_decls`, the decl table, and namespace-author
  resolution. That rippled into **~8 unit tests** (e.g. `buildImportFacts`
  namespaced-target, `buildDeclTable` keying, `module_decls` retention,
  `collectNamespaceAuthors`, shadowed-author lowering) that hard-code
  absolute `absdir`-based path expectations, plus 2 cosmetic corpus snapshots
  (`examples/./XXXX` → `examples/XXXX`). Each is individually a legitimate
  canonical-form update, but the breadth — and the risk of subtly changing
  import-graph identity matching — is more than a drive-by rework should absorb.

### Recommended approach for the fix session
1. Decide the canonical scheme deliberately: **lexical normalize** (strip `./`,
   collapse `a/../b`) may suffice to unify the abs-vs-rel entry split without the
   symlink/relativization churn realpath introduces — and changes fewer keys.
   If realpath is needed, keep the cwd-relativization for display.
2. Apply canonicalization at a single chokepoint in `resolveImportPath` (+ the
   directory-import per-file path) so every consumer sees one spelling.
3. Update ALL path-keyed unit tests in `src/imports.test.zig` (and the
   `ir.lower`/`ir.resolver` tests) to compare against `canonicalizePath(expected)`
   rather than the raw `absdir`-joined path; regenerate the 2 cosmetic snapshots
   (`0410-protocols-impl-visibility`, `0411-protocols-impl-duplicate`).
4. Add a `canonicalizePath` unit test asserting abs + cwd-relative + redundant
   `./` spellings of one file unify (the e2e absolute-entry case can't be a
   corpus example — the runner only invokes relative paths).
