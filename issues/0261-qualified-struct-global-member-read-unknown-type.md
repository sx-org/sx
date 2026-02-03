# 0261 — reading a STRUCT global's member through an import alias fails "unknown type"

> **RESOLVED (2026-07-10).** Namespace-rooted member resolution now distinguishes target-module globals from type heads for inference and reads; nested stores address the selected global and GEP its field.

## Symptom

One-line: with `lib :: #import "..."` and a struct-typed mutable global
`gp : P = ...` in lib, the qualified member READ `lib.gp.x` fails
`unknown type 'gp'` — expr.zig's namespace-rooted member path treats
`alias.member.field` as `alias.Type.member` (a type lookup), never as
global-value.field.

- Observed: "unknown type 'gp'" on a plain read.
- Expected: `lib.gp.x` reads the global's field (scalar qualified reads
  `lib.g` work; the issue-0223 fix made qualified scalar STORES work —
  struct-member paths remain broken in BOTH directions since the read
  fails first).

Pre-existing on master (verified by the 0223/0249 fix worker,
2026-07-05).

## Reproduction

```sx
// lib file: 0261-lib/lib.sx
P :: struct { x: i64 = 0; }
gp : P = .{ x = 7 };
```

```sx
#import "modules/std.sx";
lib :: #import "0261-lib/lib.sx";

main :: () -> i32 {
    print("{}\n", lib.gp.x);   // error: unknown type 'gp' — expected 7
    lib.gp.x = 9;              // (store side blocked by the same read-path gap)
    print("{}\n", lib.gp.x);   // expected 9
    0
}
```

## Investigation prompt

In src/ir/lower/expr.zig's namespace-rooted member-access arm (the
`alias.X.Y` path): the second component is classified as a TYPE in the
target module (serving `alias.Type.member` static access) with no
fallback to a GLOBAL VALUE of that name. Add the global-value arm:
when `X` resolves to a mutable/const global in the target module, lower
`alias.X` as that global (the machinery the scalar `alias.g` read
already uses — find where the 2-component form works and extend to the
3+-component chain), then apply `.Y` as ordinary field access. Then
wire the STORE side through the issue-0223 `tryLowerQualifiedGlobalStore`
helper (src/ir/lower/stmt.zig) for `alias.global.field = v` — its
current shape handles `alias.global = v`; the nested-member store needs
global_addr + field GEP (mirror the local struct-member store). Probe:
2/3/4-component chains, reads + stores + compound, const struct globals
(stores rejected), arrays-in-struct-globals, and the flat-import
spelling. Verify: the repro prints 7 then 9; corpus green; regression
example under examples/modules/.

Found by the issues-0223/0249 fix worker (2026-07-05); pre-existing.
