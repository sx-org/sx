# 0263 — `#run` of an immediately-invoked lambda as a module const panics (unresolved global type)

> **RESOLVED (2026-07-10).** Call planning infers IIFE result types from lambda closure signatures, and the comptime VM now executes closure creation/calls including the hidden environment slot.

## Symptom

One-line: `K :: #run () -> i64 { return 15; }();` — a module-global
const initialized by `#run` of an immediately-invoked anonymous lambda —
panics `unresolved type reached LLVM emission` in `emitGlobals`
(src/ir/emit_llvm.zig:924): the global `K` keeps `.unresolved` type.

- Observed: backend panic, exit 134, no diagnostic.
- Expected: `K : i64 = 15` (or a clean diagnostic if IIFE `#run`
  initializers are unsupported).

Pre-existing on master (stash-verified by the 0250 fix worker,
2026-07-05). Independent of nested fns; `#run named_fn()` works.

## Reproduction

```sx
#import "modules/std.sx";
K :: #run () -> i64 { return 15; }();
main :: () -> i32 { print("{}\n", K); 0 }
```

## Investigation prompt

The `#run` const's result type isn't threaded back to the global when
the initializer expression is an anonymous IIFE lambda — the const
registration (pass-1 inferExprType on the `#run` expr, src/ir/
expr_typer.zig / lower/decl.zig const paths) presumably has no arm for
a call-of-lambda-literal and leaves `.unresolved`, and the 0184-family
hasErrors gate doesn't fire because nothing diagnosed. Two options:
(a) infer through the IIFE (the lambda's declared return type is right
there — `() -> i64`); (b) at minimum, the 0184 rule: a const whose
type stays .unresolved with no prior diagnostic must emit "cannot infer
the type of this '#run' initializer" instead of reaching emitGlobals.
Probe: IIFE with args (`(x: i64) -> i64 {...}(41)`), IIFE without
`#run` (plain `K :: (() -> i64 {...})();` — comptime-foldable?), local
(non-global) IIFE consts, #run named-fn control. Verify: the repro
prints 15 or diagnoses; corpus green; regression under
examples/comptime/.

Found by the issue-0250 fix worker (2026-07-05); pre-existing.
