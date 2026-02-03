# issue 0204 — module-qualified struct literal in `:=` loses its type (invalid IR)

> ✅ **RESOLVED.** Root cause: the parser flattened a qualified struct-literal
> prefix (`m.Cfg.{…}`) into a `struct_name` STRING `"m.Cfg"`
> ([src/parser.zig](../src/parser.zig) ~line 2750), which `inferExprType`
> ([src/ir/expr_typer.zig](../src/ir/expr_typer.zig)) and `lowerStructLiteral`'s
> `resolveNominalLeaf` looked up as a bare type name → failed → fabricated an
> empty-fields struct literally named `"m.Cfg"`, lowered as `{}`. Fix: (1) the
> parser now carries the qualified prefix as a `type_expr` **node** (the
> `field_access`), like generic `Pair(i32).{…}` already did; (2)
> `resolveTypeWithBindings` ([src/ir/lower.zig](../src/ir/lower.zig)) handles a
> `field_access` in type position by reconstructing the dotted name
> (`qualifiedTypeName`) and resolving it the way a `: m.Cfg` annotation does
> (namespace alias → pin source → resolve leaf); (3) `inferExprType` resolves a
> struct literal's `type_expr` via the same path so a `:=` decl gets the real
> type. Works in JIT and AOT. Regression test:
> [examples/modules/0799-modules-qualified-struct-literal.sx](../examples/modules/0799-modules-qualified-struct-literal.sx).

## Symptom

A **module-qualified** struct literal in a `:=`-inferred declaration —
`c := m.Cfg.{ ... }` where `Cfg` is a struct in an imported module `m` — infers
`c`'s type as an **empty struct `{}`** instead of `m.Cfg`. Passing `c` to a
function then emits **invalid LLVM IR** and the module fails verification:

```
LLVM verification failed: Call parameter type does not match function signature!
  %load = load {}, ptr %alloca, align 1
  %call = call i64 @use({} %load)        ; {} passed where { i64, i64, i64 } expected
```

- **Observed:** LLVM verification failure (the program never runs).
- **Expected:** exit 3 (the repro's `1 + 2 + 0`).

Fails in **both** JIT (`sx run`) and AOT (`sx build`).

### What works (so this is form-specific)

- **Unqualified / local** literal: `v := Local.{ ... }` (a struct declared in the
  same file) — fine, even with many fields and partial (defaulted) literals.
- **Typed annotation**: `c : m.Cfg = .{ ... }` — fine. This is the form every
  `examples/http/*` uses, which is why the corpus never hit it.

Only the **qualified `module.Type.{ ... }` prefix + `:=` inference** path is
broken.

## Reproduction

`issues/0204-qualified-struct-literal-loses-type.sx` (+ `…/lib.sx`):

```sx
// lib.sx
Cfg :: struct { p: i64 = 0; q: i64 = 0; r: i64 = 0; }
use :: (c: Cfg) -> i64 { return c.p + c.q + c.r; }
```

```sx
// main
m :: #import "0204-qualified-struct-literal-loses-type/lib.sx";
main :: () -> i32 {
    c := m.Cfg.{ p = 1, q = 2 };   // type inferred as {} instead of m.Cfg
    return xx m.use(c);            // invalid IR: call use({} ...)
}
```

Run: `./zig-out/bin/sx run issues/0204-qualified-struct-literal-loses-type.sx`
→ LLVM verification failure; expected exit 3.

## How it was found

Building the first **standalone `http.Server`** (`bench/sx-server.sx`, for the
stress/benchmark harnesses) with `cfg := http.Config.{ port = …,
thread_pool_count = … }` failed to build (host AOT) and to JIT. The corpus http
examples all use the typed form `cfg : http.Config = .{ … }` (and run via JIT),
so none exercised the qualified `:=` form. Switching the bench server to the
typed form is the immediate fix; this issue tracks the underlying codegen bug.

## Investigation prompt (paste into a fresh session)

> In sx, `c := m.Cfg.{ ... }` — a `:=`-inferred local initialized from a
> **module-qualified** struct literal (`m.Cfg.{…}`, `Cfg` defined in imported
> module `m`) — infers `c`'s type as an empty struct `{}` instead of `m.Cfg`,
> producing invalid LLVM IR when `c` is passed to a function (`call use({} …)`).
> The unqualified `Local.{…}` form and the typed `c : m.Cfg = .{…}` form both
> work; only the qualified-prefix `:=` path is wrong. Fails in JIT and AOT.
>
> Reproduce: `./zig-out/bin/sx run
> issues/0204-qualified-struct-literal-loses-type.sx` → LLVM verification
> failure; it must exit 3.
>
> Suspected area: the **type inference for a struct-literal expression with a
> qualified type prefix** — i.e. how `inferExprType` / the expr typer resolves
> the type of a `Type.{…}` / `module.Type.{…}` literal node, vs the
> typed-annotation path which threads the declared type in. Compare the inferred
> TypeId for `Local.{…}` (correct), `m.Cfg.{…}` (wrong → empty/`{}`), and the
> annotated `: m.Cfg = .{…}` (correct). The qualified-name resolution for the
> literal's type likely returns an unresolved/empty struct TypeId that lowering
> then materializes as `{}`. Files to look at: `src/ir/lower/expr.zig`
> (`lowerStructLiteral` + how it gets `ty` for a qualified prefix),
> `src/ir/expr_typer.zig` / `inferExprType` for the struct-literal case, and the
> qualified-name/`module.Type` resolution. A `:=` decl gets its type from the
> initializer's inferred type, so the fix is making the qualified `Type.{…}`
> literal infer the right struct TypeId (the same one the typed-annotation path
> uses).
>
> Verify: the repro exits 3; then `bench/sx-server.sx` builds with the
> `cfg := http.Config.{…}` form. Add the repro to the corpus as a regression.
