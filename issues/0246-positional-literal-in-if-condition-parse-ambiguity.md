# 0246 — a positional `.{...}` literal in an `if` condition fails to parse

> **RESOLVED (2026-07-10).** While parsing an if condition, the brace after an anonymous positional literal is no longer consumed as the literal's optional init block; comparison lowering also target-types the RHS literal from the LHS.

## Symptom

One-line: `if a != .{ 9, 9 } { ... }` fails with "expected '{'" — the
parser can't disambiguate the literal's `{` from the if-body `{` in
condition position.

- Observed: parse error at the literal.
- Expected: the comparison parses (subject to the aggregate-`==` rules —
  a tuple compare would work per lowerTupleOp; a struct compare hits
  issue 0245's territory), or specs.md documents the required
  parenthesization (`if a != (.{9,9})` — probe whether THAT works today).

Cosmetic/ergonomics; pre-existing. Same family as Zig's/Go's
composite-literal-in-condition ambiguity, which those languages resolve
by requiring parens or by lookahead.

## Reproduction

```sx
#import "modules/std.sx";
main :: () -> i32 {
    a : (i64, i64) = .(1, 2);
    if a != .{ 9, 9 } { print("ne\n"); }   // parse error: expected '{'
    0
}
```

Probe the workarounds: parenthesized `(.{9,9})`, named-tuple form
`.(9, 9)`, a pre-bound local. Whichever works should be mentioned in the
diagnostic if the ambiguity is kept.

## Investigation prompt

In the parser's `if`-condition expression parse, `.{` after a binary
operator is presumably cut off by the statement-level "stop at '{' —
it's the if body" rule. Options: (a) allow `.{` to open a literal inside
a condition when it directly follows an operator/comparison (lookahead
on the preceding token — a `{` in operand position cannot be the if
body); (b) keep the restriction but emit a targeted diagnostic
("parenthesize the literal in a condition: '(.{ ... })'"). Check what
`.( )` tuple literals and `.[ ]` array literals do in the same position
for consistency. Verification: the repro either parses+runs or gives
the targeted hint; if-body parsing unaffected (the corpus is full of
`if x { }` forms); parser unit test; regression example per the
decision.

Found by the issue-0233 fix worker (2026-07-04).
