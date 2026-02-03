# Issue 0192 — qualified-import-member const is not a compile-time constant

> **✅ RESOLVED.** Root cause: the const folders in `src/ir/program_index.zig`
> had no namespace-member arm — `evalConstIntExpr` resolved a bare/flat const
> leaf (`lookupDimName`) but not a qualified `m.CAP`. Fix: a `lookupQualifiedConst`
> (+ float / float-typed twins) ctx hook that resolves the alias `m` via
> `Lowering.namespaceAliasVerdict` to its target module and folds `CAP` from
> that module's per-source const cache (`foldQualifiedConstInt` in
> `src/ir/lower/comptime.zig`), pinned to the target source so nested const RHSs
> fold there. Wired into `evalConstIntExpr` / `evalConstFloatExpr` /
> `isFloatValuedExpr` — both the EXPRESSION-position `field_access` arm (`[m.CAP]T`)
> and the TYPE-argument dotted-name arm (`Vector(m.LANES, …)`, generic
> value-params). Implemented on the source-aware ctxs (`Lowering` /
> `SourceConstCtx`); the namespace-blind `ModuleConstCtx` / `StatelessInner`
> return null (documented — a qualified-const dim reached ONLY via the stateless
> type-alias path stays a clean unresolved-dim diagnostic, never a fabricated
> length). Regression: `examples/modules/0842-modules-qualified-import-const-comptime.sx`
> (qualified const as array dim, arithmetic, integral-float dim, Vector lane,
> generic value-param, inline-for bound). Suite green 816/0.
>
> NOTE: the writeup's secondary symptom `A :: m.CAP` (a const aliasing a
> qualified const) is NOT part of this bug — `A :: B` (aliasing a *bare* local
> const) fails identically, so const-aliasing-a-single-name is a separate
> pre-existing limitation (`N :: M + 1` expression-RHS works). Out of scope here.

## Symptom

A constant reached through a **namespaced (qualified) import** — `m :: #import
"lib.sx"; … m.CAP` — is not recognized as a compile-time constant. It works
fine as a *runtime* value, but the moment a comptime context needs it the
compiler either rejects it or fails to resolve it:

- as an **array dimension** → `error: array dimension must be a compile-time
  integer constant`
- seeding **another const** (`A :: m.CAP;`) → `error: unresolved 'A'`

Expected: a qualified-import const should fold to a compile-time constant
everywhere a flat-imported const does — array dimensions, `Vector` lanes,
const initializers, value-param args. (A **flat** `#import` of the same const
works in all those positions; only the qualified `m.CONST` form fails.)

## Reproduction

Two files (the bug requires a *qualified* import, which needs a second module).

`issues/0192-qualified-import-const-not-comptime/lib.sx`:
```sx
CAP :: 8;
```

`issues/0192-qualified-import-const-not-comptime.sx`:
```sx
m :: #import "0192-qualified-import-const-not-comptime/lib.sx";

main :: () -> i64 {
    buf : [m.CAP]u8 = ---;   // ← error: array dimension must be a compile-time integer constant
    return buf.len;
}
```

```sh
./zig-out/bin/sx run issues/0192-qualified-import-const-not-comptime.sx
```

Scoping probes (all run against the same `CAP :: 8`):

| Form | Result |
|------|--------|
| `#import "lib.sx"; [CAP]u8` (flat, as dim) | ✅ works |
| `m :: #import "lib.sx"; [m.CAP]u8` (qualified, as dim) | ❌ "array dimension must be a compile-time integer constant" |
| `m :: #import …; A :: m.CAP;` (qualified, seeding a const) | ❌ "unresolved 'A'" |
| `m :: #import …; x := m.CAP;` (qualified, runtime value) | ✅ works (prints 8) |

So the value *is* reachable; only its **compile-time folding through the
qualified member-access path** is missing.

## Investigation prompt

The compile-time integer folder is `evalConstIntExpr` in
`src/ir/program_index.zig` (≈ line 318). Its `.identifier` arm resolves a
flat-scope const via `ctx.lookupDimName(id.name)` — that is why a flat import
works. Its `.field_access` arm (≈ line 325) only handles three shapes:
`<pack>.len`, `<IntType>.min`/`.max` (via `TypeResolver.integerLimitFor`), and
`<struct-const>.field` (via `ctx.lookupConstStructField`). There is **no arm
that resolves a namespace-member const** — for `m.CAP`, `obj_name == "m"`,
`fa.field == "CAP"`, none of the three match, and it falls through to `null` →
`.not_const` → the array-dim diagnostic. The const-init path
(`A :: m.CAP` → `unresolved 'A'`) is the same gap one layer up: the const
initializer can't fold `m.CAP` either.

The fix likely needs a new `ctx` hook — e.g. `lookupQualifiedConst(namespace,
name) -> ?i64` — that follows the namespace edge (the import-alias `m` →
its module, via `namespace_edges` / `module_decls` in `ProgramIndex`) to the
imported module and returns the named const's folded integer value. Wire it
into `evalConstIntExpr`'s `.field_access` arm: when `obj_name` names a known
import namespace (not a pack / type / struct-const), look the field up as a
module-level const in that namespace's module. The same resolution should make
`A :: m.CAP` fold (whatever const-init folding path also routes through, or a
sibling of, `evalConstIntExpr`).

Mirror the existing `lookupConstStructField` plumbing — it already threads a
"resolve a name's const value from another scope" capability through the
`ModuleConstCtx` / `Lowering` ctx; the qualified-namespace case is the analogous
"resolve a const from an imported module by alias" lookup. Watch the
float sibling `evalConstFloatExpr` (≈ line 443) and `isFloatValuedExpr`
(≈ line 264) — a qualified float const (`m.PI`) has the identical gap, so fix
the cluster consistently (per the comment at line 332 about keeping the const
cluster in agreement).

## Verification step

After the fix, the reproduction above should compile and run, printing exit
code `8` (`buf.len`). Add a regression example exercising a qualified-import
const as (a) an array dimension and (b) a const initializer. Then unblock the
**linux epoll** work (CHECKPOINT-FIBERS): `library/modules/std/net/epoll.sx`
wants `[N * ep.EV_SIZE]u8` event buffers sized from a qualified-import layout
const — the cleanest expression of the arch-dependent `epoll_event` stride.

## Discovered by

Building `library/modules/std/net/epoll.sx` (the linux epoll twin of
`std/net/kqueue.sx`, CHECKPOINT-FIBERS deferred follow-up). The epoll event
buffer wants to be sized `[MAXEV * ep.EV_SIZE]u8` from the bindings module's
arch-dependent stride const; `ep.EV_SIZE` as an array dimension hit this bug.
A struct-based layout (`EpollEvent` with arch-branched u32 fields) sidesteps
it, but per the project's STOP rule the workaround is not landed — the bindings
work is paused pending this fix.
