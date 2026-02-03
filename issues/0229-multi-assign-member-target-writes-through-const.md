# 0229 — multi-assign MEMBER target writes through a `::` struct const

> **RESOLVED (2026-07-03).** Root cause: the issue-0116 root-const guard (walk
> the target chain to its root ident, reject when it names an unshadowed `::`
> const) ran only in `lowerAssignment`; `lowerMultiAssign`'s member/index arms
> emitted stores unguarded (the 0218 fix had covered ident targets only). Fix:
> the guard is factored into a shared `diagConstRootWrite` helper
> (src/ir/lower/stmt.zig) used by `lowerAssignment` and applied PER TARGET in
> `lowerMultiAssign`'s store loop before any store — member (`CP.x`), index
> (`CARR[1]`), nested (`CO.a.b`), and ident targets all reject; every bad
> target in one statement is diagnosed (batched, matching consecutive
> single-assigns). Deref-of-const-pointer (`GP.*, a = ...`) stays accepted in
> both forms — the root walk stops at a deref, writing through a pointer VALUE
> is not a write to the named root. Locals shadowing a const name keep working.
> Regression test:
> `examples/diagnostics/1223-diagnostics-multi-assign-const-and-narrowing.sx`
> (shared with issue 0228).

## Symptom

One-line: `CP.x, a = 9, 9;` where `CP :: SomeStruct.{...}` is a module
const MUTATES the const — the single-assign form `CP.x = 9;` is rejected
by the root-const guard (issue-0116 machinery), but that guard only runs
in `lowerAssignment`, not `lowerMultiAssign`.

- Observed: multi-assign member target silently writes through the const.
- Expected: the same "cannot assign through constant 'CP'" rejection the
  single-assign form produces.

The issue-0218 fix guarded IDENT targets in multi-assign (a `::` const
ident target is now rejected); member/index/deref targets still bypass
the root-const walk.

## Reproduction

```sx
#import "modules/std.sx";
P :: struct { x: i64 = 0; y: i64 = 0; }
CP :: P.{ x = 1, y = 2 };

main :: () -> i32 {
    a := 0;
    CP.x, a = 9, 9;          // expected: rejected; observed: writes the const
    print("{}\n", CP.x);     // 9 (should still be 1)
    0
}
```

## Investigation prompt

`lowerMultiAssign` (src/ir/lower/stmt.zig): the member/index/deref target
arms emit stores without running the root-const guard that
`lowerAssignment` applies (the 0116 walk that rejects writes whose base
chain roots at a `::` const — find it in lowerAssignment and factor it
into a helper both callers share). Apply per-target before any store.
Also check INDEX targets (`CARR[0], a = ...` on a `::` array const) and
DEREF-of-const-pointer shapes. Verify: the repro diagnoses; legitimate
member multi-assign targets (mutable struct locals/globals) keep
working; corpus green. Regression example under examples/diagnostics/.

Found by the issue-0218 fix worker (2026-07-03). Related: 0228 (same
function, missing un-narrowing) — one fix session can take both.
