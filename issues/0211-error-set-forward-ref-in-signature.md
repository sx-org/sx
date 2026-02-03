# 0211 — forward-referencing an error set from a fn signature crashes the compiler

> **RESOLVED (2026-07-02).** Root cause exactly as analyzed below: the fn
> signature's forward reference stubs an empty STRUCT under `E` (the stateless
> `type_resolver.resolveNamed` has no kind context), and
> `adoptsForwardStructStub` (`src/ir/lower/nominal.zig`) listed only
> `.@"enum", .@"union", .tagged_union` as stub-adopting kinds — `.error_set`
> was missing, so `registerErrorSetDecl` → `internNamedTypeDecl` fell into
> `updatePreservingKey`, whose kind-stability assert (`src/ir/types.zig:484`)
> tripped on the struct→error_set re-key. Fix: add `.error_set` to the
> adopting-kind switch so the real decl re-keys the stub via
> `replaceKeyedInfo`, exactly like enum/union. Regression test:
> `examples/errors/1064-errors-error-set-forward-ref.sx` (param `e: E`,
> `-> !E`, and `(i32, !E)` positions, with raise/catch member identity);
> the minimal repro stays pinned as `issues/0211-error-set-forward-ref-in-signature.sx`.

## Symptom

**One line:** any function signature that references an error-set type
declared LATER in the file (return `!E`, tuple `(i32, !E)`, or a plain `E`
parameter) panics the compiler during decl scan.

Observed: `panic: reached unreachable code` — the kind-stability assert in
`TypeTable.updatePreservingKey` (`src/ir/types.zig:484`), reached via
`registerErrorSetDecl` → `internNamedTypeDecl`
(`src/ir/lower/nominal.zig:47` → `:255`) from `scanDecls`.

Expected: compiles and runs — top-level decls are order-independent
everywhere else (structs, enums, and unions may all be forward-referenced
from signatures; `E6a` handles their stub adoption).

## Reproduction

Standalone, no imports:

```sx
f :: (e: E) -> i32 { return 0; }
E :: error { Fault }
main :: () -> i32 { return 0; }
```

`sx run` on the above panics. Same crash with the error set in return
position (`f :: () -> !E { return; }` / `(i32, !E)`), and identically when
the fn sits inside an active `inline if OS == …` block (how it was found:
a per-OS `accept_conn_nb :: (fd: i32) -> (i32, !SockErr)` in
`std/socket.sx` above the top-level `SockErr` decl). Declaring `E` BEFORE
`f` compiles fine.

## Investigation prompt

> The sx compiler crashes on a forward reference to an error set from any
> function signature. Root cause (verified by reading the code, not yet by
> a fix): when `scanDecls` resolves `f`'s signature before `E :: error`
> is registered, the stateless resolver (`type_resolver.resolveNamed`)
> forward-creates an EMPTY STRUCT placeholder under the name `E` (it has
> no kind context, so it always stubs a struct). When `scanDecls` later
> reaches the real decl, `registerErrorSetDecl`
> (`src/ir/lower/nominal.zig:26`) builds the `error_set` info and calls
> `internNamedTypeDecl` (`nominal.zig:233`): the decl_key is unseen and
> `nominal_id == 0`, so `findByName` returns the struct stub's id — and
> `adoptsForwardStructStub` (`nominal.zig:262`) returns FALSE because its
> incoming-kind switch lists only `.@"enum", .@"union", .tagged_union`,
> NOT `.error_set`. The call therefore falls into
> `table.updatePreservingKey`, whose `TypeKeyContext.eql` assert
> (`src/ir/types.zig:484`) trips on the struct→error_set kind change.
>
> Likely fix: add `.error_set` to `adoptsForwardStructStub`'s incoming
> switch so an error set adopting a forward struct stub re-keys via
> `replaceKeyedInfo`, exactly like enum/union — and update the doc
> comments that enumerate the adopting kinds. Check for the same omission
> anywhere else the enum/union/tagged_union triple is special-cased for
> stub adoption (grep `adoptsForwardStructStub`, `tagged_union =>`).
> Verify: `sx run` on the repro above (expect exit 0), a return-position
> variant (`-> !E`, `(i32, !E)`), a `raise error.Fault` + `catch` variant
> that exercises the set's members through the forward-referenced type,
> and the full `zig build test` (Zig unit tests + corpus).
> Add a regression example under `examples/errors/` (next free number in
> the 10xx block, e.g. `1064-errors-error-set-forward-ref.sx`) per the
> "Creating a new standalone test" procedure.
