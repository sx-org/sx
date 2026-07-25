# 0354 — a closure drops captures behind a cast, a named arg, or a trailing block

Status: FIXED 2026-07-25 — `collectCaptures` walks `postfix_cast`,
`named_arg` and `trailing_block`. Regression:
examples/closures/0322-closures-capture-through-wrappers.sx.

## Symptom

A name that a closure body reads THROUGH one of three expression
wrappers never entered the env, so the body reported it unresolved —
while the identical name one syntax layer out captured fine:

    outer :: (side: f32) {
        run(() { put(Box.{ w = side }.(Shape)); });   // unresolved 'side'
        run(() { plain(Box.{ w = side }); });         // fine — no cast
        run(() { named(b = side); });                 // unresolved 'side'
        run(() { block(1.0) { use(side); }; });       // unresolved 'side'
    }

Reported by Agra from the sudoku game, whose every compose row is
`hstack(...) { … place(KeyCap.{ w = metrics.key }.(View)) … }` — the
protocol erasure is the standard spelling for placing a view, so every
metric read inside a container closure failed.

Two things made this expensive to read:

- The diagnostic names the CAPTURE, not the wrapper, and points into
  the struct literal — so it reads like a scoping problem with the
  literal.
- Once one name in an env fails, every other name in that env reports
  unresolved too. The report therefore listed unrelated locals
  alongside the real one, and (in the same build) alongside the
  unrelated aggregate-const-alias failures of issue 0353.

## Cause

`collectCaptures` (src/ir/lower/closure.zig) is an explicit per-node
walk with an `else => {}` fall-through, and three node kinds had no
arm:

- `postfix_cast` — its `operand` (and `alloc_arg`) are ordinary
  expressions;
- `named_arg` — `.call`'s walk covers `args`, but a named argument's
  value hangs off the wrapper node, not the arg slot;
- `trailing_block` — the block is a zero-param lambda parked in the
  call's arg list, and its body captures like any lambda literal.

Nothing was captured under them, so at body-lowering time the scope had
no binding and the identifier arm reported the name unresolved. This is
the same family as the `try_expr` / `catch_expr` / `push_stmt` arms
already present: every one was added after a shape reached the
`else => {}`.

## Fix

The three arms, descending into exactly the value-carrying children.
`postfix_cast.type_expr` is deliberately NOT walked — it is a type, and
the identifier arm's fn/type-name skips would drop it anyway; not
walking it keeps the intent explicit.

## Note

The `else => {}` is what makes this failure mode recur silently: a new
expression node kind is captured correctly only if someone remembers to
add an arm. Turning the switch exhaustive over the value-carrying node
kinds would surface the next one at compile time instead of as an
unresolved name in a user's build.
