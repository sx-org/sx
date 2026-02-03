# 0180 — `??` lowering defects for generic / alias / tuple optional lhs (wrong fallback, segfault, PHI mismatch)

> **RESOLVED.** (1) The generic-`??`-wrong-fallback was NOT in `lowerNullCoalesce`
> — the real root cause was that an optional→optional coercion `?A → ?B` (differing
> payload, e.g. the `?i32 → ?i64` call-arg coercion when instantiating
> `unwrap_or(99, ?i32)`) routed through `.optional_wrap`, which unconditionally
> UNWRAPPED the source and re-wrapped as ALWAYS-PRESENT — so a NULL became a
> present-zero everywhere (call args, returns, field init, var-decl, `??`). Fix:
> a `CoercionPlan.optional_to_optional` (`src/ir/conversions.zig`) + a
> presence-preserving arm in `coerceMode` (`src/ir/lower/coerce.zig`): has_value →
> present: unwrap+coerce-child+wrap-present; absent: `constNull(dst)`; merge via a
> `dst_ty` block param. `lowerVarDecl` (`src/ir/lower/stmt.zig`) gained a
> `!src_is_optional` guard so an annotated `x : ?B = <?A>` routes through the same
> arm (also makes aggregate-payload var-decl `?[3]i64 → ?[]i64` / `?Concrete →
> ?Protocol` work). (2) The alias-optional struct-literal default already works
> (grouping + issue-0166 threading) — locked by regression. (3) `?(i32)` is now a
> grouped `?i32` (issue-0177 grouping); a genuine 1-tuple default `?(i32,) ?? 5`
> emits a clean diagnostic (`lowerNullCoalesce`, `src/ir/lower/expr.zig`) instead
> of an LLVM PHI-verifier abort (no implicit scalar→1-tuple coercion per spec).
> Regressions: `examples/optionals/0916` (generic ??), `0917` (alias struct
> default), `0918` (var-decl optional→optional present/null × widen/narrow/
> int-float/array→slice/erasure), `examples/diagnostics/1202` (1-tuple-default
> diagnostic) + a `conversions.test.zig` unit test. Verified by 3 adversarial
> reviews; suite 798/0.

## Symptom

`lowerNullCoalesce` mishandles several non-trivial optional lhs shapes (all with a
genuinely-optional lhs, so the issue-0172 non-optional guard correctly does not
fire). Found during adversarial review of issue 0172.

1. **Generic `??` returns the WRONG fallback** (VERIFIED — silent miscompile):
   a `??` inside a generic function where the lhs is a type-param-typed optional
   `?T` drops the RHS default and returns the zero payload instead.
2. **Alias-optional with a struct-literal default segfaults** (reported by review):
   `?Opt ?? Opt.{}` where `Opt :: ?Struct` crashes in type interning
   (`hashString`/wyhash).
3. **`?(i32) ?? i32` LLVM PHI-type mismatch** (reported by review): an
   optional-of-1-tuple coalesced with a scalar default emits `phi { i32 }` vs
   `i32`.

(Scalar-default alias-optional `Opt :: ?i64; o ?? 7` works correctly — the
defects are specific to the shapes above.)

## Reproduction

(1) Generic `??` wrong fallback — VERIFIED, prints `0`, expected `99`:
```sx
#import "modules/std.sx";
unwrap_or :: (d: $T, x: ?T) -> T { return x ?? d; }
main :: () { b : ?i32 = null; print("{}\n", unwrap_or(99, b)); }  // prints 0 — WRONG
```

(2) Alias-optional + struct-literal default (reported segfault):
```sx
#import "modules/std.sx";
S :: struct { a: i64 = 0; }
Opt :: ?S;
main :: () { o : Opt = null; x := o ?? S.{ a = 7 }; print("{}\n", x.a); }
```

(3) Optional-of-tuple + scalar default (reported PHI mismatch):
```sx
#import "modules/std.sx";
main :: () { o : ?(i32) = null; x := o ?? 5; }
```

## Investigation prompt

`src/ir/lower/expr.zig` `lowerNullCoalesce`. For (1), when the lhs optional's
child is a TYPE PARAMETER (`?T`, resolved per monomorphization), the present/
absent merge appears to drop the RHS default and yield the zero payload — check
that `inner_ty` and the merge-block param resolve to the monomorphized child and
that the RHS (`d`) is correctly selected on the null path. For (2)/(3), the merge
of present-payload vs default has a type mismatch when the child is an
alias/struct (interning crash) or a 1-tuple (PHI `{i32}` vs `i32`) — the default
and the unwrapped payload must share the exact merge TypeId. Verify each repro
produces the expected value (`99`, `7`, and a clean `?(i32)` coalesce); confirm
the generic case across multiple instantiations. Add regressions under
`examples/optionals/09xx-...`. (These reproduce on master, independent of the
issue-0172 guard.)
