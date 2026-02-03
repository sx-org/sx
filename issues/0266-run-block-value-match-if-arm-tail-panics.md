# 0266 — block-form `#run` with a value-match tail (if-expr arm) panics "unresolved type"

> **RESOLVED (2026-07-10).** Match-expression inference is now available through `ExprTyper`, including nested if-expression arms, so block-form `#run` receives a concrete unified result type.

## Symptom

One-line: a block-form `#run { ...; <value-match with an if-expr arm> }`
panics `unresolved type reached LLVM emission` — the runtime-fn form and
the `#run fn()` form of the identical code both work (→ 42).

- Observed: backend panic, exit 134.
- Expected: 42 (or a clean diagnostic).

Pre-existing (panics on the pre-0259 commit too); specific to the
block-`#run` form. Distinct from 0259 (which fixed the nested-if tail in
block-value lowering); this is the value-MATCH tail with an if-expr arm,
where inline-comptime block-path type inference returns `.unresolved`.

## Reproduction

```sx
#import "modules/std.sx";

K :: #run {
    b := 2;
    c := true;
    if b == { case 1: 100; else: if c { 42 } else { 0 }; }
};

main :: () -> i32 {
    print("{}\n", K);   // panic: unresolved type reached LLVM emission
    0
}
```

Contrast (both work → 42): the same body inside a runtime fn, and
`K :: #run pick();` where `pick` is a fn returning that match.

## Investigation prompt

The inline-comptime BLOCK path (the `#run { ... }` form — grep the
comptime/inline-block lowering that differs from the `#run fn()` path)
infers the tail value-match's result type as `.unresolved` when an arm
is itself an if-expr. The 0259 fix set `force_block_value` for a block's
tail statement so a nested-IF tail lowers in value position; the
value-MATCH tail with an if-arm needs the arm result types unified (the
0236 `unifyMatchArmTypes` machinery) to flow through the inline-block
type inference too. Trace where the block-form `#run` types its tail vs
the fn-form (which routes through lowerValueBody/lowerBlockValue and
works), and route the block form through the same match-result-type
inference. Verify: the repro prints 42 (or diagnoses); the 0259
nested-if regression (examples/comptime/0657) stays green; runtime + fn
forms unchanged; corpus green; regression under examples/comptime/.

Found by the issue-0259 fix worker (2026-07-05); pre-existing.
