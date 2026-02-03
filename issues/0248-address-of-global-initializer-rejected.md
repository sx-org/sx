# 0248 — `@target` (address-of a global) rejected as a global initializer

> **RESOLVED (2026-07-10).** Static constants now represent relocatable global addresses, global DCE retains referenced targets, and LLVM initialization resolves those references after all globals are available.

## Symptom

One-line: `g : *i64 = @target;` at module scope (where `target` is
another module global) diagnoses "must be initialized by a compile-time
constant" — but the address of a global IS link-time constant (C and
Zig both allow it; LLVM models it as a constant GEP/global reference).

- Observed: rejection at the const-initializer check; same for the
  optional form `g : ?*i64 = @target;`.
- Expected: a global's address is a relocatable constant — accept it and
  emit the LLVM global-reference initializer.

Not optional-specific (verified by the issue-0234 fix worker,
2026-07-04); pre-existing.

## Reproduction

```sx
#import "modules/std.sx";

target : i64 = 42;
g : *i64 = @target;      // error: must be initialized by a compile-time constant

main :: () -> i32 {
    print("{}\n", g.*);  // expected 42
    0
}
```

## Investigation prompt

The global-initializer const-eval (src/ir/lower/decl.zig — the check
that produced "must be initialized by a compile-time constant", near
globalInitValue) has no arm for an address-of-global expression. Add a
ConstantValue kind (or reuse an existing global-ref kind if one exists
— grep emit_llvm for how fn-pointer globals initialize, which DO work?
probe `fp : (i64)->i64 = some_fn;` at module scope first) representing
"address of global N (+ offset)", thread it through globalInitValue →
emitGlobals as an LLVM global-reference constant. Cover: plain
`@target`, field address `@gs.a` (constant GEP), array element
`@garr[2]`, the optional wrap `?*i64 = @target` (composes with the
0234 fix), and cyclic references (`a : *i64 = @b; b : i64 = 1;` fwd
order). The comptime-VM global model (issue 0247) will need the same
representation — coordinate if both land. Verification: the repro
prints 42; JIT and AOT; regression under examples/memory/ or types/;
corpus green.

Found by the issue-0234 fix worker (2026-07-04); pre-existing.
