# 0296 — a const aliasing another const (`B :: A`) is unresolved as a value

> **RESOLVED** (2026-07-17). Root cause as filed: `scanDecls`' pass-0a
> const pre-registration switch (src/ir/lower/decl.zig) had no
> `.identifier` arm, so a bare-alias RHS never landed in
> `module_const_map` and every value use hit "unresolved". (Direct bool
> consts worked only via declaration-ordered pass 1 — which is also why
> chains couldn't see them forward.) Fix, two parts: (1) pass 0a now
> registers `.bool_literal` (.bool) and `.string_literal` (.string)
> alongside the numeric shapes, making the map order-independent for all
> literal RHS kinds; (2) a pass-0a' FIXPOINT registers each
> `.identifier`-RHS const with its TARGET's type — the typer reads the
> registered `ty`, so a placeholder would have broken `if B` on a bool
> chain — resolving chains in any declaration order and depth. Only a
> target that IS a registered module const qualifies (an identifier
> naming a type / function / global keeps its existing behavior); a
> cyclic alias never registers and diagnoses at the use site (no hang).
> `emitModuleConst` needed no change — its expression arm lowers the
> identifier through the target. Verified: int/string/float/bool chains,
> forward order, typed const over an alias, alias as array dimension,
> runtime `if` conditions, and `inline if` branch elimination through a
> chain (the 0290 fold). specs.md §Constant Binding documents const
> aliasing. Regression test:
> `examples/basic/0067-basic-const-alias-of-const.sx`.

## Symptom

A module const whose RHS is a bare identifier naming another const does not
resolve in value position: `error: unresolved 'B'`. Yet an EXPRESSION over the
same const works (`B :: A + 0` compiles and folds), so the bare-alias spelling
is strictly less capable than the expression form — an oversight, not a
design.

Observed for every value type (int chain `B :: A`, bool chain
`FEATURE :: ENABLED`); same error from any use site (print arg, `if`
condition).

## Reproduction

```sx
#import "modules/std.sx";

A :: 5;
B :: A;          // error: unresolved 'B' at the use site

main :: () {
    print("{}\n", B);
}
```

Expected: prints `5`. Actual: `error: unresolved 'B'`.
Bool variant: `ENABLED :: false; FEATURE :: ENABLED;` +
`if FEATURE { … }` → `error: unresolved 'FEATURE'`.

## Investigation prompt

Suspected area: the pass-0 const pre-registration loop in
`src/ir/lower/decl.zig` (~line 629, "Pass 0a") registers const RHS shapes
`.int_literal` / `.char_literal` / `.float_literal` / `.binary_op` /
`.unary_op` into `program_index.module_const_map` — a bare `.identifier` RHS
is missing from the switch, so `B :: A` never lands in the map and use sites
report "unresolved". `.bool_literal` is also absent from THIS loop but bool
consts work when directly `X :: true` — find which later pass registers
those, and check whether identifier-RHS consts fail there too or only in
pass 0.

Fix sketch: register `.identifier` RHS consts in the same pre-registration
loop (placeholder type; the value node is the identifier, and the existing
const evaluators — `moduleConstInt`, `evalComptimeCondition`'s new
identifier-chain arm from issue 0290's fix — already dereference through the
map recursively, with a depth guard). Verify the value path too (print/`if`
uses), not just count/dimension positions.

Verification: the repro prints `5`; the bool chain folds
(`inline if FEATURE` prunes its dead branch, extending
`examples/comptime/0665-comptime-inline-if-dead-branch-types.sx`); add a
regression example under `examples/basic/`; `zig build test` green.
