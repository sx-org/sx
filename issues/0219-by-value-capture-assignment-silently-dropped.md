> **RESOLVED (2026-07-05).** Decision: **(b) — by-value captures are
> immutable.** Assigning to any by-value capture (for-loop element, paired
> range index, match-arm payload, `catch`/`onfail` error binding, `inline
> for` pack-element alias) is now a compile error rather than a silent
> no-op — both the single-assign (`x = v` / `x += v`) and the multi-assign
> (`x, a = …`) spellings.
>
> **Rationale.** specs.md §loops/captures already declared it ("Direct
> reassignment of the capture (`elem = x`) is a compile error"); the
> compiler merely under-enforced it (only the by-ref sibling was caught, by
> issue 0216). (b) is the safer design — mutating a per-iteration copy that
> vanishes next iteration is almost always a bug; the author wanted a by-ref
> capture `(*x)` or a `:=` local. A corpus/library scan found the ONLY
> by-value-capture mutation was examples/basic/0048's own "copy-guard" (the
> very "silent lie" this issue names), so (b) costs nothing and catches real
> bugs. The choice is also consistent with issue 0214's `xx`-erasure, which
> likewise snapshots a by-value capture into a fresh temp rather than writing
> back.
>
> **Fix.** src/ir/lower/stmt.zig — the `nonstore_binding` fall-through in
> BOTH `lowerAssignment`'s ident arm and `lowerMultiAssign`'s ident arm: the
> non-`is_ref_capture` else-branch (previously an accepted no-op) now emits
> `"cannot assign to immutable capture '<name>' — …"`. Diagnostic recorded
> in specs.md (§loops/captures, "By-value captures are immutable").
>
> **Review folds (same day).** (1) The diagnostic is SHAPE-AWARE via a new
> `Binding.Origin` enum (src/ir/lower.zig), set at every non-alloca binding
> site: only the for-loop ELEMENT form suggests the `(*x)` write-back (its
> container storage exists); range indexes, match payloads (tagged-union and
> optional-match), catch/onfail bindings, and pack-element aliases get
> copy-into-a-`:=`-local advice only — a `(*x)` hint there would contradict
> the spec ("no container storage to write back into"). (2) A function-local
> `::` const also binds non-alloca and previously fell into the capture arm
> (and before 0219, into the same silent drop); it now gets the
> constant-family message ("cannot assign to constant 'c' — a '::'
> declaration is immutable; use ':=' …"). Module-global const messages are
> unchanged. (3) A `.unresolved`-typed binding (error placeholder, e.g.
> `y := xs` where `xs` is a pack) suppresses the secondary error — no
> cascade off one root cause. All shared through
> `diagNonstoreBindingAssign` (src/ir/lower/stmt.zig), used by both the
> single-assign and multi-assign ident arms.
>
> **Verification / regression tests.** examples/diagnostics/1227-diagnostics-capture-assignment.sx
> pins all capture families (incl. optional-match + onfail) + the
> multi-assign spelling + the local-const message. examples/basic/0048
> updated (header + stdout) to demonstrate the honest semantics: a `:=`-local
> copy mutates freely with the container unchanged, and a by-ref capture
> writes back. Unit tests in src/ir/lower.test.zig (range-index capture
> diagnosed / real local not; local `::` const gets the constant message).
> Full `zig build test` green (942 examples, 2 issues, 0 failed).

# 0219 — assignment to a by-value loop/match capture is silently dropped (not even the local copy mutates)

## Symptom

One-line: `for xs (x) { x += 100; print("{}\n", x); }` prints the
UNMUTATED element — the store to the by-value capture `x` is dropped
entirely (the capture is a non-alloca scope binding with no store path),
so not even the local copy observes the mutation.

- Observed: the assignment compiles and is a total no-op; `print(x)` on
  the next line shows the original value.
- Expected: either (a) by-value captures are mutable local copies —
  bind the capture to an alloca copy so `x += 100` mutates the copy
  (never the array), or (b) by-value captures are immutable — diagnose
  the assignment ("cannot assign to immutable capture 'x'; capture
  by reference with (*x)").

`examples/basic/0048-basic-for-array-large.sx` pins the ACCEPTANCE of
this syntax (its header says "mutating it" affects only the copy — but
today the copy itself never mutates either, so the pinned behavior is a
silent lie). The same silent drop applies to ALL non-alloca capture
shapes, each probe-verified by the 0216 fix review (2026-07-03):
- match-payload capture: `case .circle: (r) { r = 5.0; }` — prints old value
- catch capture: `catch (e) { e = error.Empty; }` — dropped
- paired index capture: `for xs, 0.. (x, i) { i = 99; }` — prints 0, 1
- inline-for pack-element alias: `inline for xs (x) { x = 999; }` — sum unchanged
All four must be covered by whichever semantics choice (a)/(b) is made.
The by-REF capture (`for xs (*x)`) misuse `x = v` was fixed in issue
0216 (now diagnosed with a `x.* = ...` hint); this issue is the
by-VALUE sibling.

Semantics decision needed first (consult specs.md §loops/captures): pick
(a) or (b), then make 0048's pinned behavior honest either way.

## Reproduction

```sx
#import "modules/std.sx";

main :: () -> i32 {
    xs : [3]i64 = .[ 1, 2, 3 ];
    for xs (x) {
        x += 100;
        print("{}\n", x);     // observed: 1 2 3 — expected: 101 102 103 (or a compile error)
    }
    print("first={}\n", xs[0]);  // must stay 1 under either semantics choice (copy)
    0
}
```

## Investigation prompt

Loop/match/capture bindings are lowered as non-alloca scope bindings
(direct SSA refs); `lowerAssignment`'s ident arm (src/ir/lower/stmt.zig)
finds them in scope but has no store path for a non-alloca binding —
after the 0216 fix, by-ref captures misassigned with `=` are diagnosed,
but by-VALUE captures still fall into a silently-accepted no-op store
(kept deliberately in 0216 because examples/basic/0048 pins the
syntax). Decide the semantics per specs.md: if mutable-copy, bind
by-value captures to an alloca'd copy at loop-body entry (check the
perf note: only when the body contains an assignment to the capture, or
unconditionally if the optimizer cleans it); if immutable, diagnose the
assignment and UPDATE examples/basic/0048 (its header + expected output)
to the new behavior. Cover for-loop, match/case payload captures,
catch/onfail captures, and pack-element aliases. Verification: the repro
prints 101/102/103 with first=1 (choice a) or errors cleanly (choice b);
0048 regenerated scoped + reviewed; `zig build test` green.

Found by the issue-0216 fix worker's probing (2026-07-03).
