# 0174 — positional literal for a TUPLE target does not coerce elements (same corruption class as 0168)

> **RESOLVED.** `lowerStructLiteral`'s positional branch coerced struct fields
> and array/vector elements but not TUPLE targets (a tuple is neither — empty
> `struct_fields`, `.unresolved` `array_elem_ty`), so a bare element was stored
> raw into the field slot (a `{T,i1}` optional read back absent). Fix
> (`src/ir/lower/expr.zig`): compute `tuple_fields` from `TupleInfo.fields` and
> fold it into a unified `elem_target` (`struct_fields[i].ty` → `tuple_fields[i]`
> → `array_elem_ty`) that steers per-element `target_type` and drives
> `coerceToType`. Verified across optional/int→float/protocol/slice/enum/nested
> tuple elements + named tuples by 4 adversarial reviews. Regression:
> `examples/types/0199-types-tuple-positional-optional-element.sx`.

## Symptom

A positional literal `.{ a, b }` whose target is a TUPLE does not coerce its
elements to the tuple's field types. When a field type is an optional (or any
type the element doesn't already match), the raw element is stored into the
field slot with the wrong shape — e.g. a bare `i64` into a `{i64,i1}` optional
slot — so the value reads back wrong (a present optional reads as absent). Silent
miscompile. This is the tuple analogue of issue 0168 (which fixed the
array/vector case).

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  t : (?i64, f64) = .{ 7, 3.0 };
  print("{}\n", t.0 ?? -1);   // prints "-1" — WRONG, expected 7
}
```

Expected: `7` (field 0 is a present `?i64`). Observed: `-1` (read as absent).

## Investigation prompt

`src/ir/lower/expr.zig` `lowerStructLiteral` positional branch. Issue 0168 added
element coercion for array/vector targets via `array_elem_ty`, but a TUPLE target
is neither a struct (so `getStructFields` returns empty → the `i < struct_fields.len`
field-coercion path doesn't fire) nor array/vector (so `array_elem_ty` is
`.unresolved`). Extend the positional branch to recognize a `.tuple` target:
fetch the tuple's per-field types (`TupleInfo.fields`) and coerce element `i` to
`fields[i]` (mirroring the struct-field path, which uses `struct_fields[i].ty`).
Set `target_type` per element so a nested untyped literal element resolves too.
Follow the no-silent-fallback rule. Verify: the repro prints `7`; a tuple with
mixed element coercions (int→float, concrete→protocol, array→slice) initializes
correctly; named tuples `(x: ?i64, y: f64)` too. Add an
`examples/types/01xx-tuple-positional-optional-element.sx` regression.
