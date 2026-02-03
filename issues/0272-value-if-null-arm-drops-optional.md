# 0272 — value `if` with a `null` arm + a typed value arm drops the optional

> **RESOLVED.** Root cause: `lowerIfExpr` (`src/ir/lower/control_flow.zig`)
> inferred the value-`if`'s `result_type` from the concrete (non-`null`) arm
> only — for `if c { 5 } else { null }` the then arm typed `i64`, so the `null`
> else arm (which types `.void`) was never consulted. `result_type` became
> `i64`, the merge phi was `i64`, and the `null` arm was coerced in an `i64`
> context (a bogus present optional / 0); the outer `?i64` assignment then
> re-wrapped the `i64` merge as a PRESENT optional.
>
> Fix: after computing the live-arm type `t`, lift it to an OPTIONAL when the
> arms demand it — (a) the context expects `?U` and `t` is the inner `U` /
> `.unresolved` / `void`-from-a-`null`-arm → adopt `?U`; (b) an arm structurally
> yields `null` (new `armContributesNull`, recursing into chained `else if`) and
> the other yields concrete `T` → synthesize `?T` via `optionalOf`. The existing
> arm→merge coercion then lifts each side (`void→?T` = `none`, `T→?T` = `some`).
> Both arms `null` with no optional context is a located error. Covers both arm
> orders, `:=`/`=`/`return`/ternary positions, and non-`i64` payloads.
>
> **Match-path extension.** The IDENTICAL hole existed in `match` and produced a
> SILENT WRONG VALUE: `inferMatchResultType` (`src/ir/lower/generic.zig`) only
> lifts to `?T` (`has_null → optionalOf(r)`) when a CONCRETE arm decided the
> payload `r`. When EVERY value arm is `null` (all-null, or `null` + only
> diverging/unresolved arms), `result == null`, so it returned
> `.void`/`.noreturn`/`.unresolved`; `has_value_merge` went false, the match
> lowered as a void statement, and `y : ?T = <void>` fabricated a PRESENT
> `{0,true}`. Fix in `lowerMatch` (`src/ir/lower/control_flow.zig`): after the
> `.unresolved`-fallback, when the match is in value position, `inferred_result`
> is `void`/`noreturn`/`unresolved`, and a non-diverging arm yields `null` (new
> `matchContributesNull`, reusing `armContributesNull`), adopt the contextual
> optional target `?U` (so `null` arms → `none`); with no optional target, emit
> the same both-null located error. The `null` + concrete arm case was already
> correct (lifted inside `inferMatchResultType`) and is untouched.
>
> Regression test: `examples/optionals/0925-optionals-if-null-arm.sx` (covers
> both the `if` and `match` paths, incl. all-null-match and null+diverging-match).


## Symptom

A value-position `if`/`else` whose one arm is the bare literal `null` and whose
other arm is a concrete value, assigned to an optional, does NOT produce a
proper optional — the `null` arm is not lowered to a `none`, so the result reads
as **present** when it should be absent.

- **Observed:** for `c == false`, `r : ?i64 = if c { 5 } else { null }` binds as
  present (`if x := r { … }` takes the THEN branch).
- **Expected:** `r` is `null` (absent) when `c == false`.

## Reproduction

```sx
#import "modules/std.sx";

main :: () {
    c := false;
    r : ?i64 = if c { 5 } else { null };
    print("is_null={}\n", if x := r { false } else { true });   // prints false; want true
}
```

Also reproduces through a return of declared optional type:

```sx
ro :: (c: bool) -> ?i64 { return if c { 5 } else { null }; }
// ro(false) reads as present, not null.
```

## Notes on scope

- **PRE-EXISTING** — reproduces at commit `6489e73c` (before the 0269/0271
  value-`if`/`match` lowering rework), so it is NOT caused by that work. Filed
  while regression-testing the 0269 refix.
- Root cause is the value-`if` `result_type` inference taking the concrete arm's
  type (`i64`) and ignoring the contextually-expected optional target
  (`?i64`), so the `null` arm is coerced in an `i64` context instead of becoming
  a proper `none`. `src/ir/lower/control_flow.zig` `lowerIfExpr`: the result type
  should unify to the optional when either the target type is `?T` or one arm is
  `null` and the other is `T` (so `T`→`some T` and `null`→`none`).
- The mirror `if c { null } else { 5 }` likely has the same defect; and the
  ternary `then`/`else` form should be checked too.

## Investigation prompt (paste into a fresh session)

> Fix issue 0272: a value `if` with a `null` arm and a concrete-value arm loses
> the optional — `r : ?i64 = if c { 5 } else { null }` reads as present when
> `c==false`. Pre-existing (repros at 6489e73c). Root cause: `lowerIfExpr`
> (`src/ir/lower/control_flow.zig`) infers `result_type` from the concrete arm
> (`i64`) and ignores the `?i64` target/`null` arm, so `null` is coerced in an
> i64 context rather than lowered to `none`. Fix: when the target type is an
> optional `?T`, or one arm is `null` and the other yields `T`, set `result_type`
> to `?T` and coerce each arm (`T`→`some T`, `null`→`none`) — mirror how a
> `let`-typed optional decl or a ternary handles it. Verify both arm orders, the
> `:=`/`=`/return/call-arg positions, and `then`/`else` ternary form; add a
> regression example under `examples/optionals/…`.
