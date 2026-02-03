# issue 0206 — a re-exported enum alias degrades to an empty struct `{}`

> ✅ **RESOLVED.** Root cause: the forward-alias fixpoint
> (`resolveForwardIdentifierAliases`, [src/ir/lower/decl.zig](../src/ir/lower/decl.zig))
> only resolved aliases whose RHS was a bare **identifier** (`A :: B`). A
> **qualified** RHS — `A :: ns.Type` (a `field_access` node, e.g.
> `Color :: inner.Color`) — was skipped (`if (cd.value.data != .identifier) continue;`),
> so the alias was never written to the type-alias map and stayed `.pending`.
> `resolveNominalLeaf`'s `.pending` arm fabricates an empty-struct stub
> (`struct Name {}`). For a STRUCT target that stub silently reconciles by name
> when the real struct registers (so qualified struct re-exports happened to
> work); for an ENUM / union / error-set target it never reconciles — the type
> stayed `{}`. Fix: the fixpoint now also handles a `field_access` RHS — it pins
> the namespace to its target module (`namespaceAliasVerdictFrom`, the
> source-explicit verdict built for exactly this "the namespace binds in the
> alias author's file" case) and resolves the leaf there via `selectNominalLeaf`,
> writing the real TypeId through the same `putTypeAlias`. Works in JIT + AOT.
> Regression test:
> [examples/modules/0800-modules-reexported-enum-alias.sx](../examples/modules/0800-modules-reexported-enum-alias.sx).

## Symptom

A facade module re-exports another module's **enum** via an alias decl
(`Color :: inner.Color`, the std.sx / std/http.sx prelude-facade pattern). When
a consumer uses the re-exported enum **as a parameter / value type**
(`fac.Color`), it resolves to an empty struct `{}` instead of the enum:

```
LLVM verification failed: Both operands to ICmp instruction are not of the same type!
  %icmp = icmp eq {} %load, i64 1        ; `c == fac.Color.Green` — c is {} , not the enum
```

and an `xx c` cast (enum → int) silently reads `0` regardless of the variant.

- **Observed:** invalid IR on comparison; `xx`→int always 0.
- **Expected:** the enum resolves; comparison + ordinal work.

### What works (so this is target-kind-specific)

- **Struct** re-export at the identical alias shape (`Shape :: inner.Shape`,
  used as `fac.Shape`) — fine (the empty-struct stub reconciles by name).
- A **direct** import of the defining module (no facade alias) — fine.

Only a re-exported **enum** (and, by the same mechanism, union / error-set)
used through the facade alias broke.

## Reproduction

`examples/modules/0800-modules-reexported-enum-alias.sx` (+ companion
`inner.sx` / `facade.sx`): a facade aliases `Color :: inner.Color` (enum) and
`Shape :: inner.Shape` (struct); the consumer takes both as parameter types,
compares the enum against a variant, casts it to int, and reads a struct field.
Run: `./zig-out/bin/sx run examples/modules/0800-modules-reexported-enum-alias.sx`
→ must exit 33.

## How it was found

Splitting the monolithic `library/modules/std/http.sx` into a facade + part-files
(`http/{types,tls,server,router}.sx`) for DX. The facade re-exports
`EventKind :: server.EventKind`; the `1672` observability test takes
`http.EventKind` as a hook parameter and casts it to an int to log it — which
started recording `0` for every event after the split, failing the test. The
struct re-exports (`http.Config`, `http.Request`) kept working, which localized
it to the enum (non-struct) target kind.
