# 0189 — non-type expression in type position silently fabricates an empty struct

**Status:** RESOLVED

> **RESOLVED.** Root cause: two distinct type-resolution paths silently
> fabricated a zero-field `{}` struct for a non-type AST node used in type
> position — (1) a dotted `type_expr` / field-access (`g.a`, `g` a runtime
> value) whose prefix is not a namespace alias, and (2) an `error_type_expr`
> (`!Name`) whose `Name` is not a declared error set (an undeclared name or a
> value). Both reached codegen as a real empty struct with no diagnostic.
>
> Fix: (1) the dotted-name guard in `resolveTypeWithBindings`
> (`src/ir/lower.zig` ~1071–1093) rejects a value field-access in type position
> ("expected a type, found a value '<name>' in type position"); (2) a new
> `.error_type_expr` arm in `checkTypeNodeForUnknown`
> (`src/ir/semantic_diagnostics.zig`) validates a named `!E` against a
> collected set of declared error-set names — "unknown error set '<name>'" for
> an undeclared/value name, "expected an error set after '!', found type
> '<name>'" for a declared non-error-set type. A bare `!` (void channel) and a
> declared `!E` in return position stay valid.
>
> Regression test: `examples/diagnostics/1195-diagnostics-non-type-in-type-position.sx`
> (covers both the `g.a`/`Tuple(i32, g.a)` field-access path and the
> `!Nonexistent` / nested-tuple / nested-closure error-set path).

## Symptom

A non-type expression used in **type position** — e.g. a `field_access`
like `g.a` — is silently accepted and resolved to a bogus zero-field
struct `{}` instead of being rejected with a diagnostic.

- Observed: `x : g.a = ---;` compiles with **exit 0**, emitting LLVM
  `alloca {}` (an empty struct) for `x`. `Tuple(i32, g.a)` likewise
  yields `{ i32, {} }` with a `store ... zeroinitializer`.
- Expected: a user-facing "not a type" diagnostic at the offending
  expression and a clean non-zero exit (never a fabricated empty struct
  reaching codegen).

This is the classic silent-fallback-default failure mode: a lookup that
should fail returns a "reasonable-looking" value (`{}`) and ships
invisibly.

## Reproduction

```sx
S :: struct { a: i32; }
g : S = .{ a = 1 };

main :: () -> i32 {
    x : g.a = ---;   // `g.a` is a runtime VALUE, not a type
    0
}
```

Run: `./zig-out/bin/sx run repro.sx` → exits 0 (should error). Inspect
`./zig-out/bin/sx ir repro.sx` → `x` is `alloca {}`.

The tuple form `x : Tuple(i32, g.a) = ---;` reproduces the same
fabrication for the second element. (The bug is **not** tuple-specific —
it predates and is independent of the `Tuple(...)` syntax cutover; the
plain `g.a` case above has no tuple at all.)

## Investigation prompt

The fabrication lives in the type-resolution bridge, not in the tuple
code. In `src/ir/type_bridge.zig`, `resolveAstType`'s handling of a
`field_access` (and likely any non-type-shaped expression) in type
position falls through to building a zero-field stub struct rather than
returning the `.unresolved` sentinel + a diagnostic.

The tuple-element validation arm in `src/ir/lower/generic.zig` (and the
literal screen near `src/ir/lower.zig:960`) only rejects the five literal
tags (`int/float/string/bool/null_literal`); it leans on
`resolveCompound`'s `.unresolved` propagation to catch everything else —
which works only when the element actually resolves to `.unresolved`. A
`field_access` resolves to the fabricated `{}` stub instead, so it slips
through.

Likely fix (pick one, verify against the repro):
1. In `type_bridge.resolveAstType`, the `field_access`-in-type-position
   arm (and any non-type-shaped expression) should emit a diagnostic via
   `self.diagnostics.addFmt(.err, span, "...")` and return `.unresolved`,
   never a fabricated empty struct.
2. Broaden the type-element screen to reject **any** non-type-shaped
   element node up front using `type_bridge.isTypeShapedAstNode` (already
   used by `resolveTupleLiteralTypeArg`), instead of the explicit
   literal-tag allowlist.

Verification: the repro above must error with a clear "not a type"
diagnostic and a non-zero exit; `Tuple(i32, g.a)` must reject too; the
existing `examples/diagnostics/1116` (literal non-type element) must keep
passing. Add a regression example for the `field_access` case.

(Found by adversarial review during the tuple-syntax cutover, commit
`989e18b7`.)
