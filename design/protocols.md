# Constraints and interfaces

The normative rules are specs.md, §Constraints and Interfaces. This document
states the model those rules implement and the design notes behind it.

## The model

sx has two declarations over method signatures.

```
decl := Name '::' ( 'constraint' | 'interface' ) [ '(' params ')' ] '{' body '}'
```

```sx
Ord   :: constraint { less :: (self: *Self, other: Self) -> bool; }
Show  :: interface  { fmt  :: (self: *Self) -> string; }
```

Both head words are contextual: ordinary identifiers everywhere else, read as
heads only in the `::`-head slot. `protocol` is an ordinary identifier.

A **constraint** bounds a generic binder and has no runtime values. Its methods
exist only as monomorphized direct calls; it emits no vtables, no tables, no
metadata.

An **interface** is additionally a runtime value: a three-word handle
`{ctx, type_id, vtable}` whose first two words are byte-identical to an `any` of
the referent. The handle **borrows**. The referent lives outside it, the handle
carries no allocator word, copying a handle aliases the same referent, no
spelling allocates one, and `free` refuses one. A program's ownership of the
referent is expressed where the referent lives — a local, a field, an allocation
made by `Allocator.make` — never in the handle.

## Coercion is positional

An interface-typed target position coerces its operand into a handle over the
operand's own storage. The positions are a call argument, a binding, a struct-
or array-literal field initializer, a `push` field, an assignment, and the
operand of a `?I` wrap. `x.(I)` states the same coercion explicitly.

| operand | result |
|---|---|
| conforming lvalue | handle borrowing that storage in place |
| `*T`, `T` conforming | handle borrowing the pointee |
| `*I` | loads the stored handle |
| a value already of type `I` | the handle, copied |
| conforming rvalue | frame-scoped temporary; the handle borrows it |

The `*I` arm precedes the pointer arm. A `[]I` variadic scopes its temporaries
to the call rather than the frame.

On the spine of a returned expression the rvalue arm is refused: the temporary
dies at the return. The spine covers the returned expression, the field and
element initializers of an aggregate literal that is the returned expression,
the `?I` wrap operand on it, and both arms of an `if` or `match` in return
position; it clears at call-argument lists, assignments, bindings, `push`
fields, and nested function and closure bodies. So `return f(Widget{})` is
legal and `return S{ inner = Widget{} }` is refused.

That refusal is a spelling rule. `r : I = ---; r = Widget{}; return r;`
compiles and dangles — the ordinary borrow hazard, unchanged by the rule.

`.{ }` at a non-static interface-typed target is the **zero handle**: a null
`ctx`, the bit pattern `?I` reads as absent. It is refused at a static position,
and refused on the return spine of a non-optional `-> I` (the diagnostic names
`?I`); `return .{}` at `-> ?I` is the absent sentinel.

## Static positions

Four positions build their handle before `main` runs: a module-scope global's
initializer, an `@context_extend` default, an interface-typed struct-field
default, and a field or element of a statically-constructed value. The one
operand that coerces there names a module-scope global — a bare or
module-qualified path whose root is a module namespace, `xx` recursing into it.
A path rooted at a global value (`g.field`) is refused, and so is every other
operand, `@run` included: the position is judged on the written shape, because a
relocatable symbol is what the image can hold.

`push .{ allocator = arena }` is an ordinary interface-typed field initializer
over a frame-scoped Context, not a static position.

## Conformance

An `impl` block supplies the methods. Conformance is retroactive and
import-scoped: within one import scope exactly one impl of a pair is visible, so
every coercion site selects one vtable deterministically, and duplicates are
diagnosed where both are seen.

A **constraint** head takes structs, untagged unions, enums, builtins,
structural composites, and **interface types** as conformers. An interface's own
methods are members, so exact-signature satisfaction covers them and the bridge
impl body is empty; a constraint method mentioning `Self` past the receiver is
not an interface member and needs a real body.

An **interface** head takes concrete conformers only: `impl Q for I` with both
interfaces is refused, and `p.(Q)` is the conversion between handles.

An interface body refuses a signature mentioning `Self` past the receiver, at
the declaration. A vtable slot must be typable with `Self` unknown, and no
caller-side type exists for a `Self` argument, result, or composite. The
constraint form carries those signatures.

## Re-erasure

`p.(Q)` between interfaces is one runtime read of a link-time
`(type_id, Q) → vtable-or-null` table over the pairs with a program-unique impl.
A pair with visibility-disjoint duplicate impls is absent and reads null. The
table is built per `Q` on demand and waits on the same impl facts the comptime
scheduler waits on. All three temperaments read that null: unconsumed panics,
`try` raises, `.(?Q)` answers null.

