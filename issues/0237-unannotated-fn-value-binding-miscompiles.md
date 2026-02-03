# 0237 — `f := freefn` (unannotated binding of a top-level fn) miscompiles at the call

> **RESOLVED (2026-07-10).** Unannotated declaration inference now gives a bare function reference its user-visible function type at the binding boundary while preserving the legacy `func_ref : i64` IR required by async/fiber consumers.

> **ATTEMPT 1 FAILED — DO NOT re-type `func_ref` globally (2026-07-05).**
> A first fix (`funcRefType` in decl.zig; `lowerExpr` emitting `func_ref`
> with the fn's `.function` TypeId instead of `.i64`) fixed the repro but
> **broke 13 async/fiber examples with exit-134 crashes** — 1700/1701
> (http-fiber), 1805/1806 (io async/cancel), 1813/1817/1819/1821/1823/1824/
> 1825/1826/1827 (fiber async/await/race/leak). Root cause of the breakage:
> `func_ref` is emitted for EVERY bare-fn-name-as-value; the async layer
> passes bare fn names as fiber-entry / nullary-thunk values where the
> `.i64` typing was load-bearing (the `.function` type flips a dispatch or
> struct-store decision on that path). It ALSO drifted 5 `.ir` snapshots
> cosmetically (1332/1347 objc, 1807/1808/1809 fiber — func_ref type text).
> **The fix must be TARGETED to the unannotated-binding inference, NOT the
> func_ref emission:** keep `func_ref` typed `.i64` (all existing consumers
> byte-identical), and instead fix the `:=` var-decl type INFERENCE
> (expr_typer / the decl path) so `f := freefn` infers `f`'s type as the
> fn's `(params)->ret` — the local's stored type is what routes the later
> `f(...)` through the fn-pointer call path. Verify with the FULL suite
> (the 13 async examples + the 5 .ir-pinned ones must stay green — regen
> only genuine .ir drift AFTER stdout/exit are confirmed unchanged).

## Symptom

One-line: binding a top-level function to a local with `:=` and no type
annotation, then calling it, fails LLVM verification — "Called function
must be a pointer!" — even at correct arity; the annotated form
`f : (i64, i64) -> i64 = freefn;` works.

- Observed: LLVM verifier error at the call through the unannotated
  binding (the binding falls into the untyped fallback with an `.i64`
  ret, not a `.function` type).
- Expected: the binding infers the function's type (as the annotated
  form proves the machinery supports) and the call dispatches
  call_indirect.

## Reproduction

```sx
#import "modules/std.sx";

freefn :: (a: i64, b: i64) -> i64 => a + b;

main :: () {
    f := freefn;              // unannotated fn-value binding
    print("{}\n", f(1, 2));   // LLVM: "Called function must be a pointer!"
}
```

## Investigation prompt

The `:=` inference path types `freefn` as a value — find where an
identifier RHS naming a top-level fn is lowered for a var-decl (likely
src/ir/lower/expr.zig identifier lowering emitting a fn address without
a `.function` TypeId, and/or expr_typer inferring `.i64`). Give the
binding the proper function type (the annotated path shows the target
repr). Then the issue-0188 machinery (checkCallableValueArgs +
call_indirect via callableLocalShadow — check whether the 0217 fix's
predicate also keys off the binding's type) should handle the call.
Probe: call through the binding, pass it as an arg, re-bind (`g := f`),
compare with the annotated form's IR (`sx ir`). Verify: the repro
prints 3; corpus green; regression example under examples/closures/ or
basic/. NOTE: coordinate with the 0188 + 0217 landings (both touch
call.zig dispatch) — base on master AFTER both land.

Found by the issue-0188 fix worker (2026-07-03).
