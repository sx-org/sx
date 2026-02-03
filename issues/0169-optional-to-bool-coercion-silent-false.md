# 0169 — optional passed where `bool` is expected silently coerces to `false` (always)

> **RESOLVED** (scoped to `?T → bool`, `T ≠ bool`). The "Optional → Concrete
> unwrap" classify rule treated `?i64 → bool` as unwrap+narrow (both i64 and bool
> are builtin), silently yielding `false`. specs.md defines no implicit
> optional→bool conversion, so the fix REJECTS it: `src/ir/conversions.zig` adds
> an `optional_to_bool_reject` plan (when `dst == bool` and `child ≠ bool`);
> `src/ir/lower/coerce.zig` emits a located diagnostic ("…use '!= null'…")
> instead of a constant false. Covers arg / field-init / return (all share
> `coerceMode`). `if opt` presence-test (issue 0164) is a separate path,
> untouched. Verified by 3 adversarial reviews; suite 789/0. Regression:
> `examples/diagnostics/1199-diagnostics-optional-to-bool.sx` + a
> `conversions.test.zig` unit test. NOTE: review surfaced a larger sibling
> surface — the whole implicit `?T → concrete` unwrap family (incl. the
> `?bool → bool` cell still allowed here) silently miscompiles a NULL optional to
> garbage — filed as **0179** (design-touching: needs the flow-narrowing
> decision).


## Symptom

Passing an optional (`?T`) to a `bool` parameter (or any bool-typed position:
bool field initializer, `-> bool` return) compiles WITHOUT a diagnostic and
silently yields `false` for EVERY optional — present or null alike. Silent
miscompile.

This is inconsistent with `if opt` / `while opt`, which (after issue 0164)
correctly test the has_value flag. The argument/field-coercion path does not.

## Reproduction

```sx
#import "modules/std.sx";
takes_bool :: (b: bool) { if b { print("true\n"); } else { print("false\n"); } }
main :: () {
  a : ?i64 = 42;
  n : ?i64 = null;
  takes_bool(a);   // prints "false"  — should be a type error, or "true" (present)
  takes_bool(n);   // prints "false"  — (correct only by accident)
}
```

Expected: EITHER a compile-time type error (no implicit optional→bool
coercion), OR — if implicit coercion is intended — `true` for the present
optional and `false` for null, matching `if opt` semantics. Observed: always
`false`, no diagnostic.

## Investigation prompt

Decide the intended semantics first (check `specs.md` for whether optional→bool
is a legal implicit coercion):

- If NOT legal: the call-argument / assignment type-checker
  (`src/ir/expr_typer.zig` / the coercion/check path) must REJECT an optional in
  a bool-typed position with a located diagnostic — not silently produce a
  zero/false. Find where the bool target type accepts the optional operand and
  emit `self.diagnostics.addFmt(.err, span, ...)`.
- If legal (consistent with `if opt`): the coercion must lower to the
  optional's has_value test (reuse `optional_has_value`), not a constant/garbage
  `false`. The silent always-`false` is the rejected silent-fallback pattern.

Whichever is correct, the current always-`false` is wrong. Verify with the repro
(present → `true` or a type error; null → `false` or a type error). Add a
regression: an `examples/optionals/09xx-...` if coercion is legal, or a
`examples/diagnostics/11xx-...` negative test if it's rejected.
