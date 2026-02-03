> **RESOLVED (2026-07-05).** Root cause: `lowerFunction` (src/ir/lower/decl.zig)
> created a nested static fn's body scope with `parent = self.scope` — the
> ENCLOSING block's scope — so an identifier resolved up the chain to the
> enclosing function's local binding, a Ref that is meaningless (`undef`) in the
> nested function's own SSA context. No diagnostic fired; the read silently
> produced garbage (writes silently no-op'd).
> **Fix:** flag the nested fn's root scope `is_fn_boundary` (kept the parent
> chain so SIBLING nested fns + module consts still resolve). A new
> `Scope.lookupBoundary` reports when a value binding was reached only by
> crossing that boundary; the identifier read / address-of / assignment sites
> turn that into a located diagnostic ("a nested function cannot reference the
> enclosing local 'x' — use a closure ('x := () => ...') to capture it").
> Enclosing local *value* bindings — locals, params, and local `::` consts — are
> all rejected (local consts were also miscompiling to garbage, so they are
> diagnosed rather than comptime-folded; the closure spelling captures them).
> Enclosing local TYPES, sibling nested fns, recursion, module consts/globals,
> and the nested fn's own params/locals stay legal.
> **Review fold (same day):** the first cut guarded only the identifier-
> resolution sites; every STORAGE-resolving path still leaked the dead Ref —
> indexed reads segfaulted (`getExprAlloca`'s array fast path), indexed/member
> stores Bus-errored (the `getExprAlloca`/`lowerExprAsPtr` lvalue helpers), and
> calling an enclosing closure value dispatched through a dead env pointer
> (`lookupNearest` call dispatch). Folded: the boundary check now lives IN
> `getExprAlloca` (diagnose + null; callers fall to their guarded lowering
> paths), in `lowerExprAsPtr`'s identifier arm, in call dispatch via the new
> `Scope.lookupNearestBoundary` (a crossed closure/fn-pointer binding diagnoses
> — even a non-capturing closure, for consistency; a crossed NON-callable
> binding stays invisible so the name correctly falls through to module-scope
> callables), in the trailing indirect-call fallback, and the shared
> `diagEnclosingRootWrite` guard peels `arr[0]` / `p.v` / `px.*` chains to
> their base identifier in BOTH `lowerAssignment` and `lowerMultiAssign` (the
> multi-assign ident arm stored through `scope.lookup` directly — `a, b = 7, 8`
> in a nested fn silently no-op'd). The diagnostic dedupes per (function,
> name) — the guard sits at every resolution layer and a speculative fast
> path's null-fallback re-lowers through another guard.
> Regression tests: examples/diagnostics/1228-diagnostics-nested-fn-enclosing-local.sx
> (five consumer shapes: bare read, indexed read, indexed write, field write,
> closure-value call — exit 1), examples/basic/0061-basic-nested-fn-legal-refs.sx
> (the legal side), and `Scope.lookupBoundary` + `getExprAlloca`-boundary unit
> tests in src/ir/lower.test.zig.
> specs.md §14 updated with the decided rule.

# 0250 — a local STATIC fn (`f :: () {...}` inside a fn) silently miscompiles references to enclosing locals

## Symptom

One-line: `main :: () { x := 41; f :: () -> i64 { return x + 1; } print("{}\n", f()); }`
prints garbage (undef read) with zero diagnostics — a nested `::` static
fn is NOT a closure, has no env, and its reference to the enclosing
local `x` resolves to nothing usable.

- Observed: garbage value, exit 0, no diagnostic.
- Expected: a located diagnostic ("a nested function cannot reference
  the enclosing local 'x' — use a closure ('f := () => ...') to
  capture"), OR defined capture semantics per specs (§14 lists nested
  functions as an open question — a diagnostic is the safe default).

This is why the issue-0156 Part 2 writeup's literal repro
(`captured :: () => {...}`) still segfaults after the Part-2 fix —
the `::` spelling routes to the static-fn path; the `:=` spelling
works. The bug is independent of packs/spreads.

## Reproduction

```sx
#import "modules/std.sx";
main :: () -> i32 {
    x := 41;
    f :: () -> i64 { return x + 1; }
    print("{}\n", f());   // observed: garbage; expected: diagnostic (or 42)
    0
}
```

## Investigation prompt

`lowerLocalFnDecl` / `lazyLowerFunction` (src/ir/lower/stmt.zig +
lower.zig) lower the nested fn as a top-level-style static fn; its body
resolves `x` against... find what it actually binds (an undef ref? the
enclosing frame's slot read from a dead frame?). Per specs §14 (open
question), pick the safe semantics: reject enclosing-LOCAL references
from a static nested fn with a located diagnostic naming the closure
alternative; enclosing CONSTS/globals/params-of-module-scope remain
fine. Check the interaction with the issue-0217 lookupNearest machinery
(nested fns in scope.fn_names). Probe: read, write, nested-two-deep,
reference to a SIBLING nested fn (legal, keep), recursion (legal, keep),
`#run` contexts. Verification: the repro diagnoses; legitimate nested
fns (no local captures — the corpus has examples/basic/0031) unchanged;
corpus green; diagnostics regression example.

Found by the issue-0156p2 fix worker (2026-07-04).
