> **RESOLVED.** Root cause: the lambda return-type inference in `lowerLambda`
> (`src/ir/lower/closure.zig`) always used `inferExprType(lam.body)`, which for a
> block body returns the *last statement's* value type — and a block whose value
> comes only from early `return`s ends in a `return` statement (typed
> void/noreturn), so the closure was built with a void return while the body
> returned `i64`. Fix: distinguish the two body forms exactly as a named fn does
> (`resolveReturnType` in `src/ir/lower.zig`) —
> - **arrow** `(params) => expr` → `inferExprType(expr)` (the expression IS the value);
> - **block** `(params) { stmts }` → first explicit `return <val>` type via
>   `findReturnValueType`, else **void** (the block's tail is a discarded
>   statement, not an implicit return — only an explicit `-> R` makes the tail
>   the value).
>
> This also subsumes the block-tail-references-a-local case (a `closure(() { x
> := 5; x * 2 })` with no `-> R` is now correctly **void**, not an `.unresolved`
> type reaching LLVM and panicking). Regression test:
> `examples/closures/0313-closure-inferred-return-early.sx`.
>
> Syntax note: the original repro above used the malformed `() => { ... }`
> (arrow + block) form, which the parser currently accepts but the spec does
> not define — a block body is the `closure((params) -> R? { ... })` form, and
> the `=>` lambda takes an EXPRESSION (specs.md §Lambda / §Closures). The bug is
> real under the valid form too: `closure(() { if c { return 11; } return 22; })`
> with an inferred return failed identically before the fix. The regression test
> uses the valid `closure(...)` syntax. (The parser accepting `() => { block }`
> at all is a separate leniency gap, not tracked here.)

# 0187 — lambda with INFERRED return type + block body with early `return`s mis-infers its return type (LLVM verifier failure)

## Symptom

A `:=`-bound lambda (closure literal) that has NO explicit `-> T` return type
and whose body is a BLOCK containing `return` statements infers the WRONG
return type (apparently `void`). Calling it and using the value fails LLVM
verification (`Call parameter type does not match function signature! ... i64
undef` / `Function arguments must have first-class types!`). Adding an explicit
`-> T` makes it work. No optionals or flow narrowing are involved — found while
verifying issue 0186.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  // inferred return type, block body with early returns — NO optionals
  f := () => { if 1 > 0 { return 11; } return 22; };
  print("f: {}\n", f());   // LLVM verification failed (return type inferred void/undef)
}
```

Workaround / contrast (works): annotate the return type —
`f := () -> i64 => { if 1 > 0 { return 11; } return 22; };`

## Root cause (hypothesis)

The lambda return-type inference in `lowerLambda` (`src/ir/lower/closure.zig`,
the `ret_ty` computation around line 164: `const inferred =
self.inferExprType(lam.body);`) does not infer the type from the body's
`return` statements when the body is a block. For a block whose value is
produced only via early `return`s (not a trailing tail expression),
`inferExprType` likely yields `.void`, so the lambda is built with a void
return while the body actually returns `i64` — the mismatch surfaces at the
call site / LLVM verifier.

## Investigation prompt

In `src/ir/lower/closure.zig`, the lambda return-type inference path
(`inferExprType(lam.body)` ~line 164) must, for a block body, infer the return
type from the body's `return` statement operands (matching how
`lowerValueBody` / the function-decl return inference handles bodies with early
returns), not just the block's tail-expression value. Reuse the existing
return-type inference the top-level fn path uses (a top-level
`f :: () { if c { return 11; } return 22; }` with inferred return works — see
why, and apply the same to lambdas). Verify:
1. The repro prints `f: 11`.
2. `examples/optionals/0919`/`0921` and `examples/closures/0312` still pass
   (0312 deliberately uses explicit `-> i64` to dodge this bug — once fixed, an
   inferred-return variant should also work).
3. Add a regression `examples/closures/03xx-lambda-inferred-return-early.sx`.

Unrelated to the optional-unwrap family (0179/0185) and the closure-arg
coercion fix (0186); purely lambda return-type inference.
