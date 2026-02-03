# 0264 — implicit array→slice COERCION copies instead of aliasing

> **RESOLVED** (2026-07-05). **Root cause:** the implicit array→slice
> coercion lowered to the `array_to_slice` op (`emitArrayToSlice`,
> `src/backend/llvm/ops.zig`), which alloca+stores a fresh COPY — so
> `fill(arr)` viewed a copy while the explicit `fill(arr[0..])` (issue 0225)
> aliased, a silent-wrong divergence. **Fix:** a shared `arrayToSliceView`
> helper (`src/ir/lower/coerce.zig`) mirrors 0225 — for an ADDRESSABLE array
> it recovers the storage address via the issue-0214 `refStorageAddress`
> walk and builds a `subslice [0..len]` over `[*]elem` (a zero-copy view).
> Wired into all three array→slice sites: the general coercion arm
> (`.array_to_slice` in `coerce.zig`, the call-argument path), the
> slice-typed binding (`src/ir/lower/stmt.zig`), and the spread pack
> (`src/ir/lower/pack.zig`). **Rvalue policy:** a NON-addressable rvalue
> array (call result / literal) as an ARGUMENT or as a slice-typed BINDING
> keeps the COPY — it is materialized into call-duration / function-entry
> storage that outlives the slice, so it is sound and never dangling (this
> is why `argv : []string = .[…]` is accepted). This deliberately differs
> from 0225's *subslice-of-a-temporary* rejection, because a subslice
> aliases the temp directly (dangling) whereas the coercion materializes a
> persistent copy first. **Const:** a `::` const array still aliases into a
> mutable `[]T` (same as 0225's `constArr[0..]`); the resulting mutable
> alias of a constant is a pre-existing language-wide hole filed as **issue
> 0265** (needs the `[]const T` slice type). **Regression test:**
> `examples/memory/0843-memory-array-to-slice-coercion-aliases.sx`
> (local + global + field arg legs, bound-slice alias, literal-copy leg).
> Specs updated in `specs.md §Subslicing` (implicit-coercion paragraph).

## Symptom

One-line: passing an array where a slice is expected — `fill(arr)` with
`fill :: (s: []i64)` — coerces via `array_to_slice`, which (like the
pre-0225 subslice) materializes a COPY: mutations through the slice
param never land in the caller's array.

- Observed: silent copy; `fill(arr)` then `arr[0]` unchanged.
- Expected: the coercion is a zero-copy view (specs §Subslicing calls
  slices "zero-copy views"; the issue-0225 fix made the EXPLICIT
  `arr[0..N]` syntax alias — the implicit coercion must match, or
  passing `arr` vs `arr[0..]` silently differ, which is worse).

Distinct code path from 0225: the `array_to_slice` op /
`emitArrayToSlice` (src/backend/llvm/ops.zig) alloca+stores the value.

## Reproduction

```sx
#import "modules/std.sx";

fill :: (s: []i64) {
    s[0] = 99;
}

main :: () -> i32 {
    arr : [3]i64 = .[ 1, 2, 3 ];
    fill(arr);                 // implicit array→slice coercion
    print("{}\n", arr[0]);     // observed: 1 — expected: 99
    if arr[0] != 99 { return 1; }
    0
}
```

## Investigation prompt

Mirror the issue-0225 fix on the coercion path: where the implicit
array→slice conversion lowers (grep `array_to_slice` emission and the
coercion arm in src/ir/conversions.zig / coerceToType), an ADDRESSABLE
array operand takes the storage address (the 0214/0225
`refStorageAddress` walk — reuse it) and builds the slice header over
it; a non-addressable rvalue array gets the 0225 rejection ("cannot
pass a temporary array as a slice — bind it to a local first") OR the
copy stays for rvalues-as-ARGUMENTS if the callee cannot outlive the
call... careful: unlike 0225's bound slice, an argument's temp lives
for the call — a copy for rvalue args is SOUND (document it); the
addressable case must still alias. Probe: mutation-through-param (the
repro), global arrays, field arrays, rvalue `fill(make_arr())` (copy
sound — pin whichever), const arrays passed where `[]T` expected
(mutation must be REJECTED or the param type needs []const — check the
const-propagation state per PLAN-CONST-AGG), xx-cast forms, and the
0225 regression example still green. Library audit like 0225's (grep
implicit array-as-slice call sites). Full corpus green.

Found by the issue-0225 fix worker (2026-07-05); same silent-wrong
class as 0225 on the sibling path — queue with the silent-wrong batch.
