# 0168 — indexing an array of optionals `[N]?T` produces a wrong/garbage element (segfault or wrong value)

> **RESOLVED.** Not a GEP/stride bug — a positional literal `.{ null, 7 }` for an
> array target was storing bare `T`/`null` elements into the `{T,i1}` optional
> slots because array elements were never coerced to the element type
> (`getStructFields` is empty for an array, so the per-field coercion gate
> `i < struct_fields.len` never fired). Fix (`src/ir/lower/expr.zig`): in
> `lowerStructLiteral`'s positional branch, compute `array_elem_ty` for
> array/vector targets and coerce each positional element to it; in
> `lowerArrayLiteral`, generalize the previous slice-only coercion to coerce
> every element via `coerceToType` (which is layout-aware — scalar→`{T,i1}`,
> pointer-sentinel→one-word, array→slice, concrete→protocol). Verified across
> scalar/struct/pointer-sentinel optional elements, int→float/widening/erasure/
> array→slice element coercions, nested + vector arrays, by 3 adversarial
> reviews; suite 780/0. Regression:
> `examples/optionals/0913-optionals-array-of-optionals.sx`. (Adjacent
> pre-existing bugs found + filed: 0173 typed `.[null,…]` element, 0174 tuple
> positional-element coercion, 0175 positional struct literal variable element.)

## Symptom

Reading an element of an array whose element type is an optional (`[N]?T`) is
broken: depending on how the result is used it either SEGFAULTS or yields the
WRONG value (reads a present element as absent). Independent of issue 0164 (the
`if`-on-optional fix) — reproduces with a plain `??` and with a copy-to-local.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  arr : [2]?i64 = .{ null, 7 };

  // (1) index result used directly → SEGFAULT (exit 134)
  x := arr[1];
  print("{}\n", x ?? -1);   // expected: 7

  // (2) copy element to a local then test → WRONG VALUE
  e := arr[1];              // element 1 is present (7)
  if e { print("present\n"); } else { print("absent\n"); }  // prints "absent" — WRONG
}
```

Expected: element 1 is the present optional `7`. Observed: segfault in case
(1); `absent` (a wrong/absent optional) in case (2). The original surfacing form
`if arr[0] { ... }` also segfaults.

## Investigation prompt

The element load / addressing for an array of optionals appears to compute the
wrong element stride or mis-materialize the loaded `{T,i1}` optional aggregate.
Suspect the index/element-load lowering (`src/ir/lower/expr.zig` index-get path,
and `src/backend/llvm/ops.zig` `emitIndexGet`) when the element type is an
optional aggregate `{T,i1}` — check that the element size/alignment used for the
GEP matches the optional's real size (cf. the `size_of` vs `typeSizeBytes`
nuance for optionals), and that the loaded value is the full aggregate, not a
truncated/garbage read. Compare against a working `[N]T` (non-optional) array
load to isolate whether it's stride math or aggregate materialization.

Verify: case (1) prints `7`, case (2) prints `present`; also test `[N]?T` with a
struct payload (`[2]?Pt`) and writing elements then reading them back. Add an
`examples/optionals/09xx-array-of-optionals.sx` regression.
