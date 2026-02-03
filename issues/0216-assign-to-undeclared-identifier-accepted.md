# 0216 — assignment to an undeclared identifier compiles and runs silently

> **RESOLVED (2026-07-03).** Root cause: `lowerAssignment`'s ident-LHS arm
> (src/ir/lower/stmt.zig) had no else branch after the failed global
> fallback — a name with no local slot and no visible global lowered its
> RHS and silently DISCARDED the store (plain `=` and every compound
> `OP=`). Fix: the fall-through now diagnoses "unresolved '<name>' in
> assignment — … use '<name> := ...' to declare a new variable" for a
> name that resolves nowhere, and "cannot assign to by-ref capture
> '<name>' directly — write through it with '<name>.* = ...'" for a
> `for xs (*x)` capture (previously the same silent drop). `_ = expr;`
> (the discard idiom) stays exempt; by-VALUE capture assignment keeps its
> pre-existing accepted-surface behavior (pinned by examples/basic/0048
> "copy-guard"); member/index/deref LHS with an unresolved base already
> diagnosed via the read path. Regression test:
> examples/diagnostics/1212-diagnostics-assign-undeclared-identifier.sx
> (+ unit test in src/ir/lower.test.zig).
>
> Review folds (same session): (1) a scope binding now SHADOWS the
> global fallback — `for xs (*g) { g = 77; }` with a module global `g`
> previously wrote the GLOBAL silently; now the capture wins (by-ref →
> diagnostic, by-value → the 0219-tracked accepted no-op). (2) the
> by-ref-capture diagnostic and (3) the `_ OP=` rejection (`_ += 1` had
> been silently accepted; `_ = expr` alone is the discard idiom) are
> pinned in example 1212.
>
> Sibling gaps NOT covered by this fix, filed separately:
> `lowerMultiAssign` ident targets (undeclared AND module-global names
> in `a, b = ...` silently drop — issue 0218); by-value capture mutation
> never reaches the capture's copy (`x += 100; print(x)` shows the
> unmutated element — issue 0219); qualified store `lib.g = 5` gap
> (issue 0223).

## Symptom

One-line: `undeclared_thing = 42;` (plain `=`, no `:=`) inside a function
body compiles without any diagnostic and runs — observed vs expected: no
error vs an "unresolved identifier" (or "use `:=` to declare") diagnostic.

Real-world cost: a dead assignment to a never-declared name shipped in
`std/http/client.sx` (Q3.6b, since removed) — `path_len = loc.len;` where
`path_len` existed nowhere in the repo. A typo'd variable name in an
assignment silently creates (or discards into) something instead of
failing the build.

## Reproduction

```sx
#import "modules/std.sx";

main :: () -> i32 {
    totl = 42;          // typo of a variable that does not exist —
                        // expected: compile error; observed: accepted
    total := 0;
    total = total + 1;
    print("{}\n", total);
    0
}
```

Observed: compiles, prints `1`, exit 0. Expected: a compile error on the
`totl = 42;` line.

## Investigation prompt

Assignment lowering (src/ir/lower/stmt.zig `lowerAssignment`, the same
area issue 0215 touched) evidently treats an unresolved identifier LHS as
something assignable instead of diagnosing. Find where the ident-LHS arm
resolves the name (scope lookup) and what happens on lookup FAILURE — per
CLAUDE.md's silent-fallback rule the failure must produce a diagnostic
via `self.diagnostics.addFmt(.err, span, ...)`, never a silently-created
slot or a discarded store. Check whether the same gap exists for compound
assignment (`+=`) and for member/index/deref LHS with an unresolved BASE.
Verification: the repro above fails to compile with a clear message; a
new `examples/diagnostics/11xx-...` example pins the diagnostic
(exit code + stderr snapshot); `zig build test` stays green.

Found by the Q3.6b adversarial review (probe-verified on 2026-07-03).
