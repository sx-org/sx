# 0186 — calling a closure VALUE with a `?T` parameter does not coerce the argument

> **RESOLVED.** Root cause as diagnosed below: the closure-VALUE call path in
> `src/ir/lower/call.zig` lowered args without coercing to the closure's
> declared parameter types. Two-part fix: (1) `resolveCallParamTypes` now
> returns the closure/function value's param types for an identifier callee
> bound to a closure/fn VALUE in scope (so args lower with the right
> `target_type`; precedes function-name resolution since a local value shadows
> a function); (2) new free fn `coerceClosureCallArgs` coerces each
> already-lowered user arg to the closure's param type via `coerceToType`,
> applied at all three `call_closure` emission sites (local-variable callee,
> struct-field callee, force-unwrap/expr callee) AND the local function-pointer
> `call_indirect` path (which had the identical gap — an adversarial review
> flagged that the `.function` branch of (1) typed fn-ptr args but never
> coerced them). Now a concrete arg wraps present, `null` → absent — matching a
> top-level fn call, for both closure values and fn-pointer values. Regression:
> `examples/closures/0312-closure-optional-param-arg-coercion.sx` (local +
> struct-field closure + fn-pointer value, concrete + null args).
>
> **Discovered while verifying (separate, NOT fixed here):** a lambda with an
> INFERRED return type (no `-> T`) and a block body with early `return`s
> mis-infers its return type (LLVM verifier failure) even with no optionals.
> Filed as issue 0187. (The 0312 regression uses an explicit `-> i64` to avoid
> it.)

## Symptom

When a closure value/variable (a `:=`-bound lambda, or any closure passed as a
value) has a parameter of optional type `?T`, the call site does NOT coerce the
argument to `?T`:

- A concrete argument (`pick(7)`) is NOT wrapped to a present `?i64` — inside
  the body the param reads as ABSENT (`p == null` is true), so the closure
  silently returns the wrong branch.
- A `null` argument (`pick(null)`) lowers `null` as a bare `ptr null` against a
  `{i64, i1}` parameter, which fails LLVM verification:
  `Call parameter type does not match function signature! ptr null  { i64, i1 }`.

The SAME signature/body as a TOP-LEVEL function works correctly (e.g. issue
0900's `guard`), so the bug is specific to the closure-VALUE call path
(`src/ir/lower/call.zig`'s closure/fn-pointer call lowering), not optionals or
flow narrowing. Found during the adversarial review of issues 0179 / 0185.

## Reproduction

```sx
#import "modules/std.sx";
norm :: (p: ?i64) -> i64 { if p == null { return -1; } return 99; }
main :: () {
  pick := (p: ?i64) -> i64 => {
    if p == null { return -1; }
    return 99;
  };
  print("pick 7: {}\n", pick(7));   // prints -1 (WRONG — should be 99; arg arrives absent)
  print("norm 7: {}\n", norm(7));   // prints 99 (top-level fn, correct)
  // print("pick null: {}\n", pick(null));  // LLVM verifier failure: ptr null vs {i64,i1}
}
```

Expected: `pick(7)` prints `99` (the `7` wraps to a present `?i64`), and
`pick(null)` compiles (the `null` lowers to an absent `?i64`), matching the
top-level `norm`.

## Root cause (hypothesis)

The closure-value call path in `src/ir/lower/call.zig` lowers each argument and
passes it to the closure's trampoline WITHOUT running the `coerceToType` step
that the normal sx-to-sx call path applies against the callee's declared
parameter types. So a `T → ?T` wrap (and `null → ?T`) never happens for a
closure value's optional param. A top-level fn call coerces args to param types,
which is why `norm` works.

## Investigation prompt

In `src/ir/lower/call.zig`, find the closure-value / fn-pointer call lowering
(where `%cl.fn`/`%cl.env` trampolines are invoked — grep for `cl.fn` / the
closure-call branch). Confirm it lowers args without coercing to the closure
type's parameter types. The closure's parameter types are available from the
`Closure(...)`/closure TypeInfo. Coerce each lowered argument to the
corresponding parameter type via `self.coerceToType(arg, arg_ty, param_ty)`
before building the call — mirroring the sx-to-sx call path. Verify:
1. The repro above: `pick(7)` → `99`, `pick(null)` compiles and the body sees
   absent.
2. No regression in existing closure examples (`examples/closures/`).
3. Add a regression `examples/closures/03xx-closure-optional-param.sx` covering
   a concrete arg (wraps present) and a `null` arg (absent) into a closure-value
   `?T` param.

Note: this is purely an argument-coercion gap at the closure-value call site;
it is unrelated to the implicit-optional-unwrap family (issues 0179 / 0185),
which is already fixed.
