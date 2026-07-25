# Protocol kinds — `constraint | vtable | inline | tagged` (design)

Status: **DESIGN DRAFT 2026-07-25** (decisions by Agra in-session:
kind slot after the param list; four-kind vocabulary; `constraint` is
the unmarked default; the whole-program kind is named `tagged`, not
`#open`/`set`). Not implemented. Prerequisites: the parameterized
identity tail (issues 0329/0330, tracked in the compress stream) and
issue 0283 (warnings render on success — the `-> Self` placement note
below is a warn-class diagnostic). The rvalue→view materialization
change ("part 1" in the session exploration) is a sibling design that
`tagged` composes with but does not require.

Vault task: `SX_tasks/protocol-kinds-tagged.md` — the staged
implementation breakdown. Motivating measurements (UI-shaped
benchmark, depth-6 chains, 729 shapes): tagged-simulated vs today's
owning-vtable model ran 4.0× faster build, 5.2× faster walk, 4.6×
total, at 9.5× binary size for the monomorphized variant — see the
task note for the benchmark provenance.

## Motivation

Protocols today have one runtime story: type-erased values that OWN a
heap copy of their receiver (`{ctx, type_id, vtable}` or the `#inline`
variant), with `*P` borrows and the `#identity` ownership class as the
exceptions. That model taxes exactly the workload the UI framework
lives in: deep per-frame trees of small conformers, where every
erasure is an allocator round-trip and every method call is an
indirect dispatch the optimizer cannot see through.

sx is a whole-program compiler — the full set of `impl P for T`
declarations is knowable, the same way inferred error sets are
collected by a whole-program fixpoint. A protocol kind that exploits
this ("tagged") represents a value as `{ctx, tag}` — a 16-byte
borrowed view whose dense tag indexes compiler-generated dispatch
tables. No erasure allocation, switched (inlinable) dispatch,
compile-time-diagnosable downcasts, and `Self`-in-signature methods
become dispatchable.

Separately: many protocols (`Into` being the stdlib flagship) are
never erased at all — they exist purely as generic constraints and
customization points. Today they still read as if they had a runtime
story. Naming that kind (`constraint`) and making it the DEFAULT puts
the zero-cost kind in the unmarked position: a program opts INTO
paying for dispatch.

## Declaration grammar

```
protocol-decl := Name '::' 'protocol' [ '(' params ')' ] [ kind ] [ attrs ] '{' body '}'
kind          := 'constraint' | 'vtable' | 'inline' | 'tagged'     (absent ⇒ constraint)
```

The kind words are contextual — legal identifiers everywhere else;
only this position reads them as kinds. Exactly one kind may appear.
`#inline` as an attribute is REMOVED (kind slot only; the 10 in-tree
`protocol #inline` declarations respell as `protocol inline`,
migrated in the same change, no fallback).

```sx
Into      :: protocol(Target: Type) constraint {
    convert :: (self: *Self) -> Target;
}
Show      :: protocol vtable { … }
Allocator :: protocol inline #identity { … }
View      :: protocol tagged { … }
Series    :: protocol(T: Type) tagged { … }
```

## The kind ladder

| kind | runtime values | dispatch | membership | ownership axis |
|---|---|---|---|---|
| `constraint` (default) | none — erasure is a compile error | monomorphized at each use | per call site | n/a |
| `vtable` | erased, 3 words | vtable pointer | open world | value/own or `#identity` |
| `inline` | erased, 2+N words | fn-ptrs in the value | open world | value/own or `#identity` |
| `tagged` | tagged borrow, 2 words | generated tag switch | whole program, per instantiation | n/a — always a borrow |

