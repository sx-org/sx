# 0334 — qualified struct-literal head loses its namespace through a facade import

> **RESOLVED (2026-07-21).** Root cause: `lowerStructLiteral`'s tagged-union
> pre-pass (src/ir/lower/expr.zig) probed the literal head's OBJECT with the
> loud `resolveNominalLeaf`, which emits "unknown type" in non-main modules —
> so a namespace alias object (`t.Civil.{…}`) blasted `unknown type 't'`
> before the real head resolution ran. Fix: the probe is now the
> diagnostic-free `selectNominalLeaf`; the actual head resolution
> (`resolveTypeWithBindings`' field-access arm) keeps ownership of the
> diagnostics. Not facade-specific: any imported module hit it.
> Regression: `examples/modules/0920-modules-qualified-struct-literal-namespaced.sx`
> (flat / namespaced / facade topologies, opt 0/3).

## Symptom

A struct literal with a namespace-qualified head (`t.Civil.{ … }`) inside a
module M fails with `unknown type 't'` when M is reached through a NAMESPACED
import of a facade that flat-imports M. The same code compiles when M is
reached directly (flat import from the main file, or one namespace hop).

Observed: `error: unknown type 't'` pointing at the literal head's root.
Expected: the literal resolves `t.Civil` in M's own source context (where
`t :: #import` is declared), exactly as a call `t.mk(…)` or an annotation
`c : t.Civil` does.

## Reproduction

```sx
// tmod.sx
Civil :: struct { y: i64; m: i64; }

// inner.sx
t :: #import "tmod.sx";
pack :: (y: i64) -> i64 {
    c := t.Civil.{ y = y, m = 2 };   // ← unknown type 't'
    return c.y + c.m;
}

// facade.sx
#import "inner.sx";
use_pack :: (y: i64) -> i64 { return pack(y); }

// main.sx
f :: #import "facade.sx";
main :: () -> i32 { return f.use_pack(40).(i32); }
```

`sx run main.sx` → `error: unknown type 't'` at inner.sx:3. Dropping the
facade hop (importing inner.sx directly from main) compiles and runs.

Hit in practice by `std/internal/zip.sx`'s `time.CivilTime.{ … }` when
reached through `codecs/zip.sx → internal/zip_facade.sx → internal/zip.sx`
(the std.zip public path, example 1718), while the direct-import example 1717
compiles the same line fine.

## Investigation prompt

Suspected area: the struct-literal head resolution in
`src/ir/lower/expr.zig` / `src/ir/lower/nominal.zig`
(`parseStructLiteral` produces a `struct_literal` whose `type_expr` is a
field-access / dotted head; lowering resolves it via
`staticStructHead` / `resolveTypeWithBindings`). When the literal's owning
function is lazily lowered from a call site whose `current_source_file` is
the FACADE (not M), the head's namespace alias `t` is resolved from the
wrong source authority — `namespaceAliasVerdictFrom(root, facade)` finds no
edge (the facade flat-imports M, and the carry rule correctly does not chain
into a literal-head type context), so the head falls through to bare type
resolution and diagnoses `unknown type 't'`.

The fix likely mirrors what calls already do: resolve the literal-head type
in the DECLARING function's module context (`fd.body.source_file` /
`qualified_fn_source`) rather than the lowering-time caller context, or
route the dotted head through `qualifiedMemberVerdictFrom(path, decl_source)`
with the author's source pinned before `selectNominalLeaf`.

Verification: the repro above prints 42 via
`c.y + c.m`; `examples/std/1718-std-zip.sx` compiles once
`std/internal/zip.sx` uses `time.CivilTime.{ … }`; the full corpus stays
green.
