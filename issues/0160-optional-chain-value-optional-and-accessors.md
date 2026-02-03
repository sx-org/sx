# 0160 — optional-chain field access: `?T` value-optional read miscompiles, and `#get`/`#set` accessors aren't reached through `?.`

> **RESOLVED.** Root cause was MIS-DIAGNOSED in the original writeup below: (A)
> was NOT an optional-chain bug — the chain works fine for real fields. The real
> bug was **struct-literal → optional coercion**: a bare `.{ ... }` against a
> `?T` target was built into the optional's `{payload, has_value}` layout
> instead of building the inner `T` and wrapping it. Fix:
> `lowerStructLiteral` (`src/ir/lower/expr.zig`) now builds the inner `T`,
> materializes it, and wraps via `coerceToType`; and `lowerVarDecl`
> (`src/ir/lower/stmt.zig`) only wraps when the value is not already the target
> optional (its previous UNCONDITIONAL wrap double-wrapped any already-`?T`
> value). (B) the `#get`-through-`?.` gap was real and is fixed:
> `lowerOptionalChain` dispatches the getter via a synthetic receiver, and
> `expr_typer` types `obj?.getter` through a shared `getterReturnTypeOnDeref`
> helper (handles `?T` and `?*T`). The `#set` write side through `?.` is
> intentionally left matching real-field behavior (optional-chain assignment is
> unsupported for all fields) and was never part of this bug. Regression tests:
> `examples/optionals/0906-optionals-struct-literal-into-optional.sx` and
> `examples/optionals/0907-optionals-accessor-through-chain.sx`.
>
> **Review follow-ups (5 adversarial reviews on the fix):** three further
> optional bugs in the touched code were fixed in the same pass — (1) a COLD
> generic-instance getter through `?.` panicked (`?unresolved`) because the
> monomorph wasn't lowered before its return type was queried; `lowerOptionalChain`
> + `getterReturnTypeOnDeref` now warm it. (2) a real-field read through a `?*T`
> chain reinterpreted the pointer bits as the field (silent garbage); the
> some-branch now loads through the pointer. (3) `?[]T = array` skipped
> array→slice promotion (corrupt `.len`); `lowerVarDecl`'s optional arm now
> coerces to the child before wrapping. Both regression examples were extended.
> Separately-filed PRE-EXISTING bugs the reviews surfaced (distinct subsystems,
> untouched here): [[0161]] struct-literal vs scalar, [[0162]] `#run` returning an
> optional aggregate, [[0163]] untagged-union payload-binding match.

## Symptom

Two related gaps in optional-chain field access (`obj?.field`), surfaced while
extending property accessors (`#get`/`#set`) — but the root problem (A) is
PRE-EXISTING and independent of accessors:

- **(A) `?T` value-optional read of a real field miscompiles.** `ot?.raw` where
  `ot : ?T` (optional of a *value* struct) fails LLVM verification:
  `Invalid InsertValueInst operands! ... insertvalue { { i64 }, i1 } undef, { { i64 }, i1 } %si, 0`
  — the some-branch builds the result optional by inserting the WHOLE
  `{payload, has_value}` aggregate where the bare payload is expected.
  Observed: LLVM verification failure (compile abort). Expected: prints `7`.
  *(The `?*T` pointer-optional form of the same read works correctly, so the
  bug is specific to value-optionals.)*

- **(B) `#get`/`#set` accessors are not reached through `?.`.** `pt?.p` where
  `p` is a `#get` accessor gives `field 'p' not found on type '*T'` — the
  optional-chain read path (`lowerOptionalChain`) resolves only real fields, not
  accessors. (The write form `obj?.p = x` is consistent with real fields, which
  also reject optional-chain assignment, so the write side is NOT part of this
  issue.)

(B) is blocked on (A): a correct `obj?.getter` read must run the getter inside
the optional's some-branch and re-wrap the result as `?R`, i.e. it reuses the
exact some-branch/merge optional-construction path that (A) miscompiles for
value-optionals. Layering accessor dispatch onto that path while it miscompiles
would bake the same bug into accessors.

## Reproduction

(A) — value-optional real-field read (LLVM verify failure):
```sx
#import "modules/std.sx";
T :: struct { raw: i64 = 7; }
main :: () {
    ot : ?T = .{ raw = 7 };
    print("{}\n", ot?.raw);   // expected: 7 — actual: LLVM verification failure
}
```

(B) — accessor through optional chain (field-not-found):
```sx
#import "modules/std.sx";
T :: struct {
    raw: i64 = 0;
    p :: (self: *T) -> i64 #get => self.raw;
}
main :: () {
    t : T = .{ raw = 4 };
    pt : ?*T = @t;
    print("{}\n", pt?.p);     // expected: 4 — actual: field 'p' not found on type '*T'
}
```

## Investigation prompt

Fix (A) first; (B) builds on it.

**(A)** In `src/ir/lower/expr.zig` `lowerOptionalChain` (the some-branch around
the `optional_wrap` of `field_val`): when the optional's child is a *value*
struct (`?T`, not `?*T`), the result optional is mis-assembled — the verifier
sees a `{ {i64}, i1 }` inserted into slot 0 of `{ {i64}, i1 }` instead of the
bare `{i64}` payload. Check `field_already_optional` / the `optional_wrap`
operand type and the `inner_ty` used for `optional_unwrap` vs.
`lowerFieldAccessOnType` — the some-branch likely wraps an already-aggregate
value, or unwraps to the wrong level for a value-optional. Compare against the
working `?*T` path (pointer-optional) to see where the value-optional diverges.
Verify with repro (A): expect `7`, no LLVM verification failure. Add
`examples/optionals/09xx-optionals-value-optional-chain-read.sx`.

**(B)** Once (A) is sound: teach the optional-chain read to dispatch a `#get`
accessor. The dereferenced (optional-unwrapped, then pointer-deref'd) receiver
type may have a getter — `Lowering.getAccessorFor(deref_ty, field)`. In
`lowerOptionalChain`'s some-branch, when a getter exists, bind the unwrapped
receiver to a synthetic local (see `bindSyntheticLocal` in
`src/ir/lower/stmt.zig` for the pattern) and lower a non-optional `tmp.field`
read (which hits the existing getter intercept in `lowerFieldAccess`), then wrap
as `?R`. Mirror the type in `src/ir/expr_typer.zig` — the `.field_access`
optional-chain arm already calls `getAccessorFor` after unwrapping the optional,
but it does NOT peel the extra pointer layer for a `?*T` receiver (so
`getAccessorFor(*T, ...)` returns null); peel the pointer there too. Verify with
repro (B): expect `4`. Add a regression example.

## Provenance

Found during the `#set` accessor review (mirrors the `#get` accessor). The
`#set`/`#get` work itself is complete and green; this issue is the optional-chain
interaction it surfaced. The `#set` write side through `?.` is intentionally left
matching real-field behavior (optional-chain assignment unsupported) and is not
part of this issue.
