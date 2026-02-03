# 0227 — pure-failable forward of a bare-`!` callee into a NAMED error set is silently accepted

> **RESOLVED (2026-07-03)** — folded into the issue-0205 review pass.
>
> **Root cause:** the pure `-> !E` form's `return EXPR` routed through
> `lowerReturn`'s plain coerce, bypassing the set-compat rules the 0205 fix
> added for value-carrying tuples.
>
> **Fix:** the set-compat rule is factored into a shared
> `checkForwardSetCompat` (src/ir/lower/error.zig), used by both
> `lowerFailableForwardReturn` (tuple forms) and the new
> `coercePureFailableReturn` (pure forms — wired into `lowerReturn`'s real +
> inlined-comptime paths and the pure-failable lambda tail value). Pure
> bare-`!` → named is rejected with the destructure-and-re-raise hint;
> concrete→concrete is subset-checked (escapees diagnosed); concrete→bare
> and matched sets stay legal. `coercePureFailableReturn` also rejects a
> value-carrying failable result returned from a PURE caller (the old coerce
> silently truncated the tuple into a garbage tag).
>
> **Regression tests:**
> `examples/diagnostics/1222-diagnostics-failable-forward-mixtures.sx`
> (pins this rejection + the two arity mixtures) and
> `examples/errors/1066-errors-forward-concrete-to-bare-bang.sx`
> (legal pure→pure forwards: same-set, subset, concrete→bare).

## Symptom

One-line: `fwd :: () -> !MyErr { return inner(); }` where `inner : () -> !`
(bare/inferred error channel) compiles without any subset check — a tag
OUTSIDE `MyErr` can flow into the named channel undetected.

- Observed: `lowerReturn`'s error_set branch just coerces the tag;
  a foreign error rides the `!MyErr` channel and is only caught if later
  compared against a literal from the right set.
- Expected: the same bare→named rejection the VALUE-carrying forward got
  in the issue-0205 fix ("cannot forward a bare-'!' result into the named
  set '!MyErr' — its inferred set is not statically known; destructure and
  re-raise"), or a static subset check when the callee's inferred set is
  known at the forward site.

The issue-0205 fix (`lowerFailableForwardReturn`, src/ir/lower/error.zig)
added exactly this rejection for `(T, !E)` value-carrying forms; the PURE
`-> !E` form routes through `lowerReturn`'s error_set branch instead and
kept the unchecked coercion.

## Reproduction

```sx
#import "modules/std.sx";

MyErr :: error { Boom }
OtherErr :: error { Zap }

inner :: (x: i64) -> ! {
    if x > 0 { raise error.Zap; }   // NOT in MyErr
}

fwd :: (x: i64) -> !MyErr {
    return inner(x);                // expected: diagnostic; observed: accepted
}

main :: () -> i32 {
    e := fwd(1) catch (err) { 
        // err arrives typed !MyErr but carries OtherErr.Zap's global tag
        return 1;
    };
    _ := e;
    0
}
```

## Investigation prompt

In `src/ir/lower/error.zig` / `lowerReturn`'s error_set branch: mirror the
issue-0205 `lowerFailableForwardReturn` rules for the pure `-> !E` form —
bare-`!` callee → named caller REJECTED with the destructure-and-re-raise
diagnostic; concrete→concrete allowed iff callee ⊆ caller (escapees
diagnosed); concrete→bare allowed (global tag ids, per the 0205 decision
recorded in specs.md "Forwarding a failable result"). Factor the set-
compatibility check OUT of lowerFailableForwardReturn so both forms share
it. Verification: the repro diagnoses; legal pure forwards (matched sets,
concrete→bare, subset) keep working — extend examples/errors/1066 or a
new 10xx example; full corpus green.

Found by the issue-0205 fix worker (2026-07-03).
