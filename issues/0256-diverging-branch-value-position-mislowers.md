# 0256 — a diverging branch/arm in VALUE position mis-lowers ("Terminator found in the middle of a basic block")

> **RESOLVED (verified 2026-07-10).** Current control-flow lowering excludes diverging arms from the value join and does not add merge edges after terminators; both branches of the filed repro return correctly.

## Symptom

One-line: `x := if cond { 1 } else { return 7; };` — a value-position
if/else (or match) with one DIVERGING branch (return/raise) — emits
"Terminator found in the middle of a basic block" (LLVM-level error);
the match variant post-issue-0236 gets a misleading "match arms have
incompatible types: 'i64' vs 'void'" diagnostic instead (located, but
wrong story).

- Observed: verifier-level error (if/else) / misleading arm-mismatch
  diagnostic (match).
- Expected: a diverging branch contributes NO type to the join — the
  expression takes the other branch's type and the diverging branch's
  terminator ends its block properly (standard sum-type-of-divergence
  handling; check what specs.md says about `raise` in expression arms —
  the ERR stream's `or`/`catch` machinery already handles diverging
  fallbacks, mirror it).

## Reproduction

```sx
#import "modules/std.sx";
f :: (c: bool) -> i64 {
    x := if c { 1 } else { return 7; };   // Terminator in middle of block
    return x;
}
main :: () { print("{}\n", f(true)); }    // expected 1; f(false) == 7
```

Match variant: `x := if e == { case .a: { 1 } case .b: { return 7; } };`
— post-0236 diagnoses "i64 vs void" (misleading).

## Investigation prompt

Two halves: (1) the block/terminator plumbing — the value-merge lowering
(lowerIfExpr / lowerMatch in src/ir/lower/) appends the merge jump after
a branch that already terminated (the `return` emitted its ret); a
terminated branch must skip the merge edge (check how STATEMENT-position
if/else handles a returning branch — that works — and mirror the
"block already terminated" test). (2) the typing — a diverging arm
contributes noreturn/no type to the 0236 `unifyMatchArmTypes` join and
to lowerIfExpr's result typing (0255 will route if/else through the
same join — coordinate; noreturn-arm handling belongs in the shared
helper). Probe: return/raise in either branch, both branches diverge
(the whole expr is noreturn — statement-position semantics), diverge
inside nested if-in-match, `or return`-style ERR forms for parity.
Verify: the repro prints 1 (and 7 for f(false)); the match variant
works; 0236's mismatch diagnostics unaffected; corpus green.

Found by the issue-0236 fix worker (2026-07-04); pre-existing on both
constructs.
