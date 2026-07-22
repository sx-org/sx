# 0342 — `case i64:` (concrete builtin arm) never matches in an `inline if T ==` static type dispatch

> **RESOLVED (2026-07-22).** `staticTypeMatchesCategory`
> (src/ir/lower/comptime.zig) returned false unconditionally for a builtin
> subject whose arm name was not one of the fixed CATEGORY names — concrete
> builtin arms (`case i64:`, `case u8:`, `case f32:` …) were unreachable in
> the comptime-pruned fold, silently taking `else:`. `case string:` worked
> only because "string" doubles as a category. Fix: resolve the arm
> spelling via `resolveTypePrimitive` and compare before bailing.
> Regression: `examples/comptime/0667-comptime-inline-if-concrete-builtin-arm.sx`.

## Symptom

```sx
which :: (v: $K) -> i64 {
    n := 0;
    inline if K == { case i64: { n = 1; } case string: { n = 2; } else: { n = 3; } }
    n
}
main :: () {
    x : i64 = 7;
    print("{} {}\n", which(x), which("hi"));   // printed "3 2" — expected "1 2"
}
```

Both the inline-constraint form (`v: $K`) and the leading `$T: Type` form
mis-select. Concrete USER-type arms (`case MyEnum:`) and category arms
(`case struct:`) match correctly; only concrete BUILTIN spellings fall
through. The RUNTIME type switch (0889, over `type_of` values) handles
builtin arms correctly — the static fold and the runtime switch disagreed.

## Impact

Any comptime kind-match over builtins silently takes the wrong arm —
found blocking the UI `keyed(id: $K)` dispatch (i64 | string | Key), where
the i64 arm fell to the `else: compile_error` rejection.
