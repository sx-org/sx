# 0217 — a module-scope function in an IMPORTER breaks an imported module's local variable of the same name

> **RESOLVED (2026-07-03).** Root cause: call-position name resolution in
> `lowerCall` (src/ir/lower/call.zig) consulted the PROGRAM-WIDE fn table
> before the lexical scope — the non-transitive-visibility gate fired on the
> importer's `h` while lowering server.sx's `h(...)` (whose `h` is a LOCAL
> fn-pointer), and dispatch would reach `resolveFuncByName` before the local
> fn-pointer-binding path. Fix: a CALLABLE local binding (fn pointer /
> closure) now shadows any same-named top-level fn in call position
> (`callableLocalShadow`) — the visibility gate, the early
> pack/comptime/generic dispatch, and direct name dispatch are all skipped
> for it, and the call routes `call_indirect` through the local. This also
> makes call-position resolution consistent with value-position resolution
> (`f := h` already resolved the local) per specs.md §Variable Shadowing.
> Regression test:
> `examples/modules/1618-modules-importer-fn-name-vs-importee-local.sx`
> (+ companion module) and unit tests in `src/ir/lower.test.zig`.
>
> Review fold (same day): (F1) shadowing is by DEPTH across both local
> namespaces — `Scope.lookupNearest` walks the chain once consulting the
> value-binding map AND the nested-local-fn table per level, so an outer
> callable var no longer beats an inner nested fn (nor vice versa);
> (F2) `expandCallDefaults` no longer expands a shadowed-out global's
> default params (their side effects ran and phantom args were spliced
> into the local's call_indirect); (F3) `indirectCallThroughLocal` checks
> arity against the fn-pointer signature (exact for sx conv, at-least for
> C conv, pack-variadic exempt) instead of silently truncating;
> (F4) the type-dispatch match-arm path (`cast(type)` arg) diagnoses a
> callable-local shadow loudly — a fixed-signature local fn pointer
> cannot drive per-tag dispatch.

## Symptom

One-line: declaring a module-scope function named `h` in a program that
imports `std/http` makes **server.sx's own local** `h := self.cfg.on_event`
fail to compile with "'h' is not visible" — cross-module name
contamination: the importer's global leaks into the imported module's
function-body scopes and corrupts resolution of the module's OWN locals.

Observed vs expected: server.sx (unchanged, compiles standalone) errors at
its internal `h := ...` sites (server.sx ~894/1002/1348/3474) only when
the IMPORTING program defines a top-level `h :: (...) {...}`; expected:
an importer's declarations never affect name resolution INSIDE the
imported module.

## Reproduction

```sx
#import "modules/std.sx";
http :: #import "modules/std/http.sx";

// A module-scope function whose name collides with a LOCAL inside
// server.sx (`h := self.cfg.on_event` in Server.emit et al).
h :: (x: i64) -> i64 { return x + 1; }

handler :: (req: *http.Request, resp: *http.Response, ctx: usize) {
    _ := req; _ := ctx;
    resp.body = "ok";
}

main :: () -> i32 {
    cfg : http.Config = .{ port = 18099 };
    srv, se := http.Server.init(cfg, handler, 0);
    if se { return 1; }
    _ := h(1);
    srv.close();
    0
}
```

Observed: `error: 'h' is not visible; #import the module that declares it`
pointing INTO library/modules/std/http/server.sx. Expected: compiles; the
importer's `h` and server.sx's local `h` are unrelated names.

## Investigation prompt

Name resolution appears to build (or cache) a cross-module visibility set
in which the importing program's module-scope decls are consulted while
lowering the IMPORTED module's function bodies — a local declaration
(`h := ...`) inside server.sx then resolves against the importer's global
`h` (or is invalidated by it) instead of simply declaring the local.
Suspect area: the flatten/module-merge pre-pass or the scope-stack setup
per function (src/ir/lower — wherever module-scope symbol tables are
seeded before body lowering; check whether the CURRENT-module table is
swapped per function or shared across the whole program with per-module
filtering that the local-declare path bypasses). What the fix likely
needs: body lowering must resolve locals in the module's own scope chain,
with importer decls never in that chain. Verification: the repro compiles
and runs (prints nothing, exit 0); pin as a regression example under
examples/modules/07xx; `zig build test` green.

Found by the Q3.6b adversarial review (2026-07-03): its probe named a
helper `h`, which broke the http import mid-review.
