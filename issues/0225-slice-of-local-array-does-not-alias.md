# 0225 — slicing a local array does NOT alias: the slice points at a hidden copy

> **RESOLVED** (2026-07-05). **Root cause:** `lowerSliceExpr`
> (`src/ir/lower/expr.zig`) value-lowered the sliced ARRAY object, and
> `emitSubslice`'s array-value arm (`src/backend/llvm/ops.zig`) materializes
> a fresh `alloca`+`store` — so the slice viewed a COPY, not the array.
> **Fix:** for an array object, recover its storage ADDRESS from the
> already-lowered value via the issue-0214 `refStorageAddress` walk (which
> re-emits only address arithmetic, never re-runs a side-effecting index) and
> subslice over THAT pointer, with `base_ty = [*]elem` so the comptime VM
> strides by element size. This routes both backends through their pointer
> (many-pointer) subslice arm — a genuine zero-copy view. Handles local,
> global, struct-field, and `*[N]T`-deref bases uniformly (all lower to a
> load/deref/global_get/struct_get that `refStorageAddress` walks).
> **Rvalue policy:** a NON-addressable array (call result, literal, by-value
> binding — `refStorageAddress` returns null) is now REJECTED with a
> diagnostic ("cannot slice a temporary array …"), since a slice of a temp is
> a dangling view; bind to a local first. Recorded in specs.md §Subslicing.
> **Regression tests:** `examples/memory/0842-memory-slice-aliases-array.sx`
> (write-through + read-through + offset + global + field-array) and
> `examples/diagnostics/1229-diagnostics-slice-of-temporary-array.sx` (rvalue
> rejection). **Related (separate, NOT fixed here):** implicit array→slice
> COERCION (`array_to_slice` / `emitArrayToSlice`, e.g. `fill(arr)` for a
> `[]T` param) has the same copy-not-view bug on a distinct code path — filed
> for separate triage.


> **Review fold (MED-1):** an inline array-literal slice (`i64.[1,2,3][0..2]`)
> typed the base as `.unresolved` and slipped past the `== .array` rvalue
> guard, carrying an unresolved slice-element type into codegen (a hard
> panic) instead of the promised rejection. `lowerSliceExpr` now rejects an
> `.unresolved` base up front with the temporary-array diagnostic (gated on
> `!hasErrors()` to avoid a cascade). Pinned by
> `examples/diagnostics/1230-diagnostics-slice-of-array-literal.sx`. specs.md
> §Subslicing also gained the dangling-returned-view and by-value-param-copy
> notes.

## Symptom

One-line: `sl : []S = arr[0..3];` value-lowers the local array and copies
it into a fresh temporary, so the slice points at the COPY — a write
`sl[1].v = 99;` is invisible through `arr[1]`, and vice versa.

- Observed: mutations through the slice do not affect the sliced array
  (and array mutations after the slice are invisible through the slice).
- Expected (if slices are views, Zig-like): the slice aliases the
  array's storage — `sl[1].v = 99` is visible as `arr[1].v == 99`.

Silent wrong-aliasing of this kind is dangerous: code that "works" while
values match masks the copy until the first in-place mutation. If specs.md
instead defines slicing-a-value as a copy on purpose, then this issue
becomes a docs/diagnostic question — but stdlib patterns (List.items,
buffer windows) strongly imply view semantics.

## Reproduction

```sx
#import "modules/std.sx";

S :: struct { v: i64 = 0; }

main :: () -> i32 {
    arr : [3]S = ---;
    arr[0] = S.{ v = 1 };
    arr[1] = S.{ v = 2 };
    arr[2] = S.{ v = 3 };
    sl : []S = arr[0..3];
    sl[1].v = 99;
    print("{}\n", arr[1].v);   // observed: 2 — expected: 99
    if arr[1].v != 99 { return 1; }
    0
}
```

Reproduced on unmodified master (probe `.sx-tmp/0214-slice-alias.sx`,
2026-07-03). No protocols involved.

## Investigation prompt

`lowerSliceExpr` (src/ir/lower/expr.zig ~line 1963) lowers the sliced
OBJECT as a VALUE (`const obj = self.lowerExpr(se.object)`), which for a
local array materializes a fresh temp (`%ss.arr`) that the slice then
points into. FIRST check specs.md §slices for the intended semantics.
If slices are views (expected): for ADDRESSABLE array objects (locals,
globals, fields, derefs), lower the object as a POINTER
(`lowerExprAsPtr` / the issue-0214 `refStorageAddress` machinery landed
in src/ir/lower/coerce.zig — reuse it) and build the slice over that
address; keep the copy path ONLY for genuinely non-addressable rvalues
(a call returning an array — decide: temp lifetime or reject with a
diagnostic, since a slice of a dead temp is a dangling view). Probe:
local array, global array, struct-field array, array behind a pointer,
nested (slice of slice), passing `arr[0..n]` directly as a fn arg,
and the rvalue case. Verification: the repro prints 99; existing slice
corpus (examples/types/, examples/memory/, stdlib List/fmt users) stays
green — beware code that silently RELIED on the copy; regression
example under examples/types/ or examples/memory/.

Found by the issue-0214 fix worker (2026-07-03), reproduced on master.
