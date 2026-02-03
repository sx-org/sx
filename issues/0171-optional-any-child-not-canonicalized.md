# 0171 — `?any` optional child is a non-canonical `any` TypeId (box-into-any rule misses, value silently discarded)

> **RESOLVED — NOT A BUG (wrong casing in the repro).** The type-erased value
> type is spelled **`Any`** (capital A), not lowercase `any` (specs.md §Types;
> `src/ir/type_resolver.zig`: `if name == "Any" return .any`). Lowercase `any`
> is an UNDEFINED type name that resolves to an empty-struct stub — which is why
> `?any` appeared to "silently discard" / mis-resolve. The real `Any` optional
> child works correctly: `?Any` round-trips — `x : ?Any = 42` tests present, a
> `null` one tests absent, and `x!` unwraps. There is no `Any`-TypeId
> canonicalization bug. (The confusing diagnostic for a lowercase `?any` —
> "payload type is 'any'" instead of "unknown type 'any'" — is a minor
> undefined-name-in-optional-child message-quality nit, not this issue.)

## Symptom

An optional whose child is `any` (`?any`) is broken. Baseline (before the issue
0165 fix) silently DISCARDED the boxed value: `x : ?any = 42; v := x!` yields an
empty box `any{}`, not `42` — the payload is lowered as a zero-size `{}`. After
the 0165 fix the same code now produces a clean type-mismatch diagnostic
(`cannot assign a value of type 'i64' to optional '?any': its payload type is
'any'`), which is strictly better than silent corruption but still means `?any`
does not work.

## Root cause (from adversarial review of issue 0165)

The box-into-`any` coercion rule (`src/ir/conversions.zig` ~line 57) keys on the
BUILTIN `.any` enum TypeId. But an optional's child `any` is a SEPARATELY
interned TypeId (observed `@enumFromInt(246)`, type-name `"any"`) that is NOT
identity-equal to the builtin `.any`. So `classify(i64, child_any)` falls through
to `.none`, returns the value unchanged (`i64`), and the wrap is invalid. The
`any` type is not being canonicalized to the builtin TypeId when it appears as an
optional child.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  x : ?any = 42;
  v := x!;
  print("{}\n", v);   // expected: a boxed 42; baseline yields empty any{}
}
```

## Investigation prompt

Canonicalize `any` as an optional child (and likely any other compound position)
to the builtin `.any` TypeId at type-resolution/interning time, so the
box-into-any rule in `src/ir/conversions.zig` classifies correctly and `?any`
round-trips. Find where the optional child type is resolved/interned
(`src/ir/types.zig` `optionalOf` / the type resolver) and ensure an `any` child
maps to the canonical builtin TypeId rather than a fresh interned copy.
Alternatively, make the box-into-any classifier compare by type-KIND
(`info == .any`) rather than TypeId identity — but canonicalization is the more
robust fix (it also fixes `==`, `size_of`, and any other identity check on the
`any` child). Verify the repro round-trips a boxed value; add an
`examples/types/01xx-optional-any.sx` regression. Low priority — `?any` is used
nowhere in `library/` or `examples/`.
