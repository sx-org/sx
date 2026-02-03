# 0260 — `==` between DISTINCT struct types with identical layout is silently accepted

> **RESOLVED (2026-07-10).** Struct equality now requires identical nominal TypeIds before the field-wise comparison and diagnoses distinct same-layout types.

## Symptom

One-line: `x : S` and `y : T` where S and T are separate `::` struct
decls with identical `{a: i64, b: i64}` layout — `x == y` compiles and
compares field-wise (prints "eq"), with no type-mismatch diagnostic.

- Observed: cross-type comparison accepted (pre-existing; unchanged by
  the issue-0245 field-wise rework — operands resolve before
  lowerStructEquality sees them).
- Expected: per specs.md §Struct Types, struct types are NOMINAL —
  comparing values of two different nominal types should be a type
  error ("cannot compare 'S' and 'T'"), same as assigning S to T
  (probe: does `y = x` cross-assign diagnose? mirror whichever policy
  assignment has — consistency is the requirement).

## Reproduction

```sx
#import "modules/std.sx";
S :: struct { a: i64 = 0; b: i64 = 0; }
T :: struct { a: i64 = 0; b: i64 = 0; }
main :: () -> i32 {
    x : S = .{ a = 1, b = 2 };
    y : T = .{ a = 1, b = 2 };
    if x == y { print("eq\n"); }   // expected: compile error; observed: eq
    0
}
```

## Investigation prompt

FIRST probe the assignment/param-passing policy for distinct
same-layout structs (`y = x`, `f(x)` where f takes T) — if those
diagnose (nominal typing enforced), the comparison path is the odd one
out: add an operand-type identity check in lowerBinaryOp's equality arm
(src/ir/lower/expr.zig, where the 0245 lowerStructEquality dispatches)
before the field-wise walk — "cannot compare values of distinct types
'S' and 'T'". If assignment ALSO silently coerces (structural typing in
practice), this is a spec-level decision — take it to specs.md §Struct
Types and make comparison + assignment consistent either way. Check
tuples for contrast (structural by design — cross-tuple-type compare of
same shape is legal). Verify: policy consistent across ==, =, and call
args; corpus green (watch for accidental cross-type compares in
library/ that a new rejection would surface — fix them, don't weaken).

Found by the adversarial review of the issue-0245 fix (2026-07-05);
pre-existing (0191-adjacent).
