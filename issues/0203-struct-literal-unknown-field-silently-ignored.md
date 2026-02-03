# issue 0203 — struct literal silently ignores an unknown named field

> ✅ **RESOLVED.** `lowerStructLiteral`
> ([src/ir/lower/expr.zig](../src/ir/lower/expr.zig)) reordered named fields by
> matching each `name = expr` against the struct's declared fields, but when a
> name matched NOTHING it just lowered the value and dropped it — no diagnostic.
> A typo'd field, or a field removed by an `inline if OS` branch, shipped
> silently. Fix: in the named-literal path, emit `field 'X' not found on type
> 'T'` (mirroring the field-READ error) for any explicit `name = expr` that names
> no real field. Punned bare-ident shorthand that misses a field is unaffected —
> it was already reclassified as a positional element by the `has_names` guard.
> Regression test:
> [examples/diagnostics/1200-diagnostics-unknown-struct-field.sx](../examples/diagnostics/1200-diagnostics-unknown-struct-field.sx).

## Symptom

A struct literal naming a field the struct does not have **compiles clean**; the
unknown field's value is lowered for its side effects, then silently discarded.

- **Observed:** `.{ x = 1, bogus = 99, y = 2 }` on `struct { x; y }` → exit 0,
  builds `{x=1, y=2}`.
- **Expected:** compile error `field 'bogus' not found on type 'P'`.

## How it was found

Surfaced under HTTPZ C5 while auditing `examples/socket/1630-socket-nonblocking.sx`.
After C3a made `SockAddr` per-OS (darwin's leading `sin_len` dropped on linux),
1630 still built its address with the old `.{ sin_len = 16, ... }` literal. On a
linux target that `sin_len` field no longer exists — yet the example compiled,
because the unknown field was silently ignored. The bug was MASKING the
incomplete C3a migration: the stale `sin_len` should have been a hard error on
linux, forcing the migration to `sockaddr_in`.

## Reproduction

```sx
P :: struct { x: i64 = 0; y: i64 = 0; }
main :: () -> i32 {
    p : P = .{ x = 1, bogus = 99, y = 2 };   // 'bogus' is not a field of P
    return xx (p.x + p.y);                    // compiles; returns 3 (bug)
}
```

Before the fix: exit 0. After: `error: field 'bogus' not found on type 'P'`.
