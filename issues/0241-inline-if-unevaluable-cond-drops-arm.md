# 0241 — module-scope `inline if` with an unevaluable condition silently drops the whole conditional

> **RESOLVED (2026-07-10).** The module flatten pass no longer silently drops an unevaluable `inline if`; it emits a located diagnostic naming the supported OS/ARCH/POINTER_SIZE comparison forms.

## Symptom

One-line: a top-level `inline if FLAG { ... }` whose condition is not one
of the supported comptime equalities (`OS ==`, `ARCH ==`,
`POINTER_SIZE ==`) is silently DROPPED by the flatten pass — every decl
in the arm (fns, consts, asm) vanishes with no diagnostic.

- Observed: `evalComptimeCondition` returns null for a bare identifier /
  const-bool condition and `flattenComptimeConditionals` drops the whole
  conditional (documented in a code comment at src/imports.zig:48-56).
- Expected: either bare const-bool comptime conditions are SUPPORTED
  (evaluate through the const folder that already serves `OS ==` — a
  `FLAG :: true;` is comptime-known), or the unevaluable condition is a
  located diagnostic ("cannot evaluate this 'inline if' condition at
  module scope — only OS/ARCH/POINTER_SIZE equality is supported") —
  never a silent drop of live declarations.

Pre-existing; surfaced by the issue-0194 review's probing (2026-07-03).
NOT the 0194 bug (that was the taken-arm asm node kind; this is the
condition evaluator's coverage).

## Reproduction

```sx
#import "modules/std.sx";

FLAG :: true;

inline if FLAG {
    helper :: (x: i64) -> i64 { return x + 1; }
}

main :: () -> i32 {
    print("{}\n", helper(41));   // error: unresolved 'helper' — arm dropped
    0
}
```

## Investigation prompt

`evalComptimeCondition` (src/imports.zig ~48-56) pattern-matches only
the three builtin equality forms. Decide the scope: (a) extend it to
evaluate bare identifiers / simple boolean exprs over module consts
(reuse the const folders in src/ir/program_index.zig — the 0192 fix
made qualified consts foldable there); (b) at minimum, when the
condition is unevaluable, emit a located diagnostic instead of dropping.
(b) is mandatory either way per the no-silent-drop rule; (a) is the
feature call — check specs.md §comptime for what `inline if` promises
at module scope. Verify: the repro either prints 42 (a) or diagnoses
(b); OS/ARCH/POINTER_SIZE forms unchanged (the whole corpus gates on
them); regression example under examples/comptime/ or diagnostics/.

Found by the adversarial review of the issue-0194 fix (2026-07-03).
