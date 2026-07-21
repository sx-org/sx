# 0338 — bare function does not auto-promote into `?Closure` targets (and the diagnostic mistypes it as 'i64')

> **RESOLVED (2026-07-22).** Two fixes, one per defect:
> 1. Promotion composition (`src/ir/lower/expr.zig`): the bare-fn identifier
>    promotion was target-type-driven and fired only for an exact `.closure`
>    target — a `?Closure(...)` target now promotes to the CHILD closure type
>    (same null-env trampoline) and the standard `optional_wrap` coercion
>    wraps it. Call args, struct-literal fields, decl targets, and returns
>    all thread `target_type`, so every position composes.
> 2. Diagnostic naming (`src/ir/lower/coerce.zig` + `generic.zig`): a bare-fn
>    value is carried as a legacy `i64`/`isize` `func_ref` (issue 0237), and
>    the coercion guards printed that word. `diagnosedSrcType` recovers the
>    function's real signature type for `func_ref` values (implicit ctx param
>    excluded) in the central unmodeled-coercion guard and the return-path
>    guard, and `Lowering.formatTypeName` renders `.function` types as their
>    signature (`(i64) -> i64`) instead of the `function` tag.
> Regression: `examples/closures/0320-closures-fn-into-optional-closure.sx`
> (all four positions + parameterized `?Closure(i64) -> i64` + absent slot) +
> `examples/diagnostics/1271-diagnostics-fn-value-type-name.sx` (both guards'
> corrected type names in expected stderr).

> **Symptom.** A bare function auto-promotes to a required `Closure`
> param (specs: Auto-Promotion), and a `T` value implicitly wraps to
> `?T` — but the COMPOSITION is missing: passing a bare function where
> `?Closure(...)` is expected fails. The diagnostic also reports the
> function value's type as `'i64'`:
> `error: cannot coerce a value of type 'i64' to 'closure': no implicit
> conversion applies`.

## Reproduction

```sx
#import "modules/std.sx";

toolbar :: () { print("t"); }

opt_slot :: (f: ?Closure() = null) { if g := f { g(); } }

B :: struct { on_tap: ?Closure() = null; }

main :: () {
    opt_slot(toolbar);              // FAILS — param position
    b := B.{ on_tap = toolbar };    // FAILS — struct-literal field position
}
```

Both fail identically. Working today (for contrast): `run_slot(toolbar)`
with `f: Closure()` (required), `opt_slot(() => toolbar())` (lambda into
optional), and `pre : Closure() = toolbar;` then passing `pre`.

## Expected

fn → `Closure` promotion (null-env static thunk, no allocation) chains
with `T` → `?T` wrapping, in every position where each conversion
applies individually: call args, struct-literal fields, decl targets,
returns. `opt_slot(toolbar)` and `B.{ on_tap = toolbar }` compile and
behave as `opt_slot(() => toolbar())` does.

Independently: the diagnostic must name the actual source type
(the function's type), not `'i64'`.

## Impact

Blocks the point-free slot idiom for optional closure slots
(`scaffold(top_bar = toolbar)`, `Button.{ on_tap = handler }`) in the UI
composable direction (experiment/ui): every optional slot needs a
`() => f()` wrapper today. `?Closure` fields are the established
widget-handler shape (`library/modules/ui/button.sx` `on_tap`).

## Suspected area

Implicit-conversion selection considers single-step conversions only;
fn-value typing falls back to an integer-like raw before the closure
check (hence the 'i64' in the message). Promotion likely needs to run
inside the optional-wrapping path (or conversion search needs the
two-step fn → Closure → ?Closure composition).
