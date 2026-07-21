# 0326 — qualified namespaces expose declarations from their flat imports

> **RESOLVED (2026-07-21).** Qualified type/value/static/function-value/store
> paths now prove the terminal member against `NamespaceTarget.own_decls`
> before entering the target module's source context. Regressions:
> `examples/modules/0903-modules-qualified-flat-import-types-hidden.sx`,
> `0904-modules-qualified-flat-import-values-hidden.sx`, and
> `0905-modules-qualified-flat-import-explicit-reexports.sx`.

## Symptom

If `facade.sx` flat-imports `internal.sx`, a consumer importing only
`facade.sx` as a namespace can compile `facade.Hidden`,
`facade.HIDDEN_CONST`, `facade.hidden_global`, and
`facade.HiddenKind.one`, even though none is authored by the facade.

Observed: the reproduction compiles and exits 0 at both `--opt 0` and
`--opt 3`.

Expected: the first access is rejected with a diagnostic such as
`namespace 'facade' has no member 'Hidden'`. A namespace contains only the
target module's own declarations; declarations from that target's direct flat
imports are visible while lowering the target's bodies, but are not namespace
members. An explicit facade declaration such as `Hidden :: internal.Hidden`
remains the mechanism for intentional re-export.

The same leak is observable in the stdlib as `deflate.Deflater`,
`deflate.TDEFL_RAW_BLOCK_LIMIT`, and `zip.StdZipReaderState`. Direct qualified
function calls and generic struct heads already reject equivalent missing
members, which makes the current surface internally inconsistent.

## Reproduction

The permanent reproduction is
`examples/modules/0903-modules-qualified-flat-import-types-hidden.sx`, with
its facade and implementation fixtures in the matching directory. Its
essential implementation declaration is:

```sx
HiddenStruct :: struct {
    value: i64;
    make :: () -> HiddenStruct { .{ value = 11 } }
}
```

The facade flat-imports that implementation but authors only its public marker:

```sx
#import "internal.sx";

Public :: struct { value: i64; }
```

The consumer then attempts qualified access to every hidden type surface. The
first access is representative:

```sx
facade :: #import "0903-modules-qualified-flat-import-types-hidden/facade.sx";

main :: () -> i32 {
    hidden : facade.HiddenStruct = ---;
    0
}
```

Run:

```sh
./zig-out/bin/sx run examples/modules/0903-modules-qualified-flat-import-types-hidden.sx --opt 0
./zig-out/bin/sx run examples/modules/0903-modules-qualified-flat-import-types-hidden.sx --opt 3
```

Both commands now fail at the namespace edge as intended. Example 0904 covers
hidden constants, globals, enum variants, function values, and stores; 0905
proves that explicit facade re-exports remain available.

## Surface inventory

Focused probes show the missing membership check affects:

- plain struct, enum, union, error-set, nullary protocol, and type-alias
  annotations/literals;
- scalar constants, mutable globals, and namespace-rooted enum variants;
- static method heads on imported plain structs;
- qualified function values (which currently proceed far enough to reach an
  unrelated LLVM verifier failure).

Qualified direct calls and generic struct heads correctly use the namespace
target's `own_decls`. Bare access through a flat-imported facade is also
correctly rejected as non-transitive. Issue 0324 separately tracks the bare
unique-hidden static-head compatibility fallback; issue 0325 separately tracks
transitive nested namespace aliases.

## Investigation prompt

> Fix issue 0326 without adding or changing SX syntax. The import facts are
> already correct: `NamespaceTarget.own_decls` and
> `Resolver.collectNamespaceAuthors` / `resolveQualified` in
> `src/ir/resolver.zig` represent exactly the authored namespace members. The
> leaking paths bypass that membership proof by pinning
> `current_source_file` to the namespace target and then performing a bare
> lookup, which legitimately sees the target's direct flat imports. Audit the
> qualified `type_expr` and `field_access` arms in
> `src/ir/lower.zig::resolveTypeWithBindings`, static heads in
> `src/ir/lower/nominal.zig::staticStructHead`, namespace-rooted value lowering
> in `src/ir/lower/expr.zig::lowerFieldAccess`, qualified constant/global/enum
> inference in `src/ir/lower/comptime.zig` and `src/ir/expr_typer.zig`, and any
> equivalent call/type-function route. Require a selected member from the
> namespace target's `own_decls` before source-pinning its author. Preserve
> target identity when duplicate spellings exist. Add focused negative
> regressions for every leaked category plus positive direct-member and
> explicit-re-export controls. Verify the issue repro is rejected at opt 0/3,
> `deflate.Deflater`, `deflate.TDEFL_RAW_BLOCK_LIMIT`, and
> `zip.StdZipReaderState` are hidden, intended facade aliases still compile,
> then run `zig build`, `zig build test`, and the full example corpus.
