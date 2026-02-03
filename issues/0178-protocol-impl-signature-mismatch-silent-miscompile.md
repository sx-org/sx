# 0178 — protocol impl method with a mismatched return/param TYPE silently miscompiles

> **RESOLVED.** The issue-0176 conformance gate was name-only, so an `impl P for
> T` with a mismatched return/param type (or arity) built a wrong-ABI thunk that
> silently miscompiled (exit 0, wrong value). Fix (`src/ir/lower/protocol.zig`):
> `firstUnimplementedMethod` now validates each impl method's signature against
> the protocol declaration — arity (after `self`), every param type, and the
> return type — substituting protocol `Self`→concrete via `resolveProtoTypeSubSelf`
> (recurses through pointer/many-pointer/optional/slice/array so `[]Self`↔`[]T`
> etc. match; conservative `.unresolved` for `Self`-in-generic-arg). Comparison
> is by structural `formatTypeName` (alias/module/spelling independent), and
> `typesClearlyDiffer` skips when either side has an unresolved leaf at any depth
> — biased against false-positives. Mismatch → located diagnostic. Verified by
> 3+3 adversarial reviews (a mid-fix `[]Self` false-positive was found and
> closed); suite 792/0. Regressions:
> `examples/diagnostics/1201-diagnostics-protocol-impl-signature-mismatch.sx`
> (negative), `examples/protocols/0420-protocol-self-in-slice-param.sx`
> (positive). Known gaps (pre-existing, loud not silent — out of scope): a
> `Self`-through-generic-arg mismatch (`Box(Self)`) and by-value array protocol
> params (`[2]Self`) fail at LLVM verification, not silently.

## Symptom

An `impl P for T` whose method has the right NAME but a mismatched return type or
parameter type is accepted (it satisfies the issue-0176 conformance gate, which
is name-based), and dispatch through the erased protocol silently produces the
WRONG result (exit 0). No diagnostic. (Arity mismatch and `#builtin`-body
mismatch fail loudly — exit 1 — and are not this bug; the TYPE-mismatch cases are
silent.)

## Reproduction

```sx
#import "modules/std.sx";
P :: protocol { val :: (self: *Self) -> i64; }
T :: struct { n: i64 = 7; }
impl P for T { val :: (self: *T) -> bool { return true; } }  // return type bool ≠ i64
main :: () {
  t := T.{ n = 7 };
  p : P = t;
  print("{}\n", p.val());   // prints "1" (the bool), silently wrong — no diagnostic
}
```

A parameter-type mismatch (`x: bool` where the protocol declares `x: i64`)
similarly dispatches silently wrong.

## Investigation prompt

The issue-0176 conformance gate (`firstUnimplementedMethod` in
`src/ir/lower/protocol.zig`) checks method PRESENCE (and rejects `type_params >
0`), but does NOT check that the impl method's SIGNATURE (parameter types,
arity, return type) matches the protocol method's declared signature. A
mismatched-type impl builds a thunk that calls the impl with the wrong ABI,
silently miscompiling. Add signature validation when registering / gating an
impl method against its protocol method: compare the impl method's params
(after the erased `self`) and return type against the protocol declaration, and
emit a located diagnostic on mismatch (arity, param type, or return type). The
protocol method declaration is in `protocol_decl_map`; the impl FnDecl is in
`fn_ast_map`. Decide whether this lives in the conformance gate or in
`ProtocolResolver.registerImplBlock` (`src/ir/protocols.zig`). Follow the
no-silent-fallback rule. Verify: the repro is now a clean diagnostic (exit 1);
a correctly-typed impl still works; add an `examples/diagnostics/11xx-...`
negative regression. (Found during adversarial review of issue 0176.)
