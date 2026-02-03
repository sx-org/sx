# 0235 — a comptime param (`$k`) used inside a call ARGUMENT fails "unresolved 'k'"

## Symptom

One-line: referencing a comptime value param inside the argument
expression of a nested call — `fwd :: ($k: i64, x: i64) -> i64 { return
add1(x + k); }` — fails with `unresolved 'k'`; using `k` outside a call
argument (e.g. `return x + k;`) works.

- Observed: "unresolved 'k'" at the argument expression.
- Expected: `$k` is in scope throughout the fn body, including inside
  nested call arguments.

No failable/error involvement — reproduces with a plain helper.

## Reproduction

```sx
#import "modules/std.sx";

add1 :: (v: i64) -> i64 { return v + 1; }

fwd :: ($k: i64, x: i64) -> i64 {
    return add1(x + k);      // error: unresolved 'k'
}

main :: () -> i32 {
    print("{}\n", fwd(10, 31));   // expected 42
    0
}
```

Contrast: `return x + k;` (no nested call) works; `add1(x) + k` — probe.

## Investigation prompt

Comptime value params are bound during the inlined-comptime lowering
(the `$` param path — src/ir/lower/call.zig's comptime dispatch and/or
the inline-expansion body lowering). The argument-expression lowering of
a nested call inside such a body evidently uses a scope/bindings context
that lacks the comptime param bindings (only the outer body binds them).
Find where the inlined body's call arguments are lowered and thread the
comptime bindings through (check whether `inline_return_target` /
comptime-bindings state is dropped when recursing into call args).
Probe the matrix: `$k` in arg exprs at depth 1 and 2, in UFCS args, in
generic-call args, `$T`-typed sibling params, `$k` in an index expr
`arr[k]` inside a call arg. Verification: the repro prints 42; the
probe matrix passes; corpus green; regression under examples/comptime/
(0656 reserved).

Found by the issue-0205 fold worker + its reviewer's p12 probe
(2026-07-03).
