# 0262 — a closure value shadowing a top-level fn is CALLED with the fn's return type

> **RESOLVED (verified 2026-07-10).** Current call planning takes both dispatch and result type from the callable local shadow; the filed closure returns and prints 7.

## Symptom

One-line: `out :: () -> void {}` at module scope plus a local
`out := () => 7;` — calling `out()` dispatches through the LOCAL closure
(correct, per issue 0217) but types the call against the TOP-LEVEL FN's
return type (`void`), so the i64-producing closure call LLVM-verify-fails
("i64 ccall fed to a void-typed use").

- Observed: LLVM verification failure (identical on pre-0251 master —
  pre-existing, 0217-family).
- Expected: the call's result type comes from the LOCAL binding's
  closure type (i64), consistent with the dispatch decision.

## Reproduction

```sx
#import "modules/std.sx";

out :: () -> void {}

main :: () -> i32 {
    out := () => 7;
    v := out();          // LLVM verify failure: return type taken from the FN
    print("{}\n", v);    // expected 7
    0
}
```

## Investigation prompt

The issue-0217 fix routes the DISPATCH through callableLocalShadow /
indirectCallThroughLocal, but the call's RESULT TYPE is resolved
earlier/elsewhere against fn_ast_map (grep lowerCall's return-typing —
likely the plan-side return typing in src/ir/calls.zig or the
early return-type resolution consulting fn_ast_map by name before the
shadow check). Apply the same lookupNearest-first rule to the
return-type resolution: a callable local binding's .function/.closure
ret wins over the same-named top-level fn's. Probe: the repro; the
reverse (fn returns i64, closure returns void); shadow in call-arg
position (`use(out())`); UFCS forms; generic callers. Verify: the repro
prints 7; no-shadow calls unchanged; 0217's regression examples
(modules/1618) green; corpus green; extend examples/closures/0318 or
modules/1618 with the return-type leg.

Found by the issue-0251 fix worker (2026-07-05); pre-existing,
0217-family (dispatch fixed, return-typing not).
