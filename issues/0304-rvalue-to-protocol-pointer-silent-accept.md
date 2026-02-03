# 0304 — struct rvalue assigned to `*Protocol`: silently accepted, yields a pointer

> **RESOLVED (2026-07-18)** — the ruled refusal is implemented (this cell's
> PERMANENT semantics under the erasure model): `pv : *Sizable =
> Widget.{...}` diagnoses "an rvalue has no durable storage to borrow; bind
> it to a local first, or erase to an owned 'Sizable' value" (stmt.zig
> decl-init arm; the argument form diagnoses at the node-less layer in
> coerceCallArgs). The silent byte-pun class is additionally closed by the
> aggregate↔scalar guard in noneReinterpretIsUnsafe. Regression:
> examples/diagnostics/1251-diagnostics-protocol-view-refusals.sx.

## Symptom

Declaring a pointer-to-protocol local initialized from a struct **rvalue**
compiles with NO diagnostic and produces a non-null pointer at runtime —
accidental semantics (the temporary is spilled and its address taken, or
worse). There is no defined conversion from a concrete rvalue to
`*Protocol`; this should be a compile error.

Observed: the program below prints `true`.

## Reproduction

```sx
#import "modules/std.sx";
Sizable :: protocol { size :: (self: *Self) -> i64; }
Widget :: struct { value: i64; }
impl Sizable for Widget { size :: (self: *Widget) -> i64 { self.value } }
main :: () {
    pv : *Sizable = Widget.{ value = 1 };
    print("{}\n", pv != null);
}
```

Expected: a diagnostic ("no conversion from 'Widget' to '*Sizable'"; an
rvalue has no durable storage to point at). Actual: compiles, prints `true`.

## Investigation prompt

Suspect the decl-init coercion path for pointer targets. Candidates:
(1) the pointer-target fallback in src/ir/lower/coerce.zig (~lines 157-168:
`impl Into` + implicit alloca+store for `*T` targets) firing without an
Into impl actually applying; (2) a generic struct-literal-to-pointer spill
arm in stmt.zig's annotated-decl handling. Find which path accepts
Widget→*Sizable, and make the no-conversion case diagnose instead of
spilling. NOTE: under the REFLECT erasure-model redesign
(current/CHECKPOINT-REFLECT.md ⏯ block), rvalue → view is a DEFINED refusal
("nothing durable to borrow") — this fix is that refusal arriving early.
Verification: the repro produces a clean diagnostic; sibling check that
`pv : *Sizable = w` (lvalue, issue 0303's cell) also diagnoses rather than
crashing; `zig build test` green.

## Discovered

2026-07-18, REFLECT erasure-model stress review, probe SR-P3b
(.sx-tmp/sr-p3b.sx). Pre-existing.
