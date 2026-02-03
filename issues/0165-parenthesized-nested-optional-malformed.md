# 0165 — parenthesized nested optional `?(?T)` resolves to a malformed double-wrapped type

> **RESOLVED.** The issue's premise was partly wrong: per `specs.md:843`, in
> TYPE position `(T)` is a single-field TUPLE, not a grouping — so `?(?i64)` is
> `optional(tuple(?i64))` and the compiler's `{ {{i64,i1}}, i1 }` layout was
> CORRECT. The real bug was a silent malformed-IR path: assigning a bare `?i64`
> to it had `coerceToType` classify `.none` and pass the value through unchanged,
> then `optionalWrap` built a corrupt `insertvalue` that aborted the LLVM
> verifier. Fix: after coercing toward an optional's child, verify the coerced
> value's type equals the child type (`src/ir/lower/stmt.zig` decl-init +
> `src/ir/lower/coerce.zig` `.optional_wrap`); on mismatch emit a located
> diagnostic (with a tuple-specific note only when the child is a tuple) instead
> of corrupt IR. `formatTypeName` now renders tuples as `(x: i64, y: i64)`.
> Genuine nested optionals via alias (`Opt :: ?i64; ?Opt`) work and round-trip.
> Regressions: `examples/optionals/0911-nested-optional-via-alias.sx`,
> `examples/diagnostics/1195-diagnostics-err-parenthesized-optional-tuple.sx`.
> **UPDATE (grouping):** `(T)` in type position is now a GROUPING, not a
> 1-tuple, so `?(?i64)` is a genuine NESTED OPTIONAL and compiles (what this
> issue originally wanted). The coerce guard now only fires for an explicit
> 1-tuple child `?(T,)` mismatch (note reworded). The obsolete diagnostic
> example 1195 was removed; see `examples/types/0201-types-parenthesized-type-grouping.sx`.
> Verified by 3 adversarial reviews. (A review noted `?any` over-rejection;
> that turned out to be a casing non-bug — lowercase `any` is an undefined name,
> the type is `Any`; see 0171, closed NOT-A-BUG.)

## Symptom

A nested optional written `?(?i64)` resolves to a spurious extra struct wrapper:
the destination type lowers to `{ { {i64,i1} }, i1 }` (triple-wrapped) instead of
the correct `{ {i64,i1}, i1 }`. Assigning an inner `?i64` then fails the LLVM
verifier:

```
LLVM verification failed: Invalid InsertValueInst operands!
  %ow.val = insertvalue { { { i64, i1 } }, i1 } undef, { i64, i1 } %load, 0
```

Crash (non-zero exit). `??i64` (unparenthesized) is a separate parse error
(`expected type name`) and is NOT this bug — only the parenthesized `?(?T)` form
reaches type resolution and produces the malformed layout.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  inner : ?i64 = 5;
  outer : ?(?i64) = inner;
  print("ok\n");
}
```

Expected: `ok` (a well-formed `{ {i64,i1}, i1 }` outer optional wrapping the
inner `?i64`). Observed: LLVM verifier abort.

## Investigation prompt

The type-table interning (`src/ir/types.zig` `optionalOf` / the optional
lowering near `types.zig:87`) produces the CORRECT `{ {i64,i1}, i1 }` for a
real `optional(optional(i64))`. So the malformed layout comes from
`instruction.ty` itself: the parenthesized `(?i64)` inner type expression is
resolved as a single-field STRUCT wrapping `?i64`, not as the optional type
directly. Suspected area: resolution of a parenthesized type expression
(`src/ir/type_resolver.zig` and/or the parser's handling of `(?T)` as a type) —
a parenthesized type should resolve to the inner type unchanged, not introduce a
tuple/struct wrapper. `src/backend/llvm/ops.zig` `emitOptionalWrap` is the
faithful victim (it uses `toLLVMType(instruction.ty)`), not the cause.

Verify: the repro prints `ok`; `?(?i64)` round-trips (unwrap inner, read value);
confirm the IR type is `{ {i64,i1}, i1 }`. Add an
`examples/optionals/09xx-nested-parenthesized-optional.sx` regression. (The
`unresolved type` panic seen when an `!` unwrap is added is downstream recovery
fallout of the same root cause — should disappear once the layout is correct.)
