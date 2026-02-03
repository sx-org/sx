# 0255 — if/else expression typing is first-branch-wins: narrow-first silently truncates

> **RESOLVED (2026-07-10).** Value-if typing now uses the same symmetric coercion-lattice join as match arms, so numeric width and float/int joins are order-independent.

## Symptom

One-line: `x := if c { small_i32 } else { big_i64 };` types the whole
expression from the FIRST branch — the i64 branch silently truncates
(prints 410065408 for 9000000000); the reverse order works. The
issue-0236 fix gave MATCH expressions a symmetric numeric join (float
beats int, wider beats narrower, order-independent); if/else kept the
old policy.

- Observed: silent truncation when the narrower numeric branch is first
  (verified on master 2026-07-04 post-0236: string/i64 mismatches DO
  diagnose now via the 0191 central guard — only the coercible-numeric
  asymmetry remains).
- Expected: the same `unifyMatchArmTypes` join match uses — symmetric,
  order-independent (the 0236 landing pinned the policy + rationale in
  examples/types/0803 and the issue-0236 banner).

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
    c := false;
    big : i64 = 9000000000;
    small : i32 = 5;
    x := if c { small } else { big };
    print("{}\n", x);    // observed: 410065408 — expected: 9000000000
}
```

## Investigation prompt

`lowerIfExpr` (src/ir/lower/ — the if-expression merge) types the
result from the first branch and coerces the second into it. Reuse the
issue-0236 machinery: `unifyMatchArmTypes` (src/ir/lower/generic.zig)
is arm-list-shaped — feed it the two branch types (mind null-arm → ?T
and diverging-branch handling — issue 0256 is the diverging case,
separate). Keep the 0191 central guard as the backstop for true
mismatches. Probe both orders for int-width pairs, int/float pairs,
null branches (`if c { 5 } else { null }` → ?i64 both orders?), nested
if-in-if, and if-expr feeding generic inference. Verify: the repro
prints 9000000000; examples with if-expressions unchanged where
already-correct; corpus green; pin in examples/types/ next to 0803.

Found by the issue-0236 fix worker (2026-07-04); narrowed on master by
the coordinator (the mismatch half is already cured by 0191).