`#identity` is legal only on the two erased kinds. On `constraint` it
is refused (no values to own); on `tagged` it is refused ("a tagged
protocol value is already a borrow").

## `constraint` (the default)

- No runtime values exist. Every erasure spelling — implicit at a
  typed position, `xx`, postfix `.(P)` — is a compile error:

      error: 'Show' is a constraint protocol — it has no runtime
      values; declare it 'protocol vtable', 'inline', or 'tagged'
      to erase

  No fixit beyond naming the three kinds: choosing one is a semantic
  decision (ownership vs borrow, open vs whole-program) the compiler
  must not guess.
- Constraint positions (`$V/Show`), UFCS fall-through, default
  methods, and `impl` blocks work exactly as today — monomorphized,
  zero emission. A constraint protocol emits no vtables, tables, or
  metadata, ever.
- Migration property (the reason the default flip is safe): a bare
  `protocol` that is erased anywhere fails LOUDLY at each erasure
  site. The migration of the 89 in-tree bare declarations is
  compiler-driven — respell exactly those that diagnose; the rest
  silently stop emitting vtables they never used.

## `vtable` and `inline` (the erased kinds)

Semantics unchanged from the current spec: the Ownership and
Lifetime table, the demand diagnostic, owning erasure via
`context.allocator`, `free`/`free(p, alloc)`, `#identity`, borrowed
views `*P`, the dispatchability rule (a method mentioning `Self`
beyond the receiver has no slot), and the `any`-prefix layout
invariant. Every existing spec paragraph in those sections gets its
scope annotated "erased kinds"; no behavior changes beyond the
spelling migration (`protocol #inline` → `protocol inline`).

## `tagged`

### Value and erasure

Layout: `{ ctx: *void, tag }` — 16 bytes. The tag is a dense
whole-program index into per-protocol(-instantiation) tables
generated at link time (the `__sx_type_infos` pattern). The tag is
NOT publicly observable — it renumbers when any impl is added
anywhere.

Erasure is IMPLICIT at every `P`-typed position (decl, argument,
return, field, array element):

- from `*V` — borrows: `{ctx = ptr, tag(V)}`; zero copy;
- from an lvalue `V` — borrows its storage (like `*P` views today);
- from an rvalue `V` — materializes per the rvalue placement rules
  (frame-scoped temporary; see the sibling rvalue-materialization
  design when it lands — until then rvalue erasure at tagged
  positions follows the same temp rule as `any` boxing).

There is no demand error (nothing hidden happens), no owning form,
no `free` (compile error, same gate class as `#identity`), no
`.(P, alloc)` (refused). The postfix `v.(P)` at a tagged target is
legal and identical to the implicit coercion — the explicit spelling
of the same borrow, never required.

Lifetime is the ordinary pointer doctrine: a tagged value is valid
while its referent lives; storing one beyond the referent is the
same unchecked hazard as `*T` and `any`.

`?P`: null ctx is the absent sentinel; the tag is meaningless while
null (same rule as erased protocols).

### Dispatch — every method, including `Self`-in-signature

Per method, per instantiation, the compiler emits a switch over the
conformer set; every arm is fully concrete (`Self` known exactly), so
methods mentioning `Self` or the protocol's type params anywhere in
their signature dispatch fine. The erased kinds' "no slot" rule is
explicitly scoped away from `tagged`.

**`-> Self` placement (the one subtlety).** A `Self`-returning method
called through a tagged VALUE produces a fresh concrete value of
runtime-selected type; each switch arm materializes it as a
frame-scoped temporary and yields a handle to that temporary. Two
consequences the caller must own: the handle dangles when the frame
returns, and a loop that calls such a method accumulates one
temporary per iteration for the remainder of the frame. The compiler
emits a warn-class NOTE at each such call site:

    note: 'resized' returns 'Self' through a tagged value — the
    result materializes a frame-scoped temporary (one per call;
    lives to end of frame). See design/protocol-kinds.md §"-> Self
    placement".

No fixit is offered — the right restructure (bind the receiver
concretely, place the result into owned storage, or hoist out of the
loop) depends on intent and cannot be guessed. Rendering this note on
successful compiles requires issue 0283 (warnings currently render
only on failure) — 0283 is a prerequisite of the tagged unit that
introduces the note.

### Static diagnostics

- Erasing at an instantiation whose computed conformer set is empty
  is a compile error at the erasure site:

      error: no impl of 'Series(bool)' exists in this program
             'Series' is implemented for: f32 (3 impls), i64 (1 impl)

- Downcast `v.(T)` where `T` is in the set: one immediate tag
  compare (constant known at compile time) — no table load, cheaper
  than the erased kinds' runtime type_id check.
- Downcast to a type NOT in the conformer set (including a conformer
  of a different instantiation): compile error, not a runtime false.

### `ProtocolRaw` and the `any` bridge

`v.(ProtocolRaw)` keeps its existing contract — "built field-wise per
the operand's layout, never a bit reinterpret" — with the tagged
build being `{ctx = v.ctx, type_id = table[v.tag]}` (one indexed
load from the per-instantiation `tag → type_id` table). `type_of`,
the type switch, the formatter, and debug tooling stay kind-agnostic.

Boxing a tagged value into `any` follows the same semantic rule:
`{data = ctx, type_id = table[tag]}` — a view of the CONCRETE value,
matching what erased protocols give via their prefix. The byte-level
`any`-prefix invariant is scoped to the erased kinds; for `tagged`
the bridge is synthesized.

### Templated tagged protocols

`P :: protocol(params) tagged { … }`:

1. **Each instantiation is its own protocol.** Separate conformer
   set, tag space, and tables per canonical argument tuple
   (aliases collapse before interning). Values of different
   instantiations are unrelated types.
2. **Membership is computed per instantiation**: concrete impls join
   their one set; blanket impls (`impl P(T) for C(T)`) join as a
   function of the instantiation; blanket impls over unrelated
   params (`impl P(f32) for R(U)`) contribute one member per
   REACHED `R(U)`. Collection is an SCC fixpoint keyed by
   `(Protocol, canonical args)` — the inferred-error-set machinery
   with one more key dimension.
3. **Only reached instantiations exist**, and only VALUE use
   reaches: constraint-position use (`$S/Series(f32)`) is
   monomorphized and emits nothing; the first erasure site
   materializes the instantiation's tables. Unreached
   instantiations cost nothing.
4. Dispatch, diagnostics, and `ProtocolRaw` are as in the nullary
   case, per instantiation.
5. **Recursion is free**: a conformer may contain the protocol type
   (`Scaled(T)` holding a `Series(T)` field) — the 16-byte handle is
   the indirection; there is no inline-payload size equation.

### Reflection

`protocol_kind(P)` (compile-time only, like `is_identity`) answers
the kind as an enum `{constraint, vtable, inline, tagged}` and folds
in `inline if`, so generic code can gate per-kind behavior.
`is_identity(P)` is unchanged (true only for `#identity` erased
protocols).

## Migration inventory (measured 2026-07-25)

- 89 bare `protocol` declarations: compiler-driven split — erasure
  sites diagnose the ones needing `vtable`/`inline`/`tagged`; the
  rest become (cheaper) constraint protocols with no source change.
- 10 `protocol #inline` → `protocol inline` (mechanical).
- 29 `#identity` declarations: unchanged.
- `Into` respelled `protocol(Target: Type) constraint` (explicit,
  self-documenting, though the default makes it redundant).
- Spec sections to annotate/add: layout table, ownership classes,
  dispatchability, postfix cast, `free` — scoped to "erased kinds";
  new sections "Constraint protocols" and "Tagged protocols"
  (shelved beside "Tagged unions" and "Error sets");
  diagnostics pins for every refusal named above.

## Rejected directions (recorded)

- Inline max-size existential payload: unsolvable size equation for
  recursive conformers (`size(View) ≥ 8 + size(ModBox) ≥ 8 + 56 +
  size(View)`), and strictly worse copy traffic at the measured UI
  sizes. Tag+borrow is the design.
- Kind as attributes (`#set`/`#tagged`): files a semantic fork under
  the layout-tweak syntax and needs combination diagnostics the kind
  slot makes unspellable.
- Names `open`/`closed`/`sealed`/`final` (perspective-dependent,
  each misleading from one chair), `set` (collides with the `#set`
  accessor attribute; verb-default reading), `union`/`enum`
  (established type formers with wrong intuitions).
- Exposing the dense tag: renumbers on any impl addition — an
  unstable ABI as an attractive nuisance.
