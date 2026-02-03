# 0305 — explicit `w.(*P)` / `xx` aggregate→pointer reinterpret: accepted, LLVM verifier crash

> **RESOLVED (2026-07-18)** — NOT by refusal: the corpus proved both
> directions of explicit aggregate↔scalar reinterprets are load-bearing
> (~50 examples: `Ev→i64`, `i64→string`, `closure→*Block`, …), working
> store-mediated. The issue's "no semantics to opt into" was wrong — the
> semantics is a SPILL-REINTERPRET, and the fix makes the escape hatch
> deliver it for real: coerceMode's `.none` `.explicit` arm for
> aggregate↔scalar pairs (isAggregateValueKind, by IR representation —
> string/any/slice/closure count as aggregate) emits zero-init slot (typed
> as the larger side) → store src → load dst, yielding a genuinely
> dst-typed value in EVERY context. The crash class (mistyped SSA value
> hitting icmp/call args) is unrepresentable now; width mismatches are
> deterministic (zero-filled). ROOT FIX en route: the field-assign target
> hook missed the `.ptr`/`.len` pseudo-fields on string/slice, letting the
> enclosing fn's RETURN type leak as the RHS xx target (`s.ptr = xx raw`
> in fmt.sx typed as xx-to-string) — it now mirrors the store arm's field
> types. Regression: examples/types/0874-types-explicit-reinterpret-spill.sx
> (both directions + the crash shape in a value context + zero-fill).

## Symptom

An EXPLICIT cast (`.(T)` / `xx`) from a struct VALUE to a pointer type is
accepted via the escape-hatch exemption (explicit casts skip the
assignability guards), but the passthrough keeps the value struct-typed —
downstream use emits broken IR and compilation aborts in the LLVM verifier
with no diagnostic:

```
LLVM verification failed: Invalid operand types for ICmp instruction
  %icmp = icmp ne { i64 } %load2, zeroinitializer
```

## Reproduction

```sx
#import "modules/std.sx";
Sizable :: protocol { size :: (self: *Self) -> i64; }
Widget :: struct { value: i64; }
impl Sizable for Widget { size :: (self: *Widget) -> i64 { self.value } }
main :: () {
    w := Widget.{ value = 4 };
    pv := w.(*Sizable);
    print("made: {}\n", pv != null);
}
```

Expected: a compile diagnostic. The explicit-reinterpret escape hatch
("width be damned") is only honorable for the scalar family (`*T → [*]T`,
`i64 → isize`, fn-ref → fn slot) — LLVM has no value-cast from an aggregate
to a pointer, so accepting this ALWAYS produces broken IR; there is no
semantics to opt into.

## Investigation prompt

The aggregate↔scalar pun rule added in e8fd6f74
(src/ir/lower/coerce.zig `noneReinterpretIsUnsafe` / `isAggregateValueKind`)
deliberately sits BEHIND the explicit-cast exemptions
(`initIsExplicitCast` in checkAssignable; `xx_passthrough_refs` in
implicitNoneMismatchExempt; the `.explicit` arm of coerceMode's `.none`
case). Move the aggregate-pun check IN FRONT of those exemptions: an
explicit `.none` cast whose pair is aggregate↔scalar diagnoses ("an
aggregate value cannot be reinterpreted as a pointer/scalar; take its
address (`@w`) or use a modeled conversion") instead of passing through.
Nothing can regress: every such cast crashes the verifier today.
Verification: the repro produces one clean diagnostic; `zig build test`
green (no corpus site performs an explicit aggregate↔scalar reinterpret —
the suite passed with the implicit-side guard already).

## Discovered

2026-07-18, erasure-model stress review, probe SR-P8
(.sx-tmp/sr-p8-postfix-starP.sx). Pre-existing (the exemption predates the
guard); surfaced by probing the `w.(*P)` completeness cell.
