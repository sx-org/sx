# 0172 — `??` with a non-optional left-hand side panics instead of diagnosing

> **RESOLVED.** `lowerNullCoalesce` fed `resolveOptionalInner`'s `.unresolved`
> (returned for a non-optional lhs) into the merge-block / `optionalUnwrap` / RHS
> target type → codegen panic. Fix (`src/ir/lower/expr.zig`): before computing
> `inner_ty`, if `inferExprType(nc.lhs)` is a RESOLVED non-optional type, emit a
> located diagnostic ("left operand of '??' must be an optional, but has type
> '<T>'") and bail; an `.unresolved` lhs (prior error) is excluded to avoid
> double-report. `??` is optional-only per specs.md (error unions use
> `or`/`catch`), so rejecting a failable lhs is correct. Comptime panic closed
> too. Verified by 3 adversarial reviews; suite 790/0. Regression:
> `examples/diagnostics/1200-diagnostics-null-coalesce-non-optional.sx`. (Adjacent
> pre-existing `??`-lowering defects found + filed: 0180 — generic / alias /
> tuple optional lhs.)

## Symptom

Using `??` where the left operand is NOT an optional panics the compiler:
`panic: unresolved type reached LLVM emission` (in `emitStructInit` for a struct
default, or generally), exit 134. `??` is defined to operate on an optional lhs;
a non-optional lhs is malformed user input that must be a clean type error, not a
crash. Pre-existing (reproduces independent of the issue 0166 fix).

## Reproduction

```sx
#import "modules/std.sx";
T :: struct { a: i64 = 0; }
main :: () {
  x := 5 ?? .{ a = 1 };   // panic: unresolved type reached LLVM emission, exit 134
}
```

Also panics: `5 ?? 7` (scalar default), `some_non_optional_struct ?? .{ a = 1 }`,
and nested `mk() ?? (5 ?? .{ a = 3 })`. Expected: a located diagnostic like
`error: left operand of '??' must be an optional, but has type 'i64'`, exit 1.

## Investigation prompt

`src/ir/lower/expr.zig` `lowerNullCoalesce`: `resolveOptionalInner` (~expr.zig:1900)
returns `.unresolved` when `nc.lhs` is not optional, and the function proceeds to
feed that `.unresolved` into the merge-block params, `optionalUnwrap`, and the
RHS target type — which then reaches codegen and panics. Add a guard: after
inferring the lhs type, if it is not an optional (or `resolveOptionalInner`
yields `.unresolved` for a resolved-but-non-optional lhs), emit
`self.diagnostics.addFmt(.err, nc.lhs.span, "left operand of '??' must be an
optional, but has type '{s}'", .{ formatTypeName(lhs_ty) })` and bail (return a
placeholder), mirroring the non-pointer `.*` deref diagnostic at
`lowerDerefExpr` (~expr.zig:1839). Be careful to still allow the legitimate
cases: optional lhs (incl. `a?.b` chains returning optional), and make sure an
already-`.unresolved` lhs from a PRIOR error (undefined name) doesn't
double-report (that path already diagnoses via name resolution).

Verify: `5 ?? .{a=1}`, `5 ?? 7`, non-optional-struct `?? ...` all exit 1 with the
diagnostic and no panic; existing optional `??` cases still work. Add an
`examples/diagnostics/11xx-null-coalesce-non-optional.sx` negative regression.
