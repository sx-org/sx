# 0251 — closure capture analysis skips locals that shadow a global fn name

> **RESOLVED** (2026-07-05). Root cause: `collectCaptures`'s `identifier`
> arm consulted `program_index.fn_ast_map` (and `struct_template_map`)
> BEFORE the lexical scope, so any local/param named like a program fn
> (e.g. `out`, declared by the std prelude in `std/core.sx`) was dropped
> instead of captured — the closure body then read/wrote a garbage address
> (Bus error, or a garbage value; silent wrong behavior). Fix
> (`src/ir/lower/closure.zig`, `collectCaptures`): mirror issue 0217 — call
> `Scope.lookupNearest` FIRST; a `.binding` result is captured, a
> `.local_fn` result (nested local fn — a callable, not a capturable value)
> falls through, and only when there is NO scope binding do the fn-name /
> type-name skips run. This makes the innermost lexical binding win over the
> program-wide fn table (specs §Variable Shadowing) and honours TDZ (a shadow
> declared AFTER the closure isn't in scope yet, so the fn wins).
> Regression test: `examples/closures/0318-closures-capture-fn-name-shadow.sx`
> (ptr-shadow mutation visible + param shadow + no-shadow control) plus a unit
> test in `src/ir/lower.test.zig` next to the 0217 `lookupNearest` test.
> NOTE — a related but SEPARATE pre-existing bug was found while probing (and
> reported, not fixed here): a local closure VALUE that shadows a top-level
> fn is *called* against the fn's return type (dispatch/typing path, not
> capture) — `out := () => 7; out()` LLVM-verify-fails identically on clean
> master. That is 0217-family in the call path, distinct from this capture fix.


## Symptom

One-line: a closure referencing a local (or param) whose name matches
ANY program fn — e.g. a param named `out` while the std prelude declares
fn `out` — does NOT capture it (`collectCaptures`'s
`fn_ast_map.contains` skip runs before the scope lookup), so the closure
body reads/writes through garbage instead of the captured variable.

- Observed: silent wrong behavior (writes through a garbage address /
  reads undef) — no diagnostic.
- Expected: lexical scope wins (the issue-0217 rule, already fixed for
  CALL dispatch): a local shadowing a fn name is captured like any
  other local.

Same root family as issue 0217 (program-wide fn tables consulted before
lexical scope), surfacing in `collectCaptures` (src/ir/lower/closure.zig)
instead of lowerCall.

## Reproduction

Repro shape (from the 0156p2 worker's probe .sx-tmp/p15, distilled):

```sx
#import "modules/std.sx";

apply :: (out: *i64, f: Closure() -> void) { f(); _ := out; }

main :: () -> i32 {
    result : i64 = 0;
    out := @result;               // local named like std's fn `out`
    c := () => { out.* = 42; };   // capture analysis skips `out`
    c();
    print("{}\n", result);        // observed: 0 or crash — expected: 42
    0
}
```

(Verify std actually declares `out` — grep the prelude; any fn name
from any linked module triggers it, so a self-contained repro can
declare its own module-scope `out :: () {}`.)

## Investigation prompt

In `collectCaptures` (src/ir/lower/closure.zig), the identifier walk
skips names found in `fn_ast_map` BEFORE consulting the lexical scope
chain. Mirror the issue-0217 fix: use the nearest-scope resolution
(`Scope.lookupNearest`, added by 0217 in src/ir/lower.zig) — if the
name resolves to a scope binding at the closure-creation site, it's a
capture; only fall through to the fn-name skip when no binding exists.
Probe: local shadowing a std fn name (out/print-style), param shadowing,
by-ref captured shadow mutated through the closure, closure calling the
REAL fn when no shadow exists (unchanged), closure referencing a
top-level fn as a VALUE (fn-ptr capture? whatever parent does, keep),
nested closures. Verification: the repro prints 42; closure corpus
(examples/closures/) green; regression example under examples/closures/
(0318 free).

Found by the issue-0156p2 fix worker (2026-07-04); 0217-family.
