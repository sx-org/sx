# 0320 — namespace-imported same-name struct methods cross-bind last-wins

> **RESOLVED (2026-07-21).** The three consumers the reopening review named
> now select by concrete TypeId/author identity, closing the last
> name-keyed surfaces:
> - **Field defaults**: `registerStructDecl` builds LAYOUT-ALIGNED defaults
>   (also fixing issue 0335's `#using` misalignment) and registers them in
>   `struct_defaults_by_tid`; literal/coerce/comptime lowering select by
>   TypeId first, and for an author-tracked type a miss is authoritative
>   ("no defaults"), never a fall-through to another author's name entry.
> - **Struct constants**: registered in `struct_const_by_tid` keyed by
>   (concrete TypeId, name); the `Struct.CONST` intercepts in
>   `lowerFieldAccess` and the expr-typer resolve the head through
>   `selectNominalLeaf` under the current source authority (the namespace
>   walk already re-enters with the target module as current source), with
>   the global string map only serving untracked heads.
> - **`#using` bases**: both plain-struct registration interleave loops and
>   both generic-instantiation loops resolve the base via the new
>   source-aware `resolveUsingBase` (declaring module's authority; legacy
>   global lookup only as forward/unwired fallback; a double miss now
>   DIAGNOSES instead of silently dropping the embedded fields).
> Regressions: `examples/modules/0921-modules-nominal-defaults-constants-
> using.sx` (defaults + constants + `#using` + 0335 alignment, opt 0/3) and
> `0922-modules-nominal-identity-import-order.sx` (identical selection with
> the import order flipped, opt 0/3), plus the original 0851-0853 /
> 0884-0885 method matrix. Full corpus green; 61-trial benchmark gate on
> the committed tree recorded in the commit message.
>
> Historical banner (method-surface fix + the reopening) below.

> **ADVERSARIAL REVIEW REOPENED (2026-07-21).** Plain-struct method registration and dispatch
> shared the process-global `StructName.method` spelling even though the
> layouts already had distinct nominal `TypeId`s. The compiler now retains the
> authoring `StructDecl` and source per concrete TypeId, selects static and
> instance methods from that identity, and lowers each selected declaration
> into its own FuncId. Defaults, argument/return typing, accessors, generic,
> comptime, pack, and target-typed shorthand calls use the same selection.
> Protocol impl/conformance/thunk/vtable identity is likewise keyed by the
> concrete TypeId rather than its display name. Regressions:
> `examples/modules/0851-modules-nominal-struct-method-authors.sx`,
> `0852-modules-bare-static-method-ambiguous.sx`,
> `0853-modules-namespace-vs-hidden-type-method.sx`, and
> `examples/protocols/0884-protocols-nominal-impl-thunk-identity.sx` plus
> `0885-protocols-nominal-empty-impl-no-cross-adoption.sx`. The matrix also
> covers synthesized defaults, reverse-order empty-impl adoption, direct and
> erased protocol dispatch, module-local comptime argument types, and nested
> comptime-method receiver scope. The implementation is not resolved until the
> expanded adversarial corpus, clean full suite, and independent final review
> all pass.
>
> The independent review found that nominal identity still stops at methods.
> Struct defaults remain keyed by display name, struct constants still use a
> `"Struct.CONST"` key, and `#using` layout resolution still calls global name
> lookup. Distinct `a.Thing`/`b.Thing` types can therefore retain separate
> methods while sharing defaults, constants, or embedded layout. This issue
> remains open until those consumers use exact `TypeId`/author identity.
>
> **RE-DERIVED against the current compiler (2026-07-21, post-`735c253f` /
> post-`a864f4fb` / codec commits).** All three surfaces reproduce:
>
> 1. **Constants — last-wins.** `moda: Thing :: struct { SIZE :: 111; … }`,
>    `modb: Thing :: struct { SIZE :: 222; … }`; namespaced imports of both;
>    `a.Thing.SIZE` and `b.Thing.SIZE` BOTH print `222`.
> 2. **Field defaults — collapse to zero-fill.** Same two `Thing`s carrying
>    `x: i64 = 10;` / `x: i64 = 99;` (and `extra: i64 = 7;` only in B):
>    every literal that omits the defaulted fields yields `0` — NEITHER
>    module's default applies once the display name collides (a
>    single-module control keeps `x = 10`, so the default machinery itself
>    is fine).
> 3. **`#using` — wrong module's base embedded.** `modc: Base { ca, cb };
>    Holder { #using Base; own }` and `modd: Base { da }; Holder { #using
>    Base; own }`, imported d-then-c: C's `Holder` embeds D's `Base`, so
>    C's own `ca`/`cb` fail "field not found" (flip the order and D breaks
>    instead — global-name last-registered wins).
>
> Fix direction unchanged: key struct defaults, struct constants, and
> `#using` base resolution by concrete `TypeId`/author identity exactly as
> methods now are.

