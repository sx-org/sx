# 0315 — Type-category match: a BUILTIN concrete arm (`case i64:`) is silently dead

> **RESOLVED** (2026-07-18, same day, Agra-ruled). Root cause: the
> `is_type_match` arm resolution (src/ir/lower/control_flow.zig) sent
> non-category names through `resolveTypeCategoryTags`'s `findByName`
> fallback — the user-type name map, blind to builtins — yielding zero
> tags and a silently dead arm. Fix: the branch now mirrors the
> any-switch — the visibility gate (`headTypeGate`) keeps handling
> user-type names, category keywords keep the tag-set path (an empty
> category set stays a legal never-matching arm), and everything else
> resolves through `resolveTypeArg`, which handles builtins AND
> composite type expressions (`case ?i64:` / `case []u8:` now work
> here) and diagnoses unknown names loudly; value patterns get the
> pointed refusal. Regression tests:
> `examples/types/0889-types-type-match-concrete-arms.sx` (builtin
> claims ahead of its category; composites; single-type builtins
> unchanged) and
> `examples/diagnostics/1258-diagnostics-type-match-value-pattern.sx`.
> specs §Type Category Matching note extended.

## Symptom

In the runtime type-category match on a `Type` value, an arm naming a
builtin type — `case i64:`, `case u8:`, `case f32:` — resolves to ZERO
tags and silently never fires; the value falls through to a later
category arm or `else:`. Observed: `conc(i64)` below answers `"int"`
(expected `"i64"` — a concrete arm before the category that contains
it should claim first, and does for USER types like `case Point:`).
The `any`-subject TYPE SWITCH handles the same arm correctly (its
concrete path goes through `resolveTypeArg`, the full resolver).
`string` / `bool` / `void` are unaffected (they resolve as fixed
single-type categories).

## Reproduction

```sx
#import "modules/std.sx";

conc :: (t: Type) -> string {
    if t == {
        case i64: return "i64";
        case int: return "int";
        else:     return "other";
    }
    "unreached"
}

main :: () {
    print("{}\n", conc(i64));   // "int"   — expected "i64"
    print("{}\n", conc(u8));    // "int"   — correct (category)
    print("{}\n", conc(f64));   // "other" — correct
}
```

With the `case int:` arm removed, `conc(i64)` answers `"other"` — the
builtin concrete arm is dead either way, it does not even claim its own
tag. (Since the first-wins claim set landed with 0314, the dead arm
additionally means NO unreachable-arm diagnostic fires for it: the arm
has zero raw tags, which the guard deliberately skips.)

## Suspected area

`src/ir/lower/control_flow.zig`, the `is_type_match` arm-resolution
branch (~1365): a non-category name goes `headTypeGate(name)` →
`.proceed` → `resolveTypeCategoryTags(name)`, whose specific-name
fallback is `types.findByName(name_id)` — the type-table name lookup
registers USER types only; builtin names (`i64`, `u8`, …) are not in it,
so the arm resolves to an empty tag list with no diagnostic. Compare the
`is_any_switch` branch directly above it, which routes non-category arms
through `self.resolveTypeArg(pat)` (handles builtins and composite type
expressions, and diagnoses unknown names).

## Fix sketch

In the `is_type_match` branch, resolve a non-category arm like the
any-switch does: try `resolveTypeArg` (or extend the fallback to map
builtin type names to their `TypeId`s) so `case i64:` yields the one
builtin tag, claims it first-wins, and an arm that resolves to nothing
is a LOUD unknown-type error instead of an empty set. Composite type
expressions (`case []u8:` / `case *Point:` / `case ?i64:`) in
type-match arms should get whatever ruling falls out — today they are
likewise unrecognized by `isTypeCategoryMatch`'s pattern scan.

## Investigation prompt

> In ~/projects/sx: fix issue 0315. In the runtime type-category match
> (`src/ir/lower/control_flow.zig`, the `is_type_match` branch ~1365), a
> builtin concrete arm (`case i64:`) resolves through
> `resolveTypeCategoryTags`'s `findByName` fallback, which only knows
> user types — the arm gets zero tags and is silently dead. Route
> non-category arm names through the same resolution the any-switch
> branch uses (`resolveTypeArg`, which handles builtins and diagnoses
> unknowns) so `case i64:` claims its tag first-wins ahead of
> `case int:`, and a name that resolves to nothing errors loudly. Run
> the repro above (expect "i64" / "int" / "other"), pin it as a types/
> example, and check specs §Type Category Matching documents concrete
> arms.
