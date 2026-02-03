# issue 0155 — indexing a scalar pointer (`pc[0]`, `pc: *i64`) panics at LLVM emission

> **RESOLVED (2026-07-03).** Semantics: a bare `*T` is intentionally NOT
> indexable — per specs.md (Pointer Types table: `[i]` is "no" for `*T`, "yes"
> for `[*]T` / `*[N]T` / `*[]T`; `*T` converts implicitly to `[*]T` when buffer
> indexing is intended). So the fix is a clean diagnostic, not C-style
> `*(pc + i)` lowering. (Note: `*[]T` IS indexable per that same spec table,
> but its indexing is not yet implemented — it currently receives the same
> diagnostic. That spec divergence is tracked separately as issue 0242 and is
> NOT part of this fix.)
>
> Root cause: four index-lowering paths compute the element type via
> `ptrToArrayElem(..) orelse getElementType(..)`, which yields `.unresolved`
> for a base those resolvers don't index. The READ path (`lowerIndexExpr`,
> `src/ir/lower/expr.zig`) was guarded under issue 0183, but the WRITE path
> (`.index_expr` assignment arm, `src/ir/lower/stmt.zig`), the ADDRESS-OF
> path (`address_of(index_expr)` arm, `src/ir/lower/expr.zig`), and the
> L-VALUE-POINTER path (`lowerExprAsPtr` `.index_expr` arm,
> `src/ir/lower/stmt.zig` — reached by `ps[i].field = v` / `@ps[i].field`)
> still emitted an `index_gep` typed `ptrTo(.unresolved)`, which reached LLVM
> emission and panicked.
>
> Fix: the 0183 diagnostic was extracted into a shared helper
> (`diagNonIndexable`, `src/ir/lower/expr.zig`) and all four paths now bail
> through it with the same located message ("cannot index a value of type
> '*i64' — use a many-pointer '[*]T', or dereference first"); the assignment
> target-type seeding also no longer adopts an `.unresolved` element type.
>
> Regression tests: `examples/diagnostics/1213-diagnostics-scalar-pointer-index.sx`
> (read + write + address-of + field-lvalue-through-index, exit 1) and a unit
> test in `src/ir/lower.test.zig` ("indexing a scalar pointer diagnoses in
> write and address-of positions"). The read-path guard remains pinned by
> `examples/diagnostics/1203-diagnostics-index-non-indexable.sx` (issue 0183).

> Found incidentally during an adversarial review of the fiber
> scheduler (a review probe used `pc[0]` on a `*i64`). NOT a fibers-stream
> blocker — the scheduler uses array-field indexing (`ctx.regs[i]`) and pointer
> deref (`p.*`), never scalar-pointer indexing — so it is filed for its own fix
> session, not fixed inline.

## Symptom

Indexing a pointer-to-scalar value with `[i]` crashes the compiler:

```
thread … panic: unresolved type reached LLVM emission — a type resolution
failure was not diagnosed/aborted
  src/backend/llvm/types.zig:196:28  toLLVMTypeInfo  (.unresolved arm)
  src/backend/llvm/types.zig:38      toLLVMType
  src/ir/emit_llvm.zig:2564          toLLVMType
```

Observed: compiler panic (no diagnostic). Expected: either lower `pc[i]` as
`*(pc + i)` (C semantics), or emit a clean diagnostic that a bare `*T` is not
indexable (deref with `.*`, or use a slice `[]T`). A `.unresolved` TypeId
reaching LLVM emission is unconditionally a compiler bug (a resolution failure
that was neither diagnosed nor aborted).

## Reproduction

```sx
#import "modules/std.sx";
main :: () -> i64 {
    x : i64 = 5;
    pc : *i64 = @x;
    return pc[0];   // panics the compiler
}
```

(repro promoted to `examples/diagnostics/1213-diagnostics-scalar-pointer-index.sx`)

## Investigation prompt

> The sx compiler panics ("unresolved type reached LLVM emission",
> `src/backend/llvm/types.zig:196`) when an index expression `pc[i]` is applied
> to a value of pointer-to-scalar type `*T` (repro:
> `issues/0155-scalar-pointer-index-llvm-panic.sx`). Trace `emitIndexGet`
> (`src/backend/llvm/ops.zig` ~1988) and the index-expr lowering in
> `src/ir/lower/` (the `.index_expr` arm): for a `*T` object, the element type
> resolves to `.unresolved` instead of `T`. Decide the intended semantics first
> (consult `specs.md` for whether a bare `*T` is indexable): if `pc[i]` should
> mean `*(pc + i)`, fix the index-expr type resolver to yield the pointee type
> `T` for a `*T` object (mirror the slice/array-pointer arm — see
> `ptrToArrayElem` / `getElementType` in `src/ir/lower/`), and verify codegen
> emits a GEP + load. If a bare `*T` is intentionally NOT indexable, emit a
> diagnostic at the lowering site ("cannot index `*T`; deref with `.*` or use a
> slice") and never let `.unresolved` reach emission. Verify: `sx run` the repro
> — expect either `5` (if indexable) or a clean compile error, never a panic.
> Then promote the repro to a regression test under `examples/`.
