# Context extension — `@context_extend`

The Context is sx's dynamically-scoped capability bag, threaded as the hidden
`__sx_ctx` pointer parameter and spread+patched by `push`. Its fields are not
built in: the compiler assembles the program's `Context` struct from every
`@context_extend` declaration in the compilation, so the stdlib, user
libraries, and the application all extend it through one mechanism.

```sx
@context_extend ui: ?*Ui = null;
@context_extend frame_stats: FrameStats = .{};
```

## Rules

- **Mechanism.** `@context_extend` is a top-level declaration. Any module —
  stdlib or user — declares the field it carries, and the assembled `Context`
  is exactly the set of those declarations. There is no primordial prefix:
  `allocator` and `io` are ordinary `@context_extend` declarations in
  `modules/std/mem.sx` and `modules/std/io.sx`.

- **Push is spread+patch.** `push .{ field = v } { … }` seeds from the ambient
  context and overwrites the named fields. An extended field patches exactly
  like any other.

- **Access is global and unconditional.** After assembly the Context is one
  ordinary struct type; `context.field` works in any module of the program with
  no import requirement. Imports gate EXISTENCE only — a module that is not
  compiled contributes no field, and reading it is an ordinary "no such field"
  error. Context fields have no per-source scoping.

- **One flat namespace.** Two `@context_extend` declarations of the same field
  name are a hard compile error naming BOTH declaration sites. No merging, no
  own-wins, no per-source resolution.

- **Defaults are mandatory and comptime-evaluable.** A declaration without a
  default is an error ("the default context must be constructible before `main`
  runs"). Defaults fold into the emitted `__sx_default_context` constant.
  `?T = null` is the idiom for handle fields; the root `push` in `main` is the
  wiring idiom for real values. An erasure default is spelled WITHOUT `xx` — a
  bare identifier at the protocol-typed position, since the declared type states
  the conversion — and the folded constant always borrows the instance global
  (a null ctx is exclusively the `?Protocol` absent sentinel).

- **Deterministic layout.** Fields sort by (declaring module path, field name),
  so builds are reproducible and offsets are stable within a program. No field
  has a guaranteed cross-program offset: every access, compiler-internal ones
  included, compiles against the assembled layout BY NAME.

- **Grammar.** `@context_extend <name> : <type> = <default> ;`, at top level
  only — which includes a top-level `inline if` branch or `inline for` body,
  whose statements are module scope after comptime flattening. An untaken branch
  declares no field; an undecided driver that could declare one holds the
  Context open, and comptime reads of the Context wait for it (protocols §7.9).

- **No-context builds.** A `@context_extend` declaration is inert in a
  freestanding build, so a library carrying one stays importable there. USING
  the context (`push`, `context.field`) is an error that enumerates the full
  registered field list with each field's declaring module:
  ```
  error: `context.ui` requires the implicit context, which this build disables
    registered context fields:
      allocator: Allocator   — modules/std/mem.sx
      io:        Io          — modules/std/io.sx
      ui:        ?*Ui        — modules/ui/pipeline.sx
  ```

## Cost model and field-size guideline

The hidden `__sx_ctx` param is a POINTER, so assembly changes no call ABI.
Reads are a constant-offset load (size-independent) and calls share the
pusher's slot (zero copy); the only growth cost is the spread-copy at `push`
(~1.7 ns for a 112-byte Context, ~+0.5 ns per +80 bytes) and the per-fiber
context copy. Prefer one POINTER per concern (`?*Ui`, `?*Logger`) over fat
inline values — a 2 KB inline field makes every push a 2 KB memcpy. Inline
values stay fully legal (a small value type like a FrameStats or a theme handle
is fine) and the compiler never polices field size; this is a guideline, not a
restriction.

Threads and fibers inherit by copying the spawner's whole context value
(`sched.sx` `dctx`), so added fields ride along. The comptime VM lays the
emitted `__sx_default_context` into comptime memory, so one definition serves
both the LLVM constant and the interpreter. `type_info(Context)` reports added
fields with no special casing.

## Editor support

The assembled Context carries per-field provenance: each field records the span
and file of its `@context_extend` declaration. The editor analyzer builds the
same assembled struct the compiler does through the shared collection pass —
never a second implementation — which gives:

- **Go-to-definition** on a field name in a push literal (`push .{ ui = v }`,
  cursor on `ui`) and on a `context.ui` member read, navigating to the
  declaration in its module.
- **Hover**: type, declaring module, and default value
  (`ui: ?*Ui = null — declared by modules/ui/pipeline.sx`).
- **Completion** after `context.` and inside `push .{ `, listing the full
  assembled field set with types.
- **References**: find-all-references on a `@context_extend` declaration lists
  every push-site and read of that field program-wide.

## Compiler areas

1. Parser: the `@context_extend` directive → an ast decl node.
2. Program-index collection pass (the scanDecls/pass-0a family): gather every
   declaration, sort by (module path, field name), detect collisions.
3. Context struct finalization before any lowering resolves it —
   `findByName("Context")` is the single authority that `lowerPush`, field
   access, and hidden-param typing all follow.
4. `__sx_default_context` emission from the evaluated declaration defaults.
5. Diagnostics: collision (both sites), missing default, non-comptime default,
   and the no-context field enumeration.

The fiber `.ir` goldens print `__sx_default_context`, so they shift once per
layout change.