## Classification

`is` asks whether the left operand's type satisfies a static description; `==`
and `type_eq` ask identity. A static ask answers site-local impl visibility; a
runtime ask reads program-unique pairs. The two differ only under
visibility-disjoint duplicate impls, where the site-local answer is true and the
program-unique one is false.

`int` is the umbrella over every integer type; `signed` and `unsigned` are its
disjoint, integer-only refinements. `interface` and `struct` are disjoint, a
constraint matches no category, and there is no `constraint` category word.

## Appendix: design notes

- **Why the handle is not an inline payload.** An inline existential sized to
  the largest conformer has no finite solution once any conformer contains the
  interface type (`size(I) ≥ hdr + size(C) ≥ hdr + k + size(I)`), and recursive
  containment is the normal shape of tree-building conformers. The handle is the
  indirection; referent placement belongs to the owner.

- **Why the handle borrows and never owns.** An owning erasure has to name an
  allocator at every spelling that produces one, and the value that results is
  indistinguishable at the type level from one that does not own — so the free
  discipline lives in the programmer's head, aliasing turns every copy into a
  double-free candidate, and comptime escape needs a whole refusal class of its
  own. A borrow-only handle removes all three: allocation stays where allocation
  is spelled (`Allocator.make`), `free` has one answer for handles, and the
  escape rules follow the referent.

- **Why coercion is position-gated.** A handle over a temporary is only safe
  where the temporary outlives it. Making the positions explicit is what lets
  the rvalue arm produce a frame-scoped temporary at a binding and be refused on
  a return spine, without a lifetime system.

- **Why the return-spine rule is a spelling rule.** It catches the shape a
  reader would otherwise read as safe — a literal handed straight back — at zero
  analysis cost. Extending it into a guarantee needs escape analysis across
  assignments, which is a different language.

- **Why `Self` beyond the receiver bars an interface.** Vtable slots must be
  typable with `Self` unknown, and no caller-side type exists for a `Self`
  argument, result, or composite — `[]I` and `[]Buffer(f32)` are different
  layouts, and inventing per-element coercions would smuggle allocation and
  failure into a call boundary. Refusing at the declaration puts the diagnostic
  on the author rather than on every call site.

- **Why interfaces conform to constraints, and not to each other.** A bound is a
  static question about a type, and an interface type is a type; a bridge impl
  answers it once for every handle. Conformance *between* interfaces would be a
  second dynamic dispatch discipline over a value that already carries one, and
  `p.(Q)` already answers that question against the running program.

- **Why defaults compile per conformer.** One shared erased body would split
  method semantics by call path; per-conformer compilation makes a default
  indistinguishable from a hand-written impl method, at the cost the
  impl-registration model already pays.

- **Why coherence is import-scoped.** sx has no orphan rule — conformance is
  fully retroactive — so global coherence would make two independent libraries
  that both conform the same pair permanently un-linkable into one program.
  Import-scoped visibility is the composability mechanism in place of an orphan
  rule: a handle carries its dispatch info, chosen at the coercion site, so
  "which impl" is answerable site-locally and conflicts matter only where both
  are visible.

- **Why re-erasure reads program-unique pairs instead.** The site-local
  visibility that arbitrates an ordinary coercion does not exist at a dynamic
  conversion, and no other arbiter would be sound. A duplicated pair therefore
  answers "not conforming" rather than electing one impl.

- **Why `is` and `==` stay distinct.** They coincide exactly on concrete
  descriptions, and nowhere else: `x is int` and `x is Ord` have no `==`
  spelling, and `type_eq(t1, t2)` over two runtime values has no `is` spelling.
  Collapsing them would either lose the category and conformance questions or
  make `==` phase-dependent.

- **Why `signed`/`unsigned` refine `int` instead of replacing it.** Most generic
  code branches on integer-ness, not on signedness; the umbrella keeps that arm
  a single word, and first-wins ordering gives the refinement to code that wants
  it without a second vocabulary.

- **Why suspension, not a refusal wall or speculation.** A wall (handles banned
  from expansion-driving comptime) is sound but forbids meaningful programs —
  "derive unless a hand-written impl exists" is a per-pair membership question
  with a legitimate answer. Speculation (run against current sets, invalidate,
  re-run) answers it but pays everywhere: re-executed VM waves, transactional
  retraction of speculative registrations, deferred diagnostics, and a "did not
  converge" failure class. Suspension runs every instruction exactly once
  against facts that never change afterward: positive facts are safe immediately
  because impl presence only grows; negative facts wait for finality; the only
  new error is the wait cycle — precisely the program whose meaning is genuinely
  circular. Cost is localized to one subsystem (the VM's ability to park and
  resume an evaluation).
