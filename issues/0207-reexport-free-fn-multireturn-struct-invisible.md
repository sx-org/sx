# issue 0207 — re-exported free fn with a `(Struct, !E)` return: struct type "not visible"

> **RESOLVED** (2026-06-29). **Root cause:** the call-plan's bare-name fallback
> (`CallResolver.plan`, `src/ir/calls.zig`) — taken for a re-exported alias whose
> callee registers under its BARE name (`make :: inner.make` → `make`, not
> `facade.make`) — resolved the callee's return type via
> `resolveTypeInSource(qualified_fn_source.get(qualified), rt)`. The
> facade-qualified key is absent from `qualified_fn_source` for an alias
> re-export, so `src` was null and `resolveTypeInSource` fell back to the CALL
> SITE's context. The struct member of the `(Thing, !E)` multi-return tuple then
> resolved as a bare leaf in the caller's module — namespace-only reachable there
> → `.not_visible`. (Single-return worked because its `func.ret` was resolved at
> declaration in the callee's own module; the failable multi-return is typed
> through this call-plan path via the error-flow destructure analysis.) **Fix:**
> the bare-name fallback now pins the return type to `bfd.body.source_file` — the
> callee AST's own defining module — exactly the function being called. **Fix:**
> `src/ir/calls.zig` (bare-name `namespace_fn` arm). **Regression test:**
> `examples/modules/0843-modules-reexport-free-fn-multireturn.sx` (exit 42).

## Symptom

A facade re-exports a free function via alias (`make :: inner.make`, the std.sx
prelude-facade pattern). When that function returns a **multi-return with an
error channel** whose value is a struct — `-> (Thing, !E)` — calling it through
the facade and binding the result reports the struct return type as not visible:

```
error: type 'Thing' is not visible; #import the module that declares it
  r, e := fac.make(false);
       ^^^^^
```

- **Observed:** "type 'Thing' is not visible" at the `:=` bind.
- **Expected:** resolves (the facade re-exports `make` AND `Thing`); exit 42.

### What works (so this is form-specific)

- **Single-return** through the same re-export: `make :: inner.make` where
  `make :: () -> Thing` — fine (binds and reads `r.x`).
- **A static method on a re-exported named type** returning the struct —
  `fac.Box.make() -> (Thing, !E)` — fine, because resolving a method on the
  named type `fac.Box` pins type resolution to the defining module. This is the
  workaround std.http uses: the client entry is the `http.Client` static-method
  type (`http.Client.request`), not a free `http.request`.

Only the **re-exported FREE function + `(Struct, !E)` multi-return** path fails:
the struct member of the return tuple is resolved in the CALL SITE's source
context (where it is only namespace-reachable) instead of the function's
defining module.

## Reproduction

`issues/0207-reexport-free-fn-multireturn-struct-invisible.sx` (+ companion
`inner.sx` / `facade.sx`): `inner` declares `Thing` + `make(fail) -> (Thing, !E)`;
`facade` re-exports both; `main` does `r, e := fac.make(false)`.
Run: `./zig-out/bin/sx run issues/0207-reexport-free-fn-multireturn-struct-invisible.sx`
→ "type 'Thing' is not visible"; expected exit 42.

## How it was found

Building std.http's minimal client (`http.Client`). The first design exposed a
free `http.request(...) -> (ClientResponse, !ClientErr)` re-exported through the
facade; `r, e := http.request(...)` failed with "type 'ClientResponse' is not
visible". Switching the public entry to a static method on a re-exported named
type (`http.Client.request`, mirroring `http.Server`) resolved it — that is the
shipped design. This issue tracks the underlying visibility gap.

## Investigation prompt (paste into a fresh session)

> In sx, a free function re-exported through a facade alias (`make ::
> inner.make`) that returns a multi-return-with-error `(Thing, !E)` — where
> `Thing` is a struct declared in `inner` and also re-exported — reports
> `type 'Thing' is not visible` at a `r, e := fac.make(...)` call site. The
> single-return form (`-> Thing`) works, and a static method on a re-exported
> named type returning `(Thing, !E)` works. So the gap is specific to resolving
> the STRUCT member of a multi-return tuple as the return type of a re-exported
> FREE function: it is resolved in the call site's source (namespace-only
> reachable → `.not_visible`) instead of pinned to the function's defining
> module.
>
> Reproduce: `./zig-out/bin/sx run
> issues/0207-reexport-free-fn-multireturn-struct-invisible.sx` → the error;
> it must exit 42.
>
> Suspected area: return-type resolution for a re-exported (aliased) free
> function — specifically the multi-return tuple path. Compare how a static
> method's return type is resolved (pinned to the type's module — works) vs a
> free function alias's. The fix likely pins the called function's return-type
> resolution (each tuple member) to the function's DEFINING module, the way
> qualified `ns.Type` annotations and static-method returns already do. Grep the
> call/return typing path (`src/ir/lower.zig` resolveTypeWithBindings, the
> call-result typing, and the multi-return/`!` tuple handling) for where a
> re-exported function's return tuple members get resolved against the call
> site's source instead of the callee's. Verify the repro exits 42; add it as a
> regression once fixed; then std.http could expose free `http.request` again.
