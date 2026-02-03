# Comptime Compiler API — `#library "compiler"` + `abi(.zig) extern`

> **⚠ SUPERSEDED (2026-06-17) — direction changed. See
> [`../current/PLAN-COMPILER-VM.md`](../current/PLAN-COMPILER-VM.md).**
> The **byte-weld** approach below (sx structs whose layout is validated to mirror
> the compiler's Zig types, plus serialization / marshaling at the call boundary) is
> the **wrong direction** and is being stripped. The comptime value model
> fundamentally isn't bytes, so the weld bolts a parallel layout regime + hand-built
> byte-copies onto it. The new foundation: a **bytecode VM over flat, byte-addressable
> memory**, where comptime values ARE native bytes — so the compiler-API needs no
> weld, no validation, no marshaling (the compiler exposes its real types/functions
> and sx reads/builds them directly as memory). The goal below (unify
> `declare`/`define`/`type_info` + `#compiler` onto one mechanism, delete the bespoke
> arms) is unchanged; only the *mechanism* is. This doc is retained for history and to
> scope the Phase 0 strip — do NOT implement the weld machinery from here.
>
> **Original status:** design-of-record. Captured a unified mechanism for
> sx↔compiler binding that subsumes the metatype `declare`/`define` primitives AND the
> `#compiler` struct attribute, and exposes the compiler's own type-table API to
> comptime sx. Design locked 2026-06-17; weld mechanism pivoted same day.

## Motivation

Today the compiler↔sx boundary is **two ad-hoc mechanisms**:

- `#compiler` structs (`BuildOptions`) — sx struct whose methods are compiler hooks
  (registered in `compiler_hooks.zig`). A handle to compiler state, method-bound.
- The metatype `declare`/`define`/`type_info` `#builtin`s — comptime sx reaching
  into the type table through a narrow, fixed keyhole, with a *separate, translated*
  `TypeInfo` data model in `meta.sx` (marshalled by hand in `interp.zig`).

Both are the SAME idea — comptime sx interacting with the compiler — implemented
twice, differently. And the metatype path carries real costs: a projected data
model that drifts from `types.zig`, hand-written marshaling, and the staging
fragility of issue 0141 (constructor bodies lowered at `scanDecls` in a half-built
world → wrong IR).

**This unifies them.** One mechanism: a named `compiler` library that exposes a
curated set of the compiler's real types (welded by layout) and functions
(host-call bridged), reachable from comptime sx. `declare`/`define`/`type_info`
become sx library code over the real API; `#compiler` is deleted; `BuildOptions`
migrates onto it.

## The mechanism

### `#library "compiler"`

```sx
compiler :: #library "compiler";
```

A named binding target that resolves NOT to a `.dylib` but to the compiler's own
internal surface (Zig types + functions). Two defining properties:

- **It IS the safety boundary.** The `compiler` library exports exactly the
  curated set of types + functions the compiler chooses to expose. Anything not on
  that export list is unreachable from user comptime code — the boundary is the
  lib's symbol table, not a convention.
- **It is comptime-only.** The compiler isn't present at runtime, so every function
  from `compiler` resolves only under the comptime interpreter; calling one at
  runtime is a clean "comptime-only symbol" error, falling out of the existing
  `is_comptime` boundary. (Welded *types* are still usable as plain runtime data;
  only the *functions* are comptime-gated.)

### `abi(.zig)` + `extern <lib>` — the binding surface

> **Syntax decision (2026-06-17, supersedes the original `extern(.zig) <lib>`
> single-qualifier form).** The ABI/layout selector and the linkage keyword are
> two orthogonal things, so they are two annotations, not one fused qualifier:
> - `abi(.x)` — the ABI / calling-convention annotation, in the postfix slot
>   **before** `extern`/`export`. It is the unified replacement for the old
>   `callconv(...)` (which is removed): `ABI = { default, c, zig, pure }` —
>   `.c` (C ABI / cdecl), `.zig` (Zig-layout weld → the `compiler` library),
>   `.naked` (naked asm). `.default` = unannotated (ordinary sx convention).
> - `extern <lib>` — the linkage keyword + binding source (the named library).

`abi(...)` sits where `callconv(...)` went (after the return type for fns); the
`extern`/`export` keyword and the library handle follow. For welded types, the
same `abi(.zig)` + `extern <lib>` pair sits after `struct`:

```sx
// functions:
text_of       :: (id: StringId)     -> string    abi(.zig) extern compiler;
intern        :: (s: string)        -> StringId   abi(.zig) extern compiler;
register_type :: (info: StructInfo) -> Type       abi(.zig) extern compiler;
find_type     :: (name: StringId)   -> ?Type      abi(.zig) extern compiler;

// types (layout-welded to the lib's real Zig type):
Field      :: struct abi(.zig) extern compiler { name: StringId; ty: Type; };
StructInfo :: struct abi(.zig) extern compiler {
    name: StringId; fields: []Field; is_protocol: bool; nominal_id: u32;
};
```

`abi(.zig)` = "Zig ABI / Zig layout"; `extern compiler` = the linkage + binding
source.

### Layout welding — why it's exact, not brittle

The sx compiler is itself a Zig program; `types.zig` is part of it. So at
**compiler-build time** the real record's layout is available via
`@offsetOf` / `@sizeOf` / `@alignOf`. An `abi(.zig) extern compiler` struct is laid out
to the bound Zig type's EXACT offsets (queried, not guessed), and the compiler
ASSERTS the sx declaration matches the Zig type byte-for-byte (a mismatch is a
build error — the sx side is a header checked against the implementation). Because
the same compiler builds both, they're guaranteed identical, and a `types.zig`
change re-bakes the offsets on the next build — both sides move together.

> **Implementation note (how it's exact, concretely).** No layout-override engine
> is needed. The sx header DECLARES its fields in the compiler type's **memory
> order** (Zig may reorder a struct from source order). The compiler REFLECTS the
> bound Zig type — field names from `@typeInfo`, offsets from `@offsetOf`, size
> from `@sizeOf`, nothing hand-maintained — and VALIDATES the header matches that
> memory order, with loud diagnostics on drift (*field not found*, *wrong field
> order* + the expected order, *type/layout size mismatch*). On pass the sx
> struct's NATURAL layout already equals the Zig layout, so it is an ordinary
> struct — no reorder, no padding tricks, no index/remap tables, no special LLVM
> path — and `@ptrCast`ing it to the compiler's own type and dereferencing is
> byte-identical. When `types.zig` shifts, the header stops matching and the
> developer gets a specific message to fix it.

This is what C-ABI `extern` can't do: it copies Zig's REAL layout, so Zig slices
(`{ptr,len}`), field reordering, and `union(enum)` tag placement all "just work" —
no slice→ptr+len surgery on `types.zig`, no version fragility.

### Host-call bridge (functions)

`compiler` functions dispatch, under the comptime interp, to the registered
internal Zig function — the generalization of the path that already exists
(`host_ffi.zig` resolves comptime `extern "c"` via dlsym; `compiler_hooks.zig`
registers `#compiler` method hooks). The `compiler` lib's registry maps each
exported sx name → its Zig function + welded signature.

## The exposed surface (curated)

Types (welded): `StringId` (u32 handle), `Type` (≡ `TypeId`, u32), `Field`,
`StructInfo`, `EnumInfo`, `TaggedUnionInfo`, `TupleInfo`, and a kind-tagged
`TypeInfo` view (see Risks — the `union(enum)` is the one harder shape).

Functions (comptime-only): `intern(string)->StringId`, `text_of(StringId)->string`,
`find_type(StringId)->?Type`, guarded mutators
`register_struct/register_enum/register_tuple(info)->Type`, and the reflection
readers (`type_of`, field/variant iteration) over the welded records.

`declare`/`define`/`type_info` collapse into thin sx over `register_*`/`find_type`
— or disappear. The bespoke interp arms (`.declare`/`.define`/`.type_info`,
`defineEnum`/`defineStruct`/`defineTuple`/`reflectTypeInfo`) are deleted.

## What it buys (and the one honest limit)

Dissolves: the bespoke `declare`/`define` surface, the projected `TypeInfo` model,
the hand-marshaling, the `#compiler` duplication, and the **0141 class of bugs** —
registration becomes a direct, guarded API call, not "evaluate an sx stdlib body
(List/append) at `scanDecls`," so there's no body to mis-lower at a half-built
stage.

Does NOT repeal: the **ordering law** — a type's layout must exist before code
that uses it is lowered. That's inherent to the compiler, not machinery. The win
is that it stops leaking as "weird exposed stages" and becomes an encapsulated
contract inside the compiler API (the API decides how a registration slots in),
instead of the user threading `declare`→forward-slot→`define`→eval-timing by hand.

## Safety boundary

- Only the `compiler` export list is reachable — no raw `*TypeTable`.
- Mutators are **guarded** (`register_*` validate: dup field/variant names, kind
  changes, well-formedness) — the same checks `define` does today, now at the API.
- Comptime-only enforcement on functions; runtime use is a clean error.
- Mirrors Zig's own discipline: comptime builds types through sanctioned doors
  (`@Type`), it doesn't let user code scribble on the compiler's tables.

## BuildOptions migration

`BuildOptions :: struct #compiler { ... }` + `build_options() #compiler` →
`abi(.zig) extern compiler`: the setter/getter hook-methods become `abi(.zig)
extern compiler` functions (or methods on a welded/handle `BuildOptions`), backed by the
same `BuildConfig` state. The `compiler_hooks.zig` registry becomes the `compiler`
lib's function/type registry. Net: the build DSL and the metatype API ride one
mechanism.

## `#compiler` removal

After both consumers are migrated, delete the `#compiler` attribute and its
special paths: lexer/parser token + sema handling (`src/lexer.zig`, `src/parser.zig`,
`src/sema.zig`, `src/token.zig`, `src/ast.zig`), and the `#compiler`-specific
registration in `compiler_hooks.zig` (the registry stays, re-homed under `compiler`).
sx footprint is tiny (2 lines in `library/modules/build.sx`).

## Code anchors (confirmed 2026-06-17)

Foundation that ALREADY exists:
- `#library "name"` lexes (`hash_library`, `src/lexer.zig:91`) and parses into a
  `library_decl { lib_name, name }` AST node (`src/parser.zig:210`). So
  `compiler :: #library "compiler";` works today (used for FFI libs like raylib).
- `extern` / `export` are keywords (`src/token.zig:46`, `kw_extern`/`kw_export`).

New work for Phase 1:
- **Lexer/parser**: the `abi(.zig)` annotation (a new `abi` keyword replacing
  `callconv`; `ABI = { default, c, zig, pure }`) in the slot before `extern`,
  followed by the `<lib>` handle — `… abi(.zig) extern <lib>` postfix on FN decls
  (after the return type, before `extern`) and STRUCT decls (beside
  `struct #compiler`). **DONE (parse-only)** — `parseOptionalAbi`
  (`src/parser.zig`) wired on fn decls AND struct decls, `ast.ABI`, parser unit
  tests; the `callconv`→`abi` rename migrated 52 sx files + the compiler's
  CC-mismatch diagnostic.
- **AST**: the `abi: ABI` field lives on `FnDecl` / `Lambda` / `FunctionTypeExpr`
  (carries `.zig` for a welded fn); `StructDecl` gained `abi: ABI` +
  `extern_lib: ?[]const u8`. **DONE.**
- **Binding registry**: re-home / generalize `src/ir/compiler_hooks.zig` (today's
  `#compiler` registry) into the `compiler` lib's type+function registry, keyed by
  exported sx name → Zig type (`@offsetOf` layout) / Zig fn (host-call).
- **Layout + emit**: sx struct layout (`src/ir/types.zig` / lowering) honors the
  bound type's offsets; LLVM emission (`src/backend/llvm/types.zig`) hits them.
- **Host-call bridge**: extend the comptime path (`src/ir/host_ffi.zig` +
  `interp.zig`) to dispatch `compiler` functions to their registered Zig fns,
  comptime-only.

## Build order (each phase keeps `zig build test` green)

1. **`abi(.zig) extern <lib>` + `#library` foundation** — parse the postfix
   annotation (the `#library` decl already exists); a binding registry (sx name →
   Zig type/fn); the layout engine honoring the bound type's `@offsetOf` offsets +
   LLVM emission that hits them; **build-time layout-equality assertion**. Prove
   with `Field` (two u32s). First testable sub-step **DONE**: `abi(.zig) extern
   <lib>` PARSES on a fn decl (parser unit test), AST carries the binding (`abi ==
   .zig`, `extern_lib`) — no semantics yet.
2. **Weld `StructInfo`** + `StringId` accessors (`intern`/`text_of`) over the
   host-call bridge.
3. **Re-express `type_info`/`define` (struct)** as sx over `register_struct`/
   `find_type`; migrate `examples/0622`; delete the struct interp arms; suite green.
4. **Widen to enum/tuple** — weld `EnumInfo`/`TaggedUnionInfo`/`TupleInfo`
   (optional fields → sentinels: `backing_type` `.unresolved`, `explicit_values`
   len-0); migrate `examples/0619`/`0623`; delete the enum/tuple interp arms.
5. **Migrate `BuildOptions`** to `abi(.zig) extern compiler`.
6. **Delete `#compiler`**; suite green.

## Risks / open questions

- **`union(enum)` welding.** `TypeInfo` is a Zig tagged union; mirroring its tag
  placement is the one shape harder than plain structs. Start with a `kind`-tagged
  *view* (weld the payload structs, drive the discriminant via a `kind` accessor),
  defer full-union welding. `type_info`/`define` mostly traffic in the payload
  records anyway.
- **Optional fields in welded records** (`?[]const i64`, `?TypeId`) — represent via
  sentinels on the sx side, or expose through accessor functions rather than raw
  fields.
- **LLVM layout emission** for arbitrary external offsets (padding / byte-offset
  GEPs) is the meatiest part of phase 1.
- **Mutation safety** — the guarded-mutator surface must cover every invariant the
  type table relies on (interning, nominal ids, forward slots).
- **`@offsetOf` binding for nested/parameterized types** — the registry must map
  each exported sx type to a concrete Zig type; generic Zig types need a concrete
  instantiation to bind.
