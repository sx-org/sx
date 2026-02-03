# 0166 — `?? .{ ... }` struct-literal default panics with "unresolved type reached LLVM emission"

> **RESOLVED.** The `??` RHS struct literal was lowered with no target type, so
> its `struct_init.ty` stayed `.unresolved` and reached `emitStructInit`. Fix:
> in `src/ir/lower/expr.zig` `lowerNullCoalesce`, save `self.target_type`, set it
> to `inner_ty` (the optional's resolved child) before lowering `nc.rhs`, and
> restore afterward (unconditional, leak-free — `lowerExpr` returns a plain
> `Ref`). Verified across struct/slice/enum/tuple/protocol/nested-optional/
> generic child types and present/absent branches by 3 adversarial reviews.
> Regression: `examples/optionals/0912-null-coalesce-struct-literal.sx`.
> (Adjacent pre-existing bug found + filed: 0172 — `??` on a NON-optional lhs
> panics; `lowerNullCoalesce` must diagnose it.)

## Symptom

Using a struct literal as the default of a `??` (null-coalesce) operator panics:

```
panic: unresolved type reached LLVM emission
```

in `emitStructInit` (exit 134 / SIGABRT). The coalesce result type is inferred
correctly (the optional's child `T`), but that target type is NOT threaded into
the RHS struct-literal lowering, so the `struct_init` instruction's `.ty` stays
`.unresolved` and reaches codegen.

## Reproduction

```sx
#import "modules/std.sx";
T :: struct { a: i64 = 0; }
mk :: () -> ?T { return null; }
main :: () { t := mk() ?? .{ a = 9 }; print("{}\n", t.a); }
```

Expected: `9` (null lhs → take the struct-literal default, typed as `T`).
Observed: `panic: unresolved type reached LLVM emission`, exit 134.

## Investigation prompt

The result type IS inferred correctly — `src/ir/expr_typer.zig` (~lines 413–425)
returns the optional's child `T` for the coalesce expression. The gap is in
lowering: the `??` RHS struct literal is lowered without a target type. Suspected
area: `src/ir/lower/expr.zig` `lowerNullCoalesce` (dispatched ~expr.zig:2417)
must set the lowering target type to the lhs optional's child (`T`) before
lowering `nc.rhs`, so an untyped `.{ ... }` literal on the RHS resolves to `T`
the same way an assignment/return target would. Mirror however other contexts
push an expected type into an untyped struct-literal lowering.

Verify: the repro prints `9`; also test a present lhs (`mk` returns a value →
prints the value's field, default not taken) and a nested-field struct literal
default. Add an `examples/optionals/09xx-null-coalesce-struct-literal.sx`
regression.
