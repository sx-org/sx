# 0277 — Printing an explicit-valued enum variant segfaults

> **RESOLVED** (2026-07-09)
>
> **Root cause.** `field_index(T, val)` — the reflection builtin that
> `enum_to_string` uses to recover a variant's ordinal — lowered to a bare
> `enum_tag`. For a payload-less enum with EXPLICIT values (`K :: 7`) the
> runtime tag IS the explicit value (7), not the sequential ordinal (2). The
> spec (`specs.md`, `field_index` = inverse of `field_value_int`) requires the
> ordinal. `enum_to_string` then called `field_name(T, 7)`, and
> `emitFieldNameGet` did an in-bounds GEP at index 7 on a 3-entry name array →
> out-of-bounds load of a garbage `string` struct → segfault in the formatter.
>
> **Fix.** `src/ir/lower/call.zig` `tryLowerReflectionCall`, `field_index` arm:
> when the type is a plain `enum` with `explicit_values`, reverse-map the tag to
> the ordinal with a branchless linear search (no `select` op):
> `acc = -1; for i,v: acc = acc + (i - acc) * (tag == vals[i])`. Plain enums
> without explicit values and tagged unions are unchanged (tag already equals
> the ordinal), so they still return `enum_tag` directly.
>
> **Decision.** `K :: 7` inside an enum body is an explicit-VALUED VARIANT
> (specs.md, `esc :: '\x1b'`), NOT an associated constant. Enums do not carry
> associated `::` constants — the parser folds `name :: expr` into a variant
> value. So the correct outcome is that `E.K` reads/prints as the variant `.K`
> (with underlying value 7), which it now does.
>
> **Regression test.** `examples/types/0223-types-explicit-enum-value-print.sx`.
>
> **Note (out of scope, separate pre-existing issue).** Printing a TAGGED-union
> variant with explicit tag values (`Ev :: enum { quit :: 0x100; key :: 0x300: i64 }`;
> `print("{}", Ev.quit)`) misprints (e.g. `.(72)`) but does NOT segfault. That is
> a distinct defect in the tagged-union tag/payload formatting path, untouched by
> this fix.

## Symptom

Reading/printing a payload-less enum variant that carries an explicit value
segfaults. Observed: `Segmentation fault` (exit 134). Expected: prints `.K`.

## Reproduction

```sx
#import "modules/std.sx";
E :: enum { A; B; K :: 7; }
main :: () { print("{}\n", E.K); }
```

`sx run` → segfault. Constructing/comparing the value (`x : E = E.K; if x == E.K`)
works; only the format path (`enum_to_string`) crashes. An all-explicit enum
(`enum { A :: 3; B :: 7; }`) segfaults on any variant read too.

## Investigation prompt

Suspect area: `src/ir/lower/call.zig`, `tryLowerReflectionCall`, the
`field_index` arm — it emitted `enum_tag` (raw value) instead of the sequential
ordinal. Fix: reverse-map the tag through `explicit_values` to the ordinal.
Verify: run the repro, expect `.K`; run `examples/types/0221-types-char-enum-value.sx`
and `examples/types/0122-types-flags.sx` still pass; full `zig build test`.
