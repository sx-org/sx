# 0218 — multi-assign silently drops undeclared and module-global identifier targets

> **RESOLVED (2026-07-03).** Root cause: the ident-target arm of
> `lowerMultiAssign` (src/ir/lower/stmt.zig) only consulted local scope —
> a target with no alloca slot fell through with no diagnostic and no
> global fallback, so both an undeclared name and a module-global name in
> `a, b = x, y;` silently dropped the store. Fix: the arm now mirrors
> single-assign's post-0216 chain — local alloca slot → non-alloca scope
> binding (a capture SHADOWS any same-named global: by-ref capture →
> "cannot assign to by-ref capture '<name>' directly — write through it
> with '<name>.* = ...'"; by-value capture → the 0219-tracked accepted
> no-op) → `_` discard exemption (`a, _ = x, y` keeps working; multi-assign
> is always plain `=`, so no `_ OP=` case exists) → const-write rejection
> for a `::` const target (mirrors issue 0116's single-assign guard, so the
> new global fallback can never write a const) → `resolveGlobalRef` global
> store (source-aware per issue 0115; ambiguous/not-visible diagnose inside
> the resolver, not double-reported) → "unresolved '<name>' in assignment"
> diagnostic. Member/index/deref targets with an unresolved base already
> diagnosed via the read path. Regression tests:
> examples/diagnostics/1218-diagnostics-multi-assign-undeclared.sx
> (undeclared target, by-ref capture target, capture-shadows-global, const
> target) and examples/basic/0060-basic-multi-assign-global.sx (positive
> module-global store + `_` discard leg); unit test in
> src/ir/lower.test.zig (issue 0218).
>
> Review fold (same session, HIGH): the global path above opened a new
> surface — every multi-assign RHS lowered against the AMBIENT
> target_type (the enclosing fn's return type), so `go, a = null, 2;`
> with `go: ?i64` typed the `null` as an i32 zero and coerceToType then
> wrapped a PRESENT Some(0) into the optional (same corruption for
> optional LOCAL targets, pre-existing). lowerMultiAssign now runs the
> single-assign target-typing preamble per (target, value) pair
> (setMultiAssignTargetType: ident local/global, index element, member
> field via fieldLvalueResolve, deref pointee) before lowering that RHS
> — pure typing, so left-to-right evaluate-all-then-store-all (swap
> semantics) is unchanged. Also cures enum/struct-literal RHS diagnosing
> against the wrong destination type. Pinned in
> examples/basic/0060-basic-multi-assign-global.sx (null → optional
> global AND local, scalar→optional coercion, enum-literal leg; the
> optional global is null-initialized at file scope because a non-null
> optional-global initializer miscompiles — issue 0234).
>
> Sibling gaps found while probing, NOT covered by this fix (report
> filed separately): multi-assign does not kill flow narrowing
> (`o, a = null, 1;` inside `if o != null { }` leaves `o` narrowed, so a
> following `o + 1` compiles — single-assign correctly un-narrows and
> rejects); a multi-assign MEMBER target rooted at a `::` struct const
> writes through the constant (`CP.x, a = 9, 9;` mutates `CP` — the 0116
> guard only runs in `lowerAssignment`).

## Symptom

One-line: in a multi-assign `a, b = x, y;`, an identifier TARGET that is
undeclared is silently dropped, and a module-global identifier target is
ALSO silently dropped — `lowerMultiAssign` has no global fallback at all.

- Observed: `a, undeclared_b = b, a;` compiles and runs (the store to
  `undeclared_b` vanishes); `g, x = 1, 2;` with `g` a module global
  compiles but never writes `g`.
- Expected: an "unresolved '<name>' in assignment" diagnostic for the
  undeclared target (parity with the single-assign diagnostic from issue
  0216), and a working store for the module-global target (parity with
  single-assign `g = 1;` which resolves globals).

This is the multi-assign sibling of issue 0216 (single-assign fixed in
its own session): the ident-target arm of `lowerMultiAssign` only
consults local scope, and a failed lookup falls through silently.

## Reproduction

```sx
#import "modules/std.sx";

g_total : i64 = 0;

main :: () -> i32 {
    a := 1;
    b := 2;
    a, undeclared_b = b, a;    // expected: compile error; observed: accepted, store dropped
    print("a={}\n", a);

    g_total, a = 40, 50;       // expected: g_total == 40; observed: g_total stays 0
    print("g={}\n", g_total);
    0
}
```

Observed: compiles, prints `a=2` then `g=0`, exit 0. Expected: a compile
error on the `undeclared_b` target; with that line removed, `g=40`.

## Investigation prompt

In `src/ir/lower/stmt.zig`, `lowerMultiAssign` (~line 2169): the
identifier-target arm resolves ONLY against local scope and silently
drops the store on lookup failure — no diagnostic, and no
`resolveGlobalRef` fallback (single-assign `lowerAssignment` has both
since the 0216 fix; mirror its shape: local slot → global fallback →
`self.diagnostics.addFmt(.err, span, "unresolved '{s}' in assignment …")`).
Also check the other target shapes in multi-assign (member/index/deref
bases) for the same silent-drop, and the by-ref/by-value capture cases
the 0216 fix handled. Verification: the repro errors on `undeclared_b`;
with that line removed, `g=40` prints; new
`examples/diagnostics/12xx-...` pins the diagnostic; a positive
multi-assign-to-global case joins an existing basic/ example or a new
one. `zig build test` green.

Found by the issue-0216 fix worker's probing (2026-07-03).
