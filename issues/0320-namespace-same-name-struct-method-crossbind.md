# 0320 — namespace-imported same-name struct methods cross-bind last-wins

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
