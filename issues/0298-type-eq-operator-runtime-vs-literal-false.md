# 0298 — `==` between a runtime `Type` and a type literal is always false

## Symptom

Comparing a RUNTIME `Type` value (e.g. `type_of(av)` on an `any`) against a
compile-time type literal with the `==` operator yields `false` even when
the types are identical — while `type_eq(...)` on the same operands is
`true`, and `==` between two runtime `Type` values is also correct.

- Observed: `type_of(av) == i64` → `false` (av boxing an i64);
  `type_of(av) == T` inside a generic (`$T: Type` bound to i64) → `false`.
- Expected: `true` — one equality semantics for `Type` operands regardless
  of which side is a literal/comptime constant.
- Control: `type_eq(type_of(av), i64)` → `true`;
  `t := type_of(av); u := type_of(av); t == u` → `true`.

Silent-wrong-value class: runtime type dispatch written with the natural
operator quietly takes the wrong branch.

## Reproduction

```sx
#import "modules/std.sx";

main :: () {
    av : any = 42;
    print("{}\n", type_of(av) == i64);            // false — expected true
    print("{}\n", type_eq(type_of(av), i64));     // true (control)
    t := type_of(av);
    u := type_of(av);
    print("{}\n", t == u);                        // true (control)
}
```

## Investigation prompt

Suspected area: the binary-`==` lowering for `Type` operands
(src/ir/lower/expr.zig `lowerBinaryOp` / the comparison arm) when exactly
one side is a type LITERAL (an identifier resolving to a type, lowered via
`constType`) and the other a runtime `Type` (`.type_value`-typed
expression). Likely either (a) the literal side lowers through a different
representation than the runtime tag the other side carries (TypeId index vs
anyTag-normalized value — compare with what `rt_type_eq` and 1a's runtime
`type_of` emit), or (b) the comparison constant-folds against the STATIC
type of the runtime operand. `type_eq` (which folds statically only when
both args are static and otherwise emits `rt_type_eq`) is the known-good
reference — `==` on Type operands should route through the same dispatch.

Verification: the repro prints true/true/true; add a regression example
(comptime or types block) covering literal==runtime both orders, $T-bound
generic comparisons, and the != dual; `zig build test` green.
