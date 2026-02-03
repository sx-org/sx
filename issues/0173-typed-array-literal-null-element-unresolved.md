# 0173 — `(T).[ ... ]` typed array-literal with a `null` element panics (unresolved type at LLVM emission)

> **RESOLVED.** `resolveArrayLiteralType` had no arm for an `array_type_expr` /
> `slice_type_expr` head, so a `([2]?i64).[...]` head fell to `else =>
> .unresolved` — the `?i64` element type was lost and a bare `null` element
> reached LLVM as `const_null(.unresolved)`. Fix (`src/ir/lower/expr.zig`): route
> structural heads through `resolveTypeWithBindings` (recurses into the element).
> To honor the no-silent-fallback rule, an UNDEFINED element name in the head is
> now validated by `UnknownTypeChecker` (`src/ir/semantic_diagnostics.zig` —
> wired `al.type_expr` into `walkBodyTypes`), emitting `unknown type '<name>'`
> instead of a silent empty-struct stub. Regression:
> `examples/optionals/0914-optionals-typed-array-literal-null-element.sx` +
> `examples/diagnostics/1196-diagnostics-array-literal-head-unknown-type.sx`.
> Verified by 4 adversarial reviews.

## Symptom

An explicit-type array literal of the `(T).[ elems ]` form (the `.[...]`
`array_literal` AST node, NOT the `.{ ... }` positional struct literal) whose
element type is an optional and one of whose elements is the bare `null`
literal reaches LLVM emission with an `.unresolved` type and panics:

```
thread … panic: unresolved type reached LLVM emission — a type resolution
failure was not diagnosed/aborted
  src/backend/llvm/types.zig:196  toLLVMTypeInfo (.unresolved arm)
  src/backend/llvm/ops.zig:120    emitConstNull   (instruction.ty == .unresolved)
```

Observed: hard panic (exit 134).
Expected: the `null` element lowers to a null `?i64`, the literal builds a
`[2]?i64`, and `arr[1] ?? -1` prints `7`.

## Reproduction

```sx
#import "modules/std.sx";
main :: () {
  arr := ([2]?i64).[ null, 7 ];   // typed `.[...]` form with a null element
  print("{}\n", arr[1] ?? -1);    // expected: 7
}
```

Notes:
- The equivalent **positional** form works (fixed under issue 0168):
  `arr : [2]?i64 = .{ null, 7 };` correctly prints `7`.
- The `.[...]` form works fine when no element is `null`
  (`(i64).[10,20]`, `([2]?i64).[ 1, 7 ]`), and nested slices via `.[...]`
  (`rows : [][]i64 = .[ .[1,2], .[3,4,5] ]`) also work. The panic is specific
  to a **`null` element under the typed `.[...]` array-literal path**.
- Pre-existing: reproduces on clean HEAD (commit
  `2ea25e84`, before the 0168 fix). Independent of issue 0168.

## Investigation prompt

`lowerArrayLiteral` (`src/ir/lower/expr.zig`, the `.[...]` `array_literal`
node, NOT `lowerStructLiteral`) resolves the literal's element type from
`al.type_expr` via `resolveArrayLiteralType`. For `([2]?i64).[ ... ]` the
element type should resolve to `?i64`, and each element is lowered with
`target_type = elem_ty`. A bare `null` element lowers via the `null_literal`
path, which produces a `const_null` whose type is `.unresolved` — the
`target_type` (`?i64`) is apparently not being consulted when lowering the bare
`null` element inside the `.[...]` form (whereas it IS in the `.{ ... }`
positional / scalar-assignment paths, which wrap correctly).

Likely fix area: the `null_literal` lowering in `src/ir/lower/expr.zig` (search
for `.null_literal` / `constNull`) — it must honor `self.target_type` (the
optional element/dest type) so `null` becomes `const_null(?i64)` rather than
`const_null(.unresolved)`. Alternatively, the per-element coercion in
`lowerArrayLiteral` (around the `elem_ty != .unresolved` coercion added for
0168) could coerce the `.unresolved`-typed null to `elem_ty` — but the cleaner
fix is for the bare `null` to resolve its type from `target_type` at lowering
time (matching how `x : ?i64 = null` already works).

Per the no-silent-fallback rule: do NOT default the unresolved null to a
guessed type; resolve it from the contextual `target_type`, and if that is
itself unresolved, emit a diagnostic rather than letting `.unresolved` reach
LLVM emission.

Verify: the repro above prints `7`. Also check `([3]?i64).[ null, null, 5 ]`
and a struct-payload `([2]?Pt).[ null, .{x=1,y=2} ]`. Add an
`examples/optionals/09xx-typed-array-literal-null.sx` regression.
