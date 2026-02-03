# 0230 — unknown types inside a non-tuple type-alias RHS are silently stubbed

> **RESOLVED (2026-07-06).** Generalized the issue-0196 tuple-alias
> deferred-fixpoint (`src/ir/lower/decl.zig`) to EVERY composite alias RHS
> kind — array / slice / optional / pointer / many-pointer / function /
> closure (`isCompositeAliasRhs`, `registerCompositeAlias`,
> `resolveCompositeAliases`). A composite alias registers eagerly only when
> every element/pointee/param/return leaf already resolves; an element that
> references a LATER decl DEFERS to the forward-alias fixpoint and is
> ADOPTED once its decl is seen (`A :: [2]B; B :: i64` now compiles + works,
> not a permanent size-0 stub — the POSITIVE fix). Generic-instantiation
> elements (`[2]List(i64)`) instantiate for REAL via the same stateful
> `resolveTypeWithBindings` the inline form uses, so `size_of` matches the
> inline spelling exactly (no lying size-0 nominal). A genuinely unknown
> name (`[3]NoSuchType`) routes through the `UnknownTypeChecker` and gets
> the located "unknown type 'X'" diagnostic; other unresolvable shapes
> (bad dims, unbound generics, `..pack`) poison to `.unresolved` with one
> located per-element message (`reportCompositeAliasElement`), never a
> silent lying layout. Two carefully-scoped nuances: (1) a pointer/
> many-pointer POINTEE tolerates a forward NOMINAL leaf (`*RouteCtx` above
> `RouteCtx :: struct` — the stub is key-stably adopted, the stdlib's
> `next: *Node` forward-field pattern), probed via
> `typeNodeLeavesReadyBehindPtr`; (2) the 0196 MED-4 stub-above-decl
> rejection stays SCOPED TO TUPLE aliases — function/closure/pointer/etc.
> aliases named above their decl by a struct field/signature
> (`body_read_fn: BodyReadFn` above `BodyReadFn :: (...) -> i64`) are
> patched by the field re-resolution machinery the http module relies on,
> so widening the rejection there would break working code. 1129's
> non-const-dim message now matches the direct `a : [N]T` form (deduped).
> Regression tests: `examples/diagnostics/1231-diagnostics-alias-rhs-unknown-type.sx`
> (unknown-name → exit 1), `examples/types/0805-types-alias-forward-element.sx`
> (declared-later adoption across every composite kind + List-element
> size_of parity, exit 0), and unit tests in `src/ir/lower.test.zig`.
> Full suite green (no latent unknown types surfaced in the corpus/stdlib).
>
> Scope note: this covers the DECLARED-LATER / UNKNOWN-NAME families in
> composite ALIAS RHS. The sibling non-alias silent-stub families (0220
> undeclared nominal in other positions, 0254 UnknownTypeChecker walk-reach
> gaps in method/impl/global-init/default positions) remain their own
> issues.

## Symptom

One-line: `Bad :: [3]NoSuchType;` compiles silently — the unknown element
type becomes a never-patched empty-struct stub (size 0), miscompiling any
use of the alias; the same silent stub applies to slice / optional /
pointer alias RHS shapes.

- Observed: alias decl compiles; uses read/write 0-size elements.
- Expected: "unknown type 'NoSuchType'" at the alias decl (the diagnostic
  the inline annotation form already gets).

`UnknownTypeChecker.run` (src/ir/semantic_diagnostics.zig) walks fn
signatures and struct fields, and — since the issue-0196 fix — TUPLE
alias RHS, but no other alias RHS kinds.

## Reproduction

```sx
#import "modules/std.sx";

Bad :: [3]NoSuchType;      // expected: unknown-type diagnostic; observed: silent

main :: () -> i32 {
    b : Bad = ---;
    _ := b;
    print("ok\n");          // compiles + runs on a 0-size stub array
    0
}
```

Also probe: `S :: []NoSuchType;`, `O :: ?NoSuchType;`, `P :: *NoSuchType;`,
`F :: (NoSuchType) -> i64;` (function-type alias), and nested
(`N :: [2][]NoSuchType;`).

**Scope extension (2026-07-03, from the 0196 review):** the same silent
stubbing hits DECLARED-but-unadopted elements, not just unknown names —
`AL :: [2]List(i64);` registers with `size_of == 0` silently, and
`A :: [2]B; B :: i64;` (element alias declared LATER) prints garbage
then segfaults. Root mechanism: scanDecls resolves alias RHS eagerly in
decl order; forward-stub adoption (issue-0211 machinery) patches only
nominal decls, and `resolveForwardIdentifierAliases` re-tries only
identifier-RHS aliases — composite alias RHS elements (array/slice/
optional/pointer/function, and tuple before the 0196 fold) keep the
stub. The fix session should cover BOTH unknown-name diagnosis and
later-declared-element adoption (defer composite alias registration to
after the forward fixpoint, mirroring the 0196 fold's direction for
tuple RHS).

## Investigation prompt

Extend `UnknownTypeChecker.run` (src/ir/semantic_diagnostics.zig) to walk
EVERY type-alias RHS shape the alias registration in scanDecls
(src/ir/lower/decl.zig) accepts — array, slice, optional, pointer,
function-type — recursing into element/pointee/param/return positions,
mirroring what the issue-0196 fix did for tuple RHS (`tupleCarriesUnresolved`
+ the checker's tuple walk; generalize rather than copy). The underlying
silent empty-struct stub for undeclared nominals is issue 0220 — this
issue is the alias-RHS coverage gap specifically; coordinate if both
land (0220's fix may make the stub loud everywhere, which could subsume
this — verify rather than assume). Verification: each probe shape above
diagnoses at the decl; legitimate aliases keep working; corpus green;
diagnostics regression example.

Found by the issue-0196 fix worker (2026-07-03).
