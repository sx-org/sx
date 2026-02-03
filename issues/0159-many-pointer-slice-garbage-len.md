# issue 0159 — slicing a many-pointer `mp[lo..hi]` produces a garbage slice (wrong `.len`/`.ptr`)

> **RESOLVED.** Root cause: `emitSubslice` (`src/backend/llvm/ops.zig`) handled a
> struct (slice/string) base and an array base, but a many-pointer `[*]T` base is
> an LLVM *pointer* kind — it fell through to the `else` arm, which mapped the
> result to `LLVMGetUndef(slice_ty)` (a silent-undef default), so the slice's
> `.len`/`.ptr` were garbage. Fix: added a `LLVMPointerTypeKind` branch — the
> base value IS the data pointer, so GEP by `lo` and `len = hi - lo` (the caller
> supplies the bound; no length is read from the unbounded pointer). A `List`
> (whose `items` is `[*]T`) is now iterable with `for items[0..len] (e)`, applied
> in `Scheduler.deinit`. Regression: `examples/types/0195-types-many-pointer-slice.sx`.
> (The comptime/interp path can't take a many-pointer to a stack array — `xx @a[0]`
> — at comptime; that is a separate pre-existing limitation, not this bug.)

## Symptom

Slicing a `[*]T` many-pointer with a range, `mp[lo..hi]`, yields a slice whose
`.len` (and `.ptr`) are garbage — iterating it reads out of bounds and
segfaults. The identical slice of the underlying ARRAY is correct.

```
array slice : len=3 s0=5 s2=7          ← a[0..3]      (correct)
manyptr slice: len=4340757212 (want 3) ← mp[0..3]     (garbage)
```

The compiler ACCEPTS `mp[0..hi]` (it type-checks as `[]T`) but lowers it wrong.
specs.md documents many-pointer *indexing* (`mp[2]`) but not *slicing*; either
slicing a many-pointer should build a correct `{ ptr = mp + lo, len = hi - lo }`
slice, or it should be a compile error — a silently-garbage slice (which then
segfaults on use) is the forbidden silent-wrong outcome.

Practical impact: `for xs.items[0..xs.len] (e)` over a `List` crashes, so a
`List` cannot be iterated with a `for` loop; every consumer uses the
`while i < xs.len { ... xs.items[i] ... }` index loop instead.

## Reproduction

```sx
#import "modules/std.sx";
main :: () -> i64 {
    a : [4]i64 = .[5, 6, 7, 8];
    sa : []i64 = a[0..3];        // correct: len=3
    print("array : {}\n", sa.len);
    mp : [*]i64 = xx @a[0];
    sm : []i64 = mp[0..3];       // BUG: garbage len
    print("manyptr: {}\n", sm.len);
    return 0;
}
```

(repro: `issues/0159-many-pointer-slice-garbage-len.sx`. The garbage value is
uninitialized memory, so it varies per run — the bug is that it is NOT `3`.)

## Investigation prompt

> Slicing a `[*]T` many-pointer with a range (`mp[lo..hi]`) produces a slice
> with a garbage `.len`/`.ptr`, whereas slicing an array (`a[lo..hi]`) is
> correct. Repro: `issues/0159-many-pointer-slice-garbage-len.sx`.
>
> Trace the slice-expression lowering (`src/ir/lower/` — the range-index /
> `slice_expr` arm; grep for where `a[lo..hi]` builds a `{ ptr, len }` slice
> aggregate). The array path computes `len = hi - lo` and `ptr = &base[lo]`
> correctly; the many-pointer base falls through to a path that reads a bogus
> length (likely it assumes the base is an array/slice with a known bound, or
> reuses an uninitialized slot). Decide the intended semantics from specs.md
> (§Pointer Types — many-pointer; slicing a many-pointer is currently
> unspecified): if `mp[lo..hi]` is supported, build `{ ptr = mp + lo,
> len = hi - lo }` (the user-supplied `hi`/`lo` ARE the bounds — no length is
> read from the unbounded pointer); if it is NOT supported, emit a diagnostic at
> the lowering site ("cannot slice a many-pointer `[*]T` with an open length;
> …") rather than producing a garbage slice. Verify: `sx run` the repro —
> expect `manyptr: 3` (if supported) or a clean compile error, never a garbage
> length / segfault. Then promote the repro to a regression under `examples/`.
