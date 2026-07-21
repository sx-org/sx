# 0329 — generic cache keys collapse nominal and protocol-template identity

> **OPEN (2026-07-21).** Independent adversarial review found compiler-internal
> cache identity defects. No SX syntax or public language API change is needed.

## Symptom

Generic struct/type-function keys use display-only `formatTypeName`, so two
distinct same-spelled nominal arguments can reuse one instantiation.
Parameterized protocol templates are selected through a global spelling map,
and their instance/impl/thunk keys likewise omit exact template identity.
Qualified generic/pack function dispatch has the same class of defect: a
source hash is not declaration identity, allocation failure must not fall back
to the bare function name, and `GenericResolver.mangleGenericName` silently
truncates the entire emitted key to 256 bytes. A long base can therefore drop
the author suffix, while long argument mangles can merge otherwise distinct
instantiations.

Observed: the first or last global author can determine both layouts or both
protocol dispatches. Expected: template declaration identity and every nominal
argument identity participate in all cache, symbol, impl, thunk, and vtable
keys.

## Reproduction

Create modules `a` and `b` which each author a different-layout `Thing` and a
different method-set `P($T)` protocol, then exercise:

```sx
Wrap :: struct($T: Type) { value: T; }
Make :: ($T: Type) -> Type { return struct { value: T; }; }

WA :: Wrap(a.Thing);
WB :: Wrap(b.Thing);
MA :: Make(a.Thing);
MB :: Make(b.Thing);

impl a.P(i64) for AImpl { /* A method set */ }
impl b.P(i64) for BImpl { /* B method set */ }
```

Construct and inspect all generic results and erase/dispatch both protocols,
including the same concrete type where possible. Each identity must remain
independent of declaration/import order.

## Investigation prompt

Fix issue 0329 without changing syntax. In `src/ir/lower/generic.zig`, replace
generic struct and type-function cache/symbol argument keys based on
`formatTypeName` with the nominal-aware mangling in `src/ir/generics.zig`. In
`src/ir/protocols.zig` and `src/ir/lower/protocol.zig`, select the exact
parameterized `ProtocolDecl` author (bare and fully qualified) and include its
declaration/source identity in instance, impl, projection, thunk, and vtable
keys. Do not use a global winner after a visibility-only gate.

Also make generic/pack function monomorph caches key directly on exact
`FnDecl`/source identity plus the complete nominal-aware argument/value key.
Generate collision-free dynamically sized backend names from that key; remove
the fixed 256-byte truncation and every allocation fallback that erases author
or argument identity. Allocation failure must be loud/propagated rather than
selecting a plausible bare-name key.

Add same-name layout, pack-argument, qualified generic/pack author, >256-byte
base/argument, and parameterized-protocol runtime regressions. Verify opt 0/3,
`zig build`, `zig build test`, and the full corpus.
