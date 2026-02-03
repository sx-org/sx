> **RESOLVED.** Root cause: an argument is a value position, but argument
> lowering did not set `force_block_value`. A block-form `if`/`match` reaches
> `lowerIfExpr` with `force_block_value == false` and `is_inline == false`, so
> `is_value` is false — it lowers as a *statement* and returns a bare
> `constInt(0, .void)`, which is then passed as the argument (or, for a
> const-folded `if false { … }`, the else-block runs as a statement and yields
> 0 too). A wider branch type (string `{ptr,i64}`) reinterprets that 0 as a null
> fat pointer → segfault. The `then`-form works (it is `is_inline`, and
> constant-folds); a `:=` var-decl-initialized local works because
> `lowerVarDecl` already sets `force_block_value` on its RHS. NOTE — the `=`
> **assignment** RHS (`lowerAssignment`) did NOT set it (a distinct path from
> the `:=` `lowerVarDecl`), so `z = if false { … } else { … }` — and the
> compound `+=`, index `arr[0] =`, and field `s.x =` target forms — hit the same
> bug; that site is now patched too. Fix: set `force_block_value = true` around
> the value-position lowering at each site — the general-call arg path
> (`src/ir/lower/call.zig`), both the pack-arg and prefix-arg paths for
> variadic/pack calls like `print` (`src/ir/lower/pack.zig`), and the assignment
> RHS in `lowerAssignment` (`src/ir/lower/stmt.zig`). Regression test:
> `examples/basic/0063-basic-block-if-expr-as-call-arg.sx`.

# 0268 — block-form `if C { A } else { B }` as a call argument miscompiles

## Symptom

A **block-form** `if` expression (`if COND { A } else { B }`, branches as
`{ … }` blocks) used **directly as a call/print argument** produces the wrong
value — garbage `0`, the wrong branch, or a **segfault** — instead of the
selected branch's value.

- **Observed:** `take(if false { 1 } else { 2 })` prints `got 0`.
- **Expected:** `got 2`.

Two things make it work, proving the value/branches are fine and isolating the
trigger to *block-form-if in argument position*:

1. **Bind to a local first** — `y := if false { 1 } else { 2 }; take(y);` →
   `got 2` (correct).
2. **Use the `then`/`else` form** — `take(if false then 1 else 2)` → `got 2`
   (correct).

## Reproduction

```sx
#import "modules/std.sx";

take :: (x: i64) { print("got {}\n", x); }

main :: () {
    take(if false { 1 } else { 2 });   // prints "got 0"  — WRONG (want "got 2")

    y := if false { 1 } else { 2 };
    take(y);                            // prints "got 2"  — correct (local binding)

    take(if false then 1 else 2);      // prints "got 2"  — correct (then-form)
}
```

Run:

```sh
./zig-out/bin/sx run repro.sx
```

Worse variants (same root, block-form-if as a direct argument):

```sx
print("{}\n", if false { 111 } else { 222 });   // prints 0
print("{}\n", if lo { "T" } else { "F" });       // SEGFAULT (string branches, lo : ?i64 = null)
```

## Notes on scope

- ONLY the block-form (`{ … }` branches) is affected. The `then`/`else`
  expression form lowers correctly in the same argument position — e.g.
  `examples/http/1691-http-date-server-header.sx` uses
  `(if yy >= 0 then yy else yy - 399) / 400` and passes.
- The condition kind is irrelevant: a plain `if false { 1 } else { 2 }` (bool
  literal) is enough; an optional condition is not required.
- Assigning the same block-form `if` to a local and then using the local works,
  so the branch values and the merge/phi are individually fine — the defect is
  in how the block-form `if`'s result value is threaded when the `if` sits in
  **value/argument position** feeding a call, rather than a statement/`let`.

## Suspected area

`src/ir/lower/control_flow.zig`, `lowerIf` (value-position path, `is_value ==
true`, ~lines 255-320: the `merge_bb` phi construction and the coercion of each
arm's value into `result_type`). The contrast between the working `then`-form
and the broken block-form suggests the block-form arm's tail value is not being
captured as the merge result Ref when the `if` is consumed as a call argument —
likely `result_type` / `target_type` is unset in that context (a local binding
sets it via the declared/inferred type; a bare call argument may leave it
`.void`, so the merge yields `0`/undef, and a differently-sized branch type like
a string overruns → segfault). Check how argument lowering requests the `if`'s
value vs. how a `let`/assignment does, and ensure the value-position block-form
`if` materializes and returns the merge phi Ref with the branch element type
even when no outer `target_type` is supplied.

## Investigation prompt (paste into a fresh session)

> Fix issue 0268: a block-form `if C { A } else { B }` used directly as a call
> argument miscompiles — `take(if false { 1 } else { 2 })` prints `got 0`
> instead of `got 2`, and string-branch variants segfault. The SAME expression
> works when (a) bound to a local first, or (b) written in `then`/`else` form.
> So the bug is block-form-`if`-in-argument-position, in the value-position path
> of `lowerIf` (`src/ir/lower/control_flow.zig`, `is_value` branch, merge_bb /
> phi construction around lines 255-320).
>
> Hypothesis: in argument position no outer `target_type`/`result_type` is
> supplied (a `let`/assignment supplies one from the declared/inferred type),
> so the block-form arms' tail values aren't coerced/captured into the merge
> phi correctly and the merge yields `0`/undef (and, for wider branch types like
> strings, a size mismatch → segfault). The `then`-form path evidently infers
> and threads the branch type independently, which is why it works.
>
> Steps: (1) determine `result_type` for a value-position block-form `if` when
> the consumer is a call argument — compare against the `then`-form path and the
> `let`-binding path; (2) ensure the block-form arms infer their common branch
> type and the merge phi is returned with that type even when `target_type` is
> unset; (3) verify `take(if false { 1 } else { 2 }) == 2`, the int/string print
> variants, and that no regression hits the many block-form `if` statements
> (non-value position) already in the corpus.
>
> Verify: turn `issues/0268-block-if-expr-as-call-arg-miscompiles.sx` into a
> regression example under `examples/<category>/…` (prints `got 2` three times),
> seed the marker, capture goldens scoped with `-Dname=<path>`, then
> `zig build && zig build test`.
