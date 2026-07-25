# 0353 — a const alias of an AGGREGATE const registers nowhere

Status: FIXED 2026-07-25 — the const-alias fixpoint runs a second time
after aggregate consts register (scanDecls pass 2c), and the three
aggregate folders follow an identifier-RHS alias chain to its terminal
target. Regression:
examples/basic/0071-basic-const-alias-of-aggregate.sx.

## Symptom

`B :: A` resolved for a scalar target but not for a struct- or
array-literal one, in the SAME file and across an import:

    P     :: struct { x: i64; }
    BASE  :: P.{ x = 5 };
    ALIAS :: BASE;

    main :: () {
        print("{}\n", BASE.x);      // 5
        print("{}\n", ALIAS.x);     // FAILED: unresolved 'ALIAS'
    }

while `N :: 7; N_ALIAS :: N` and the string / bool / float forms all
worked (issue 0296's coverage). Reported by Agra from the sudoku game,
whose theme file names its semantic colours after its palette
(`DIGIT_GIVEN :: PAPER`, `KEY_TEXT :: TEXT`, …) — every one of those
aliases failed at every use site.

The report also showed a second face of the same failure. Once one name
in a closure's captured set fails to resolve, EVERY other name in that
env reports unresolved too, so the diagnostics named unrelated locals
(`unresolved 'm'` for a plain struct param) alongside the real cause.
That cascade is what makes this expensive to read: the true root cause
is whichever unresolved name is NOT a local.

## Cause

Two independent gaps, both from aggregate consts registering later than
scalar ones.

1. `scanDecls`' pass 0 registers only LITERAL-valued consts (int, char,
   float, bool, string, and binary/unary expressions). A struct- or
   array-literal const does not reach `module_const_map` until pass 1 /
   pass 2. The const-alias fixpoint (pass 0a', issue 0296) runs between
   them at pass 0a', so an alias of an aggregate found no registered
   target and never registered. The `.identifier` RHS then fell through
   to the type/fn-alias branch, where `selectNominalLeaf` correctly
   answered `.undeclared` — leaving the alias registered in no map at
   all, hence "unresolved" at the use site.

2. The aggregate folders — `foldConstAggLen`, `foldConstArrayElem`,
   `foldConstStructField` — test `sel.info.value.data` against
   `.array_literal` / `.struct_literal`. An alias's registered value
   node is the IDENTIFIER it was declared with, so the shape test failed
   on every alias even once (1) registered it: `SIZES :: DIMS` folded in
   value position but not as `[SIZES[0]]` or `SIZES.len`.

## Fix

- `registerConstAliases` (src/ir/lower/decl.zig) — the pass-0a' fixpoint
  extracted as a function and called a SECOND time at the end of
  `scanDecls` (pass 2c), where the aggregate consts exist. Idempotent:
  the fixpoint skips a name already in `module_const_map`, so every
  alias resolved at pass 0a' keeps its exact binding and ordering.
- `selectShapedConst` (src/ir/lower/comptime.zig) — follows an
  identifier-RHS chain to the const that carries a value SHAPE, pinning
  each hop's author source so a chain whose middle link is visible only
  inside its own module still follows. Hop-bounded, so a cycle yields
  null rather than spinning. The three aggregate folders select through
  it.

## Note

The alias's registered value node deliberately stays the identifier —
`emitModuleConst`'s expression arm lowers it through the target, which
is what keeps a single definition of the value. That is also why the
folders, not the registration, are where the shape has to be chased.
