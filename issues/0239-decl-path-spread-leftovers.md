# 0239 — decl-based call path: slice-spread placeholder undef + post-spread target_type misindexing

> **RESOLVED (2026-07-04)** — folded into the issue-0188 fold-in commit
> (same file, same loop). Note the issue-0156p2 value-spread landing
> (`861a03c6`) did NOT cure part 2 — verified pre-fold: `f(..p, null)`
> into `(i64, i64, ?i64)` still printed 0 (present-zero optional at the
> wrong slot) on both the closure and top-level paths.
> **Part 1 (slice-spread placeholder undef):** the decl path now rejects a
> leftover `Ref.none` spread placeholder when the callee decl has NO
> variadic param (`rejectLeftoverSpreadPlaceholder` +
> `fnDeclHasVariadicParam` in src/ir/lower/call.zig, run before
> `checkCallArity` so the diagnostic names the spread, not a miscount) —
> covers both the count-mismatch shape (`take2(..sl)`, previously a
> misleading "1 was given" arity error) and the count-lines-up shape
> (`take1(..sl)`, previously undef). The same rejection guards the
> fn-pointer-local `indirectCallThroughLocal` call sites.
> **Part 2 (post-spread target_type misindexing):** lowerCall's shared arg
> loop now tracks a running `param_idx` that advances by each spread's
> EXPANDED width; all param-indexed steering/coercion in the loop
> (target_type, comptime-float fold, implicit address-of, *T-vs-T hint)
> indexes by it instead of the AST position. `f(..pair, null)` → -1,
> struct-literal and coercible-i32 args after a spread land on their true
> params. (`expandCallDefaults` width-counting — the sibling F2 fold — is
> documented in issues/0188's banner.)
> **Regression tests:** examples/diagnostics/1214 (decl-path slice-spread
> legs incl. take1's count-lines-up case), examples/closures/0316
> (post-spread null/struct/i32 target-typing + default-width legs).

## Symptom

Two residual gaps on the DECL-based (top-level fn) call path, same class
as issue 0188 (which fixed the callable-VALUE paths):

1. A runtime SLICE/ARRAY spread into a NON-variadic top-level fn leaves
   the `Ref.none` placeholder counted as one arg — if the count lines
   up, the call emits undef for that slot (silent garbage); expected: a
   located diagnostic (the 0188 fix diagnoses exactly this for callable
   values).
2. `target_type` steering for args AFTER a spread indexes `param_types`
   by AST position, so post-spread args are typed against the wrong
   parameter (pre-existing for pack spreads too); later value coercion
   corrects common cases, which is why it hides. Expected: index by the
   EXPANDED position.

## Reproduction

```sx
#import "modules/std.sx";

take2 :: (a: i64, b: i64) -> i64 { return a + b; }

main :: () {
    sl : []i64 = .[ 10, 20 ][0..2];
    print("{}\n", take2(..sl));   // one spread placeholder + count 1 vs 2:
                                  // probe exact behavior — diagnostic wanted,
                                  // undef-arg silent garbage observed when
                                  // counts line up (e.g. take1(..sl))
}
```

(For (2), construct a call `f(..pack, x)` where x's param type differs
from the AST-position param and observe the steering — the 0188 report
notes value coercion usually rescues it; find a shape where it doesn't,
e.g. a struct-literal arg needing target-typing.)

## Investigation prompt

In src/ir/lower/call.zig's decl-based arg loop: (1) when a runtime
slice/array spread survives to a non-variadic callee (no variadic slot
to consume it), emit the same located diagnostic the 0188 fix added for
callable values — never a Ref.none→undef arg; (2) track the expanded
arg index separately from the AST index when steering target_type after
any spread (tuple spreads now expand inline per 0188 — verify their
post-spread steering too). Verify: probes diagnose/type correctly;
examples/diagnostics/1214 + examples/closures/0316 (0188's tests) stay
green; corpus green; extend 1214 with the decl-path diagnostic case.

Found by the issue-0188 fix worker (2026-07-03). Base on master after
the 0188 landing (same file/loop).
