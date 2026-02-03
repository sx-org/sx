> **RESOLVED.** A value-position `match` whose arms are MIXED — some yield a real
> value, some yield void (a bare-statement tail like `case .A: { print("x\n"); }`,
> or a no-`else` `if` tail) — is now a clean located compile-time error instead of
> reaching the backend as `alloca void` / `i64 undef`. **Fix** (`lowerMatchExpr`
> in `src/ir/lower/control_flow.zig`): before lowering, when the `match` is in
> value position (`force_block_value`), classify each non-diverging arm via
> `armYieldsVoid` (empty block, a no-`else` `if` tail, or a tail expression that
> types `void`; `null` and `;`-terminated value tails are NOT void — a `match`
> arm's `;` does not discard). If the arms are a MIX of value and void, emit
> `diagnostics.addFmt(.err, arm.body.span, "this \`match\` arm is used as a value
> but yields no value …")` at each void arm — mirroring the 0270 value-`if`
> diagnostic. A `match` used purely as a STATEMENT (all arms void) still works; a
> value `match` with a diverging arm (`return`/`break`/…) still works (the
> diverging arm is excluded via `armStaticallyDiverges`). A related `match`
> result-type fix (`inferMatchResultType` skipping diverging arms) landed with
> issue 0269. Regression test:
> `examples/diagnostics/1233-diagnostics-value-match-void-arm.sx`.

# 0271 — value-position `match` with a void-yielding arm crashes (`alloca void`)

## Symptom

A block-form `match` used in VALUE position, where one arm's body yields **no
value** (a void tail — a `print(...)` statement, a no-`else` `if`, etc.) while
sibling arms yield a real value, reaches the backend as an unsized `alloca void`
instead of being rejected with a located type error.

- **Observed:** `LLVM verification failed: Cannot allocate unsized type …
  %alloca = alloca void` (and `Call parameter type does not match … i64 undef`).
- **Expected:** a clean compile-time located error — the arms of a value
  `match` must all yield a common value type (analogous to the if/else
  arm-type-mismatch and the issue-0270 "an `if` used as a value must have an
  `else`" diagnostic).

## Reproduction

```sx
#import "modules/std.sx";

E :: enum { A; B; }

main :: () {
    e := E.A;

    // Arm .A yields void (a bare statement); arm .B yields i64.
    y := if e == {
        case .A: { print("x\n"); }
        case .B: { 2 }
    };
    print("{}\n", y);
}
```

The no-`else` `if` form triggers the same crash (this is how it was found while
verifying issue 0270):

```sx
    y := if e == {
        case .A: { if true { 1 } }   // no-else if → void tail
        case .B: { 2 }
    };
```

## Notes on scope

- This is **not** specific to `if`. A plain void-tail arm (`case .A: { print("x\n"); }`)
  crashes identically — so it is a general "value-`match` arm yields void" defect,
  distinct from the issue-0270 `if`-lowering fix (which correctly rejects a
  no-`else` `if` in *directly-lowered* value positions).
- The `if`/`else` analog IS handled: `y := if c { if true { 1 } } else { 2 }`
  correctly produces the 0270 located error. The asymmetry is because value-`if`
  arms are lowered via `lowerExpr` (keeping `force_block_value` set, so
  `lowerIfExpr`'s guard fires), whereas value-`match` arms are lowered via
  `lowerBlockValue` (`src/ir/lower/control_flow.zig` ~line 1228), and
  `lowerBlockValue`'s `isNoElseValuelessIf` exemption (`src/ir/lower/stmt.zig`
  ~line 142) clears `force_block_value` for the tail — so the guard never fires
  and the resulting void arm value is branched into the i64 merge phi.

## Suspected area / fix direction

`src/ir/lower/control_flow.zig`, the value-`match` lowering (`lowerMatchExpr` /
its per-arm `lowerBlockValue` calls, ~line 1228). When the match is in value
position (a merge phi with a non-void result type), each arm body MUST yield a
value of the common type; an arm whose lowered body value is `void`/`.unresolved`
should be a located error (`self.diagnostics.addFmt(.err, arm.body.span, "...")`),
NOT branched into the phi. Prefer diagnosing at the arm level so the message can
point at the offending arm. Do not paper over with a silent default.

## Investigation prompt (paste into a fresh session)

> Fix issue 0271: a value-position block-`match` whose one arm yields void (a
> bare statement tail like `case .A: { print("x\n"); }`, or a no-`else` `if`
> tail) crashes the backend with `alloca void` / `i64 undef` instead of a located
> error. The value-`if`/`else` analog is already handled (issue 0270). Root cause:
> value-`match` arms lower via `lowerBlockValue` (`src/ir/lower/control_flow.zig`
> ~1228), and `lowerBlockValue`'s `isNoElseValuelessIf` exemption (`stmt.zig` ~142)
> clears `force_block_value`, so a void arm value is fed into the i64 merge phi.
> Fix: in the value-`match` lowering, detect an arm whose lowered body type is
> `void`/`.unresolved` (while the match is producing a value) and emit a located
> error pointing at that arm — mirror the 0270 diagnostic. Verify: the two repros
> now error cleanly (no `alloca void`, no `i64 undef`); a well-formed value-`match`
> (all arms yield the same type) still works; a `match` used purely as a STATEMENT
> (arms yield void) still works. Add a diagnostics regression example, seed the
> marker, capture goldens scoped with `-Dname`.
