# 0175 — positional struct literal with a VARIABLE element silently zeroes the field

> **RESOLVED.** Root cause was named-vs-positional misclassification: the parser
> PUNS a bare-ident element `.{ x, … }` into a named field `x = x` (the legit
> `Vec4.{ w, z }` shorthand), so a positional-with-variable literal arrived as a
> spurious "named" literal and the named branch left every field at its default.
> Fix (`src/ir/lower/expr.zig`): `has_names` now consults the struct definition —
> a punned bare-ident whose name matches no declared field reclassifies the whole
> literal as positional; positional field coercion now uses the lowered value's
> actual `getRefType` (not a re-inferred `src_ty`) and steers per-field
> `target_type`. Legit shorthand, named, mixed, generic, forward-ref, and nested
> cases all verified unbroken by 4 adversarial reviews. Regression:
> `examples/types/0200-types-positional-struct-literal-variable-element.sx`.

## Symptom

A positional struct literal `S.{ x, ... }` whose element is a VARIABLE reference
(not a literal constant) silently stores `0` instead of the variable's value. The
NAMED form `S.{ a = x, ... }` works correctly. Silent miscompile. Pre-existing
(reproduces on clean master; surfaced while fixing issue 0168).

## Reproduction

```sx
#import "modules/std.sx";
P :: struct { a: i64 = 0; b: i64 = 0; }
main :: () {
  x := 5;
  p : P = .{ x, 2 };           // positional, variable first element
  print("{} {}\n", p.a, p.b);  // prints "0 0" — WRONG, expected "5 2"
}
```

Expected: `5 2`. Observed: `0 0` (the variable element zeroed; note even the
`2` literal field is wrong here — the whole positional path mis-coerces once a
variable element is present). The named form `P.{ a = x, b = 2 }` prints `5 2`.

A related crash: `[2]P = .{ .{ x, 2 }, .{ 3, 4 } }` with an i32 variable `x`
aborted the LLVM verifier on master (`Invalid InsertValueInst operands`); after
the issue 0168 fix it no longer crashes but still prints the residual `0 …` for
the variable element — confirming the root cause is the positional-element
coercion, independent of 0168.

## Investigation prompt

`src/ir/lower/expr.zig` `lowerStructLiteral` positional branch, the field
coercion at the `i < struct_fields.len` path (~expr.zig:235-237): it computes
`src_ty = self.inferExprType(fi.value)` then `coerceToType(val, src_ty,
struct_fields[i].ty)`. For a variable reference element, `inferExprType` appears
to return a wrong/narrower type, causing `coerceToType` to mis-narrow/zero the
value. Investigate why `inferExprType(variable_ref)` disagrees with the value's
actual `getRefType`, and prefer coercing from the lowered value's real type
(`self.builder.getRefType(val)`) rather than a re-inferred source type — or fix
the inference for a bare variable element. Verify: the repro prints `5 2`; a
positional literal mixing variable + literal + expression elements; with field
types needing real coercion (i32 var → i64 field, concrete var → protocol field).
Add an `examples/types/01xx-positional-struct-literal-variable-element.sx`
regression.
