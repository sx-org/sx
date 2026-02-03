# 0181 — `?.`-chain (and `?`-postfix) on an optional whose child struct contains an ARRAY field panics `unresolved type reached LLVM emission`

> **RESOLVED.** `opt?.xs[i]` typed and lowered the index over the optional
> CONTAINER (`?[N]T`) — `getElementType` returned `.unresolved`, so `index_get`
> reached LLVM with an unresolved element type and panicked. Mirroring the
> issue-0101 `!`-unwrap fix: added `lowerOptionalChainIndex`
> (`src/ir/lower/expr.zig`) — `optional_has_value` → some: unwrap + index
> (`index_gep`+load for `?*[N]T`, else `index_get`) + `optional_wrap`; none:
> `const_null`; merge → `?ElemType` (element-optional flattened, so `[N]?T` →
> `?T`). The typer (`src/ir/expr_typer.zig`) and the dispatch guard both compute
> the element via `ptrToArrayElem(child) orelse getElementType(child)` so
> value-arrays, slices, many-pointers, AND pointer-to-array (`?*[N]T`) children
> resolve. Null receivers short-circuit (no null deref, verified in IR).
> Regression: `examples/optionals/0915-optional-chain-array-field-index.sx`.
> Verified by 3 adversarial reviews; suite 794/0. (Broader pre-existing gap
> found + filed: **0183** — indexing a non-indexable type `*T`/`*[]T`/struct
> panics instead of a diagnostic, reproduces without optionals.)
## Symptom

A `?.` optional-chain access (or the `?` optional-test postfix used in a
member-access chain) on a value of type `?S`, where `S` is a struct that
contains an **array field**, panics:

`thread … panic: unresolved type reached LLVM emission — a type resolution
failure was not diagnosed/aborted` (exit 134).

The same chain on `?S` where `S` has **no** array field works fine, and the
`!` force-unwrap chain (`opt!.field`) on the same array-containing `?S` works
fine. The defect is specific to the `?`/`?.` operator's receiver-type inference
when the optional's child struct contains an array field — that receiver types
as `.unresolved` and reaches LLVM. This is a pure **runtime** lowering bug: no
`#run`/comptime is involved.

Observed vs expected:
- Observed: SIGABRT panic (exit 134) at `src/backend/llvm/types.zig:196`
  (`toLLVMTypeInfo` `.unresolved` arm), reached from `declareFunction`'s
  `param.ty` lowering of a synthesized accessor.
- Expected: the chain evaluates (prints the field), exactly as the `!`-unwrap
  and the non-array `?.` forms already do.

## Reproduction

Pure runtime, no `#run` — panics:
```sx
#import "modules/std.sx";
Arr3 :: struct { xs: [3]i64; }
mk :: () -> ?Arr3 { r : Arr3 = .{ xs = .[1,2,3] }; return r; }
main :: () { print("{}\n", mk()?.xs[0] ?? 99); }   // PANIC exit 134
```

Control A — same chain, child struct has NO array field — WORKS, prints `7`:
```sx
#import "modules/std.sx";
Pt :: struct { x: i64; }
mk :: () -> ?Pt { return Pt.{ x = 7 }; }
main :: () { print("{}\n", mk()?.x ?? 99); }
```

Control B — same array-containing `?Arr3`, but `!` force-unwrap — WORKS, prints `1`:
```sx
#import "modules/std.sx";
Arr3 :: struct { xs: [3]i64; }
mk :: () -> ?Arr3 { r : Arr3 = .{ xs = .[1,2,3] }; return r; }
main :: () { print("{}\n", mk()!.xs[0]); }
```

(The issue 0167 (E) repro `A?.xs[0]` hit this same bug — it used `?` where `!`
was meant; with `!` the comptime `#run ?Arr3` case evaluates. So this is the
*residual* defect that 0167's (E) repro tripped, distinct from 0167 (C)/(E),
both of which are fixed.)

## Investigation prompt

The `?` optional-chaining / optional-test path synthesizes an accessor whose
receiver (the unwrapped child) types as `.unresolved` specifically when the
child is a struct containing an array field — mirroring the already-fixed
issue-0101 `!`-unwrap bug (`inferExprType` had no force_unwrap arm → receiver
typed `.unresolved`). The `!` path was fixed (see
`examples/optionals/0905-optionals-unwrap-field-chain.sx`); the `?`/`?.` path
has an analogous gap that only surfaces for an array-containing child (a
plain-scalar/string child happens to resolve).

Suspected area: `src/ir/lower.zig` `inferExprType` (grep for the optional-chain
/ `?` postfix / `safe_nav` handling) and/or `src/ir/lower/` accessor-chain
lowering — find where the `?`-chain receiver type is computed and why an
array-containing struct child yields `.unresolved`. Compare against the working
`!`-unwrap arm (issue 0101 fix) and apply the same receiver-type flow.

Verification: the first repro above prints `1` and exits 0; controls A and B
still pass; add a regression under `examples/optionals/` covering `?.`-chain on
an array-containing `?S` (field read + `?? default`). Confirm
`examples/comptime/0644-comptime-run-array-aggregate.sx` (issue 0167) still
passes.

## Provenance

Discovered while implementing issue 0167 (C: comptime reg→value array-in-
aggregate bridge; E: clean-abort on comptime-init failure). 0167 (C) and (E)
are FIXED and verified; the `?Arr3` access form in 0167's (E) repro tripped this
SEPARATE, pre-existing runtime lowering bug (confirmed reproducible on clean
`HEAD` with no `#run`).
