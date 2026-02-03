# 0161 — struct literal against a non-aggregate (scalar) type crashes instead of diagnosing

> **RESOLVED.** Root cause: `lowerStructLiteral` (src/ir/lower/expr.zig) called
> `getStructFields(ty)` and fell through to `structInit`/`insertvalue` without
> ever checking that the resolved target `ty` is an aggregate — a scalar target
> produced `insertvalue` against a scalar LLVM type (verification failure), and
> the empty `.{}` produced a fieldless `struct_init` that read back as garbage.
> Fix: after the tagged-union / union / optional intercepts, a guard accepts
> only struct / tuple / array / vector / slice (plus the builtin `string` fat
> pointer) — both `{ptr, len}` literal forms are stdlib/corpus idioms — and otherwise emits
> "cannot build a struct literal for non-struct type '…'" and returns a typed
> zero placeholder (`hasErrors()` aborts before codegen). The `?i64 = .{...}`
> optional recursion lands on the same guard via the unwrapped child type.
> Regression test: `examples/diagnostics/1209-diagnostics-struct-literal-non-aggregate.sx`.

## Symptom

A struct literal `.{ field = ... }` whose resolved target type is a scalar (or
any non-struct) reaches LLVM emission and fails verification, instead of emitting
a clean "struct literal against non-struct type" diagnostic.

- Observed: `LLVM verification failed: Invalid InsertValueInst operands! %si = insertvalue i64 undef, i64 1, 0` (exit 1).
- Expected: a diagnostic like "cannot build a struct literal for non-struct type 'i64'".

`.{}` (empty) against a scalar is worse — it silently produces garbage with no
diagnostic.

This surfaced while reviewing issue 0160: `?i64 = .{...}` routes through the
struct-literal→optional path (which recurses with the child type `i64` as
target) into this same crash. But it is NOT optional-specific — a plain
`i64 = .{...}` crashes identically, so the root cause is the general
struct-literal path, not the 0160 optional handling.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
    x : i64 = .{ a = 1 };   // struct literal targeting a scalar
    print("{}\n", x);       // actual: LLVM verification failure
}
```
Also: `y : i64 = .{}` → silent garbage; `o : ?i64 = .{ a = 1 }` → same crash.

## Investigation prompt

`src/ir/lower/expr.zig` `lowerStructLiteral`: after the resolved literal type
`ty` is computed (and the optional/union special-cases), the named/positional
field path calls `getStructFields(ty)` and emits `structInit`/`insertvalue`
without first checking that `ty` is actually a struct. Add an early guard: if
`ty.isBuiltin()` or `module.types.get(ty)` is not `.@"struct"` (after the
existing tagged-union / union / optional intercepts), emit a diagnostic via
`self.diagnostics.addFmt(.err, span, "...", .{...})` and return a placeholder,
rather than building `insertvalue` against a scalar LLVM type. Verify with the
repro (expect a clean error, exit 1, no LLVM panic). Add
`examples/diagnostics/11xx-...` for the negative case.
