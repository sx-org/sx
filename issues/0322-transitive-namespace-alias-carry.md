# 0322 — namespace aliases leak through transitive flat imports

> **RESOLVED (2026-07-21).** Re-derivation against the current compiler
> (post-`735c253f`, post-`1b1a59bb`) found EVERY reopened finding fixed —
> the corrected qualified call/store slice (`735c253f`) closed them with
> its source-aware domain verdicts and exact declaration identity:
> - same-name generics through namespaces monomorphize per author (no
>   shared base-name mono key), int and float instantiations, incl.
>   >256-byte author-path keys (0911 long-author legs);
> - selected default ASTs evaluate under the AUTHOR's module (module-local
>   consts in defaults select per namespace);
> - contextual/target-typed literal arguments select each author's
>   parameter type;
> - a selected terminal non-function DIAGNOSES ("this namespace member is
>   not callable") — no silent fallback to a same-named global callable;
> - an unrelated non-visible global does not suppress a valid namespace
>   root (fresh regression `examples/modules/0923-modules-namespace-root-
>   vs-hidden-global.sx`, opt 0/3);
> - deep nested-namespace paths keep exact leaf identity; pack (`..$args`)
>   authors select per namespace.
> Evidence: the pinned multi-hop negative (this issue's repro, corpus);
> permanent matrix 0851-0854, 0899-0902, 0908-0914 (incl. 0911's
> arbitrary-depth default/comptime-typing/mono/pack legs and 0914's
> non-callable no-fallback), new 0923; fresh probe set exercised at opt
> 0+3 during re-derivation (recorded in the vault task). No code change
> was needed in this slice; the only addition is the 0923 regression. The focused one-inner-edge call
> matrix proves an inner alias against the outer target and rejects a
> transitive alias before global fallback. Independent review found that deeper
> call paths and several planning/default/monomorph consumers still use
> separate capped or global-name resolution. No SX syntax or public API
> changed.
>
> Independent review found separate two-segment shortcuts for dispatch,
> defaults, contextual argument typing, and generic monomorphization, while
> call planning does not carry the full-path author. Deeper paths can still
> fall through to global names; direct `a.generic(T)`/`b.generic(T)` share a
> base-name mono key; and selected default ASTs are evaluated under caller
> authority. Reopen until one exact `FnDecl`+source identity flows through all
> call consumers at arbitrary path depth.
>
> **FOLLOW-UP PATCH BLOCKED (2026-07-21).** The first arbitrary-depth repair
> built, but `zig build test` failed both corpus aggregate tests (53 examples
> and one pinned issue). Fresh independent review found that nested runtime
> receivers were classified as namespaces, a selected terminal non-function
> could silently fall back to a same-named global callable, an unrelated
> non-visible global could suppress a valid namespace root, bare selected
> defaults still used the process-global winner, and generic/pack author keys
> could hash, allocation-fallback, or truncate. The next repair must use one
> source-aware domain verdict and exact declaration identity; `.none` may mean
> only “not a qualified candidate”, never “proved member but wrong kind”.

## Symptom

An internal module owns a named import, an implementation bridge flat-imports
that module, and a public facade flat-imports the bridge. The public facade
correctly does not expose ordinary declarations from the implementation, but
it incorrectly exposes the internal named import and everything in its
namespace.

This defeats the non-reexporting flat-import pattern required by stdlib codec
facades. For example, hiding `std/internal/zip.sx` is insufficient while its
`fs :: #import ...` alias can still appear as `std.zip.fs`, carrying platform
ABI declarations into the supported namespace.

## Reproduction

`issues/0322-transitive-namespace-alias-carry/deep.sx`:

```sx
secret :: () -> i64 { 9 }
```

`issues/0322-transitive-namespace-alias-carry/internal.sx`:

```sx
engine_alias :: #import "deep.sx";
internal_api :: () -> i64 { engine_alias.secret() }
```

`issues/0322-transitive-namespace-alias-carry/bridge.sx`:

```sx
#import "internal.sx";
bridged :: () -> i64 { internal_api() }
```

`issues/0322-transitive-namespace-alias-carry/facade.sx`:

```sx
#import "bridge.sx";
public_api :: () -> i64 { bridged() }
```

`issues/0322-transitive-namespace-alias-carry.sx`:

```sx
facade :: #import "0322-transitive-namespace-alias-carry/facade.sx";

main :: () -> i32 {
    // This alias crossed internal -> bridge -> facade and must not exist here.
    if facade.engine_alias.secret() == 9 { return 0; }
    1
}
```

Run:

```sh
./zig-out/bin/sx run issues/0322-transitive-namespace-alias-carry.sx
```

Resolved result: compilation exits 1 with:

```text
namespace 'facade' has no member 'engine_alias'
```

The adjacent ordinary declaration is already correctly hidden:
`facade.internal_api()` reports that it is not a member.

## Required behavior

- An alias owned by module A is visible in A and through a direct flat import
  from B.
- A second flat edge B -> C does not carry A's alias into C.
- Direct named imports and a facade's own aliases remain unchanged.
- Collision and ambiguity behavior for two aliases carried exactly one level
  remains unchanged.
- Qualified calls enforce the source-edge gate for dispatch, signature typing,
  defaults and generic identity. Qualified types, constants, enum variants,
  generic type heads and aliases are tracked separately by issue 0325.

Inspect the plain-root namespace call shortcut noted near
`src/ir/lower/call.zig` and make every qualified lookup consult the same
source-aware alias verdict already used by declaration resolution. Add both a
negative multi-hop regression and positives for direct/one-hop carry.
