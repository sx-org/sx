# 0249 — multi-assign to a mutable GLOBAL array index silently drops the store

> **RESOLVED** — `src/ir/lower/stmt.zig` `lowerMultiAssign` index-target arm.
> Root cause: for an `is_array` base the arm chose `getExprAlloca(ie.object)`
> and, on the null it returns for a global, fell through to
> `lowerExpr(ie.object)` — a `global_get` that loads the WHOLE array into a
> register. The `index_gep`+`store` then hit that throwaway copy, so the write
> never reached the global's storage. Single-assign already took the correct
> `is_array → getExprAlloca orelse lowerExprAsPtr` path (lowerExprAsPtr emits a
> `global_addr` for a global base). Fix: the multi-assign index arm now mirrors
> single-assign — `is_array` bases resolve via `getExprAlloca orelse
> lowerExprAsPtr` (in-place `global_addr` for globals, alloca for locals), and a
> slice/pointer base still loads the pointer VALUE. Also folded in the missing
> 0155 `diagNonIndexable` guard (a non-indexable multi-assign base — `ps[i], a =
> …` where `ps: *S` — previously built an `index_gep` typed `ptrTo(.unresolved)`
> that panicked at LLVM emit; now it diagnoses and bails). Neighboring shapes
> probed: global struct-member multi-assign (already worked — confirmed), global
> slice-element (behaves identically to single-assign — pre-existing slice-copy
> semantics, no drop), nested `GARR[i].field`, deref through a pointer to a
> global — all store correctly, no silent drop found in the family. Regression:
> `examples/basic/0060-basic-multi-assign-global.sx` extended with global-array
> index legs (single, two-index, swap `GA[0],GA[1]=GA[1],GA[0]` RHS-before-store
> ordering); unit test `lower: multi-assign to a GLOBAL array index stores in
> place via global_addr, not a value copy (issue 0249)` in `src/ir/lower.test.zig`.

## Symptom

One-line: `MARR[1], a = 77, 4;` where `MARR : [3]i64` is a mutable
module global — compiles, but `MARR[1]` reads back the ORIGINAL value;
the single-assign form `MARR[1] = 77;` writes correctly, and multi-
assign to LOCAL array indices works.

- Observed: store silently dropped (A/B-verified identical on the
  pre-0228/0229 parent — pre-existing, not introduced by that fix).
- Expected: the store lands, same as single-assign.

Same silent-drop family as 0218/0223/0229: `lowerMultiAssign`'s
INDEX-target store arm doesn't handle a GLOBAL-resolved base.

## Reproduction

```sx
#import "modules/std.sx";

MARR : [3]i64 = .[ 10, 20, 30 ];

main :: () -> i32 {
    a := 0;
    MARR[1], a = 77, 4;
    print("{}\n", MARR[1]);   // observed: 20 — expected: 77
    if MARR[1] != 77 { return 1; }
    0
}
```

## Investigation prompt

In `src/ir/lower/stmt.zig` `lowerMultiAssign`, the index-target store
arm resolves the base against local scope; a module-global base either
misses (store dropped silently — find the fall-through) or takes a
value-copy path. Mirror what single-assign's `.index_expr` arm does for
a global base (global_addr + index_gep + store — check `lowerAssignment`
post-0155, which also guards non-indexable bases via diagNonIndexable).
Also probe: global STRUCT-member multi-assign (`GS.x, a = ...` —
the 0228/0229 review probed "global-member targets keep working", so
likely fine — confirm), global slice-element, nested `GARR[i].field`,
and by extension DEREF targets with global bases. Apply the same
no-silent-drop rule: any unhandled base shape must diagnose. Verify:
the repro prints 77; local/struct/member forms unchanged; the 0229
const-guard still rejects const-array writes; corpus green; extend
examples/basic/0060 (multi-assign suite) or diagnostics/1223 per shape.

Found by the adversarial review of the 0228+0229 fix (2026-07-04);
pre-existing on d0e46aad.
