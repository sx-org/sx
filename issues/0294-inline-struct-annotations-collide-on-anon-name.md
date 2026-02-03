# 0294 — two different inline `struct { … }` annotations collide on the `__anon` name

> **RESOLVED** (2026-07-17). Root cause as filed: the inline resolvers
> (`type_bridge.resolveInlineStruct` AND the union/enum siblings — probes
> confirmed all three collide; anonymous error sets can't be parsed, so
> exempt) short-circuit through the name-keyed `findByName`, and every
> inline decl displays as `__anon`. Fix: `TypeTable.internAnonStruct`
> generalized to `internAnonShape` (kind byte + canonical field/variant
> key, covering struct / union / tagged_union / enum); the three inline
> resolvers route `__anon` decls through it, so identical shapes unify
> (including with untyped `.{ }` literal types) and distinct shapes
> separate. Also fixed the same class one level down: an ANONYMOUS enum's
> inline payload structs no longer qualify as `__anon.<variant>` (two anon
> enums sharing a variant name collided on it) — they take the shape-keyed
> path too. specs.md gained the "Anonymous Structs" identity section (+
> the stale `TypeName{…}` interpolation line updated to the Step-2
> prefix-less format). Regression test:
> `examples/types/0866-types-inline-anon-annotations-shape-keyed.sx`.

**Symptom** — Struct interning keys nominal arms by DISPLAY NAME (+ nonzero
nominal_id); every inline struct type parses under the name `__anon`, and
`resolveInlineStruct` short-circuits through `findByName` — so the FIRST
inline struct in a program claims the name and every later, differently-
shaped inline struct annotation resolves to it.

- Observed: `a : struct { x: i64; } = .{ x = 1 }; b : struct { y: f64; } =
  .{ y = 2.5 };` → `error: field 'y' not found on type '__anon'` (b's
  annotation resolved to a's type).
- Expected: distinct shapes are distinct types; identical shapes unify.

Silent-wrong-type class when the shapes happen to be field-compatible;
loud-but-misleading when not. Found during aggregate-ladder Step-1 work:
the anon-literal synthesis initially interned through the same name-keyed
map and different `.{ }` literal shapes collapsed onto one TypeId
(`type_eq(type_of(.{1,2}), type_of(.{x=1}))` came back true). The literal
path now interns through the SHAPE-KEYED `TypeTable.internAnonStruct`; the
inline-ANNOTATION path (`type_bridge.resolveInlineStruct` and its union /
enum siblings) still has the collision.

**Reproduction** (standalone):

```sx
#import "modules/std.sx";

main :: () -> i64 {
    a : struct { x: i64; } = .{ x = 1 };
    b : struct { y: f64; } = .{ y = 2.5 };   // error: field 'y' not found on '__anon'
    print("{} {}\n", a.x, b.y);
    return 0;
}
```

**Investigation prompt** — ready to paste into a fresh session:

> Fix issue 0294: differently-shaped inline `struct { … }` type annotations
> collide because they all intern under the display name `__anon` and the
> struct arm of `TypeKey` (src/ir/types.zig `hashTypeInfo`/`typeInfoEql`)
> keys nominal types by name. Repro:
> `issues/0294-inline-struct-annotations-collide-on-anon-name.sx`. The
> aggregate-ladder Step-1 work added shape-keyed interning for anonymous
> struct LITERALS — `TypeTable.internAnonStruct` (src/ir/types.zig), which
> dedupes on a canonical (field-name, field-type) key and appends the entry
> WITHOUT touching the name-keyed intern map. Route
> `type_bridge.resolveInlineStruct` (src/ir/type_bridge.zig:609) through the
> same shape-keyed path when the decl name is `__anon` (drop its
> `findByName` short-circuit for that name), so identical annotation shapes
> unify and distinct ones separate — and check the inline union/enum
> siblings (`resolveInlineUnion`, `resolveInlineErrorSet`) for the same
> hazard. Verify with the repro (expect `1 2.5` + distinct types), then
> `zig build test`; add a regression example under examples/types/ per the
> resolving-an-open-issue procedure.
