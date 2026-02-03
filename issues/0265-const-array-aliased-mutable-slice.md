# 0265 — a `::` const array aliased as a mutable `[]T` lets a write mutate the constant

> **BY DESIGN / WONTFIX (2026-07-05, per the project owner).** This is
> **expected behavior, not a bug** — do NOT fix it, add a rejection, or
> re-file it. A `::` const is an immutability contract on the NAME and on
> DIRECT writes (`C[i] = …` is still rejected), not a deep guarantee
> against an aliased mutable view. sx has no `[]const T` slice type and
> deliberately does not police const-through-slice aliasing; the behavior
> falls out of the slice-is-a-view semantics (issues 0225 / 0264): a slice
> of an addressable array — including a const one — aliases its backing
> storage. Kept as a writeup for provenance; the "Expected" section below
> is superseded by this banner.

## Symptom

One-line: a `::` constant array coerced (or subsliced) to a *mutable*
`[]T` produces an aliasing view, and a write through that slice mutates
the immutable constant — bypassing the const-write check that rejects the
direct `C[i] = …` form.

- Observed: `fill(C)` / `C[0..3]` then a `s[0] = 99` through the slice
  changes `C[0]` to 99; no diagnostic.
- Expected: either the coercion to a *mutable* slice is rejected (a const
  array should coerce only to a not-yet-existent `[]const T`), or the
  write through the slice is diagnosed the way the direct `C[0] = 99` write
  already is.

This is **pre-existing and independent of issue 0264/0225** — it is present
on BOTH the explicit `constArr[0..]` subslice path (0225) and the implicit
array→slice coercion path (0264). Neither introduced it; both correctly
alias, and there is simply no const-slice type to carry the immutability
through the view. Filed while fixing 0264 (2026-07-05).

## Reproduction

```sx
#import "modules/std.sx";

C :: i64.[ 1, 2, 3 ];

fill :: (s: []i64) { s[0] = 99; }   // mutates through a mutable slice param

main :: () -> i32 {
    // (a) implicit coercion path (issue 0264)
    fill(C);
    print("{}\n", C[0]);            // 99 — the constant was mutated

    // (b) explicit subslice path (issue 0225)
    s := C[0..3];
    s[0] = 77;
    print("{}\n", C[0]);            // 77

    // (c) but the DIRECT write is correctly rejected:
    // C[0] = 5;  // error: cannot assign through constant 'C'
    0
}
```

Expected: (a)/(b) rejected or diagnosed; (c) already rejected.

## Investigation prompt

The real fix needs the `[]const T` slice type from the const-propagation
work (PLAN-CONST-AGG): a `::` const array must coerce only to `[]const T`
(and `constArr[0..]` must yield `[]const T`), with a write through a
`[]const T` diagnosed. Until `[]const T` exists there are two stopgap
options — pick per the const-agg plan's direction:

1. **Reject** the coercion/subslice of a `::` const array to a *mutable*
   `[]T` at lowering time. Const arrays are recognizable where the
   array→slice view is built: the coercion arm in
   `src/ir/lower/coerce.zig` (`arrayToSliceView` / the `.array_to_slice`
   classify arm) and the subslice arm in `src/ir/lower/expr.zig`
   (`lowerSliceExpr`). The const-ness of the source is the same signal the
   direct-write check uses (grep the "cannot assign through constant"
   diagnostic — find where a decl is flagged const, e.g. an `is_const`
   scope/global flag) — thread it to the view builder and diagnose when the
   destination slice element is not const.

2. **Diagnose the write** through a slice known to alias a const backing —
   harder (requires provenance tracking through the slice), so (1) is the
   pragmatic stopgap until `[]const T` lands.

Verification: run the repro; expect (a) and (b) to produce a
"cannot form a mutable slice of constant 'C'" diagnostic (or, once
`[]const T` exists, a "cannot write through `[]const i64`" on the `s[0] =`
line), while (c) stays rejected and a non-const array still aliases fine.

Suspected area: `src/ir/lower/coerce.zig` (`arrayToSliceView`),
`src/ir/lower/expr.zig` (`lowerSliceExpr`), and wherever `::` const decls
carry their immutability flag (the direct-write check consumes it).
