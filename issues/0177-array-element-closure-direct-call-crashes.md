# 0177 — calling a closure stored in an array element directly (`fns[i](args)`) crashes / miscompiles

> **RESOLVED via parenthesized-type grouping.** The repro
> `[1](Closure(i64,i64) -> i64) = .[ add ]` was not an array of closures — under
> the old rule `(Closure(...) -> R)` was a 1-tuple, so it was an array of
> 1-tuples and `fns[0](...)` tried to call a tuple → LLVM "Called function must
> be a pointer!". Per the user's direction, parentheses in TYPE position are now
> a GROUPING (mirroring value position): `(T)` (no trailing comma) resolves to
> the inner type, `(T,)` is the 1-tuple. So `[1](Closure(...) -> R)` is now an
> array of closures and `fns[0](3,4)` returns `7`. (The canonical non-paren
> `[1]Closure(...) -> R = .[ add ]` already worked.) Implemented in
> `src/parser.zig` (single unnamed non-spread element, no trailing comma →
> return the inner type node). Regression:
> `examples/types/0201-types-parenthesized-type-grouping.sx`. specs.md §Type
> Syntax updated. Verified by 3 adversarial reviews; suite 792/0.

## Symptom

A closure (or `Closure(...)`-typed value) stored in an array, called DIRECTLY via
index (`fns[i](args)`), does not dispatch through the closure ABI: it emits a bare
`call_indirect` on the whole `{fn,env}` struct → LLVM "Called function must be a
pointer!" (verify fail) for some return/arg shapes, or returns garbage for others.
Pre-existing (reproduces on master); distinct from issue 0170 (which fixed the
unwrap-through-optional call `g!()`). Here the callee is a non-optional closure
reached via array index, called directly without unwrap.

## Reproduction

```sx
#import "modules/std.sx";
add :: (a: i64, b: i64) -> i64 { return a + b; }
main :: () {
  fns : [1](Closure(i64, i64) -> i64) = .{ add };
  print("{}\n", fns[0](3, 4));   // LLVM "Called function must be a pointer!" — expected 7
}
```

Expected: `7`. Observed: LLVM verification failure (or, for other shapes, garbage
return / f64-arg verify failure).

## Investigation prompt

`src/ir/lower/call.zig`: issue 0170 added closure-vs-fn-pointer dispatch to the
indirect-call catch-all `else` arm via `inferExprType(callee)` → `.closure` →
`call_closure`. A direct call whose callee is an ARRAY-INDEX expression
(`fns[0]`) of closure type apparently does not reach that dispatch — either it
takes an earlier call arm that still emits `call_indirect`, or
`inferExprType(index_expr)` does not return `.closure` so the `else` arm falls to
the fn-pointer path. Trace which arm `fns[0](args)` lowers through and ensure a
closure-typed callee — regardless of whether it's a bare ident, field access,
index, or call result — dispatches through `call_closure` (threading env + ctx
via the `[ctx, env, user_args]` ABI). Compare with the working `arr[i]!()`
(unwrap) path. Follow the no-silent-fallback rule. Verify: `fns[0](3,4)` → 7;
array-of-closure with captures; non-i64 returns (void/f64/struct); f64 args.
Add an `examples/closures/03xx-array-of-closures-call.sx` regression.
