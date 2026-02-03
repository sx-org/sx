# 0258 — bare vector `==` used as an `if` condition panics at codegen

> **RESOLVED (2026-07-10).** Expression typing preserves vector comparison results as `Vector(N,bool)`; the lowering condition guard now rejects them with a located diagnostic before codegen.

## Symptom

One-line: comparing two `Vector(4, f32)` values yields an element-wise
vector-of-bool; using that directly as an `if` condition panics
`emitCondBr: non-boolean condition reached condBr`
(src/backend/llvm/ops.zig:2440) instead of a lowering diagnostic (or an
implicit all-true reduction).

- Observed: codegen panic.
- Expected: either `==` on vectors reduces to a scalar bool in boolean
  contexts (all-lanes-equal — check specs.md §Vectors for the intended
  comparison semantics; SIMD languages usually keep the lane-wise result
  and require an explicit reduction), or the boolean-context use of a
  vector-of-bool diagnoses cleanly ("vector comparison yields per-lane
  results; reduce with all()/any()" — if such builtins exist).

## Reproduction

```sx
#import "modules/std.sx";
main :: () -> i32 {
    a : Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
    b : Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
    if a == b { print("eq\n"); }   // panic: non-boolean condition reached condBr
    0
}
```

## Investigation prompt

specs.md §Vectors first: what does vector `==` return? If lane-wise
(likely, matching the SIMD model): the boolean-context coercion
(condition lowering in src/ir/lower/control_flow.zig or the cond
emission) must reject a vector-of-bool condition with a located
diagnostic naming the reduction (and add all()/any() reductions if the
vectors module lacks them — check library/modules/math/ and the 15xx
vectors examples for existing spellings). If scalar-reducing: lower the
comparison to an all-lanes reduction in boolean contexts. Either way,
never let a non-i1 reach emitCondBr — consider a general lowering-side
guard for ANY non-boolean condition type (what does `if some_i64 {}` do
today? probe — same guard family). Regression: vectors 15xx example or
diagnostics per the decision; corpus green.

Found by the issue-0245 fix worker (2026-07-05).
