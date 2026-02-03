# 0276 — module-qualified enum variant as a generic-fn argument panics the backend

> **RESOLVED** (2026-07-09).
> **Root cause:** `inferExprType`'s `.field_access` arm (`src/ir/expr_typer.zig`)
> only inferred a payloadless enum-variant VALUE when the variant's OBJECT was a
> bare identifier (`E.on`, the issue-0274 fix). A MODULE-QUALIFIED object
> (`lib.Mode.on` — where `lib.Mode` is itself a `field_access` resolving to an
> enum in the aliased module) fell through to `.unresolved`. A generic call
> `id(lib.Mode.on)` then bound `T = .unresolved`, minting a `__unresolved`
> monomorph whose return type reached LLVM emission → the
> `unresolved type reached LLVM emission` panic at `src/backend/llvm/types.zig:196`.
> **Fix:** extended the arm with a module-qualified sibling case. When the
> variant object is a namespace-rooted member (`alias.Type`), resolve `alias` via
> `namespaceAliasVerdict` (diagnostic-free) and the inner type name via
> `selectNominalLeaf` against the target module (`from = target_module_path`).
> A payloadless variant (`isPayloadlessVariant`) of the resolved enum /
> tagged-union infers to that enum type; everything else (`mod.value`,
> `mod.CONST`, `mod.Struct.field`, payloadful reads) still falls through to
> `.unresolved`. Mirrors `lowerFieldAccess`'s `namespaceRootedMember`
> enum-literal path, so inference and lowering agree.
> **Regression test:** `examples/modules/0847-modules-qualified-enum-variant-generic-arg.sx`
> (+ companion `.../0847-.../lib.sx`).

## Symptom

A module-qualified (or otherwise nested field-access) enum variant used as a
generic-function argument panics the backend:
`panic: unresolved type reached LLVM emission` (`src/backend/llvm/types.zig:196`).

- Observed: backend panic.
- Expected: `id(lib.Mode.on)` binds `T = lib.Mode` and compiles (same as the
  bare `id(E.on)` case fixed in issue 0274).

## Reproduction

`lib.sx`:

```sx
Mode :: enum { on; off; }
```

`main.sx`:

```sx
#import "modules/std.sx";
lib :: #import "lib.sx";
id :: (v: $T) -> T { v }
main :: () {
    m := id(lib.Mode.on);
    print("ok\n");
}
```

`sx run main.sx` → `panic: unresolved type reached LLVM emission`.

## Investigation prompt

This is the sibling of issue 0274 (commit `9502a443`), which fixed the
BARE-identifier case. `inferExprType`'s `.field_access` arm in
`src/ir/expr_typer.zig` infers a payloadless `Enum.variant` value (bare object)
to the enum type via `isPayloadlessVariant`, but a module-qualified object
(`lib.Mode.on`, object `lib.Mode` is a `field_access`) returns `.unresolved`, so
`buildTypeBindings` binds `T = .unresolved` and the `__unresolved` monomorph
reaches LLVM emission.

Extend the arm so the variant OBJECT may be a namespace-rooted member
(`alias.Type`). Reuse the resolution path `lowerFieldAccess` uses for
`lib.Mode.on` (`namespaceRootedMember` → `namespaceAliasTarget` /
`resolveNominalLeaf` in the target module's context). Do it diagnostic-free in
inference (`namespaceAliasVerdict` + `selectNominalLeaf(name, target_path, false)`).
Keep every 0274 guard (payloadless only, non-shadowed, not a real value/const,
fall through to `.unresolved` for genuine non-enum field access). Verify:
`id(lib.Mode.on)` prints `ok` and `m` is `lib.Mode`. Do NOT regress the bare
case or ordinary `mod.value` / `Struct.field` / `mod.Struct.field`.
