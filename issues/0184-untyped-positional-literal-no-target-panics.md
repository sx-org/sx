# 0184 — an untyped positional literal `.{ ... }` with no inferable target type panics instead of diagnosing

> **RESOLVED.** Root cause: in `lowerStructLiteral` (src/ir/lower/expr.zig) a
> bare `.{ ... }` whose type stayed `.unresolved` emitted an `.unresolved`-typed
> `struct_init` that flowed to codegen and panicked LLVM emission. This covers
> the genuinely targetless binding (`t := .{1,2,3}`, `target_type` null) AND the
> silently-unresolved-target shapes: a global const `K :: .{1,2,3}` (pass-1
> `inferExprType` → `.unresolved`, on-demand const lowering targets it — also
> panicked `sx ir` / `#run`), an inferred return (`f :: () { return .{1}; }`),
> and an inferred array-literal element (`arr := .[ .{1}, .{2} ]`). Fix: a guard
> at the literal site diagnoses "cannot infer the type of this '.{ }' literal —
> annotate the binding or provide a target type" and returns an `.unresolved`
> poison ref (`hasErrors()` aborts before codegen). Suppression to avoid
> double-reporting: a named/generic literal whose own type failed resolution
> already carries its diagnostic; and a SET-but-`.unresolved` target only mutes
> the message when an error is already recorded (`hasErrors()` gate) — a target
> poisoned WITH a diagnostic (`s : Secret = .{}`, `Secret` not visible) yields
> exactly one error, while the silent-inference shapes above still report.
> Deliberate trade: an unrelated earlier error in the same compile mutes a
> later silently-unresolved literal's message (the compile already fails).
> Typed positional literals (annotated binding, `S.{...}`, tuple/array targets)
> are unaffected.
> Regression tests: `examples/diagnostics/1210-diagnostics-untyped-positional-literal-no-target.sx`
> (targetless + global-const shapes) and the unit tests in `src/ir/lower.test.zig`
> (all three silently-unresolved shapes standalone).

## Symptom

A positional struct/tuple literal `.{ a, b, ... }` used where NO target type is
available (e.g. `t := .{ 1, 2, 3 };` with no annotation) cannot resolve its type
and is left `.unresolved`. Any later use (`t.0`, `t[0]`, passing it, etc.) then
panics `unresolved type reached LLVM emission` (exit 134) — with no diagnostic.
The literal's type is never resolved upstream nor reported.

Found during adversarial review of issue 0183 (the index guard correctly DEFERS
on an already-`.unresolved` object to avoid double-reporting, so this surfaces as
the upstream panic rather than the index diagnostic).

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  t := .{ 1, 2, 3 };   // untyped positional literal, no target type
  print("{}\n", t.0);  // panic: unresolved type reached LLVM emission, exit 134
}
```

Expected: a located diagnostic, e.g. `error: cannot infer the type of this `.{ }`
literal — annotate the binding (`t : (i64, i64, i64) = …` or a struct type) or
provide a target type`, exit 1. (A TYPED positional literal `t : (i64,i64,i64) =
.{1,2,3}` or `S.{...}` works.)

## Investigation prompt

`src/ir/lower/expr.zig` `lowerStructLiteral` (and `expr_typer.zig`'s inference for
an untyped `.{ }`). When a positional `.{ }` literal has no `self.target_type`
(and isn't a named struct literal that names its own type), its `struct_init.ty`
stays `.unresolved` and flows to codegen → panic. Add a diagnostic at the literal
site: if a `.{ }` literal cannot determine a target/struct type, emit
`self.diagnostics.addFmt(.err, span, "cannot infer the type of this '.{{ }}'
literal — annotate the binding or provide a target type", .{})` and return a
placeholder (so `hasErrors()` aborts before codegen), instead of emitting an
`.unresolved`-typed `struct_init`. Follow the no-silent-fallback rule (here it is
a loud PANIC that must become a clean diagnostic). Verify: the repro exits 1 with
the diagnostic; a TYPED positional literal (annotated binding, `S.{...}`,
array/tuple target) still works. Add an `examples/diagnostics/12xx-...` negative
regression. (Related: 0173 closed the same silent-fallback for typed
`.[...]`-array-literal heads with undefined element names; this is the
no-target-type variant for `.{ }`.)
