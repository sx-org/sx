> **RESOLVED** (2026-06-27). Fix: the `Any`-shaped `==`/`!=` arm in
> `src/ir/lower/expr.zig` now fires when EITHER operand is `.any` (was both). A
> concrete operand is boxed to `Any` (`builder.boxAny`) first, so both sides are
> 16-byte boxes; then both unbox to their `.i64` value words and compare — the
> same value-identity the both-`Any` path uses (tags not compared). An
> already-errored `.unresolved` / `.void` operand falls through (no cascade).
> Verified: `x == 5`, `x == 6`, `x != 6`, `5 == x` (reversed), bool `Any`, and the
> both-`Any` form all work; no verifier abort. Regression test:
> `examples/comptime/0654-comptime-any-eq-concrete.sx`. (Aggregate-`Any`
> comparison still uses value-word identity — the same limitation the both-`Any`
> path always had; orthogonal to this verifier fix.)
>
> **SUPERSEDED** (2026-07-16, Improvement 1b): `==`/`!=` with an `any` operand
> is now a COMPILE ERROR (Odin parity) — under the borrow representation the
> value words are addresses, so the whole comparison arm was deleted rather
> than adapted. The crash class cannot recur (the lowering rejects before any
> icmp is built). Example 0654 was replaced by the diagnostic pin
> `examples/diagnostics/1245-diagnostics-any-compare-rejected.sx`.

# 0199 — `Any == <concrete>` (one operand `Any`) fails LLVM verification

**Symptom** — An equality / inequality comparison where exactly ONE operand is
`Any` and the other is a concrete type is not handled: it falls through to a
plain `icmp` on a 16-byte `{tag, value}` aggregate vs a scalar and aborts the
LLVM verifier.

- Observed: `x : Any = 5; if x == 5 { ... }` →
  `error: Both operands to ICmp are not of the same type! {i64,i64} vs i64`,
  `LLVM verification failed`, exit 1 (loud — not a segfault / silent miscompile).
- Expected: either box the concrete operand to `Any` (then compare as `Any ==
  Any`, the path that already works) consulting the tag, OR a clean located
  compile diagnostic (e.g. "compare an 'Any' against a value of its boxed type,
  or `xx` the Any first"). Not an LLVM verifier abort.

Distinct from issue 0198 (the implicit `Any → T` unbox). Surfaced by the
adversarial review of the 0198 fix. `Any == Any` works correctly.

## Reproduction

```sx
#import "modules/std.sx";

main :: () -> i64 {
    x : Any = 5;
    if x == 5 { return 1; }   // error: ICmp operand type mismatch {i64,i64} vs i64
    return 0;
}
```

`./zig-out/bin/sx run repro.sx` → `LLVM verification failed`, exit 1.

## Investigation prompt

The `Any` equality path is in `src/ir/lower/expr.zig` (~3201-3215), gated on
`lhs_ty == .any and rhs_ty == .any` — it `unbox_any`s both sides to `.i64` and
`cmp_eq`s the value words. When only ONE side is `.any`, that guard is false and
the comparison falls through to the generic numeric/`icmp` path, which emits an
`icmp` between the 16-byte `Any` aggregate and the scalar → verifier abort.

The fix likely adds a mixed-operand arm: when exactly one operand is `.any` and
the other is a concrete type `T`, box the concrete operand to `Any`
(`self.builder.boxAny(concrete, T)`) and reuse the existing `Any == Any`
value-word comparison — OR, if comparing only the payload word is unsound across
types (a `5:i64` and a `5.0:f64` would compare equal by bits), gate on the tag
too / emit a diagnostic. Decide whether `Any == concrete` should compare by
(tag AND value) or be disallowed; mirror whatever `Any == Any` semantics are
documented. Verify: the repro compiles and `x == 5` is true, OR a clean
diagnostic is emitted — never an LLVM verifier abort.
