# 0280 — Printing a payload-less variant of an explicit-tag tagged union misprints

> **RESOLVED** (2026-07-09)
>
> **Root cause.** `field_index(T, val)` — the reflection builtin
> `enum_to_string` (fmt.sx) uses to recover a variant's ordinal — reverse-mapped
> the runtime tag to the ordinal only for a PLAIN `enum` with `explicit_values`
> (the 0277 fix). A TAGGED UNION (an enum with payload-carrying variants) whose
> variants carry explicit tag values stores those explicit values in a SEPARATE
> field, `TaggedUnionInfo.explicit_tag_values`, which the `field_index` arm never
> consulted — so it returned the raw tag (`quit` = 0x100 = 256) instead of the
> ordinal (0). `enum_to_string` then called `field_name(Ev, 256)`, whose
> `field_name_get` did an out-of-bounds GEP on the 2/3-entry name array → a
> garbage (empty) `string` → `Ev.quit` printed `.(<?>)` instead of `.quit`.
> (Plain enums crashed under 0277 because the enum name array was indexed
> directly; the tagged-union struct's larger backing happened to yield an empty
> string rather than a segfault — same defect, milder symptom.)
>
> **Fix.** `src/ir/lower/call.zig` `tryLowerReflectionCall`, `field_index` arm:
> extend the tag → ordinal reverse-map to tagged unions. Extract the explicit
> value slice from EITHER kind (`enum.explicit_values` or
> `tagged_union.explicit_tag_values`) and run the same branchless linear reverse
> lookup. The accumulator is now seeded with the RAW TAG (the identity) rather
> than `-1`: the spec-inverse of `field_value_int` maps an explicit value back to
> its ordinal, but when the runtime tag is already an ordinal (no explicit value
> equals it) the identity is the correct answer — and, unlike a `-1` sentinel, it
> can never index `field_name` out of range (which would crash). This keeps the
> plain-enum 0277 path bit-identical (every plain-enum value has an explicit tag,
> so a match always fires before the identity seed matters).
>
> **Verified.** `Ev.quit` → `.quit`; payload-less variants of a tagged union with
> non-zeroth explicit tags (`Sig.term`/`Sig.interrupt`) print correctly; the
> explicit value is still read by `xx` (256, 15); auto-tag tagged unions and the
> plain-enum 0277 case (examples/types/0223) are unchanged. Full corpus green.
>
> **Regression test.** `examples/types/0224-types-tagged-union-explicit-tag-print.sx`.
>
> **Note — separate, distinct bug filed as 0281.** While fixing this I found
> that CALL-shaped construction of a PAYLOAD-CARRYING variant of an explicit-tag
> tagged union (`Ev.key(payload)`) stores the ORDINAL as the tag instead of the
> explicit value, while `match` (and the struct-literal `.key.{…}` construction
> form) use the explicit value — so a payloadful `match` falls through to its
> unreachable default. That is a construction/match consistency bug in a
> different area (`resolveVariantIndex` vs `resolveVariantValue` at the call
> sites in `call.zig`), independent of this formatting fix. Filed as issue 0281;
> NOT addressed here. The identity-seed above keeps the FORMAT path robust to
> both encodings in the meantime.

## Symptom

Printing a payload-less variant of a tagged union (an enum with payload
variants) whose variants carry explicit tag values mis-prints. Observed:
`Ev.quit` prints `.(<?>)`. Expected: `.quit`.

## Reproduction

```sx
#import "modules/std.sx";
Ev :: enum { quit :: 0x100; key :: 0x300: i64; }
main :: () { print("{}\n", Ev.quit); }
```

`sx run` → `.(<?>)`. `key :: 0x300: i64` makes `Ev` a tagged_union; the
payload-less `quit :: 0x100` stores its explicit tag value (256) at runtime, and
the reflection reverse-map that recovers the ordinal was plain-enum-only.

## Investigation prompt

Suspect area: `src/ir/lower/call.zig`, `tryLowerReflectionCall`, the
`field_index` arm — it reverse-mapped only `enum.explicit_values`, not
`tagged_union.explicit_tag_values`. Fix: extend the reverse-map to tagged
unions. Verify: run the repro, expect `.quit`; run
`examples/types/0223-types-explicit-enum-value-print.sx` (plain-enum 0277) still
prints right; full `zig build test`.
