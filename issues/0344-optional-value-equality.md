# 0344 — optional value-equality: `?T == ?T` and the mixed `?T == T`

Status: RESOLVED (language extension, Agra-directed 2026-07-22)

## Symptom / motivation

The emit core's `place(v, m)` needed the natural default probe
`m == MOD_DEFAULT` on a `Mod` whose fields include `?f32` / `?Color` /
`?Stroke` — but a struct with any optional field was not comparable, and
bare `?T == ?T` was rejected by the no-implicit-unwrap operand policy:

```sx
Mod :: struct { width: ?f32 = null; ... }
MOD_DEFAULT :: Mod.{};
m == MOD_DEFAULT
// error: cannot compare struct: field of type '?f32' has no value-equality

a : ?f32 = 1.5;  b : ?f32 = null;
a == b
// error: cannot use a value of type '?f32' as an operand: an optional does
//        not implicitly unwrap ...
```

## Decision (Agra: Option A + mixed)

Equality extracts no payload — null is a legitimate comparison value — so
defining it does not weaken the no-implicit-unwrap doctrine (0179/0185):

- `?T == ?T`: equal iff both null, or both present with `==`-equal payloads
  (payload compared by its own type's rule: IEEE for floats, content for
  strings, field-wise recursion for structs, tag-only for tagged unions).
- `?T == T` (either order): false on null, payload compare when present;
  a concrete-side literal types at the payload.
- `== null` unchanged (subsumed). Arithmetic/ordering on un-narrowed
  optionals still reject. Distinct optional types don't compare; a payload
  without value-equality keeps the rejection.
- Struct field-wise `==` recurses through optional fields with the same rule
  (the `?T` entry leaves the not-comparable list).

## Implementation

`src/ir/lower/expr.zig`: `lowerOptionalEquality` / `lowerOptionalMixedEquality`
(branch-guarded payload compare — a null payload is never read; the merge is
a block-param phi, the same shape as `lowerNullCoalesce`); an eq/neq arm in
`lowerBinaryOp` ahead of the operand-unwrap rejection; `lowerFieldEquality`'s
`.optional` arm compares instead of rejecting; the RHS target-type block
types literals at the payload for `?T == <literal>`. The shared
non-comparable message dropped the word "struct" ("cannot compare: field of
type '{s}' has no value-equality") — it now also covers bare optional
payloads.

## Regression

- `examples/optionals/0926-optionals-value-equality.sx` — bare/mixed/null
  truth tables, struct + tagged-union + NaN payloads, optional fields inside
  a struct compared against a constant, narrowed-operand path.
- `examples/optionals/0927-optionals-equality-uncomparable.sx` — array
  payload rejection + distinct optional types (compile-fail goldens).
- specs.md: §Optional Types gains "Value Equality"; §Struct Value Equality
  moves `?T` from the rejection list into the compare walk.
