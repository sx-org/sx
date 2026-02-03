> **RESOLVED** — root cause: the operand of a `cast(T) X` call was lowered by
> the generic argument-lowering loop *before* the `cast` handler applied the
> target type `T`. An integer-literal operand therefore folded against the
> ambient default `i64` and was range-checked against `i64.max` — so
> `cast(u64) 0xcbf...` (fits u64, not i64) was rejected. A second, latent
> defect: a same-width signed↔unsigned reinterpret (`i64 → u64`) classifies
> `.none`, so `coerceExplicit` passed the operand through with its *source*
> type, and a `:=`-inferred cast result mis-inferred `i64` and printed signed.
>
> Fix (`src/ir/lower/call.zig`, arg loop): when the callee is `cast` with a
> static type arg, lower the operand with `self.target_type` = the resolved
> cast target `T`, so the literal folds/emits directly as `T` (value masked to
> `T`'s width at const emission, correct type for `:=` inference). Because
> `cast` still truncates, a literal that fits `i64` but overflows a narrower
> `T` (`cast(i8) 300` → 44) must NOT error: a new `Lowering.int_lit_extra_fit_ty`
> field (set to `i64` for the cast operand) makes `checkIntLiteralMagnitudeFits`
> (`src/ir/lower.zig`) accept a value fitting *either* `T` or `i64`, erroring
> only when it fits neither (`cast(u8) 0xcbf...` still errors, now naming `u8`).
>
> Regression test: `examples/basic/0065-basic-u64-literal-cast.sx` (`:=`
> inference, call-arg, max-u64, `xx`-to-u64). `cast(i8) 300` truncation stays
> covered by `examples/types/0174-types-int-literal-boundaries.sx`.

# 0275 — `cast(u64) <bignum>` literal range-checked as i64

## Symptom

A `u64` integer literal larger than `i64.max`, written with an explicit
`cast(u64)` (or `xx`) in a `:=`-inferred or call-argument position, was
REJECTED — the literal was range-checked against `i64` BEFORE the cast's
target type was applied.

- Observed: `error: integer literal 14695981039346656037 does not fit in i64
  (max 9223372036854775807) — use an explicit xx / cast to truncate` (the cast
  IS present, yet it is rejected).
- Expected: `cast(u64) 0xcbf29ce484222325` accepts any literal that fits u64,
  and `x := cast(u64) 0x...` infers `u64` and prints `14695981039346656037`.

A typed const/decl already worked (`x : u64 = 0xcbf29ce484222325;`,
`SEED : u64 : 0x...`), so the value fits u64 fine — only the
`cast(u64) <bignum>` expression in an inference/arg position mis-checked.

## Reproduction

```sx
#import "modules/std.sx";
main :: () { x := cast(u64) 0xcbf29ce484222325; print("{}\n", x); }
```

Expected output: `14695981039346656037`.

## Investigation prompt

The bug is in `src/ir/lower/call.zig`. `cast(T) X` parses to a call of the
identifier `cast` with args `[T, X]`. The generic argument-lowering loop
(around line 590) lowers `X` before the `cast` handler (around line 744)
resolves `T` and calls `coerceExplicit`. For an `int_literal` operand,
`src/ir/lower/expr.zig` (`.int_literal` arm) defaults `target_type` to `i64`
and runs `checkIntLiteralMagnitudeFits(value, i64)` — which rejects a value
above `i64.max`.

Fix: in the arg loop, when the callee is the builtin `cast` with a static type
arg (`isStaticTypeArg(c.args[0])`), set `self.target_type =
self.resolveTypeArg(c.args[0])` for the operand (arg index 1). Then the literal
range-checks against the cast target. Do NOT weaken the check for
genuinely-out-of-range literals: a literal too big for the target must still
error. Verify with the repro (expect `14695981039346656037`), and that
`cast(u32)` of a value > u32.max still errors.
