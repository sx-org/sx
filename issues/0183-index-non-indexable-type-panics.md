# 0183 — indexing a non-indexable type (`*T`, `*[]T`, struct, …) panics instead of a clean diagnostic

> **RESOLVED.** `lowerIndexExpr` (`src/ir/lower/expr.zig`) fell through to an
> `index_get` with an `.unresolved` element type for any non-indexable object,
> reaching codegen → panic. Added a guard after all indexable arms: if
> `getElementType(obj_ty)` is `.unresolved` and `obj_ty` is itself resolved (so a
> genuinely non-indexable type, not a prior-error placeholder), emit a located
> `cannot index a value of type '<T>'` diagnostic and return a placeholder
> (`hasErrors()` aborts before codegen). A single pointer hints by pointee:
> pointer-to-scalar → "use a many-pointer `[*]T`, or dereference first";
> pointer-to-array/slice → "dereference first (`(*p)[i]`)". No false-positives —
> generics, type aliases, late-resolved objects, and every indexable shape
> (`[N]T`/`[]T`/`[*]T`/`string`/`Vector`/`*[N]T`/optional-chain) still work
> (verified by 3 adversarial reviews; suite 799/0). Regression:
> `examples/diagnostics/1203-diagnostics-index-non-indexable.sx`. (Adjacent
> pre-existing panic found + filed: **0184** — an untyped positional `.{ }`
> literal with no target type panics; the guard correctly defers on it.)

## Symptom

`expr[i]` where `expr`'s type is not array / slice / many-pointer / string —
e.g. a single-element pointer `*T`, a pointer-to-slice `*[]T`, or a struct — does
NOT emit a type error. It falls through `lowerIndexExpr` to an `index_get` with an
`.unresolved` element type and reaches codegen, panicking `unresolved type
reached LLVM emission` (exit 134). Pure runtime, no optionals/comptime. (`[*]T`
many-pointers and `[N]T`/`[]T`/`string` ARE indexable and unaffected.)

Found during adversarial review of issue 0181 (the optional-chain index fix); the
same fall-through underlies the `?*[]T`/`?*T`/`?struct` chain-index panics, but it
reproduces identically WITHOUT optional chaining, so it is a separate, broader
gap in the index lowering.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  x := 5;
  p : *i64 = @x;
  print("{}\n", p[0]);   // panic: unresolved type reached LLVM emission, exit 134
}
```

Also panics: indexing a `*[]i64` (pointer-to-slice), indexing a plain struct
value. Expected: a located diagnostic, e.g. `error: cannot index a value of type
'*i64' (use a many-pointer '[*]T', or dereference first)`, exit 1.

## Investigation prompt

`src/ir/lower/expr.zig` `lowerIndexExpr`: after the array / slice / many-pointer /
string / optional-chain dispatch arms, the fall-through emits `index_get` with
`getElementType(obj_ty)` even when that is `.unresolved`. Add a final guard: if
the object type is not indexable (element type resolves to `.unresolved` and the
type isn't a recognized indexable shape), emit
`self.diagnostics.addFmt(.err, span, "cannot index a value of type '{s}'", .{...})`
and return a placeholder — never emit an `index_get` with an unresolved element
type. Mirror the located-diagnostic + placeholder pattern used elsewhere in the
lowering. The static typer (`src/ir/expr_typer.zig` `index_expr`) should likewise
yield `.unresolved` (already does) so this is the single choke point. Follow the
no-silent-fallback rule (here it's a loud PANIC, which must become a clean
diagnostic). Verify: the repro exits 1 with the diagnostic; `[*]T`/`[]T`/`[N]T`/
`string`/optional-chain indexing all still work. Add an
`examples/diagnostics/12xx-index-non-indexable.sx` negative regression.
