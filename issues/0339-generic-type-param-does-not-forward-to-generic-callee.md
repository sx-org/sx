# 0339 — a bound `$T: Type` does not forward into another generic's type-arg slot

> **RESOLVED (2026-07-22).** Fix in `buildTypeBindings` Strategy 1
> (src/ir/generics.zig): a bare identifier naming a type param bound in the
> ACTIVE `type_bindings` (the enclosing monomorphization) now counts as an
> explicit type argument — `resolveTypeArg`'s identifier arm already
> resolved it; only the type-shaped gate refused it. Regression:
> `examples/generics/0223-generics-type-param-forwarding.sx` (direct
> forwarding, forwarding into a recursive comptime walk, generic-struct
> construction from the forwarded param).

> **Symptom.** Inside a generic function, passing the bound type param to
> another generic's leading `$T: Type` slot fails:
> `error: cannot infer generic type parameter 'T' for 'inner' from this
> call's arguments`. Inconsistent with folded type expressions:
> `inner(struct_field_type(T, i))` binds fine in the same position, and a
> bare `T` is at least as comptime-known.

## Reproduction

```sx
#import "modules/std.sx";

inner :: ($T: Type) { print("{}\n", size_of(T)); }
outer :: ($T: Type, v: T) { inner(T); }

main :: () { outer(i64, 5); }
```

## Expected

`inner(T)` monomorphizes `inner` with the enclosing binding (`T = i64`) —
type params compose through generic call chains, exactly like a folded
`struct_field_type(T, i)` argument already does.

## Actual

"cannot infer generic type parameter 'T'" at the inner call site.

## Root cause

`buildTypeBindings` Strategy 1 (src/ir/generics.zig) gates explicit type
args on `isTypeShapedAstNode`, whose `.identifier` arm only accepts names
registered in the type table. An identifier bound in the ACTIVE generic
`type_bindings` (installed for the enclosing monomorphization) is not
recognized — even though `resolveTypeArg`'s identifier arm already checks
`type_bindings` first and would resolve it correctly.

## Impact

Blocks generic helpers layered over generic entry points — hit by the UI
StateStore (G4 Step 2): `use_state($T, …)` forwarding `T` into its shared
`claim_entry(store, ui, T, …)` / `trivial_state_check(T)`.
