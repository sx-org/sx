# Packages — design contract (locked)

This document is the stable design contract for the sx package system: the
goal, all 49 user-locked decisions, the resolved design-gate rationale
(D1–D11), the compiler audit anchors, target semantics, the library mapping,
the verification matrix, and the definition of done.

It was extracted unchanged from the superseded staged plan (abandoned chain,
last at `packages/phase3-round13-resume`; master was reset before that chain
started). Any reference to a phase or step number (P0.x … P10.x, "Phase 9
cutover", etc.) refers to that superseded plan and is retained only for
provenance. The ACTIVE execution order is `current/PLAN-PACKAGES.md`, which
replaces the staged strategy with atomic cutover landings (L0–L6). Where this
document says a migration/compat mode exists "during migration", the active
plan overrides it: no compatibility mode, shim, or dual import style may exist
at any time on master.

The decisions themselves (## Locked decisions, 1–49) remain binding verbatim.

## Goal

The end state is:

```sx
// app/main.sx
package main;

import "core:fmt";
import "core:mem";
models :: import "../models";

main :: () {
    allocator := mem.GPA.init();
    user: models.User;
    fmt.print("{}\n", user);
}
```

with this library organization:

```text
library/
├── base/
│   ├── builtin/       package builtin
│   ├── intrinsics/    package intrinsics (only if a real low-level need remains)
│   └── runtime/       package runtime
├── core/
│   ├── atomic/        package atomic
│   ├── build/         package build
│   ├── c/             package c
│   ├── fmt/           package fmt
│   ├── http/          package http (many files)
│   ├── io/            package io
│   ├── mem/           package mem
│   ├── meta/          package meta
│   └── ...
└── vendors/
    ├── mbedtls/       package mbedtls
    ├── sdl3/          package sdl3
    └── ...
```

The compiler loads and validates `base:runtime`, resolves all compiler-required
types/fields/hooks once, and passes stable handles through lowering. No later
phase searches globally for `"Context"`, assumes that its allocator is field
zero, or dispatches compiler services through a second name list.

## Locked decisions

1. **Packages replace namespaces/modules as the language boundary.** A package
   is a directory of `.sx` files that all declare the same package name.
2. **One package per directory.** Subdirectories are separate packages; they do
   not create nested namespaces or implied dependencies.
3. **Every package file has `package <name>;`.** The declaration is part of
   package/ABI identity and validates that all files selected for the directory
   belong together.
4. **Files in the same package see every package declaration.** There are no
   forward declarations and no imports between sibling files.
5. **`import` is a language keyword.** The final forms are `import "path";` and
   `localName :: import "path";`; `#import` exists only as migration syntax.
6. **Imports are qualified by default.** Bare import binds the imported
   package's declared name; it never splices declarations into the current
   scope. The import path locates the package but does not name its binding.
7. **Named imports only rename.** `models :: import "../models";` changes the
   local spelling, never the target package identity.
8. **Import bindings are file-local.** All files share package declarations,
   but each source file states the external packages its own bodies use.
9. **No package re-export and no `export import`.** Packages are not values and
   cannot be nested or forwarded wholesale.
10. **Declaration aliasing is the forwarding mechanism.** A declaration alias
   creates a name in the current package while retaining the original entity's
   type, protocol, symbol, and ABI identity.
11. **Aliases are not wrappers or new nominal types.** They emit no duplicate
    function/global symbol and do not create a second protocol/type identity.
12. **Protocol and nominal type identity is package-qualified.** Import aliases
    do not affect identity; declaration aliases preserve it.
13. **`base:` is a collection.** `base:runtime` owns the compiler/runtime
    contract; `core:` contains ordinary standard-library packages; `vendors:`
    contains maintained third-party/foreign bindings.
14. **Collection layering is one-way.** `base` may depend only on `base`; `core`
    may depend on `base` or `core`; `vendors` may depend on all configured lower
    layers. A dependency-cycle diagnostic is mandatory.
15. **Reflection belongs in `core:meta`.** `sizeOf`, `fieldType`, `typeInfo`,
    and their siblings do not move to `base:runtime` merely because the compiler
    implements them.
16. **Public atomics belong in `core:atomic`; math intrinsics belong in math.**
    Package ownership follows semantics, not implementation mechanism.
17. **Compiler-provided declarations use `intrinsic`.** The registry records
    whether an intrinsic lowers a runtime call, evaluates in the compiler VM,
    or supports both.
18. **No function-level compile-time domain.** Ordinary functions can be
    compiler-reachable, runtime-reachable, both, or neither. `#run`, constant/
    type evaluation, and registered callbacks are compiler-stage roots.
19. **`abi(.compiler)` is removed.** `abi(...)` remains for genuine calling
    conventions (`.c`, `.naked`, and the default sx ABI), not evaluation stage.
20. **Compiler services are capability-oriented.** Operations such as emit/link
    take an opaque `core:build.Build` value created by the compiler.
21. **Single-file root mode remains supported.** `sx run file.sx` compiles the
    selected root file as the root package and does not aggregate unrelated
    sibling examples. A directory input aggregates that directory's package.
22. **Package semantics land before separate compilation.** The first package
    implementation may still lower the entire resolved graph into one LLVM
    module, but all identities and mangled symbols must already be package-safe.
23. **The package interface is the future sx-binary boundary.** Separate object
    emission and a semantic interface follow the semantic cutover; they do not
    redefine package identity later.
24. **Idiomatic sx identifiers do not contain `_`.** Compiler-owned and stdlib
    sx APIs use `UpperCamelCase` for types/protocols and `lowerCamelCase` for
    functions, values, fields, and import bindings. `_` remains lexically legal
    for exact foreign names, generated bindings, compatibility aliases, and the
    discard identifier; environment variables and Zig implementation names are
    outside this source-level convention.
25. **The declared package name is the package ABI identity.** Following Odin,
    it must be unique across the final resolved program. Canonical directories
    identify loaded source packages during compilation, but paths, collection
    names, and import aliases never enter sx type, protocol, or linker identity.
    Changing `package foo;` is an ABI break; moving its directory is not.
26. **Package identity requires no project metadata.** There is no project ID,
    manifest identity, registry coordinate, or per-package UUID. Two packages
    with the same declared name cannot coexist in one program; vendored forks or
    simultaneous versions must use different declared package names.
27. **Package declarations are public by default.** A declaration enters its
    package interface unless explicitly marked `private`. Package
    visibility is separate from linker export and calling convention: ordinary
    public sx functions remain package-mangled and use the default sx ABI; only
    `export` creates an exact externally visible C symbol.
28. **`private` means package-wide access and is the only non-public level.** It
    is written as a prefix (`private helper :: ...`). Every file in the package
    may use the declaration; importers may not. SX will not add a distinct
    `internal`, file-private, type-private, protected, or wider package-group
    access level later.
29. **Protocol implementation selection counts as import usage.** A normal
    package import is not unused when protocol resolution selects an `impl`
    defined by that package, even if the file never spells the package binding
    in an expression. SX does not require a discard/effect-only import form or a
    source-level name on the implementation merely for usage accounting.
30. **External implementations require a file-local direct package import.** An
    `impl` defined outside the current package participates at a use site only
    when that exact source file directly imports the implementation's package.
    Imports in sibling files and transitive dependencies do not activate it.
    Implementations defined by the current package are visible throughout that
    package without an import.
31. **A package may define at most one implementation for a canonical pair.**
    Across all files bearing the same package declaration, SX rejects a second
    implementation of the same canonical `(protocol, protocol type arguments,
    concrete type)` pair. Splitting declarations across files does not create
    separate implementation scopes.
32. **Implementations from different packages may coexist.** At a protocol use
    site, the current package's implementation plus implementations contributed
    by that source file's direct imports form the candidate set. Exactly one
    candidate is selected; none is a missing-implementation error and more than
    one is an ambiguity. No package, import order, or concrete-over-generic
    candidate receives implicit priority.
33. **A `::` alias of a mutable global is a constant alias to the same
    storage.** It preserves the target declaration and linker symbol and does
    not snapshot or duplicate the value. Direct assignment through the alias is
    forbidden because the alias binding is constant. Mutation of the underlying
    global, including through SX's existing explicit pointer escape hatch, is
    observed through every alias.
34. **Third-party protocol implementations are allowed unless the type package
    already provides the pair.** A package may define `impl P for T` while
    owning neither declaration, enabling adapter packages. However, an exact or
    overlapping implementation authored alongside `T` reserves that canonical
    pair and makes an implementation in any other package invalid. Multiple
    non-type-owner adapter packages may still provide the pair and are selected
    contextually under D4c.
35. **The standard collection root contains `base`, `core`, and `vendors`.**
    `SX_STDLIB_PATH` overrides discovery of this root. A repeatable
    `--collection name=path` overrides any individual built-in collection or
    defines an additional collection; there is no special `--base` flag or
    `SX_ROOT` variable.
36. **The intrinsic declaration token is bare `intrinsic`.** It is written
    `sizeOf :: ($T: Type) -> i64 intrinsic;`; `#intrinsic` is not introduced.
37. **Compiled packages use separate `.si` and `.o` artifacts.** `.si` is the
    semantic interface and `.o` is the compiled, linkable object paired with it.
    SX does not use `.sxi`, `.so`, or a combined `.sxpkg` container for compiled
    package artifacts.
38. **Standard-library source filenames use lower snake_case.** For example,
    `source_location.sx`, `default_allocator_linux.sx`, and `objc_block.sx` may
    contain declarations named `SourceLocation`, `defaultAllocator`, and
    `ObjcBlock`; filename casing does not affect package or declaration identity.
39. **There is no final `core:std` package — and no compatibility-facade
    phase.** (Amended 2026-07-11 to align with locked decision 46.) `std.sx`
    never becomes a temporary compatibility package: it is deleted in the
    same single batch that rewrites every remaining consumer to qualified
    imports of the owning packages, using the P0.4 migration tool with
    per-file reports. No compatibility surface persists at any point.
40. **(D9) The four additive words are reserved immediately.** `package`,
    `import`, `private`, and `intrinsic` become real reserved keywords at
    P1.1; there is no contextual-keyword migration mode and no Phase 9
    keyword flip. The P0.4 inventory found exactly two real-code identifier
    collisions (`library/modules/platform/bundle.sx:949–950`, a parameter
    named `package`), which are renamed before P1.1 reserves the words.
    Out-of-repo sx code using these words as identifiers breaks with a parse
    error at its next compile; this was explicitly accepted.
41. **(D5b) Extra collections are top-layer.** A `--collection name=path`
    collection may depend on `base`/`core`/`vendors`; shipped collections may
    never depend on a configured one. No rank/dependency configuration
    surface exists.
42. **(D3c) Public interfaces must not reach private declarations.** Every
    public-interface path — signatures, layouts, fields, protocol methods,
    generic constraints, constants, and implementation facts — that reaches a
    `private` declaration is a compile error. There are no opaque private ABI
    facts. The narrow callable-alias re-export exception is defined by locked
    decision 48: the private target declaration itself is not a forbidden
    reachability edge, but its externally observable signature and other
    interface facts remain subject to this rule. `.si` emission reruns the same
    check. Function-parameter default expressions are not public-interface
    reachability edges under locked decision 49; parameter types and
    constraints remain edges.
43. **(D4e) Impl methods stay dot-callable; helpers are excluded.** Protocol
    impl methods participate in ordinary receiver method lookup. When two
    visible protocols supply the same method name for a receiver, the call is
    an ambiguity error with a protocol-qualified disambiguation form and a
    diagnostic listing every `(protocol, impl)` candidate. Extra helper
    methods written inside an `impl` that are not declared by the protocol do
    NOT join direct method lookup.
44. **(D4f) Ownership propagates through builtin shells; impl heads are
    first-order.** For D4d reservation, a package that defines a nominal type
    owns every head that wraps that type in any depth of builtin shells
    (slices, tuples, optionals, pointers, function types). Reservation bites
    only when an owner authors a matching/overlapping impl; until then
    adapters coexist under D4a/D4c file-contextual selection. Multi-nominal
    heads are co-owned: any package owning some nominal inside the head may
    reserve by authoring an impl alongside its type; non-owner impls become
    invalid when any owner has spoken; multiple owners' impls coexist
    contextually. Impl heads are restricted to a first-order unifiable
    pattern grammar (concrete constructors + type variables, no value
    parameters, packs, or type-function expressions in heads); overlap
    checking is syntactic unification and every overlap diagnostic names a
    concrete witness type. Value/shape specialization is written inside the
    impl body via comptime branches. The grammar may be extended later
    without breaking existing heads.
45. **(D6) Default runtime implementations live inside `base:runtime`.** The
    default allocator, default I/O, and minimal platform/CRT bindings are
    target-selected source files within the single `base:runtime` package,
    using package-private helpers. No `base:` leaf packages are introduced
    for them, preventing the protocol/implementer dependency cycle and
    keeping the entire compiler/runtime contract auditable in one package.
46. **(D10) No legacy shims, ever.** A Phase 8 relocation batch moves a
    provider together with the rewrite of ALL its direct consumers (driven by
    the P0.4 migration tool with per-file reports); no legacy-path forwarder
    is ever created. P8 substeps are expanded as provider-plus-consumer-set
    batches in dependency order.
47. **(D11) Self-contained interfaces and standard coalescing.** `.si` files
    serialize the closed, non-importable support IR/facts (private helpers,
    types, constants, implementation facts) that downstream generic
    instantiation needs, so consumers never parse producer source. Duplicate
    downstream specializations coalesce through standard COMDAT/linkonce
    (weak-def on Mach-O) linkage keyed by the full monomorphization key;
    specializations differing in selected `ImplKey` evidence emit distinct
    symbols and never coalesce.
48. **Public callable aliases are re-exports; protocol methods have fixed
    public visibility.** A package may deliberately expose one of its private
    functions through a public declaration alias. The alias declaration's
    author must be allowed to resolve the target; an external use checks the
    selected alias's visibility and does not re-check the canonical target as
    though the caller named it directly. The target's externally observable
    signature still obeys D3c. A private alias remains inaccessible. Protocol
    requirements and every method declaration inside a protocol `impl` are
    always public and do not admit a `private` prefix; only the protocol
    declaration itself may be private. D4e's exclusion of extra impl helpers is
    structural and does not create a private-method spelling.
49. **Function-parameter defaults are declaration-author implementation
    logic, not public-interface edges.** A default expression is resolved with
    the declaring function's lexical and package authority even though the AST
    is freshly lowered when an omitted call supplies it. The caller does not
    directly access declarations referenced by that default, so a public
    function may use a private declaration in its parameter default. Parameter
    types and constraints remain externally observable D3c edges. This
    exception applies only to function/lambda/protocol callable parameter
    defaults; it does not decide or change struct-field-default visibility.

## Resolved syntax and remaining design gates

These decisions have real syntax/API blast radius. Do not silently choose them
during implementation.

### D1 — import token (resolved)

The final surface uses the `import` keyword while retaining sx's declaration
form for an explicit local rename:

```sx
import "core:fmt";
fmt2 :: import "core:fmt";
```

The existing `#import` spelling is accepted only during migration and is
removed at the Phase 9 semantic cutover.

### D2 — default local import name (resolved)

A bare import binds the target's declared package name:

```sx
// core/format/package.sx
package fmt;

// consumer
import "core:format";
fmt.print("hello");
```

The path locates the package but its final component does not determine the
binding. This keeps use sites stable when a directory moves or is renamed and
allows filesystem names that are not sx identifiers. The declaration form is
the explicit file-local rename:

```sx
format :: import "core:format";
format.print("hello");
```

Changing `package fmt;` itself is an API/package-identity change and therefore
changes the default binding for consumers.

### D2b — stable package key (resolved: Odin-style ABI)

`PackageId` is a compact compilation-local handle interned from the declared
package name. The portable semantic key is simply that name:

```text
PackageKey = declared package name
```

The loader separately maps canonical directories to loaded package records so
lexically different imports of one directory deduplicate. After loading, the
compiler rejects two different directories/artifacts that declare the same
package name anywhere in the resolved program, including built-in collections.

```text
core:json             package json
vendors:acme/json     package json   -> duplicate package-name error
```

An import alias changes only a file-local binding. Collections and paths locate
source but do not namespace the ABI. Package-level canonical symbols/types use
the declared name, so checkout and directory moves preserve identity. Interface
and content hashes remain separate compatibility/cache facts. No project or
package metadata file participates in identity.

### D2c — mutable-global declaration aliases (resolved: constant storage alias)

Declaration aliasing includes mutable globals, but the `::` binding itself is a
constant view of the target declaration:

```sx
currentContext :: runtime.currentContext;
```

`currentContext` resolves to the exact storage, `DeclId`, and linker symbol of
`runtime.currentContext`; it does not capture the value or emit another global.
Reading either name observes mutations made through the original declaration.
Direct assignment through `currentContext` is rejected because `::` declares a
constant binding. SX's existing explicit pointer escape hatch may still mutate
the underlying storage at runtime, and subsequent reads through the alias see
that mutation.

### D3a — visibility default (resolved)

Declarations are public by default. An explicit `private` marker makes a
declaration package-private: every sibling file in the package may use it, but
importers may not. `private` does not mean file scope, does not change package or
nominal identity, and does not rename/link-export a symbol.

This rule applies uniformly to functions, globals, constants, types, protocols,
intrinsics, declaration aliases, and foreign bindings. Unnamed `impl`
participation remains the separate D4 coherence decision.

### D3b — package-private marker (resolved)

The keyword is `private` and is written as a prefix:

```sx
private helper :: () { ... }
private State :: struct { ... }
private cache : Map = ---;
```

It always means package-wide access, including when applied to supported type
members: sibling files may access the declaration, importers may not. There is
no `public` keyword because public is the default, and no narrower or wider
privacy tier. Imports and locals do not accept `private`: imports are already
file-local bindings and locals already have lexical scope.

### D3c — private declarations in public interfaces (resolved: strict rejection; locked decision 42)

Decide whether a public declaration may expose a private declaration through an
externally observable signature, layout, constraint, alias target, constant, or
implementation fact. For example:

```sx
private Token :: struct { value: i64; }
parse :: (input: string) -> Token { ... }
```

Two coherent policies are available:

- reject every public-interface path that reaches a private declaration
  (**recommended for the first package implementation**), or
- permit selected private ABI identities to appear as inaccessible/opaque facts
  in interfaces, with explicit construction, layout, reflection, and diagnostic
  rules for importers.

The first policy is locked, with decision 48's narrow callable-alias rule: a
public alias may deliberately re-export a private function, so the target
declaration's private marker alone is not rejected. The alias still exposes the
target's signature, and every private type, constraint, or other interface fact
reachable through that signature remains an error.

Locked decision 49 further clarifies that a function-parameter default
expression is implementation logic, not an externally observable signature
edge. Its type and constraints still participate in D3c, but declarations
referenced only while computing the omitted argument do not. This clarification
does not generalize to struct field defaults.

Do not let `.si` serialization accidentally decide this. Settle D3c before
P3.4 implements visibility across declaration categories; the same validator
must later gate P10 interface emission.

### D4a — impl visibility (resolved: file-local direct package import)

An unnamed external `impl` is visible only in the source file that directly
imports its defining package. A sibling file's import and a transitive package
dependency are insufficient. An implementation authored by the current package
is visible to every file in that package. Import aliases affect only the package
binding spelling, not implementation identity.

```sx
package app;

import "../models";
import "../modelsDisplay"; // makes its impls candidates in this file only

show :: (user: *models.User) {
    user.print();
}
```

Generic constraint satisfaction selects the implementation at the concrete
instantiation site and includes canonical implementation identity in the
monomorphization key. Erased protocol values retain their selected vtable and
need no later implementation import for dynamic dispatch.

This has an explicit evidence boundary. A generic constraint such as `$T/P`
records a requirement on the template; it does not select a concrete
implementation while the template is defined. The exact source file requesting
the concrete instantiation selects the implementation from that file's D4a
candidate set. The selected `ImplKey` becomes compile-time evidence supplied to
the monomorphized body and is part of its key. Ordinary name/type resolution in
the generic body remains pinned to the template's defining file. A protocol
operation or `xx` conversion inside a generic that is not backed by a declared
constraint therefore uses the defining file's direct imports and cannot vary
silently with caller imports. The `.si` interface must serialize generic
requirements so downstream instantiation can repeat this selection without
parsing source.

If a file's protocol operation selects an implementation owned by an imported
package, that import is semantically used. If it contributes no selected
declaration or implementation, ordinary unused-import diagnostics may still
apply. No `_ :: import`, `import impl`, or named-implementation activation syntax
is introduced for this purpose.

### D4b — package-local impl coherence (resolved)

A declared package is one implementation scope. It may define at most one
implementation for a canonical `(protocol, protocol type arguments, concrete
type)` pair, regardless of which package files contain the declarations:

```sx
// text.sx
package app;

impl fmt.Display for models.User { ... }

// debug.sx
package app;

impl fmt.Display for models.User { ... } // error: duplicate implementation
```

The compiler diagnoses the duplicate while assembling the package, not only
when an operation happens to need the implementation.

Generic implementation heads must also be checked for overlap. If two
implementations in one package can both apply to the same concrete canonical
pair, the package is rejected rather than relying on declaration order or an
implicit "more specific" rule:

```sx
impl fmt.Display for models.Box($T) { ... }
impl fmt.Display for models.Box(i64) { ... } // error: overlaps for Box(i64)
```

### D4c — cross-package impl collisions (resolved: contextual)

Different packages may define implementations for the same canonical pair and
coexist in the final package graph. Protocol resolution uses only the current
package's implementation and implementations supplied by packages directly
imported by the exact source file containing the use:

```sx
// compact.sx
package app;

import "../models";
import "../compactDisplay";

showCompact :: (user: models.User) {
    user.print(); // compactDisplay's implementation
}

// verbose.sx
package app;

import "../models";
import "../verboseDisplay";

showVerbose :: (user: models.User) {
    user.print(); // verboseDisplay's implementation
}
```

For a requested canonical pair, candidate count has the following meaning:

- zero candidates: missing-implementation error;
- one candidate: select it; and
- more than one candidate: a required ambiguity diagnostic at that operation or
  generic instantiation; the compiler must not select by traversal or import
  order.

The ambiguity diagnostic must show the requested canonical protocol/type pair,
the protocol operation or generic instantiation that required it, every matching
implementation declaration, and—for external candidates—the direct import that
made each candidate visible. For example:

```text
error: ambiguous implementation of fmt.Display for models.User
  --> report.sx:8:5
   |
 8 | user.print();
   | ^^^^^^^^^^^^ requires fmt.Display for models.User
   |
   = candidate: compactDisplay at ../compactDisplay/display.sx:4:1
     made visible by import at report.sx:4:1
   = candidate: verboseDisplay at ../verboseDisplay/display.sx:4:1
     made visible by import at report.sx:5:1
   = help: remove one direct import or move the two choices into separate files
```

If a generic candidate overlaps a concrete candidate, the diagnostic also shows
the substitutions that made the generic implementation match. If one candidate
belongs to the current package, it has a declaration span but no import span.

A package-local implementation is always a candidate in every file of its
package. Directly importing an external package that supplies the same pair
therefore creates an ambiguity; the local implementation does not silently win.
Likewise, a concrete candidate does not silently outrank a generic candidate.
Import order and import aliases never break a tie.

Two packages with colliding implementations may be imported by the same file
for unrelated declarations. The ambiguity is diagnosed only if resolution in
that file requests the colliding pair. An implementation selected for a
non-generic function is fixed by the file containing that function, not its
callers. Generic instantiation keys include selected implementation identity,
so the same generic may be instantiated separately from files selecting
different implementations. Erased protocol values retain the selected vtable.

This deliberately makes implementation selection contextual: moving a
protocol-using function to a file with different direct imports can change its
implementation. The required direct imports make that context explicit at the
top of the destination file.

### D4d — implementation ownership (resolved: adapters with type-side reservation)

A package may define `impl P for T` when it owns neither `P` nor `T`, enabling
dedicated adapter packages such as `compactDisplay` and `verboseDisplay`.

The exception is an implementation authored by the package that defines `T`.
An exact or generic type-side implementation that can apply to the canonical
pair reserves it: any implementation of that pair from another package is an
invalid declaration, not merely a use-site ambiguity. The adapter compiler can
check this deterministically because the adapter must resolve and load `T`'s
package.

```sx
// package models
impl fmt.Display for User { ... }

// package compactDisplay
impl fmt.Display for models.User { ... }
// error: models defines fmt.Display for User alongside User
```

If the type package provides no matching implementation, multiple adapter
packages may define the pair and coexist under D4c's file-contextual selection.
Adding a type-side implementation later invalidates those adapters and is
therefore a compatibility-breaking change for that protocol/type pair.

### D4e — static impl-method lookup (resolved: dot-call preserved, helpers excluded; locked decision 43)

The contextual candidate rules start from a requested canonical protocol/type
pair, but current sx also makes impl methods directly dot-callable. A call such
as `user.print()` does not identify that pair when two visible protocols both
declare `print` for the receiver type, even if each pair has exactly one
implementation.

Choose one source-level model before implementing P4.4:

- preserve impl-method-as-struct-method lookup and add a protocol-qualified
  disambiguation form plus diagnostics that list every `(protocol, impl)`
  candidate (**recommended for compatibility**), or
- remove impl methods from the ordinary struct-method namespace and allow
  protocol dispatch only where the protocol is already known from a constraint,
  an erased protocol value, or an explicit qualification.

The decision must also state whether extra helper methods written inside an
`impl` participate in direct method lookup. Do not infer a protocol from import
or declaration order.

### D4f — type ownership and decidable impl heads (resolved: propagated ownership + first-order heads; locked decision 44)

D4d's reservation rule is defined for a nominal `T`, but sx implementations can
also target builtins and structural types such as slices, tuples, closures, and
function types. Generic overlap also needs a terminating, deterministic rule
when heads contain value parameters, packs, or type-function expressions.

Before P4.4, decide both:

- whether ownership follows only the outer nominal constructor (making builtin
  and structural heads unowned), propagates through structural wrappers to an
  inner nominal type, or uses another explicitly documented rule; aliases must
  canonicalize before this decision; and
- whether impl heads are restricted to a first-order, unifiable pattern grammar
  (**recommended**), or richer heads are accepted with a conservative rule that
  rejects any pair the compiler cannot prove disjoint.

The selected normalized-head grammar, ownership function, substitutions, and
overlap algorithm are semantic interface data. Source and precompiled-package
checks must produce the same answer.

### D5 — collection configuration (resolved)

The compiler discovers its distribution library root relative to the executable,
as it does today. `SX_STDLIB_PATH` is the single environment override for that
root, which contains exactly the three shipped collection directories:

```text
SX_STDLIB_PATH=/path/to/sx/library
/path/to/sx/library/base
/path/to/sx/library/core
/path/to/sx/library/vendors
```

Any collection, including a shipped one, can be replaced with the repeatable
general flag:

```text
--collection base=/path/to/custom-base
--collection core=/path/to/custom-core
--collection vendors=/path/to/custom-vendors
--collection tools=/path/to/tools
```

An explicit `--collection` entry wins over the corresponding directory under
the discovered/`SX_STDLIB_PATH` root. Repeating the same collection name in one
invocation is an error rather than last-wins behavior. There is no special
`--base` option and no `SX_ROOT` environment variable. Collection names must be
valid package-binding identifiers; roots are canonicalized, and a
`collection:path` import must not escape its configured root through `..`.

### D5b — custom-collection layering (resolved: top-layer extra collections; locked decision 41)

D14 fixes the order of the shipped collection names, including when their roots
are overridden: `base` may depend only on `base`, `core` on `base`/`core`, and
`vendors` on lower shipped layers. A newly configured collection has no layer in
the resolved `--collection name=path` syntax, however. Choose one policy before
P2.4 creates collection records:

- treat additional collections as application/top-layer collections that may
  depend on shipped collections, while shipped collections may not depend on
  them (**recommended; preserves D5's syntax**), or
- add an explicit rank/dependency configuration surface for additional
  collections and define its precedence and diagnostics.

The package loader must validate the selected policy on every resolved import
edge. Cycle detection alone is not layering enforcement.

### D6 — default runtime implementations (resolved: inside base:runtime; locked decision 45)

`base:runtime` cannot depend on `core:mem`, `core:io`, or `core:c`. Decide where
the default allocator, default I/O, and minimal platform/CRT calls live:

- target-selected files inside `base:runtime`, with package-private helpers
  (**recommended**), or
- small leaf packages under `base:` consumed by `base:runtime`.

Do not make `base:runtime -> core:*` edges; that recreates the cycle the base
collection is intended to prevent.

Odin uses the first model. Its single `base:runtime` package contains
`default_allocators_*.odin`, `heap_allocator_*.odin`, `os_specific_*.odin`, and
`entry_*.odin`; build tags/private files select the target implementation. The
files either use `base:intrinsics` or bind the minimal OS/libc surface directly
instead of importing `core:` wrappers. Its custom-runtime guidance replaces the
base root and reimplements the compiler-required runtime declarations. Aligning
SX with this structure keeps the required contract and its default
implementations auditable in one cycle-free package.

### D7 — intrinsic token (resolved)

```sx
sizeOf :: ($T: Type) -> i64 intrinsic;
```

`intrinsic` is a declaration keyword/modifier without a `#` prefix. The compiler
does not accept or document `#intrinsic`.

### D8 — package artifacts (resolved: separate `.si` and `.o`)

Each compiled package emits a semantic `.si` interface and a paired `.o`
compiled object. A combined package container is not introduced. The semantic
contents, target/compiler ABI data, and hashes described in Phase 10 remain
mandatory. Using the conventional relocatable-object suffix avoids colliding
with Unix `.so` shared libraries; SX associates the object with its package
through the paired `.si` metadata.

The association is cryptographic, not basename convention. The `.si` records
the exact object digest/build ID, and the `.o` embeds the matching interface and
package-build ID in a platform-appropriate note or retained symbol. Pair paths
include the target and package/cache hash so target/configuration variants and C
companion objects cannot overwrite one another. Emission publishes the two files
atomically (or through an atomic completed-directory rename), and consumers
reject stale, missing, cross-target, or mixed pairs before invoking the linker.

### D9 — additive-keyword collisions (resolved: reserve immediately; locked decision 40)

The current corpus uses future keywords as ordinary identifiers; for example,
`library/modules/platform/bundle.sx` has a parameter named `package`. Choose how
the additive parser remains behavior-compatible before reserving tokens:

- recognize `package`, `import`, `private`, and `intrinsic` contextually in their
  new grammar positions until the Phase 9 cutover (**recommended**), or
- use the migration tool to rename/backtick every colliding identifier before
  each word becomes globally reserved.

P0.4 must produce a collision inventory either way. Phase 1 may not break a
legacy-mode file merely because it used one of the new words as an identifier.

### D10 — moved-library compatibility (resolved: no shims, same-batch consumer migration; locked decision 46)

The suite must stay green while library packages move in Phase 8 but most corpus
imports are not rewritten until Phase 9. Choose one transition discipline:

- leave a legacy-path shim for every relocated module, not only `std.sx`, until
  its last consumer migrates (**recommended for small, reviewable P8 batches**),
  or
- migrate every direct consumer, including compiler-synthesized imports and LSP
  fixtures, in the same batch that relocates its provider.

Do not move a provider while leaving an unresolved legacy path. Packages first
created in Phases 6–7 are audited/finished in P8; P8 must not independently
recreate or remigrate them.

### D11 — downstream generic ownership/support facts (resolved: self-contained .si + COMDAT coalescing; locked decision 47)

A public generic or type-function body may depend on package-private helpers,
types, constants, and implementation facts. Decide how `.si` provides that
transitive implementation-support closure without making those names importable:

- serialize closed, non-importable support IR/facts needed by downstream
  instantiation, or
- retain producer-owned support symbols/facts with an explicit cross-object
  visibility and ABI contract.

Also choose the deterministic specialization ownership mechanism: COMDAT/linkonce
coalescing or dedicated owner/instantiation objects. The policy must distinguish
full mono keys with different selected `ImplKey` evidence and work on Mach-O,
ELF, and COFF; ordinary strong duplicate definitions are not acceptable.

### Blocking adversarial-review gates (all resolved 2026-07-11)

All eight gates were resolved by the user on 2026-07-11 and recorded as locked
decisions 40–47:

| Gate | Boundary | Resolution |
|---|---|---|
| D9 | P1.1 | RESOLVED: reserve `package`/`import`/`private`/`intrinsic` immediately; migrate the two bundle.sx collisions first (LD 40) |
| D5b | P2.4 | RESOLVED: extra collections are top-layer (LD 41) |
| D3c | P3.4 | RESOLVED: strictly reject public interfaces reaching private declarations, excluding declaration-author function-parameter default expressions (LD 42 amended by LD 48 and LD 49) |
| D4e | P4.4 | RESOLVED: keep direct impl-method lookup with protocol-qualified disambiguation; impl helper methods excluded (LD 43) |
| D4f | P4.4 | RESOLVED: ownership propagates through builtin shells with co-ownership and unlimited depth; first-order unifiable impl-head grammar (LD 44) |
| D6 | Phase 6 | RESOLVED: default runtime implementations live inside `base:runtime` as target-selected files (LD 45) |
| D10 | Phase 8 | RESOLVED: no shims ever; provider + all direct consumers migrate in one batch (LD 46) |
| D11 | P10.1 | RESOLVED: `.si` serializes closed support facts; COMDAT/linkonce specialization coalescing with ImplKey-distinct symbols (LD 47) |

The remaining planned user decision is the P8 API-placement batch: at the
start of Phase 8, the coordinator presents every API-placement/scope choice
(`out` placement, `core:target` retention, UI/GPU/math/platform package
boundaries, and the `hash -> fs` / `mem -> fmt` layering knots) to the user as
one batched decision session, with audit evidence gathered beforehand. No
agent decides these silently.
Portable entity keys, generic evidence separation, contextual vtable identity,
and cryptographic `.si`/`.o` pairing are engineering requirements derived from
already locked semantics, not additional user-facing choices.

## Current-state audit

The migration is large but the compiler already contains useful foundations.

### Surface blast radius (2026-07-10 inventory)

| Surface | Current count |
|---|---:|
| Bare/flat `#import "..."` | ~1,678 |
| Named `name :: #import "..."` | ~286 |
| Extensionless/directory imports | ~79 |
| `abi(.compiler)` occurrences | ~114 |
| `#builtin` occurrences | ~45 |
| Parent-relative `#import "../..."` | 0 |

The examples are grouped by category, with many independent programs in the
same directory (e.g. diagnostics/types/modules each contain more than 130 root
files). That is why root-file mode must not aggregate the input file's siblings.

### Compiler anchors

| Area | Current anchor | Migration consequence |
|---|---|---|
| AST | `src/ast.zig` (`Root`, `ImportDecl`, `NamespaceDecl`, `ABI`) | Add package declaration/identity and intrinsic marker; eventually remove namespace nodes and `.compiler`. |
| Parser | `src/parser.zig` import/builtin/function postfix parsing | Parse `package`, collection imports, intrinsic declarations, compatibility diagnostics. |
| Import loader | `src/imports.zig::resolveImports` / `resolveDirectoryImport` | Replace recursive flat merging with package loading and explicit dependency edges. |
| Path discovery | `src/imports.zig::resolveImportPath` / `discoverStdlibPaths` | Add collection roots and directory-package canonicalization. |
| Compilation owner | `src/core.zig::Compilation.resolveImports` | Own `PackageGraph`, collection config, runtime contract, and package/file IDs. |
| Resolver | `src/ir/resolver.zig` | Replace flat-author and namespace-edge modes with own-package and import-binding modes. |
| Stable declarations | `src/imports.zig::DeclTable` | Extend `DeclInfo` with `PackageId`/`FileId`; preserve node reverse maps. |
| Lowering facts | `src/ir/program_index.zig` | Key source/package caches by IDs, not raw path/name pairs. |
| Symbol/type identity | `src/ir/lower/decl.zig`, `generic.zig`, `protocol.zig`, `coerce.zig` | Package-qualify all nominal/protocol/function/global identities and mono keys. |
| Hidden runtime contract | `src/ir/lower/protocol.zig`, `call.zig`, `coerce.zig`, `error.zig`, `imports.zig` | Centralize and validate `base:runtime`; replace name and numeric-field assumptions with handles. |
| Builtins | `src/ir/calls.zig`, `lower/call.zig`, `type_bridge.zig`, backend ops | Route canonical intrinsic IDs through one registry. |
| Compiler services | `src/ir/compiler_lib.zig`, `src/ir/comptime_vm.zig::callCompilerFn` | Delete duplicated allow-list/string dispatcher; use the intrinsic registry. |
| Stage flags | `src/ir/inst.zig::Function` (`is_comptime`, `compiler_welded`, `is_compiler_domain`) | Replace mixed booleans with explicit compiler/runtime reachability and intrinsic identity. |
| Emission | `src/ir/emit_llvm.zig` | Emit runtime-reachable functions only; retain compiler-only IR for VM evaluation. |
| Build callbacks | `library/modules/build.sx`, `compiler.sx`, `platform/bundle.sx`, `src/core.zig` | Make callbacks ordinary functions; compiler service calls become evaluate intrinsics. |
| LSP | `src/lsp/document.zig`, `src/lsp/server.zig` | Share package loading, aliases, visibility, collection resolution, hover/definition. |

The current unified resolver work is an asset: `module_decls`, `namespace_edges`,
and `DeclId` already preserve authors that the legacy flat merge drops. Evolve
those facts into package facts instead of building a third parallel resolver.

## Target semantics

### Package identity

Introduce stable compilation-local IDs:

```zig
pub const CollectionId = enum(u32) { _ };
pub const PackageId    = enum(u32) { _ };
pub const FileId       = enum(u32) { _ };
```

Each package record contains at least:

```text
PackageId
declared name (the ABI/semantic PackageKey)
canonical directory (loader identity only)
collection/origin locator (resolution and diagnostics only)
ordered FileIds
package declaration span per file
authored declarations
public declaration index
dependency PackageIds
ABI/interface version and hash
```

Filesystem paths locate source; they are not nominal identity. Import aliases
and collection names are never part of identity. A package loaded twice through
lexically different paths canonicalizes to one loaded record. A second canonical
directory with the same declared name is a hard whole-program diagnostic, not a
second `PackageId`.

### Portable entity identity

`PackageId`, `FileId`, `DeclId`, `TypeId`, and `FuncId` are compilation-local
table handles. None may be serialized or used directly in a linker name. Before
Phase 4 makes these handles authoritative, define and test portable keys:

```text
DeclKey = PackageKey + canonical authored declaration identity
TypeKey = builtin/structural shape, or nominal DeclKey + canonical arguments
ImplKey = author PackageKey + normalized canonical impl head
```

The declaration component includes the canonical authored name and kind plus
whatever deterministic signature discriminator the language permits. Aliases
serialize the target's `DeclKey`, never the alias's local `DeclId`. Anonymous or
synthesized entities derive identity from an enclosing `DeclKey` and a stable
semantic discriminator; absolute paths, `FileId`, AST addresses, and package
walk order are forbidden.

A selected generic implementation is identified by its `ImplKey` plus canonical
substitutions. Generic monomorphization keys include the template `DeclKey`,
canonical type/value arguments, every selected implementation, and target ABI.
Protocol thunk/vtable identity includes the protocol `DeclKey`, concrete
`TypeKey`, and selected `ImplKey`; two contextual implementations of the same
protocol/type pair must never share a thunk or vtable symbol. The compiler may
intern all of these keys back to compact local IDs after loading.

### Root modes

```text
sx run/build/ir file.sx
    root package contains only file.sx
    package declaration is still required after final cutover
    sibling files are ignored unless imported as packages

sx run/build/ir directory/
    root package contains all selected top-level .sx files
    every file must declare the same package
```

Target/file selection must be deterministic. Initially preserve the current
top-level `inline if OS/ARCH` mechanism; a later filename-tag feature can select
platform files without changing package identity.

### Package/file scopes

For a declaration body authored in file `F` of package `P`:

1. local/block declarations,
2. every declaration authored by `P`,
3. import aliases declared in `F`,
4. universal/predeclared language names.

There is no flat-import visibility walk. An external declaration is reachable
only through a file-local package binding, unless it has been deliberately
aliased into `P` as a declaration.

### Imports and collections

```sx
import "core:fmt";             // default local binding
format :: import "core:fmt";   // rename only
import "../models";            // project-relative package
```

Resolution rules:

- `collection:path` starts at the configured collection root.
- `./x` and `../x` start at the importing file's directory and resolve a
  package directory.
- Canonicalization happens before cache/identity lookup.
- Project imports do not fall back to CWD and then stdlib search paths; an
  ambiguous spelling must not silently bind a different package.
- File imports are legacy-only during migration. The final package language
  imports directories/packages, not arbitrary implementation files.
- Package dependency cycles are diagnosed with the full cycle chain. They are
  never silently skipped.

### Declaration aliasing

```sx
package mem;

runtime :: import "base:runtime";

Allocator       :: runtime.Allocator;
AllocatorError :: runtime.AllocatorError;
AllocatorProc  :: runtime.AllocatorProc;
```

Required alias categories and tests:

- nominal type and type constructor,
- protocol,
- function and generic function,
- intrinsic,
- constant,
- external function,
- global/reference as a D2c constant alias to the same storage,
- alias-of-alias across packages.

Package import bindings themselves are not declarations that can be aliased
into another package's public surface. `std.fmt` package nesting therefore does
not emerge accidentally.

### Protocols

- Protocol definitions use local `(PackageId, DeclId)` handles backed by a
  portable canonical `DeclKey`.
- `impl P for T` records canonical protocol/type identities, not spellings.
- Import renames do not change impl keys.
- Declaration aliases of `P` or `T` resolve to the same impl key.
- Vtable/thunk names include canonical protocol, concrete-type, and selected
  implementation identity.
- Coherence diagnostics name both packages and both source spans.
- The compiler-known conversion protocol resolves through the validated
  `base:runtime.Into` declaration handle, never the bare string `"Into"`.

### Symbol identity and linkage

Ordinary sx symbols must include the declared package name in their canonical
internal linker name. The encoding must be deterministic and unambiguous, but
must contain no source/absolute/collection path. External C/exported names
continue to use their explicit linker name. The mangler must cover:

- functions and globals,
- nominal types and protocols,
- generic monomorphizations,
- protocol thunks/vtables,
- closures/trampolines,
- synthesized runtime/JNI/Obj-C helpers where sx package ownership applies.

The display name and linker name remain separate fields. Diagnostics show source
names; LLVM/linking use the stable package-name mangling. Default sx functions
retain the sx calling convention and implicit `Context`; package mangling does
not turn them into C functions. `abi(.c)` changes calling convention only, while
`extern`/`export` preserve their explicit foreign symbol contract.

### `base:runtime`

`base:runtime` is normal, readable sx source with a privileged validated
contract. It owns:

```text
CompilerAbiVersion
Context
Allocator
Io
Into
SourceLocation
raw closure/slice/protocol/Any/error ABI views that need documenting
default context construction
startup/cleanup hooks
compiler-inserted runtime hooks actually needed by sx
target-selected minimal default allocator and I/O implementations
```

It does not own `fmt`, general containers, reflection APIs, public atomics, or
the build DSL.

The compiler-side contract is centralized in one source file (provisional:
`src/compiler_contract.zig`). It contains required canonical declarations and
shape validators. On load it produces resolved handles such as:

```text
context_type
context_allocator_field
context_io_field
allocator_protocol
io_protocol
into_protocol
source_location_type
default_context_decl
```

All lowering code consumes this resolved object. Direct string lookups for
contract declarations and direct numeric field assumptions are forbidden after
Phase 6.

### Intrinsics

Source declaration:

```sx
package meta;

sizeOf    :: ($T: Type) -> i64 intrinsic;
fieldType :: ($T: Type, index: i64) -> Type intrinsic;
```

Registry entry:

```text
canonical PackageId + DeclId
stable intrinsic ID
mode: lower | evaluate | dual
expected signature
handler(s)
capability requirements
```

One registry is the allow-list, signature validator, lowerer dispatch, VM
dispatch, documentation source, and audit source. There must not be a separate
`bound_fns` list and `callCompilerFn` name chain.

### Stage-polymorphic functions

Functions carry reachability, not an execution ABI:

```text
compiler-reachable: #run, const/type evaluation, registered build callback
runtime-reachable: main, exports, runtime callbacks, runtime call graph
```

| Reachability | Result |
|---|---|
| compiler only | Lower enough IR for the VM; do not emit into the binary |
| runtime only | Emit normally |
| both | Evaluate in VM where requested and emit once for runtime |
| neither | Dead-strip/not lower until demanded |

Compiler-evaluate-only intrinsics diagnose when reached from the runtime graph.
Intrinsic calls that lower IR (atomics, math, layout queries as appropriate)
remain usable from ordinary runtime-reachable functions.

Build callbacks become ordinary functions:

```sx
package app;

build :: import "core:build";

customBuild :: (b: build.Build) -> bool {
    object := b.emitObject();
    b.link(.{object});
    return true;
}

#run build.onBuild(customBuild);
```

`onBuild` requires a compiler-known named function or supported persistent
capture-free closure. The callback type has the ordinary sx calling convention;
the compiler invokes its `FuncId` in the VM, not through a runtime ABI.

## Target library mapping

Initial migration map:

| Current | Target |
|---|---|
| `modules/std/core.sx` compiler/runtime declarations | `base:runtime` |
| `modules/std/core.sx` reflection declarations | `core:meta` |
| `modules/std/core.sx::out` | `core:fmt` or `core:io` (decide during API audit) |
| `modules/std/target.sx` | predeclared/`base:builtin`, with a normal `core:target` facade only if useful |
| `modules/std/meta.sx` | `core:meta` |
| `modules/std/atomic.sx` | `core:atomic` |
| `modules/compiler.sx` compiler services | `core:build` or private helpers behind it |
| `modules/build.sx` | `core:build` |
| `modules/std/c.sx` | `core:c` |
| `modules/std/posix.sx` | `core:posix` |
| `modules/std/{fmt,mem,io,list,map,...}.sx` | `core:{fmt,mem,io,list,map,...}` |
| `modules/std/http.sx` + `modules/std/http/*.sx` | one multi-file `core:http` package |
| `modules/ui/*.sx` | one multi-file `core:ui` package (or a project collection if not stdlib; decision gate) |
| `modules/math/*.sx` | one multi-file `core:math` package unless APIs warrant subpackages |
| `modules/gpu/*.sx` | one multi-file `core:gpu` package unless backend packages are independently useful |
| `modules/platform/*.sx` | `core:platform` plus target-selected files/subpackages as the audit determines |
| `modules/ffi/*.sx` | one package directory per binding under `vendors:` or `core:` |
| `library/vendors/<name>/<name>.sx` | `vendors:<name>` |

The current `modules/std.sx` facade gets no compatibility-package phase
(amended 2026-07-11 per locked decisions 39/46): it remains the legacy flat
facade until the single dissolution batch deletes it together with the rewrite
of every remaining consumer. There is no final `core:std` convenience package.

## Verification matrix

### Parser/loader

- missing/duplicate/late package declaration,
- lower-snake-case stdlib filenames may contain UpperCamelCase/lowerCamelCase
  declarations without affecting identity,
- same/different package declarations across directory files,
- file-root sibling isolation,
- deterministic directory selection,
- collection/project-relative imports,
- alias/default binding,
- missing package and cycle chain,
- canonical path dedupe and collection-root escape.

### Resolver/identity

- same declaration name in multiple differently named packages for every
  declaration category,
- duplicate declared package name across relative/collection/artifact paths,
- same package cross-file reference,
- file-local import binding not visible in sibling file,
- visibility/private diagnostics,
- D3c public-interface reachability across return/parameter types, aggregate
  layouts, protocol methods, generic constraints, aliases, and impl metadata,
- function-parameter defaults resolve with declaration-author package authority
  and may reference private declarations, while their parameter types and
  constraints remain strict D3c edges (LD 49),
- public callable alias re-export of a private same-package function, with the
  private alias and direct private target still rejected externally,
- parse rejection of `private` on protocol requirements and protocol-impl
  methods, while a private protocol declaration remains valid,
- declaration alias identity and cycles,
- mutable-global alias has the target's address/storage, rejects direct
  assignment, and observes mutation performed through the existing pointer
  escape hatch,
- generic and protocol identity through renamed imports,
- portable declaration/type/impl keys are byte-identical across shuffled file
  discovery, different import traversal, and separate compiler invocations,
- duplicate/overlapping impl diagnostics within one package, with both source
  spans,
- same-pair implementations from different packages coexist when selected in
  different files,
- zero, one, and multiple directly visible implementation candidates produce
  missing, successful, and ambiguous resolution respectively,
- ambiguity diagnostics anchor the requesting operation and list every
  candidate declaration plus each external candidate's enabling import,
- a current-package implementation plus a directly imported external
  implementation is ambiguous, with no local/import-order/specificity priority,
- colliding implementation packages may be imported together when the
  colliding pair is never requested,
- generic specializations selected under different implementation contexts do
  not share a monomorphization or vtable entry,
- constrained generics select `ImplKey` evidence in the concrete instantiation
  file, while unconstrained protocol operations inside a generic retain the
  defining file's direct-import context,
- D4e's selected rule covers two protocols exposing the same method name for one
  receiver and never resolves by import/declaration order,
- D4f's selected ownership and overlap rules agree for source and `.si` facts,
  including builtin, structural, nominal-generic, alias, pack, and type-function
  boundary cases,
- import used only through a selected implementation is accepted, while an
  import contributing neither declarations nor implementations is diagnosed,
- sibling-file and transitive imports do not activate an external impl; the
  exact use-site file must directly import its defining package,
- an adapter package may implement a pair it owns neither side of when the type
  package has no implementation,
- an exact or overlapping type-side implementation rejects implementations of
  that pair in adapter/protocol-owner packages with both declaration spans.

### Runtime/compiler contract

- exact `Context`/Allocator/Io layouts,
- default context under runtime, FFI inbound, threads/fibers, and `#run`,
- custom base missing/wrong declaration diagnostics,
- contract audit deterministic output,
- no direct contract name/index lookup outside the validator.

### Intrinsic/staging

- bare `intrinsic` parses while `#intrinsic` is rejected,
- lower/evaluate/dual mode per intrinsic,
- runtime rejection for evaluate-only services with call path,
- ordinary helper used at compile time and runtime,
- compiler-only callback absent from object/binary,
- callback registration and post-codegen VM invocation,
- registry/source/handler one-to-one validation,
- alias of intrinsic preserves identity.

### Codegen/artifacts

- package-mangled functions/globals/types/protocol thunks,
- explicit foreign/export symbol preservation,
- same member names in differently named packages in one LLVM module and
  separate objects,
- same declared package name rejected before LLVM emission/linking,
- interface hash determinism and mismatch diagnostics,
- `.si`/`.o` pairing, target compatibility, and missing/mismatched-pair
  diagnostics,
- stale-object/new-interface, cross-target pair, interrupted publication, and C
  companion basename-collision diagnostics,
- generic downstream instantiation, including two independently compiled
  consumers of one mono key and two consumers differing only by `ImplKey`,
- target/calling-convention coverage on aarch64/x86_64 and supported OSes.

### Commands after each implementation step

```sh
zig build
zig build test
```

Focused corpus work:

```sh
zig build test -Dname=examples/modules/<case>.sx
zig build test -Dname=examples/modules/<case>.sx -Dupdate-goldens
```

Only update goldens after behavior is correct against existing snapshots and
only for the focused cases whose output/IR intentionally changed.

## Definition of done

The stream is complete when all are true:

- Every active sx source belongs to a declared package.
- Directory packages and single-file roots both work as specified.
- Bare `import` binds a package; no flat-splicing mode remains.
- Import aliases are file-local renames only.
- Compiler-owned and stdlib sx APIs follow the no-underscore casing convention;
  any retained underscore names are documented foreign or compatibility seams.
- Standard-library `.sx` filenames use lower snake_case.
- Declaration aliasing preserves canonical entity identity.
- D9, D5b, D3c, D4e, D4f, D6, D10, and D11 are resolved and recorded before
  their phase boundaries.
- Package visibility and public-interface reachability are enforced.
- Protocol coherence, direct-method lookup, generic evidence selection, and
  structural type ownership follow their recorded policies.
- `base:`, `core:`, and `vendors:` collections ship in the distribution.
- `SX_STDLIB_PATH` locates their common root, while `--collection` can replace
  any one of them or add a collection without a special base flag.
- No `core:std` compatibility package remains.
- `base:runtime` is source-visible, validated, replaceable through
  `--collection base=...`, and inspectable.
- Compiler lowering uses resolved runtime contract handles, not scattered
  names/field indexes.
- Reflection, atomic, math, and build APIs live in their semantic packages.
- One intrinsic registry services lowering and compiler evaluation.
- `#builtin` and `abi(.compiler)` are gone.
- Ordinary functions are stage-polymorphic and emission follows reachability.
- The stdlib/corpus/LSP use package semantics exclusively.
- Declared-package-name mangling prevents cross-package collisions, and duplicate
  package names are rejected across the final program.
- All serialized/linkable entities use portable keys; numeric compiler handles
  remain compilation-local.
- Precompiled package interfaces/objects are deterministic, cryptographically
  paired, and reusable; downstream generic instantiations coalesce only when
  their full keys, including selected implementations, match.
- SX artifacts carry inspectable package/base ABI metadata.
- Issue 0030 remains in its explicitly chosen state unless the user separately
  authorizes that feature.

