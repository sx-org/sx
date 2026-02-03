# 0188 — closure-VALUE calls skip argument validation: no arity check + runtime-tuple spread not expanded

> **RESOLVED (2026-07-03).**
> **Root cause:** the closure-value / fn-pointer-value call paths in
> `src/ir/lower/call.zig` (identifier closure binding, identifier + global
> fn-pointer bindings, struct-field closure/fn-pointer, expression callee)
> emitted `call_closure` / `call_indirect` with no arity validation — the
> decl-based `checkCallArity` has no `ast.FnDecl` to consume for a callable
> VALUE — and lowerCall's arg loop left a runtime spread as a `Ref.none`
> placeholder that only the slice-variadic path resolved, so a spread into a
> callable value reached the call op as undef.
> **Fix:** (1) new `checkCallableValueArgs` (call.zig) validates exact arity
> against the callable TYPE's param list (`closure.params` /
> `function.params` — user-visible, no `__sx_ctx` slot; pack-variadic
> `pack_start != null` shapes skipped like `isPackFn`) at the callable-value
> emission sites, and rejects any leftover spread placeholder
> (`rejectLeftoverSpreadPlaceholder`). (2) **Spread decision: EXPANDED, not
> rejected** — a runtime TUPLE (and fixed-array) spread expands into
> positional args; only a runtime SLICE spread into a callee with no
> variadic slot is diagnosed (no static length to expand).
> **Reconciliation (2026-07-04 rebase):** the spread expansion itself landed
> independently as the issue-0156p2 value-spread fix (`valueSpreadRefs` +
> `packVariadicCallArgs` hardening — that shape won; this issue's duplicate
> expansion and pack.zig guards were dropped at rebase). The 0217 fold's
> `indirectCallThroughLocal` owns the fn-pointer-LOCAL arity check (with
> C-variadic gating; single diagnostic, no double-fire); this issue's
> validation covers the remaining callable-value sites plus the
> spread-placeholder rejection. Review folds absorbed here: post-spread args
> are target-typed by a running EXPANDED param index, not the AST index
> (`f(..pair, null)` lands the null on the `?T` param — issue 0239 part 2),
> and `expandCallDefaults` counts a spread by its static WIDTH (tuple
> fields / array length / pack arity; unknown width declines expansion), so
> a 2-tuple spread into `(a: i64, b: i64 = 99)` fills no default (review F2).
> **Regression tests:**
> `examples/diagnostics/1214-diagnostics-closure-value-arity.sx` (arity +
> slice-spread diagnostics incl. the decl path per issue 0239),
> `examples/closures/0316-closures-value-call-validation.sx` (positive
> surface incl. spreads, post-spread target-typing, default-width counting),
> plus a unit test in `src/ir/lower.test.zig`.

## Symptom

Calling a closure VALUE (a `:=`-bound lambda, struct-field closure, fn-pointer
value) does NOT validate arguments the way a top-level function call does. Two
distinct gaps, both pre-existing (surfaced during the adversarial review of the
issue-0186 fix; 0186 fixed only arg COERCION for correctly-counted args):

1. **No arity check.** A closure value called with the WRONG number of args
   compiles and silently drops/ignores extras (or reads garbage for missing
   ones), exit 0. A top-level fn call diagnoses arity.
2. **Runtime-tuple spread `f(..tuple)` is never expanded for a closure value.**
   The spread leaves a `Ref.none` placeholder (`call.zig` ~line 404) that the
   `call_closure` sites emit as `undef`, so the call passes garbage.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  // (1) arity: extra arg silently dropped
  one := (a: i64) -> i64 => a;
  print("arity: {}\n", one(1, 2));      // prints 1 (no error; `2` dropped)

  // (2) spread into a closure value → garbage
  add := (a: i64, b: i64) -> i64 => a + b;
  pair := (10, 20);
  print("spread: {}\n", add(..pair));   // prints garbage (e.g. -17590042754976), not 30
}
```

Expected: (1) an arity diagnostic (as for a top-level fn); (2) `add(..pair)`
expands to `add(10, 20)` → `30`, OR a clear diagnostic that spread into a
closure value is unsupported (never silent garbage).

## Root cause (hypothesis)

The closure-value call paths in `src/ir/lower/call.zig` (the three
`call_closure` emission sites + the local `call_indirect` fn-pointer path) build
the arg list and emit directly without (a) an arity check against
`closure.params.len` / `function.params.len`, and (b) without running the
runtime-slice/tuple spread expansion that the normal call path uses
(`packVariadicCallArgs` / the `Ref.none` spread placeholder is never resolved
for closures). The pack-spread `..xs` path (`packSpreadRefs`) handles comptime
packs but not a runtime tuple value spread into a closure.

## Investigation prompt

In `src/ir/lower/call.zig`, for each closure-value / fn-pointer-value call site
(grep `call_closure` and the local `call_indirect` path ~line 655):
1. Add an arity check against the callee value's `closure.params` /
   `function.params` length (mirror `checkCallArity` used for top-level fns),
   accounting for the implicit `__sx_ctx` slot.
2. Either expand a runtime-tuple/slice spread argument into positional args for
   closure values (as the normal call path does), or emit a located diagnostic
   that spread into a callable value is unsupported — never emit the `Ref.none`
   placeholder as `undef`.
3. Regression: extend `examples/closures/0312-...` or add
   `examples/closures/03xx-closure-value-arity.sx` covering both the arity
   diagnostic and the spread behavior.

Unrelated to the arg-COERCION fix (issue 0186, already landed) — that fix
correctly coerces a correctly-COUNTED arg; these gaps are about COUNT and
spread expansion.
