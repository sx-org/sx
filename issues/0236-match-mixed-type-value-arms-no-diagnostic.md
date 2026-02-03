# 0236 — match arms with MIXED result types never diagnose (PHI verifier failure)

> **RESOLVED (2026-07-04).** `inferMatchResultType` (src/ir/lower/generic.zig)
> now UNIFIES the result type across all value-producing arms instead of taking
> the first decisive arm's type. Policy: numerics join SYMMETRICALLY over the
> implicit-coercion lattice — float beats int, wider beats narrower — so arm
> order never picks the type (preserves the issue-0226 pinned "f64 payload arm
> + int-literal arm → f64" in BOTH orders; deliberately stronger than the
> if/else-expression merge, which is first-branch-wins and silently truncates
> `if cond { an_i32 } else { an_i64 }`). Non-numeric pairs mirror if/else
> exactly: the earlier type wins when the later arm coerces to it (a modeled
> coercion or a same-width reinterpret — `!noneReinterpretIsUnsafe`, the
> issue-0197 store-guard predicate), else the join flips when only the other
> direction coerces; no safe direction either way is a true mismatch and gets
> a located "match arms have incompatible types: 'T' vs 'U'" at the offending
> arm (matching if/else's diagnose-on-uncoercible policy: `if cond { 1 } else
> { 2.5 }` diagnoses the narrowing). `null` arms now contribute optionality
> (?T) wherever they appear; diverging (`noreturn`) and void arms stay out of
> the join. A backstop at the merge feed in `lowerMatch`
> (src/ir/lower/control_flow.zig) catches inference-blind arms — diagnose
> (cascade-gated on errorCount()==0) + inert undef so no mixed-type phi can
> reach the verifier. Arm values coerce to the unified type via the same
> `coerceToType` the if/else merge uses.
> Regression tests: examples/diagnostics/1224-diagnostics-match-arm-type-mismatch.sx
> (true mismatches, exit 1) and examples/types/0803-types-match-arm-unification.sx
> (order-independent unification, exit 0), plus a unit test in
> src/ir/lower.test.zig. Note: value-position if/else shares the pre-fix
> silent-PHI hole for true mismatches (`if cond { 1 } else { "hi" }`), and
> diverging branches/arms in value position mis-lower in both constructs —
> separate pre-existing bugs, reported to the coordinator, not fixed here.

## Symptom

One-line: a value-position match whose arms produce different types —
`if c == { case .red: { 1 } case .green: { "hi" } }` — fails LLVM
verification ("PHI node operands are not the same type as the result!")
with no located diagnostic.

- Observed: verifier failure, exit 1, no diagnostic (value arms);
  capture-dependent variants share the failure mode since the issue-0226
  fix (before it they panicked exit 134).
- Expected: a located "match arms have incompatible types: 'i64' vs
  'string'" diagnostic at the offending arm.

Pre-existing on baseline e91df844 (verified by the 0222/0224/0226
review, 2026-07-03).

## Reproduction

```sx
#import "modules/std.sx";
Color :: enum { red; green; }
main :: () {
    c : Color = .red;
    r := if c == { case .red: { 1 } case .green: { "hi" } };  // PHI verifier failure
    print("{}\n", r);
}
```

## Investigation prompt

`inferMatchResultType` (src/ir/lower/generic.zig) types the arms but
evidently picks one arm's type without unifying/diagnosing when arms
disagree, and the lowering (src/ir/lower/control_flow.zig) PHIs the raw
arm values. Add an arm-type unification pass: infer each arm's type
(captures bound, per the 0226 machinery), unify with the usual coercion
lattice (numeric widening allowed? check what if/else expression arms do
— `if cond { 1 } else { 2.0 }` — and mirror that policy), and diagnose
per-arm on mismatch with the arm's span. Coercible-but-unequal arms
(i32 + i64) should coerce to the unified type before the PHI if if/else
does. Verify: the repro diagnoses cleanly; homogeneous arms unchanged;
coercible arms match if/else policy; capture-dependent arms too; corpus
green; diagnostics regression example.

Found by the adversarial review of the 0222/0224/0226 fix (2026-07-03).
