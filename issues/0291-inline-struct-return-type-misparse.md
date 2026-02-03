# 0291 — inline `struct { ... }` return type misparses the fn decl as a type alias

> **RESOLVED** (2026-07-17). Root cause exactly as filed:
> `hasFnBodyAfterArrow`'s allow-list scan bailed at `kw_struct` /
> `kw_union` / `kw_enum`, classifying the decl as a type alias so the real
> body `{` errored as "expected ';'". Fix: the scan recognizes the three
> keywords and skips their balanced `{ … }` group (brace-depth tracked),
> then continues to the genuine body `{`. The bodyless edge holds —
> `F :: () -> struct { x: i64; };` resumes at `;` and stays a
> function-TYPE alias (and, via issue 0294's shape-keyed anon identity, a
> function with a matching return shape is assignable to it).
> `parseTypeExpr` needed no change, as predicted. Verified: bare +
> parenthesized struct returns, inline union + enum returns, the bodyless
> alias, `zig build test` green. specs.md §Anonymous Structs notes the
> return-type position. Regression test:
> `examples/types/0867-types-inline-struct-return-type.sx`.

## Symptom

A function declaration whose return type is an inline struct type fails to
parse. Observed: `error: expected ';'` pointing at the function's body `{`.
Expected: the declaration parses like any other fn def (inline struct types
already work in parameter and annotation position).

```
error: expected ';'
  --> probe.sx:2:42
   |
 2 | make :: () -> struct { x: i64; y: i64; } { .{ x = 3, y = 4 } }
   |                                          ^
```

Parenthesizing the return type (`-> (struct { ... })`) fails identically.
Inline `union`/`enum` return types share the same failure mode (same missing
keywords in the same scan).

## Reproduction

```sx
#import "modules/std.sx";

make :: () -> struct { x: i64; y: i64; } { .{ x = 3, y = 4 } }

main :: () {
    m := make();
    print("{}\n", m.x + m.y);
}
```

Expected: prints `7`, exit 0.
Actual: parse error above, exit 1.

Baseline showing the type itself is fine outside return position (works
today):

```sx
take :: (p: struct { x: i64; y: i64; }) -> i64 { p.x + p.y }
a : struct { x: i64; y: i64; } = .{ x = 1, y = 2 };
```

## Investigation prompt

Suspected area: `src/parser.zig`, `hasFnBodyAfterArrow` (~line 4150), called
from `isFunctionDef` (~line 4138).

The const-decl parser decides "fn definition vs function-type-literal alias"
(`make :: () -> T { body }` vs `F :: (i64) -> i64;`) by scanning tokens after
`->` through an allow-list until it finds a body `{` (→ definition) or an
unrecognized token (→ alias). The allow-list does not include `kw_struct` /
`kw_union` / `kw_enum`, so the scan bails at `struct`, classifies the decl as
a type-alias const expression, parses the RHS as `() -> struct {...}`
(which succeeds), and then the const-decl terminator check demands `;` where
the real body `{` sits. Note the heuristic's comments already document prior
patches of this exact failure class (arith ops in `[N + 1]f32` dims, named
multi-return slot defaults) — this is the same bug shape with new tokens.

The fix likely needs to: teach the scan to recognize `kw_struct`/`kw_union`/
`kw_enum` and skip their balanced `{ ... }` token group (tracking brace
depth), then continue scanning for the genuine body `{`. Preserve the
bodyless edge: `F :: () -> struct { x: i64; };` must still classify as a
type alias (scan ends at `;` → no body). Alternatively, replace the token
scan with save/restore backtracking (the parser already uses that pattern in
`parseStructLiteral`) to retire this heuristic-patching class entirely —
larger change, evaluate blast radius first.

`parseTypeExpr` needs no change — its `kw_struct` arm
(`parseStructDecl("__anon", ...)`, ~line 854) already parses the inline
struct correctly once `parseFnDecl` → `parseFnReturnType` is actually
entered.

Verification: run the repro above with `./zig-out/bin/sx run` — expect `7`,
exit 0. Also verify the parenthesized spelling, an inline `union`/`enum`
return, the bodyless alias `F :: () -> struct { x: i64; };`, and
`zig build test` green. Then move the repro into `examples/types/` as a
regression test per the resolution procedure.