## Symptom

Two namespace-imported modules may correctly own distinct same-named structs,
but methods on those structs are still selected through the global
`StructName.method` key. Instantiating either method can therefore lower the
other module's last-registered body against the wrong receiver type.

Observed: module A's `Thing.init`/`Thing.reset` are type-checked with module B's
`Thing`/`BState` body, producing missing-field and visibility diagnostics.
Expected: `a.Thing` methods bind only A's declarations and `b.Thing` methods
bind only B's declarations; the program exits 0.

This blocks idiomatic codec namespaces such as `deflate.Encoder`,
`zlib.Encoder`, and `gzip.Encoder`: calling `deflate.encode_into` currently
tries to assign a `GzipDeflater` into the raw DEFLATE encoder state.

## Reproduction

`issues/0320-namespace-same-name-struct-method-crossbind/a.sx`:

```sx
AState :: struct { a: i64; }
Thing :: struct {
    state: AState;
    init :: () -> Thing { Thing.{ state = .{ a = 1 } } }
    reset :: (self: *Thing) { self.state = AState.{ a = 2 }; }
}
use :: () -> i64 {
    value := Thing.init();
    value.reset();
    value.state.a
}
```

`issues/0320-namespace-same-name-struct-method-crossbind/b.sx`:

```sx
BState :: struct { b: bool; }
Thing :: struct {
    state: BState;
    init :: () -> Thing { Thing.{ state = .{ b = true } } }
    reset :: (self: *Thing) { self.state = BState.{ b = false }; }
}
use :: () -> bool {
    value := Thing.init();
    value.reset();
    value.state.b
}
```

`issues/0320-namespace-same-name-struct-method-crossbind.sx`:

```sx
a :: #import "0320-namespace-same-name-struct-method-crossbind/a.sx";
b :: #import "0320-namespace-same-name-struct-method-crossbind/b.sx";

main :: () -> i32 {
    if a.use() != 2 { return 1; }
    if b.use() { return 2; }
    0
}
```

Run:

```sh
./zig-out/bin/sx run issues/0320-namespace-same-name-struct-method-crossbind.sx
```

Before the fix, diagnostics included `field 'b' not found on type 'AState'` and
`type 'BState' is not visible` in A's source.

## Original investigation prompt

Fix issue 0320 in the SX compiler. Same-named nominal structs from distinct
modules already receive distinct type identities (issue 0105), but ordinary
instance/static struct methods still flow through globally name-keyed entries
such as `program_index.fn_ast_map["Thing.reset"]`. Inspect
`src/ir/lower/call.zig` around the plain-struct method path (it builds
`StructName.method` from `getStructTypeName(obj_ty)`), method registration and
lazy lowering in `src/ir/lower/decl.zig`, and the source-aware struct-author
helpers near `structMethodFn`. The method body and generated function identity
must be selected from the receiver TypeId's nominal author/source, not from the
last global spelling match; static calls need the same rule. Preserve the
existing loud ambiguity behavior for genuinely bare ambiguous references.

Add a regression under `examples/modules` using the three-file reproduction,
with both distinct method bodies exercised. Verify:

```sh
./zig-out/bin/sx run issues/0320-namespace-same-name-struct-method-crossbind.sx
zig build
zig build test
```

The repro must exit 0 with no diagnostics, and the full suite must remain green.
