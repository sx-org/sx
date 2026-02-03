# 0257 — a match expression as a GENERIC call argument panics (ExprTyper has no .match_expr arm)

> **RESOLVED (2026-07-10).** `ExprTyper` now routes match expressions through `inferMatchResultType`, so generic argument binding sees the unified arm type rather than `.unresolved`.

## Symptom

One-line: passing a match expression directly as a generic fn argument —
`ident(if c == { case .red: { 1.5 } case .green: { 2 } })` with
`ident :: (x: $T) -> T` — panics "unresolved type reached LLVM emission"
(exit 134): `ExprTyper.inferType` has no `.match_expr` arm, so `$T`
binds `.unresolved`.

- Observed: backend panic, no diagnostic (`print("{}", match...)` works
  — print's variadic path types differently).
- Expected: `$T` binds the match expression's unified result type (the
  issue-0236 `unifyMatchArmTypes` join).

Pre-existing (verified identical on the pre-0236 baseline by the 0236
fix worker, 2026-07-04).

## Reproduction

```sx
#import "modules/std.sx";
Color :: enum { red; green; }
ident :: (x: $T) -> T { return x; }
main :: () {
    c : Color = .red;
    r := ident(if c == { case .red: { 1.5 } case .green: { 2 } });  // panic exit 134
    print("{}\n", r);   // expected 1.5
}
```

## Investigation prompt

Add a `.match_expr` arm to `ExprTyper.inferType`
(src/ir/expr_typer.zig) that routes through the issue-0236
`inferMatchResultType`/`unifyMatchArmTypes` (src/ir/lower/generic.zig —
mind the layering: ExprTyper may not have a Lowering; check how other
arms needing lowering-side info handle it, or extract the unification
into a shared, Lowering-free helper). Never leave the catch-all
returning `.unresolved` silently for match exprs (the CLAUDE.md rule;
a loud "cannot infer a match expression's type here" diagnostic is the
floor if full inference is out of scope). Probe: generic arg (the
repro), if-EXPR as generic arg (does .if_expr have an arm? — same
family), match feeding size_of/reflection, match as a struct-literal
field value with generic target. Verify: the repro prints 1.5 (or
diagnoses loudly); corpus green; regression under examples/generics/.

Found by the issue-0236 fix worker (2026-07-04); pre-existing.
