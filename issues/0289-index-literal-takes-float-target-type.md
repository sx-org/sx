# 0289 — an integer literal index is lowered as a float when the target type is a float

> **RESOLVED** (fixed 2026-07-16 in fd212db0; banner added 2026-07-17 —
> the fix landed without one). A literal index under a float target type
> lowered as a float constant, producing an invalid GEP. Fixed by lowering
> index operands as i64 via a shared `lowerIndexOperand` helper across all
> seven index sites. Regression test:
> `examples/types/0852-types-index-literal-under-float-target.sx`.

## Symptom

Indexing a slice with a literal (`s[0]`) in any context whose target type is a
float lowers the INDEX operand as a float constant, producing an invalid GEP:

```
LLVM verification failed: GEP indexes must be integers
  %ig.ptr = getelementptr float, ptr %ig.data, float 0.000000e+00
```

Observed: LLVM verifier failure (compilation fails).
Expected: `1.500000` — the index is an integer position, wholly independent of
the element/target type.

The ambient target type is steering literal lowering for an operand that is
never of the target type. It reproduces with an `f32` binding, an `f32` return,
and an `f32` field — anywhere the target type is a float:

```sx
v : f32 = s[0];                        // fails
first :: (xs: []f32) -> f32 { xs[0] }  // fails
```

Controls that pass, which bracket it:

| code | result |
|---|---|
| `v : f32 = s[0];` | **fails** |
| `v : f32 = s[i];` (index via an i64 local) | ok |
| `first :: (xs: []f32) -> i64 { v := xs[0]; 0 }` (non-float target) | ok |
| `first :: (xs: []i64) -> i64 { xs[0] }` | ok |

Generics are NOT involved — the original sighting was through a `[]$T` generic,
but the same failure occurs with a fully concrete `[]f32`, so the
monomorphization path is a red herring.

## Reproduction

```sx
#import "modules/std.sx";

main :: () {
    f : [2]f32 = .[1.5, 2.5];
    s : []f32 = f;
    v : f32 = s[0];       // LLVM verification failed: GEP indexes must be integers
    print("{}\n", v);
}
```

Equivalent through a return type:

```sx
#import "modules/std.sx";

first :: (xs: []f32) -> f32 { xs[0] }

main :: () {
    f : [2]f32 = .[1.5, 2.5];
    print("{}\n", first(f));
}
```

## Investigation prompt

`Lowering.target_type` steers integer-literal lowering (a literal in an `f32`
slot lowers as an `f32` constant — the intended behaviour for a VALUE). The
index operand of an `index_get` / `index_set` is not a value in the target
type: it is always an integer position. The lowering of the index expression
appears to leave the ambient `target_type` installed while lowering the
subscript, so `0` folds to `0.0`.

Look at the `.index_expr` arm of `lowerExpr` (`src/ir/lower/expr.zig`) and the
`index_get`/`index_set` emission (`src/backend/llvm/ops.zig` ~2031 —
`emitIndexGet` is where the bad GEP is built). The index operand should be
lowered with the target type cleared (or pinned to `i64` / `usize`), the same
way any other non-value position would be. Check `slice_expr` (`a[i..j]`)
bounds for the identical hole.

An integer-typed index is an invariant of the IR, so it is also worth asserting
at the `index_get` / `index_set` construction site: a float index should be a
compile-time error (or an assertion) at IR-build time, not an LLVM verifier
message that names no source location.

Verify with both reproductions above (expect `1.500000`), plus a regression
example under `examples/`.

## Context

Found while writing the regression example for [0288] — the `f32`
monomorphization of a generic `first(xs: []$T) -> T` failed. Reducing it showed
generics were incidental. `f32` slices are pervasive in `modules/ui` (geometry,
vertex data), so this is easy to hit in UI code.
