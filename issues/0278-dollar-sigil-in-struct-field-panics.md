# 0278 — `$T` sigil in a struct field type panics the backend

> **RESOLVED** (2026-07-09). Root cause: `reportIfValueParamInTypePosition`
> (`src/ir/semantic_diagnostics.zig`) only fired when an `is_generic` name was
> *found* in the struct's in-scope type params and turned out to be a value
> param. When the name was **not** in scope — the case for a literal `$T` sigil
> in a field of a struct with no matching header param — the loop fell through
> silently, the field type resolved to `.unresolved`, and reached LLVM emission
> → `@panic("unresolved type reached LLVM emission")`.
> Fix: thread a `struct_field: bool` context flag through
> `checkTypeNodeForUnknown`; in struct-field position an `is_generic` name not
> in scope (only reachable via a literal `$T`) now emits a located diagnostic.
> Regression test: `examples/diagnostics/1234-diagnostics-dollar-sigil-struct-field.sx`.

## Symptom

A struct field whose type is written with the `$T` comptime-type-param sigil,
in a struct that does NOT declare `T` in its header, panics the LLVM backend
instead of producing a diagnostic.

- Observed: `panic: unresolved type reached LLVM emission — a type resolution
  failure was not diagnosed/aborted` (`src/backend/llvm/types.zig:196`), exit 0
  (crash).
- Expected: a clean, located compile-time diagnostic pointing at the `$T` field
  type; nonzero exit; no panic.

## Reproduction

```sx
#import "modules/std.sx";
Gen :: struct { v: $T; }
main :: () { print("hi\n"); }
```

The `$T` in a field is invalid — a generic struct is written
`Gen :: struct ($T: Type) { v: T; }` (type param declared in the header,
referenced WITHOUT `$` in fields). Writing `$T` as a field type leaves `T`
unbound; the field type resolves to `.unresolved`.

## Investigation prompt

The struct-field unknown-type walk lives in
`src/ir/semantic_diagnostics.zig` (`UnknownTypeChecker`). Field types flow
through `checkStructFieldTypes` → `checkTypeNodeForUnknown`. A `$T` /
struct-param-matched name is parsed as `type_expr{ is_generic = true }`; the
`.type_expr` arm routes an `is_generic` name to
`reportIfValueParamInTypePosition`. That function iterated the in-scope type
params and only diagnosed a *value*-param misuse; a name absent from scope was
never diagnosed. In a struct FIELD position, an `is_generic` name that is not
in scope can only come from a literal `$T` sigil (a bare name matching a header
param would be in scope), and a struct field cannot introduce a fresh type
parameter the way a function param can. Fix: thread a `struct_field` flag and,
when set and the name is not in scope, emit a located diagnostic. Verify with
the repro above: expect a located `error:` + caret, exit 1, no panic. Guard
against over-rejection: `struct ($T: Type) { v: T; a: []T; }` + `Foo(i64).{…}`
must still compile.
