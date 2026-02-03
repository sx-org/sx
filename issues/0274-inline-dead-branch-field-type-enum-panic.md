# 0274 — comptime-dead `inline if`/`inline match` branch doesn't prune types → `field_type(enum)` panics LLVM emission

> **RESOLVED** (2026-07-08).
>
> **Root cause (two independent defects, both surfacing as the same panic):**
> 1. The *actual* trigger in the repro was NOT the dead branch. `inline if false`
>    lowering already elides the untaken branch (`tryConstBoolCondition` folds a
>    bare `false` → the then-branch is never lowered, so `field_type(enum)` is
>    never resolved during lowering). The panic came from the CALL `go(E.x)`:
>    `inferExprType` had no arm for a bare `Enum.variant` VALUE read
>    (`field_access` on a type name), so it returned `.unresolved`.
>    `buildTypeBindings` then bound the generic param `T = .unresolved`, minting a
>    `go__unresolved` monomorph whose param type reached LLVM emission → panic.
> 2. There was no folding comptime type-kind predicate usable to gate the
>    reflection branch, so the field-wise hash could not route an enum key to the
>    leaf byte-hash.
>
> **Fix:**
> - `src/ir/expr_typer.zig` — added a `Enum.variant` value arm to the
>   `field_access` case of `inferExprType` (mirrors `lowerFieldAccess`'s
>   qualified-enum-literal path via `isPayloadlessVariant`): a payloadless variant
>   of a non-shadowed enum/tagged-union type name now infers to the enum type, so
>   `go(E.x)` / `hash_val(E.A)` bind `T = E`.
> - Added a folding `is_struct($T) -> bool` comptime predicate: intercepted in
>   `tryConstBoolCondition` (`src/ir/lower/control_flow.zig`) so `inline if
>   is_struct(T)` elides the reflection branch (incl. `field_type(T,i)`) when T is
>   an enum/scalar; folds to `const_bool` at value position in
>   `tryLowerReflectionCall` (`src/ir/lower/call.zig`); registered for pack-mangling
>   in `src/ir/calls.zig`; added to the reflection type-arg guard.
>
> **Regression test:**
> `examples/comptime/0658-comptime-inline-if-struct-gate-field-type.sx` — the
> `is_struct(T)`-gated field-wise fold compiles + runs for struct, enum, and scalar
> instantiations (no panic).
>
> **Note (orthogonal, NOT fixed here):** a bare `cast(u64) 0xcbf29ce484222325` in a
> `:=`-inferred / call-arg position is range-checked against i64 *before* the cast
> target applies and is rejected; an explicit `: u64 =` annotation works. Unrelated
> to this issue's enum/inline-if resolution.

## Symptom

A comptime-dead `inline if false { ... }` (or the never-taken arm of an
`inline match`) whose body contains `field_type(T, i)` for a `T` that is an enum
(or any type `field_type` can't index) does **not** get its types stripped
before backend emission: the resulting `.unresolved` TypeId escapes to LLVM and
trips the emission tripwire, panicking the compiler.

- **Observed:** `panic: unresolved type reached LLVM emission — a type
  resolution failure was not diagnosed/aborted` (`src/backend/llvm/types.zig:196`).
- **Expected:** a comptime-dead branch is pruned before emission (its invalid
  types never lower), OR `field_type(<enum>)` surfaces a located diagnostic
  instead of returning `.unresolved`.

## Reproduction

```sx
field_type :: ($T: Type, idx: i64) -> Type #builtin;
E :: enum { x; y; }
go :: (v: $T) {
    inline if false { f := cast(field_type(T, 0)) v; print("{}\n", f); }
}
main :: () { go(E.x); }
```

```sh
./zig-out/bin/sx run repro.sx
```

→ `thread NNNN panic: unresolved type reached LLVM emission …` at
`src/backend/llvm/types.zig:196` (`.unresolved => @panic(...)`).

The identical body with `T` a **struct** compiles clean (its `field_type(T,0)`
resolves). A NON-`inline` `if false { field_type(enum,…) }` instead gives a
clean located diagnostic — it's specifically the `inline`-branch path that
suppresses the diagnostic yet still lowers the bad type.

## Why it matters

This blocks a general, comptime-unrolled, field-wise structural hash (needed to
fix issue 0273 — hash maps hashing struct-key padding). The natural design:

```sx
hash_val :: (v: $T, h: u64) -> u64 {
    if type_eq(T, string) { ... content hash ... }
    inline if is_struct(T) {          // want: recurse only real structs
        inline for 0..field_count(T) (i) {
            hh = hash_val(cast(field_type(T, i)) field_value(v, i), hh);
        }
        ...
    } else { ... leaf byte hash ...  }  // scalars, ENUMS, bool, pointer
}
```

fails because (a) there is no folding `is_struct`/type-kind predicate usable as a
comptime gate in a generic (`type_kind` doesn't fold as a bare const;
`type_info(T)` errors on scalar leaf types — "'i64' is not reflectable"), and
(b) even guarding with `inline if false`/an unreachable `inline match` arm, the
dead branch's `field_type(enum,…)` still lowers `.unresolved` → this panic.
`field_count(enum) > 0` (it returns the variant count), so an enum key/field
enters the field-loop path and cannot be routed to the leaf byte-hash.

## Fix direction (one or both)

1. **Prune comptime-dead `inline if`/`inline match` branches before backend
   emission** — a `false` `inline if` (or an unreachable `inline match` arm)
   should strip its body's instructions/types so nothing in it reaches LLVM.
   (This is the general fix and also lets `inline if is_struct(T) {…} else {…}`
   type-gate reflection.)
2. **`field_type(T, i)` on a non-indexable `T` (enum/scalar) should emit a
   located diagnostic**, never return `.unresolved` that reaches emission — so
   even a mis-guarded use fails loud at compile time, not as a backend panic.
3. Optionally, expose a **folding comptime type-kind predicate**
   (`is_struct($T) -> bool` / a `type_kind` that folds as a const in a generic)
   so field-wise reflection can gate struct-vs-enum-vs-scalar without relying on
   `field_type` erroring.

## Context / provenance

Found during the issue-0273 fix exploration (field-wise key hashing for the std
hash maps). Field-wise hashing is otherwise feasible, `==`-consistent, and
*faster* than the current raw-byte hash (padded `struct{u8,i64}`: 13 ns vs 33 ns;
scalars bit-identical/zero-cost; `inline for` fully unrolls with no runtime
reflection), with zero prelude cost (a local `field_type` `#builtin` forward-decl
avoids importing `meta.sx`). The ONLY blocker to landing it is this enum-gating
panic.
