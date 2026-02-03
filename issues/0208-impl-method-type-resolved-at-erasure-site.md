# issue 0208 — impl method's declared types resolved at the erasure site, not the impl's module

> **RESOLVED** (2026-06-29). **Root cause:** TWO sites. (1) `signatureMismatch`
> (`src/ir/lower/protocol.zig`) resolved the impl method's param/return type
> nodes via `self.resolveType(...)` = the ERASURE-SITE source, while the proto
> side was already pinned to `proto_src`; a module-local impl type
> (bare-visible only in the impl's module) hit `resolveNominalLeaf`'s
> `.not_visible` HARD diagnostic instead of resolving-and-comparing
> structurally. (2) `stampFnBodySource` (`src/imports.zig`) had **no
> `.impl_block` arm**, so impl-method `body.source_file` was always null — making
> a one-site fix inert (`resolveTypeInSource(null, …)` falls back to the erasure
> site). **Fix:** pin the impl side to `fd.body.source_file` via
> `resolveTypeInSource` at both conformance sites (param loop + return), AND add
> `stampImplMethodSources` so impl-method bodies are stamped with their module
> (mirroring `stampStructMethodSources`). **Files:** `src/ir/lower/protocol.zig`,
> `src/imports.zig`. **Adversarially reviewed** SAFE — blast-radius of the
> null→non-null stamp flip analyzed (body lowering uses `Function.source_file`,
> already correct; `calls.zig` bare-name fallback unreachable by impl methods
> which register under the qualified key only; the monomorphizer + closure-shape
> flips move in the correct direction). **Regression test:**
> `examples/protocols/0421-protocols-impl-type-resolved-in-impl-module.sx`
> (exit 42). Same family as 0207/0206/0204.

## Symptom

Erasing a concrete value to an **imported protocol** (`p : inner.P = xx @im`)
runs the impl-conformance check, which resolves the IMPL method's declared
parameter / return types against the **erasure site's** source instead of the
impl's defining module. When an impl type is a named type that is bare-visible
only inside the impl's module (reachable from the call site only namespaced),
the resolution emits a hard diagnostic:

```
error: type 'Q' is not visible; #import the module that declares it
```

- **Observed:** "type 'Q' is not visible" at the `xx @im` erasure, with a bogus
  span (points into a comment / EOF — the same span-misattribution symptom as
  issue 0207).
- **Expected:** the erasure succeeds (the impl IS correct; `Q` is `inner.Q`),
  `p.get().v` reads 42 → exit 42.

## Reproduction

`issues/0208-impl-method-type-resolved-at-erasure-site.sx` (+ companion
`inner.sx`): `inner` declares a module-local struct `Q`, a protocol
`P { get :: (self: *Self) -> ?Q; }`, a struct `Impl`, and `impl P for Impl`
whose `get` returns `?Q`. `main` reaches them only namespaced (`inner.P` /
`inner.Impl`) and does `p : inner.P = xx @im`.

Run: `./zig-out/bin/sx run issues/0208-impl-method-type-resolved-at-erasure-site.sx`
→ "type 'Q' is not visible"; expected exit 42.

## Root cause (already diagnosed)

`signatureMismatch` in `src/ir/lower/protocol.zig` (called from
`firstUnimplementedMethod` ← `buildProtocolValue`, which runs whenever a value
is coerced/erased to a protocol) checks the impl against the protocol method:

```zig
// protocol.zig — the impl side is NOT source-pinned:
const proto_pty = resolveProtoTypeSubSelf(self, proto_pnode, value_ty, proto_src); // proto pinned ✓
const impl_pty  = self.resolveType(impl_param.type_expr);                            // impl: current src ✗  (line ~642)
...
const proto_ret = ... resolveProtoTypeSubSelf(self, rt, value_ty, proto_src);        // proto pinned ✓
const impl_ret  = if (fd.return_type) |rt| self.resolveType(rt) else .void;          // impl: current src ✗  (line ~653)
```

The function's own doc-comment assumes this is safe ("comparison is by
STRUCTURAL NAME … independent of the resolving module's visibility context — so
the same type resolved in the protocol's module vs the erasure site compares
equal"). That assumption holds for the *comparison*, but the *resolution itself*
is not side-effect-free: when the impl's type isn't bare-visible at the erasure
site, `resolveType` → `resolveNominalLeaf` hits its `.not_visible` arm and emits
a **hard diagnostic** (`hasErrors()` → the build fails) before any comparison
happens. So a perfectly correct impl is rejected purely because the erasure
happens in a module that reaches the impl's types only namespaced.

This is the exact family as issue 0207 (re-exported fn return type),
0206 (re-exported enum alias), and 0204 (qualified struct literal): a type
referenced inside an imported module's machinery must resolve in its DEFINING
module, not the use/erasure site.

Stack at the diagnostic (from a `dumpCurrentStackTrace` in the `.not_visible`
arm of `resolveNominalLeaf`):

```
resolveNominalLeaf (decl.zig)               name="Q", from=<consumer source>
resolveTypeWithBindings                     te.name "Q"
resolveInner / resolveCompound              .optional_type_expr  (the `?Q`)
resolveType (lower.zig)
signatureMismatch (protocol.zig:653)        impl_ret = self.resolveType(rt)
firstUnimplementedMethod (protocol.zig:508)
buildProtocolValue (protocol.zig:712)
coerceMode / coerceExplicit (coerce.zig)    erase to optional protocol
lowerXX (coerce.zig:83)                     the `xx` cast
```

## Investigation prompt (paste into a fresh session)

> In sx, erasing a concrete value to an IMPORTED protocol — `p : inner.P =
> xx @im`, where `inner.P`'s method returns a module-local named type `Q` and
> `inner.Impl` impls it — fails with `type 'Q' is not visible` at the erasure,
> even though the impl is correct and `Q` is reachable as `inner.Q`. The
> conformance check (`signatureMismatch` in `src/ir/lower/protocol.zig`) resolves
> the IMPL method's param/return type nodes with `self.resolveType(...)`, which
> uses the erasure-site `current_source_file`; when the impl's type isn't
> bare-visible there, `resolveNominalLeaf`'s `.not_visible` arm emits a hard
> diagnostic. The PROTOCOL side is already pinned (`resolveProtoTypeSubSelf(...,
> proto_src)`); only the IMPL side leaks to the call site.
>
> Fix: resolve the impl param/return type nodes in the IMPL's defining module.
> `signatureMismatch` already has `fd` (the impl method `FnDecl`); use
> `self.resolveTypeInSource(fd.body.source_file, node)` instead of
> `self.resolveType(node)` at BOTH sites (the param loop ~line 642 and the
> return ~line 653). This mirrors the issue-0207 fix in `src/ir/calls.zig`
> (pin a re-exported callee's return type to `bfd.body.source_file`) and how
> `resolveParamTypeInSource(fd.body.source_file, …)` is already used in
> `src/ir/lower/call.zig`. `resolveTypeInSource(null, …)` falls back to the call
> site unchanged, so a synthesized impl with a null `body.source_file` is no
> worse than today.
>
> Reproduce: `./zig-out/bin/sx run
> issues/0208-impl-method-type-resolved-at-erasure-site.sx` → the error; it must
> exit 42. Add it as a regression (`examples/protocols/04xx-…`). Verify the full
> suite stays green (`zig build test`). Real-world impact: it blocks the clean
> HTTPS server API — `cfg.tls = xx @provider` where the provider impls
> `http.TlsAcceptor` over mbedTLS (Phase T3) — forcing the consumer to also
> `#import "modules/std/http/tls.sx"` as a workaround.
