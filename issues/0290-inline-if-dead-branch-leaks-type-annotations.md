# 0290 — a statically-dead `inline if` branch still resolves its type annotations

> **RESOLVED** (2026-07-17). Root cause as filed:
> `UnknownTypeChecker.walkBodyTypes` walked both `.if_expr` branches (and
> every `.match_expr` arm) ignoring `is_comptime`. Fix: the checker borrows
> the constructing Lowering and prunes exactly what lowering prunes —
> `.if_expr` gates on `evalComptimeCondition`, comptime `.match_expr` on
> `evalComptimeMatch`; unfoldable conditions keep walking both branches, and
> live branches / runtime `if`s still diagnose. `evalComptimeCondition`
> itself gained two leaf shapes (shared by lowering AND the checker):
> `.bool_literal` and a bare identifier folding through
> `module_const_map` (depth-guarded) — so `inline if ENABLED` (case D) is
> now genuinely branch-eliminated at lowering too (the dead branch used to
> survive to LLVM as a dead block). Case E (top level) was already pruned.
> DISCOVERED en route, filed as issues/0296: a const aliasing another const
> (`B :: A`, any type) is unresolved in value position — pre-existing,
> separate class. specs.md documents the dead-branch-dropped-whole rule
> under §Compile-Time Constants. Regression test:
> `examples/comptime/0665-comptime-inline-if-dead-branch-types.sx` (bool
> const, `OS ==`, `and`/`or`, match forms).

## Symptom

An `inline if` whose condition folds to a compile-time constant lowers only the
taken branch, so a *function call* in the dead branch is correctly never
resolved. But a **type annotation** on a local binding in that same dead branch
*is* resolved, so a type that only exists on another target (or behind a
disabled feature) reports a spurious error even though its branch is dropped:

```
error: unknown type 'Missing'
  --> a.sx:4:14
```

Observed: the dead branch's `x : *Missing` is type-checked; compilation fails.
Expected: a statically-false `inline if` branch is dropped whole — its type
annotations are not resolved, exactly as its statements are not lowered.

The leak is narrow and precisely bracketed:

| case | dead-branch content | result |
|---|---|---|
| A `inline if OS == .ios { … } else { … }` (fn body) | `x : *Missing = null;` | **error** |
| B `inline if OS == { case .ios: … else: … }` (fn body) | `x : *Missing = null;` | **error** |
| C `inline if OS == .ios { … } else { … }` (fn body) | `missing_fn(42);` | ok |
| D `inline if false-const { … } else { … }` (fn body) | `x : *Missing = null;` | **error** |
| E top-level `inline if OS == .ios { … }` | `g : *Missing = null;` | ok |

So: it is **not** OS-specific (D, a plain `false` const, leaks too); it is
**type annotations only** (C, a call, is fine); and it is **function-body
only** (E, top level, is fine). A dead branch that names a value/function is
pruned; a dead branch that names a *type* is not.

## Reproduction

```sx
#import "modules/std.sx";

ENABLED :: false;

main :: () {
    inline if ENABLED {
        x : *Missing = null;   // error: unknown type 'Missing' — but this branch is dead
        print("{}\n", x);
    } else {
        print("ok\n");
    }
}
```

The original sighting: a cross-platform app guards its iOS bring-up with
`inline if OS == .ios { u : *UIKitPlatform = …; … }`. Importing `UIKitPlatform`
only on iOS (so the wasm/desktop linker doesn't drag in the Obj-C runtime) makes
the type absent on other targets — and the dead iOS branch then fails to
compile for wasm with `unknown type 'UIKitPlatform'`, even though it is dropped.

## Root cause

`UnknownTypeChecker.walkBodyTypes` (`src/ir/semantic_diagnostics.zig`, the
`.if_expr` arm ~line 668) descends into **both** `then_branch` and
`else_branch` unconditionally:

```zig
.if_expr => |ie| {
    self.walkBodyTypes(ie.condition, declared, in_scope, type_vals);
    self.walkBodyTypes(ie.then_branch, declared, in_scope, type_vals);
    if (ie.else_branch) |e| self.walkBodyTypes(e, declared, in_scope, type_vals);
},
```

It ignores `ie.is_comptime` / `ie.is_inline`. Lowering does the opposite —
`lowerIfExpr` (`src/ir/lower/control_flow.zig` ~238) evaluates the comptime
condition and calls `lowerInlineBranch` on the taken branch only, which is why
the *call* in case C never resolves. The diagnostic walker just never got the
same treatment, so it type-checks code the backend will discard.

The `.match_expr` arm immediately below has the same shape (walks every arm) and
would leak an `inline if x == { case …: }` the same way — worth fixing together.

## Investigation prompt

In `walkBodyTypes`, when an `.if_expr` (and the comptime `.match_expr`) has
`is_comptime` set and its condition folds to a known bool, walk only the taken
branch — mirror `lowerIfExpr`'s `evalComptimeCondition` gate so the checker and
lowering agree on which branch is live. Reuse the existing comptime-condition
evaluator rather than duplicating the fold. When the condition can't be folded
(a genuine runtime `if`, or an `inline if` over a not-yet-known value), keep
walking both branches as today.

Verify with the reproduction (expect `ok`), the `OS ==` forms (cases A/B), and a
control that a *live* branch still reports a real unknown type. A regression
example belongs under `examples/` (e.g. an `inline if false { x : *Missing }`
that compiles and runs).

## Context

Found writing a cross-platform sudoku game against `modules/ui`. Guarding the
Metal/UIKit and GLES3/Android imports per target is the natural way to keep
their `objc_*` / `egl*` externs off the wasm and desktop link lines; this bug
forces those platform bring-up blocks into separate per-OS files instead of a
single `main.sx` with `inline if OS` guards.
