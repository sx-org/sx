# 0185 — binary-op operand auto-unwrap silently miscompiles a NULL `?T` operand to garbage

> **RESOLVED.** Root cause as diagnosed below: `lowerBinaryOp`
> (`src/ir/lower/expr.zig`) auto-unwrapped optional operands UNCONDITIONALLY.
> Fix: gate both operand unwraps on flow narrowing (the same `narrowed_refs`
> mechanism issue 0179 introduced) — an un-narrowed `?T` operand is rejected via
> the new `diagOptionalOperand`; a guard-narrowed operand still unwraps. `== null`
> / `!= null` presence tests are unaffected (they return early before the
> auto-unwrap). While fixing, an adversarial review of 0179 surfaced a real
> soundness hole: `narrowed_refs` (keyed by per-function `Ref` index) leaked into
> nested bodies whose `Ref` space overlaps (closure literals, generic/pack/comptime
> monomorphization, AND — caught by an INDEPENDENT second-pass review — the JNI
> native-method body path, where residue leaked between consecutive `#jni_main`
> method stubs), letting an outer narrowed `Ref` falsely match a nested `Ref`.
> Closed with `Lowering.NarrowGuard` (save/clear/restore around each such nested
> body): lowerLambda (closure.zig), monomorphizeFunction (generic.zig),
> createComptimeFunctionWithPrelude (comptime.zig), monomorphizePackFn (pack.zig),
> synthesizeJniMainStub (ffi.zig). FnBodyReentry + the explicit clear in
> lowerFunction (decl.zig) cover the rest. Regressions:
> `examples/optionals/0921-optionals-binop-narrowing.sx` +
> `examples/optionals/0922-optionals-binop-no-implicit-unwrap.sx`.
>
> **Discovered (separate, NOT fixed here):** calling a closure VALUE/variable
> whose parameter is `?T` does not coerce the argument to the param type — a
> concrete `7` arrives absent and `null` emits `ptr null` against a `{T,i1}`
> param (LLVM verifier failure). Pre-existing, orthogonal to optional unwrap.
> Filed as issue 0186.

## Symptom

An arithmetic / comparison binary op with an OPTIONAL operand (`a + b`,
`a < b`, etc.) unconditionally unwraps the optional's payload — for a PRESENT
optional it yields the value, for a NULL optional it yields the zero/garbage
payload with NO diagnostic. Silent miscompile, same spirit as issue 0179 but a
DIFFERENT code path: this auto-unwrap is in the binary-op lowering, NOT the
`classify` / `coerceMode` coercion ladder that 0179 fixed.

Per specs.md §Optional Types, the only legal ways to extract `T` from `?T` are
`!` / `??` / `if v := opt` / pattern match / flow-sensitive narrowing after a
`!= null` guard. There is no implicit unwrap-at-an-operand-position; a null
operand must not silently become its zero payload.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  a : ?i64 = null;
  b : i64 = 10;
  c := a + b;            // prints "c = 10" (0 + 10) — silent miscompile, no diagnostic
  print("c = {}\n", c);
}
```

Expected: a compile error like 0179's
(`cannot use a value of type '?i64' where 'i64' is expected: an optional does
not implicitly unwrap; ...`), unless `a` is proven present by a `!= null`
guard (flow narrowing), in which case the unwrap is sound.

## Root cause

`src/ir/lower/expr.zig` (`lowerBinaryOp`, ~line 3210, "Auto-unwrap optional
operands for arithmetic/comparison"): both operand arms do an unconditional
`.optional_unwrap` when the operand type is `.optional`, never reading the
has_value flag and never consulting flow narrowing. This is the operand-side
analogue of the coercion-side bug fixed in 0179.

## Investigation prompt

Gate the binary-op operand auto-unwrap on the SAME flow-narrowing mechanism
0179 introduced (`Lowering.narrowed` / `narrowed_refs`, see
`src/ir/lower/control_flow.zig` + `coerceMode`'s `.optional_unwrap` arm in
`src/ir/lower/coerce.zig`):

1. In `lowerBinaryOp`, when an operand is `?T`, only auto-unwrap it when its
   lowered `Ref` is in `self.narrowed_refs` (proven present); otherwise emit
   the same loud diagnostic 0179 uses and skip the silent unwrap. The operand
   `Ref` is produced by `lowerExpr(bop.lhs/rhs)`, so a guard-narrowed local is
   already tagged into `narrowed_refs` by `lowerIdentifier` — the gate is a
   `narrowed_refs.contains(operand)` check.
2. Decide the semantics for a present-but-mixed case (e.g. `?i64 + i64`): the
   result stays `i64` (unwrap the optional operand) only when narrowed, as
   above. Confirm comparisons (`==`/`!=`) against `null` are unaffected — those
   are presence tests, not operand unwraps, and must keep working.
3. Verify: the repro above must become a compile error; a guarded
   `if a != null { c := a + b; }` must still compute `a + b` correctly; the
   existing `examples/optionals/0900-optionals-optionals.sx` `guard2`
   (`return a + b` after a compound `== null or` guard) must still pass.

Add a positive regression (guarded arithmetic) + a negative regression
(unguarded `?T` operand rejected), mirroring 0179's
`examples/optionals/0919` / `0920`.
