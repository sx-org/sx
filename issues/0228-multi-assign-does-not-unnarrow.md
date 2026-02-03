# 0228 — multi-assign does not invalidate flow narrowing on its targets

> **RESOLVED (2026-07-03).** Root cause: `lowerAssignment` removes an ident
> target from `self.narrowed` at its top (before RHS lowering); `lowerMultiAssign`
> never touched the set, so a narrowed name assigned via multi-assign kept its
> proven-present status. Fix: `lowerMultiAssign` (src/ir/lower/stmt.zig) now
> drops every IDENT target from `self.narrowed` before any RHS lowers — exact
> parity with single-assign (narrowing keys are bare local names only, per
> `narrowableLocal`; member/index/deref targets invalidate nothing in either
> form, and un-narrowing before RHS means `o, a = o + 1, 2;` diagnoses the RHS
> use just like `o = o + 1;`). Unrelated targets leave narrowing intact;
> re-narrowing after the multi-assign works. Regression test:
> `examples/diagnostics/1223-diagnostics-multi-assign-const-and-narrowing.sx`
> (shared with issue 0229) + unit test in `src/ir/lower.test.zig`.

## Symptom

One-line: inside `if o != null { ... }`, a multi-assign `o, a = null, 1;`
leaves `o` narrowed to non-null, so a following use of `o` as the payload
type (`o + 1` style) still compiles — the SINGLE-assign form correctly
un-narrows and rejects.

- Observed: multi-assign target keeps its narrowing; stale-narrowed uses
  compile (and read a now-null optional as its payload).
- Expected: assignment through EITHER form invalidates narrowing on the
  assigned name (parity with `lowerAssignment`).

## Reproduction

```sx
#import "modules/std.sx";
main :: () -> i32 {
    o : ?i64 = 5;
    a := 0;
    if o != null {
        o, a = null, 1;    // multi-assign: o's narrowing survives (bug)
        v := o + 1;        // compiles; single-assign form rejects this
        print("{}\n", v);  // reads a null optional as payload
    }
    0
}
```

## Investigation prompt

`lowerAssignment` (src/ir/lower/stmt.zig) starts by removing the target
name from `self.narrowed`; `lowerMultiAssign` never does. Add the same
`self.narrowed.remove(...)` for every ident target (and member/deref
targets if single-assign invalidates those too — check what
lowerAssignment invalidates and mirror it exactly, per-target). Verify:
the repro's `o + 1` diagnoses ("possibly null" class error); narrowing
still works when the multi-assign targets are unrelated names; corpus
green. Regression under examples/optionals/ or diagnostics/ per shape.

Found by the issue-0218 fix worker (2026-07-03).
