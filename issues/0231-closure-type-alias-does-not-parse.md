# 0231 — a `::` alias of a closure type does not parse

> **RESOLVED (2026-07-03).** Root cause: in const-decl (`::`) RHS position the
> parser reached `Closure(i32)` through the EXPRESSION grammar — `Closure`
> parsed as an identifier, `(i32)` as a call — leaving the `-> i32` tail
> dangling ("expected ';'"). Annotation position never hit this because it
> enters via `parseTypeExpr`, which owns the `Closure(...) -> R` form. Fix:
> (1) parser — `Closure(` in expression position now routes through the
> shared closure-type parse (`parseClosureTypeBody`, extracted from
> `parseTypeExpr`; exact mirror of the existing `Tuple(` magic — a bare
> `Closure` not followed by `(`, or a backtick-raw `` `Closure ``, stays an
> ordinary identifier, and a non-Closure call followed by `->` still errors);
> (2) lowering — `closure_type_expr` added to the scanDecls type-alias
> kind-list (src/ir/lower/decl.zig) so the alias registers like
> `function_type_expr` already did. Regression test:
> `examples/closures/0317-closures-type-alias.sx` (param, multi-arg, zero-arg
> void, struct field, return type, alias-of-alias) + parser unit tests in
> `src/parser.test.zig`.

## Symptom

One-line: `CB :: Closure(i32) -> i32;` fails to parse — "expected ';'" at
`->` — so a closure type cannot be aliased at all, while every other type
form can.

- Observed: parse error at the `->` of the closure type in const-decl RHS
  position.
- Expected: the alias parses and works as a type (params, fields, casts),
  OR specs.md documents that closure types must be spelled inline.

The same spelling works fine in annotation position
(`cb : Closure(i32) -> i32 = ...;`) and in struct fields, so the gap is
the const-decl (`::`) RHS grammar not consuming the `-> ret` tail of a
closure type expr.

## Reproduction

```sx
#import "modules/std.sx";

CB :: Closure(i32) -> i32;      // parse error: expected ';' at '->'

apply :: (f: CB, x: i32) -> i32 { return f(x); }

main :: () -> i32 {
    double := (v: i32) -> i32 => v * 2;
    print("{}\n", apply(xx double, 21));
    0
}
```

## Investigation prompt

FIRST check specs.md §Closures / §Type aliases for whether a closure-type
alias is meant to be legal (structural closure types + "aliases work for
any type" strongly suggest yes). In the parser's const-decl RHS path,
the type-expr parse for `Closure(...)` evidently stops before the
`-> ret` tail (annotation position parses it — find the divergence
between the two type-expr entry points; likely the const-decl RHS uses
an expression parse that treats `->` as a terminator). Fix by routing
the RHS through the same full type-expr grammar annotation position
uses when the RHS starts a type form. Then confirm the issue-0196 alias
registration (`scanDecls` kind-list, src/ir/lower/decl.zig) accepts the
resulting node kind — `.function_type_expr` is already listed; check
what a full closure type parses to. Verification: the repro prints 42;
alias usable as param/field/return; corpus green; regression example
under examples/closures/ (0317 free) or types/.

Found by the issue-0196 fix worker (2026-07-03).
