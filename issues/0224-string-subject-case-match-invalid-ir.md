# 0224 — a string-subject case match emits invalid LLVM IR

> **RESOLVED (2026-07-03).** Semantics decision: string subjects are
> **REJECTED**, not lowered as an equality chain. Evidence from specs.md
> §Pattern Matching: case patterns are exhaustively "Enum literals",
> "Integer/bool literals", and "Type categories" — string literal patterns
> are not part of the language (the `string` CATEGORY keyword applies only to
> Type-value matches), and no corpus or library code used string case-matches
> (it could never have worked — it always failed LLVM verification). Root
> cause: same missing subject gate as issue 0222 — the string (pointer)
> scrutinee reached `switch_br` against integer case constants. Fix: the
> subject-type gate in `lowerMatch` (`src/ir/lower/control_flow.zig`) rejects
> non-dispatchable subjects with "cannot match on '<T>' — match subjects must
> be enums, tagged unions, integers, or bools". Adjacent probes: **f64**
> subjects produced the same verifier failure (`switch double`) → now rejected
> by the same gate; **bool** subjects already worked (unchanged);
> **pointer** subjects to an integer/bool pointee produced `switch ptr` →
> now auto-DEREF and match on the pointee, per specs §for by-ref capture
> ("a pointer subject matches through the deref"), joining the existing
> pointer-to-tagged-union/enum deref. Regression tests:
> `examples/diagnostics/1221-diagnostics-string-subject-match.sx` (string +
> f64 rejection) and the pointer-to-int leg of
> `examples/types/0802-types-match-pointer-tagged-union-value.sx`.
>
> **Review fold.** A `case string:` type-CATEGORY pattern no longer smuggles
> a string VALUE subject past the gate — the type-match exemption keys off
> the SUBJECT type (`.type_value`, i.e. `type_of(...)` / `$T` results), not
> the patterns. Direct `Any` subjects flip from silently-wrong dispatch on
> the unboxed value (baseline printed the wrong arm, exit 0) to rejection.
> The gate message now names the full legal set: enums, tagged unions,
> error sets, optionals, integers, bools, or Type values.

## Symptom

One-line: `if s == { case "hi": { ... } case "bye": { ... } }` on a
`string` subject fails LLVM verification — `Switch constants must all be
same type as switch value!` (`switch ptr %etag`) — instead of either
working (string equality dispatch) or being rejected with a diagnostic.

- Observed: LLVM verification failure, exit 1, no located diagnostic.
- Expected: either lower string case-matches as an if-else equality
  chain (strings can't drive an LLVM switch), or a clean diagnostic that
  string subjects aren't matchable.

Pre-existing (verified identical on master e91df844). Zero corpus or
library coverage of string case-matches exists today. Same
enumTag-on-non-union family as issue 0222 but a distinct subject type.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
    s : string = "hi";
    r := if s == { case "hi": { 1 } case "bye": { 2 } else: { 0 } };
    print("{}\n", r);   // LLVM verification failure today
}
```

## Investigation prompt

In `lowerMatch` (`src/ir/lower/control_flow.zig`), the tag computation
produces the raw string (pointer) as the switch scrutinee and the case
values as incompatible constants. FIRST check specs.md §match for
whether string subjects are meant to be supported. If yes: lower the
string-subject match as a sequential `string_eq` if-else chain (the
equality helper the `==` operator on strings already lowers to — grep
the string-equality lowering), keeping arm order semantics and `else:`;
if no: reject the subject type up front with a located diagnostic
("cannot match on 'string' — match subjects must be enums, tagged
unions, or integers"). Never hand a ptr-scrutinee switch to the
verifier. Check adjacent subject types while there: f64 subjects, bool
subjects, pointer subjects — probe each; any that produces verifier
errors joins this fix or gets the same rejection. Verification: the
repro either prints 1 or diagnoses cleanly; regression example
(examples/basic or examples/diagnostics per the decision); full corpus
green.

Found by the adversarial review of the issue-0163 fix (2026-07-03).
