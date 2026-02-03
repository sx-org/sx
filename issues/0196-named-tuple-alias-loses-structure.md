# Issue 0196 — a named-tuple type alias (`NT :: Tuple(a: i64, b: bool)`) loses its structure

> **RESOLVED (2026-07-03).**
> **Root cause:** the type-alias registration branch in `scanDecls`
> (`src/ir/lower/decl.zig`) matched `.type_expr` / `.pointer_type_expr` /
> `.array_type_expr` / `.slice_type_expr` / `.optional_type_expr` /
> `.function_type_expr` RHS kinds but omitted `.tuple_type_expr` (the node
> `Tuple(...)` parses to), so the alias was never written to `type_alias_map`
> and every use resolved the name to an opaque empty-struct nominal stub.
> Affected BOTH named (`Tuple(a: i64, b: bool)`) and positional
> (`Tuple(i64, bool)`) tuple aliases.
> **Fix:** tuple-type aliases register through a dedicated path in `scanDecls`
> (`src/ir/lower/decl.zig`) — tuples are structural (specs §3.5), so the alias
> binds the structural tuple TypeId like every other type-expr alias. The
> registration is stub-hardened (adversarial-review fold):
> • **Deferred fixpoint** — an element referencing a LATER decl
>   (`A :: Tuple(a: B); B :: i64;`) defers past the forward-alias fixpoint
>   (readiness probed via the non-minting `selectNominalLeaf`), so the element
>   binds the real type instead of minting a permanent empty-struct stub with
>   a silently-wrong layout. Forward tuple-in-tuple chains converge the same
>   way (interleaved with `resolveForwardIdentifierAliases`).
> • **Stateful element resolution** — elements resolve through
>   `resolveTypeWithBindings` (the inline-annotation resolver), so
>   `TL :: Tuple(a: List(i64), b: string)` instantiates the generic for REAL:
>   field access, reflection, and `size_of` all match the inline spelling.
> • **Composite-deep poisoning** — `typeCarriesUnresolved` recurses through
>   ALL composite shapes (tuple/array/slice/vector/pointer/optional/
>   function/closure), so `Tuple(a: [2][zz]i64)` poisons with a located
>   per-element diagnostic instead of panicking the LLVM tripwire. A
>   `..pack` spread element short-circuits with its own precise message.
> • **Use-above-decl rejection** — a fn signature / struct field referencing
>   the alias ABOVE its declaration binds a never-adopted stub; registration
>   detects the pre-minted stub and diagnoses cleanly (previously an LLVM
>   verifier dump).
> • **Cycle rejection** — mutually-recursive tuple aliases
>   (`T1 :: Tuple(a: T2); T2 :: Tuple(b: T1)`) diagnose a reference cycle and
>   poison, never registering a stubbed member.
> The `UnknownTypeChecker` semantic pass also walks a tuple-alias RHS so
> `Bad :: Tuple(NoSuchType, i64)` gets the canonical "unknown type" the inline
> annotation form gets.
> **Regression test:** `examples/types/0801-types-tuple-alias.sx` (named +
> positional aliases, field access, `field_count`/`field_name` reflection,
> alias as fn param/return type, alias-of-alias, forward element alias,
> `List(i64)` element with `size_of` parity, forward tuple-in-tuple chain) +
> unit tests in `src/ir/lower.test.zig` (structural registration, pack-spread
> poison, forward-element fixpoint, use-above-decl diagnostic, cycle poison).

Status: **RESOLVED.** Found while building `race` (does NOT block it — `race` reflects a tuple type
PARAMETER `$T`, which works; this is the narrower *named alias* path). Filed so the inconsistency is
tracked.

## Symptom

Binding a named tuple type to a `::` alias and then using the alias drops the tuple's field
structure. Both field access and comptime reflection fail on the alias, even though the identical
**inline** type and a **type-parameter** `$T` bound to the same type both work.

| form | `field_count` / `field_name` | field access `x.a` |
|---|---|---|
| inline `Tuple(a: i64, b: bool)` | ✓ works (`fc=2`, `name0=a`) | n/a |
| type param `($T: Type)` ← `Tuple(a: i64, b: bool)` | ✓ works (`fc=2`, `name0=a`) | n/a |
| **alias `NT :: Tuple(a: i64, b: bool)`** | ✗ `error: unresolved type: 'NT'` | ✗ `error: field 'a' not found on type 'NT'` |

## Reproduction

```sx
#import "modules/std.sx";

NT :: Tuple(a: i64, b: bool);

main :: () -> i32 {
    // (1) field access through the alias fails:
    x : NT = .(a = 1, b = true);
    print("x.a={} x.b={}\n", x.a, x.b);     // error: field 'a' not found on type 'NT'

    // (2) reflection through the alias fails:
    print("fc={}\n", field_count(NT));      // error: unresolved type: 'NT'
    return 0;
}
```

Contrast — both of these work today:
```sx
// inline (see examples/comptime/0646-comptime-field-reflect-tuple-array.sx):
field_count(Tuple(a: i64, b: bool));               // 2
field_name(Tuple(a: i64, b: bool), 0);             // "a"

// type parameter:
count :: ($T: Type) -> i64 { return field_count(T); }
count(Tuple(a: i64, b: bool));                     // 2
```

## Notes / investigation prompt

> A `::` alias of a named tuple type (`NT :: Tuple(a: i64, b: bool)`) doesn't behave like the inline
> named tuple: `x : NT` then `x.a` reports "field 'a' not found on type 'NT'", and `field_count(NT)` /
> `field_name(NT, i)` report "unresolved type: 'NT'". The inline form and a generic `$T` type
> parameter bound to the same `Tuple(...)` both work, so the named-tuple TypeId is correct — the alias
> binding is where the structure (or the resolvability) is lost.
>
> First determine whether this is intended (tuples are structural / non-nominal per specs.md §3.5, so
> perhaps a `::` alias is meant to be spelled differently, e.g. a type-fn `NT :: () -> Type { ... }`)
> or a genuine bug in how a `::` type-alias binds a structural tuple type. If it's a bug: the alias
> likely registers a forward/opaque type entry that never resolves to the underlying `TupleInfo`
> (hence both "unresolved type" in reflection and "field not found" in member access). Check the
> type-alias decl lowering path (where `Name :: <type-expr>` binds) and whether a structural tuple
> type-expr is resolved + carried vs. left as an unresolved nominal placeholder.
>
> Also check the POSITIONAL case (`PT :: Tuple(i64, bool)` → `x : PT = .(1, true)`, `x.0`,
> `field_count(PT)`) to see whether the breakage is named-tuple-specific or all tuple aliases.

## Why it doesn't block `race`

`race` is `RaceResult :: ($T: Type) -> Type` over a tuple type **parameter** (the named tuple arrives
as the inferred `$T` of the `race(tasks)` call), and reflection on a `$T` tuple parameter works
(verified). The alias form is a convenience that `race` does not depend on.
