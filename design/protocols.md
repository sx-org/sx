# Protocols

A protocol names a set of method signatures. A type conforms by
providing those methods in an `impl` block; the protocol then serves
as a generic constraint, and — depending on its **kind** — as a
runtime value with dynamic dispatch.

```
protocol-decl := Name '::' 'protocol' [ '(' params ')' ] [ kind ] [ attrs ] '{' body '}'
kind          := 'constraint' | 'vtable' | 'inline' | 'tagged'     (absent ⇒ constraint)
attrs         := '#identity'                                        (erased kinds only)
```

The kind words are contextual: they are ordinary identifiers
everywhere else in the language; only this position reads them as
kinds. Exactly one kind may appear.

## 1. The kind ladder

| kind | runtime values | dispatch | membership known | ownership |
|---|---|---|---|---|
| `constraint` (default) | none | monomorphized per use site | per call site | — |
| `vtable` | erased, 3 words | vtable pointer | open world | value/own or `#identity` |
| `inline` | erased, 2 + N words | fn-ptrs in the value | open world | value/own or `#identity` |
| `tagged` | tagged borrow, 2 words | generated switch | whole program, per instantiation | always a borrow |

The ladder is ordered by cost. The default is the kind that emits
nothing; a program opts *into* paying for dynamic dispatch by
naming an erased or tagged kind. Every kind supports the full
constraint-position vocabulary (`$T/P` bounds, UFCS fall-through,
default methods); the kinds differ only in what a protocol-typed
**value** is and costs.

```sx
Into      :: protocol(Target: Type) constraint {
    convert :: (self: *Self) -> Target;
}
Show      :: protocol vtable   { fmt :: (self: *Self) -> string; }
Allocator :: protocol inline #identity {
    alloc_bytes   :: (self: *Self, size: i64) -> *void;
    dealloc_bytes :: (self: *Self, ptr: *void);
}
View      :: protocol tagged {
    size_that_fits :: (self: *Self, proposal: ProposedSize) -> Size;
    layout         :: (self: *Self, bounds: Frame);
    render         :: (self: *Self, ctx: *RenderContext, frame: Frame);
}
Series    :: protocol(T: Type) tagged {
    count :: (self: *Self) -> i64;
    at    :: (self: *Self, i: i64) -> T;
}
```

## 2. Declaration

**Body.** A protocol body holds method signatures and default-method
bodies — nothing else (no fields, no constants).

**Receiver.** Every method declares its receiver explicitly as the
first parameter, `self: *Self` or `self: Self`. A first parameter of
any other shape is a parse error. An impl's receiver spelling must
match the protocol's declaration. Dispatch passes the receiver as
the context pointer in the ABI regardless of spelling; a `self:
Self` receiver reached through dynamic dispatch receives a **copy**
of the referent (made by the dispatch thunk or switch arm before the
body runs), so by-value semantics are preserved — mutations of a
by-value receiver are never visible through the protocol value, on
any kind, matching the concrete call.

**`Self`.** A contextual keyword naming the conforming type. It may
appear at any depth in later parameters and returns (`Self`, `*Self`,
`?Self`, `[]Self`, `Box(Self)`); what that does to dispatch depends
on the kind (§5.6, §6.4).

**Keyword member names.** Every reserved word except `inline` is a
legal *bare* method name; `inline` is spellable only in backtick
form (`` `inline ``). The keyword-classified type names (`f32`,
`f64`, …) follow the same backtick rule in member slots.

**Default methods.** A method with a body is a default; impls may
omit it (or override it by providing their own). Default bodies are
compiled **per conformer**, against the concrete `Self` — for every
kind. A call `self.method(…)` inside a default body therefore
resolves statically against the conformer, which means a default may
freely call methods that are excluded from erased dispatch (§5.6):
exclusion constrains call sites *through erased values*, and inside
a default the receiver is concrete. Dynamic dispatch happens at the
outer call site only — the vtable slot (or tagged switch arm) for a
defaulted method points at that conformer's compiled instance.

**Parameterized protocols.** The head may declare type and value
parameters, exactly as generic structs do (`protocol(T: Type) …`,
`protocol(N: u32) …`). Parameters are in scope throughout the body.
A parameterized protocol is a *family*; each canonical argument
tuple names one protocol (§6.7). Canonicalization resolves type
aliases and folds value arguments to comparable constants.

## 3. Conformance — `impl`

```sx
impl Show for Point {
    fmt :: (self: *Point) -> string { … }
}
impl Series(f32) for Sine { … }            // conformance to one instantiation
impl Series($T) for Buffer(T) { … }        // blanket: one impl, a family of conformances
```

- `impl` blocks are top-level declarations. Conformance is
  retroactive: any module may implement any protocol for any type
  with canonical identity — nominal types, and structural composites
  of them (`[]T`, `[N]T`, fn types). Conformer identity is canonical
  type identity; structural types canonicalize structurally.
- In a blanket impl, `$T` introduces the parameter at its first
  mention; later mentions are bare references.
- Impl methods also register as ordinary methods of the type
  (`Point.fmt`), so concrete calls never pay dispatch. If the type
  already declares a member (method or field) with the same name:
  a method with the exact protocol signature satisfies conformance
  and the impl may omit it (providing it anyway is a duplicate
  definition error); any other same-name member is a compile error
  at the impl — sx does not build overload sets across impl
  registration.
- An impl must provide every non-default method not already
  satisfied by an exact-signature existing method.
- **Coherence.** For `constraint` and the erased kinds, duplicate
  `(protocol-instantiation, concrete type)` pairs follow
  import-scoped visibility: a duplicate within one compilation unit
  is an error at the impls; duplicates across modules are diagnosed
  at a use site that sees both. The `tagged` kind requires **global
  coherence**: its conformer sets are whole-program, so a duplicate
  pair is an error regardless of import visibility — diagnosed,
  naming both impl sites, when the pair's instantiation is reached
  (§6.6). Colliding blankets whose instantiations are never reached
  are not diagnosed (nothing exists to collide at).

## 4. Constraint protocols (the default kind)

A constraint protocol has **no runtime values**. It exists to bound
generics and to serve as a compiler-recognized customization point.

```sx
largest :: (xs: []$T/Ord) -> T { … }          // bound: any T conforming to Ord

Into :: protocol(Target: Type) constraint {
    convert :: (self: *Self) -> Target;
}
// `xx val : T` falls through the built-in conversion ladder to an
// `impl Into(T) for Source` lookup; the compiler monomorphizes
// `convert` for the (Source, T) pair and emits a direct call.
```

**Erasure refuses.** Every erasure spelling — implicit at a
protocol-typed position, `xx`, postfix `.(P)` — is a compile error:

```
error: 'Ord' is a constraint protocol — it has no runtime values;
       declare it 'protocol vtable', 'inline', or 'tagged' to erase
```

No fixit names a specific kind: the choice between ownership,
inline layout, and whole-program tagging is semantic and cannot be
guessed from the refusing site. The same refusal applies wherever a
constraint protocol is used as a *storable* type: a field, array
element, or generic type argument of a constraint-protocol type
diagnoses at the declaration or instantiation site.

**Emission: none.** A constraint protocol produces no vtables, no
tables, no metadata. Its methods exist only as monomorphized direct
calls at use sites. Default methods are shared code in source only;
each bound instantiation compiles them against the concrete `Self`.

**Edge cases.**
- A marker constraint protocol (empty body) is legal; it partitions
  types for overload/bound purposes and costs nothing.
- `#identity` on a constraint protocol is refused (there are no
  values to classify).
- `Self`-in-signature methods are unrestricted — every use site
  knows the concrete type.
- `protocol_kind(P) == .constraint` (§8) lets a generic body reject
  or specialize kinds via `inline if`.

## 5. Erased protocols — `vtable` and `inline`

The two erased kinds share every rule in this section; they differ
only in value layout and call sequence.

### 5.1 Value layout

```
vtable:   { ctx: *void, __type_id: Type, __vtable: *Vtable }     3 words
inline:   { ctx: *void, __type_id: Type, fn_1, …, fn_N }         2 + N words

            ┌──────────┬────────────┬───────────┐
Show value  │ ctx *────┼─►concrete  │ vtable *──┼─► global constant,
            │          │  __type_id │           │    one per pair
            └──────────┴────────────┴───────────┘
```

Slot 0 is the receiver address; slot 1 is the concrete type's id,
stamped at erasure. The first two words are byte-identical to an
`any` `{data, type_id}` — an erased protocol value *is* an `any` of
its receiver, extended with dispatch information. `type_of`, the
downcast, the type switch, and `ProtocolRaw` all read this prefix.

Vtables are global constants, one per `(protocol-instantiation,
concrete type, impl)` — a parameterized erased protocol gets
distinct vtables per instantiation (slot types differ, §5.6), and
distinct impls of the same pair in visibility-disjoint modules (§3)
each get their own. Within any one import scope exactly one impl is
visible, so every erasure site selects one vtable deterministically.
They emit on first erasure and are shared by every value erased
through that impl; they are never allocated or freed at runtime. `inline` trades value size for
zero indirection: the fn-ptr words are copied into every value.
Choose `inline` for few-method, call-heavy protocols (allocators,
io); `vtable` keeps many-method values small.

### 5.2 Ownership classes

Every erased protocol belongs to one of two classes:

- **value/own** (unmarked): a protocol value `P` OWNS its ctx — a
  heap copy of the receiver, made at erasure through
  `context.allocator`. `*P` is the borrowed view.
- **`#identity`**: for protocols whose runtime object *is* unique
  state (an allocator, an io runtime). Values only ever borrow, in
  every spelling; there is nothing to free.

### 5.3 Erasure spellings (value/own)

| spelling | receiver | result |
|---|---|---|
| implicit / `xx` | rvalue | **owns** — heap copy via `context.allocator` |
| `expr.(P)` | concrete lvalue or rvalue | **owns** — independent heap copy |
| `expr.(P)` | `*Concrete` | **owns** — snapshot of the pointee |
| `expr.(P)` | `P` (same protocol, value) | **owns** — independent copy of the receiver (`rt_size_of(type_id)` bytes; vtable/fn words reused) |
| `expr.(P)` | `*P` (same protocol) | **owns** — promotion: fresh ctx copy, vtable/fn words reused |
| `expr.(P, alloc)` | any owning shape | **owns** — the copy allocates through `alloc` (an lvalue naming an allocator); pairs with `free(p, alloc)` |
| implicit / `xx` | lvalue or pointer | **compile error** — the demand diagnostic |
| any lvalue / pointer | at a `*P` target | **view** — borrows storage (§5.5) |

Re-erasure to a *different* protocol (`p.(Q)`) is a conversion in
its own right — see §7.4.

The demand diagnostic exists because an implicit erasure of named
storage would silently heap-copy (or silently alias) something the
reader believes is shared:

```sx
w := Widget.{ value = 7 };
s : Sizable = w;      // error: 'w' is an lvalue and 'Sizable' values own
                      // their storage — write the copy ('w.(Sizable)')
                      // or pass a view ('*Sizable') for transient use
s := w.(Sizable);     // the explicit owning copy — independent of w
```

**Shallow-copy caveat.** Owning erasure copies the receiver's BYTES.
Interior pointers (slices, strings, pointers) are copied as
pointers; the copy and the source share their referents. Types whose
deep state must not be shared belong behind `#identity` or a view.

**`#identity` erasure** borrows in every spelling — `xx gpa`,
`gpa.(Allocator)`, decl targets, call arguments, struct-literal
fields. Rvalue erasure refuses ("identity objects need a name; bind
it first"); `.(P, alloc)` refuses (a borrow allocates nothing).

### 5.4 `free`

`free` is one ordinary function, kind-dispatched at compile time via
an inline type match. Its protocol arm reads the backing through
`x.(ProtocolRaw)` — one body for both erased layouts:

- `free(p)` releases through `context.allocator` **as current at the
  free**. If a different allocator was pushed since the erasure, the
  free redirects to it (the context-drift hazard); pair the call
  with the same ambient allocator the erasure ran under.
- `free(p, allocator)` pairs the allocator explicitly, immune to
  drift. The protocol value carries no allocator slot; the caller
  supplies it.
- `free` on an `#identity` value, a tagged value, or a `*P` view is
  a compile error (no owned backing; a view owns nothing).

### 5.5 Borrowed views — `*P`

A pointer-to-protocol is the borrowed view of erased state, under
the ordinary pointer doctrine (unchecked; valid while the pointee
lives). Protocol methods dispatch through `*P` directly, in both
layouts. Views build implicitly at `*P` positions:

- a concrete lvalue builds the view in place — a hidden `P` value
  (borrowing ctx = the lvalue's own address) materializes as a
  temporary scoped to the enclosing function frame, and the `*P`
  points at it; mutations through the view reach the original, and
  the view stays valid to the end of the frame;
- a pointer-to-concrete views its pointee (same hidden-value rule);
- an owned protocol value lends a view via `*s`.

An **rvalue** has no durable storage to borrow: both the
annotated-local and argument forms are compile errors — never a
reinterpretation of value bytes into a pointer slot.

```sx
measure :: (v: *Sizable) -> i64 { v.size() }
w := Widget.{ value = 7 };
measure(w);                            // view in place — aliases w
pv : *Sizable = w;                     // view over w, valid to end of frame
pv : *Sizable = Widget.{ value = 1 };  // error: rvalue — nothing durable to borrow
```

### 5.6 Dispatchability (per method)

Erased dispatch requires a signature expressible with `Self`
unknown. A method whose signature mentions `Self` anywhere beyond
the receiver — at any depth, in parameters or return — has **no
vtable/inline slot**:

| position | `Self` allowed? |
|---|---|
| receiver | yes (required) |
| later parameter, any depth | no — method excluded from erased dispatch |
| return type, any depth | no — method excluded from erased dispatch |

The protocol's own *parameters* are not `Self`: they are concrete
per instantiation, so methods mentioning them keep their slots
(`Conv :: protocol(T: Type) vtable { get :: (self: *Self) -> T; }`
dispatches — each instantiation's vtable types the slot at its own
`T`).

An excluded method is still required of every impl, still callable
on concrete receivers and through constraint bounds; calling it
through an erased value is a compile error that points at the bound
alternative. Because the excluded method is still a *member*, the
call does NOT fall through to UFCS (§7.8) — members win, then the
member's unavailability diagnoses:

```sx
e := p1.(Eq);
e.eq(p2);            // error: 'eq' is unavailable on an erased 'Eq' value —
                     // its parameter 'other: Self' has no expressible type here
are_equal :: (a: $T/Eq, b: T) -> bool { a.eq(b) }    // fine
```

A protocol always erases, whatever its methods: a marker protocol
and an all-excluded protocol both produce legal values with an empty
vtable — `type_of`, downcast, type switch, `ProtocolRaw`, and `free`
work without any dispatchable method. Slots index the dispatchable
methods only, in declaration order. Non-receiver parameters keep
their declared concrete types; only the receiver erases.

## 6. Tagged protocols

A tagged protocol exploits whole-program compilation: the compiler
collects the complete conformer set and represents a protocol value
as a tagged borrow into that set.

**The program** is the import closure of the build's root file. An
`impl` in a module nothing imports does not exist for the build.
Within the closure, membership is **presence-based, not
path-based**: an impl anywhere in the program joins the set — no
import path from an erasure site to the impl's module is required
(the site needs only the type and the protocol in scope; the erased
kinds' site-local impl visibility does not apply). Importing a
module for any reason enrolls all its tagged impls; removing an
import can shrink a set.

### 6.1 Value layout and tables

```
            ┌──────────┬─────────┐
View value  │ ctx *────┼─►concrete│      16 bytes, always
            │ tag      │          │
            └──────────┴─────────┘

per protocol (per instantiation), emitted at whole-program link:
  __sx_tags_<P>_type_ids : [N]Type          tag → concrete type id
  __sx_tags_<P>_m_<name> : per-method dispatch (see 6.3)
```

The tag is a dense index `0..N-1` over the conformer set, assigned
in a deterministic canonical order (sorted by conformer type
identity). It is **not observable**: adding any impl anywhere
renumbers, so no source spelling reads or writes a tag. Table
symbols embed the protocol's full canonical nominal identity —
including instantiation arguments spelled out completely — so two
instantiations can never share or truncate into one symbol.

### 6.2 Erasure: implicit, allocation-free, ownership-free

Erasure is implicit at every `P`-typed position — declaration,
argument, return, field, array element:

- from `*V`: borrows — `{ctx = ptr, tag(V)}`, zero copy;
- from an lvalue `V`: borrows its storage in place (mutations
  through the value reach the original);
- from an rvalue `V`: materializes a temporary scoped to the
  enclosing function frame and borrows that (the same placement
  rule as boxing an rvalue into `any`) — **except at a `return`
  position**, where the frame is about to die: erasing an rvalue
  directly at `return` is a compile error ("nothing durable to
  borrow beyond this frame; bind it, or place it in storage the
  caller owns"). Returning a tagged value whose referent is a
  callee LOCAL is legal and unchecked — the same doctrine as
  returning a slice of a local array: the borrow dangles, and the
  caller must not use it. Sound component patterns return values
  whose referents outlive the frame (arena placements, globals,
  fields).

There is no owning form, hence: no demand diagnostic (nothing
hidden happens), no `free` (compile error, same gate class as
`#identity`), no `.(P, alloc)` (refused), and `#identity` itself is
refused ("a tagged protocol value is already a borrow"). The postfix
`v.(P)` at a tagged target is legal and identical to the implicit
coercion — never required.

Lifetime is the ordinary pointer doctrine: a tagged value is valid
while its referent lives. Storing one beyond its referent — in
particular, letting a frame-temp-backed value escape the frame — is
the same unchecked hazard as `*T` and `any`.

`?P`: null ctx is the absent sentinel; the tag is meaningless while
ctx is null.

### 6.3 Dispatch: the generated switch

Per dispatchable method, per instantiation, the compiler emits one
dispatch routine switching on the tag; every arm is a direct,
inlinable call with `Self` fully concrete. Schematically (backend
pseudocode, not sx syntax):

```
__sx_tags_Series$(f32)$_at(v: {ctx, tag}, i: i64) -> f32:
    switch v.tag:
        0: Buffer(f32).at(cast v.ctx to *Buffer(f32), i)
        1: Sine.at(cast v.ctx to *Sine, i)
        2: Scaled(f32).at(cast v.ctx to *Scaled(f32), i)
```

The switch is total over the set — no default arm exists; a tag out
of range is unreachable by construction. Backend-standard switch
lowering applies (jump table at scale, direct call when the set has
one member — a single-conformer tagged protocol devirtualizes
completely). Methods whose ABI depends on the selected arm —
`Self`-returning methods (§6.4) — do not use an outlined routine:
their switch is expanded **inline at each call site**, so arm-local
materializations land in the caller's frame.

### 6.4 Dispatchability on tagged values

Tagged dispatch extends the erased rule by exactly the *direct*
`Self` positions — because each switch arm knows `Self`, a bare
`Self` parameter or a bare `Self` return is expressible:

| position | erased kinds | tagged |
|---|---|---|
| receiver | yes | yes |
| bare `Self` later parameter | no | **yes** — caller passes a `P` value; the arm checks its tag against the arm's own (mismatch is a checked runtime failure — the one runtime check in tagged dispatch) and passes the referent |
| bare `Self` return | no | **yes** — see placement below |
| `Self` at depth (`*Self`, `?Self`, `[]Self`, `Box(Self)`, fn types) | no | **no** — excluded, same rule: a composite of `Self` has no caller-side type (a `[]P` of 16-byte handles is not a `[]Buffer(f32)`), and no per-element coercion exists |
| protocol's own parameters, any depth | yes (concrete per instantiation) | yes |

An excluded method behaves exactly as on the erased kinds:
required of impls, callable concretely and through bounds, compile
error through the value, members-win over UFCS.

**Bare `Self` return — placement.** The dispatch switch for a
`Self`-returning method expands inline at the call site (§6.3), and
each arm materializes its concrete result as a temporary in the
**calling function's frame**, yielding a tagged borrow of it. Two
consequences the caller owns: the value dies with the caller's
frame, and a loop accumulates one temporary per iteration until the
frame ends. The compiler emits a warn-class note at each such call
site:

```
note: 'resized' returns 'Self' through a tagged value — the result
materializes a frame-scoped temporary (one per call; lives to end
of frame). See design/protocols.md §6.4.
```

No fixit is offered: the right restructure (bind the receiver
concretely, place the result into owned storage, hoist out of the
loop) depends on intent.

### 6.5 Conformer collection

Membership is computed by a whole-program fixpoint over `impl`
declarations, keyed by `(protocol, canonical argument tuple)`:

```
seed:  every instantiation with a value-use site in the
       monomorphized program (§6.6)
step:  set(P(args)) = { T : concrete impl P(args) for T,  T instantiated }
                    ∪ { C(args′) : blanket impl P($params) for C(params),
                                   params unified with args,
                                   C(args′) instantiated }
       admitting a conformer whose fields/methods mention other
       tagged instantiations marks THOSE instantiations reached
       (and monomorphizes the admitted conformer's impl methods,
       which may itself instantiate further types/instantiations)
repeat until no set and no reached-instantiation changes
```

**What "instantiated" means.** Admission draws only from types the
monomorphized program instantiates — the fixpoint itself never
invents new *type* instantiations out of blanket unification alone.
Reaching a protocol instantiation and monomorphizing admitted
impl bodies CAN instantiate new types (an impl body may spell
`Nest(Nest(T))`); such chains fall under the ordinary generic
instantiation-depth diagnostic, exactly like a generic function
recursing with a growing type argument. With that guard, admission
draws from a finite type population and each iteration only adds
sets or members, so the fixpoint terminates.

Argument tuples are canonicalized (aliases resolved, value args
folded) before keying, so `Series(Sample)` and `Series(f32)` are one
entry when `Sample :: f32`. Blanket impls over parameters the head
does not mention (`impl Series(f32) for Repeat($U)`) contribute one
member per *instantiated* `Repeat(U)` — never an open-ended family.
Blanket impls bounded by constraint protocols
(`impl Show for $T/Ord`) are not a supported form: an impl's `for`
target must name a type constructor, not a bound.

### 6.6 Reached instantiations only

Constraint-position use (`$S/Series(f32)`) is monomorphized and
reaches nothing. **Value use** — an erasure site, protocol-typed
field or array-element declaration, protocol-typed return or
parameter — reaches the instantiation and materializes its tables.
Reachability is judged over the **monomorphized program**: every
compiled function body counts, called or not; generic bodies count
once instantiated and not otherwise. An instantiation nobody
value-uses emits nothing at all; a tagged protocol used only as a
bound costs exactly what a constraint protocol costs.

### 6.7 Templated tagged protocols

Each canonical argument tuple names its own protocol with its own
conformer set, tag space, and tables. Values of different
instantiations are unrelated types; tags never travel between
spaces:

```
Series(f32)                       Series(i64)
tag 0 → Buffer(f32)               tag 0 → Buffer(i64)
tag 1 → Sine                      tag 1 → Counter
tag 2 → Scaled(f32)
```

Tag `1` means `Sine` in one space and `Counter` in the other — one
more reason tags are unobservable.

### 6.8 Static diagnostics

- **Empty set**: any value-consuming operation — erasure, method
  call, downcast — at an instantiation whose computed set is empty
  is a compile error at that site (no value of the type can exist):

  ```
  error: no impl of 'Series(bool)' exists in this program
         'Series' is implemented for: f32 (3 impls), i64 (1 impl)
  ```

  A *type-position* use (a field or parameter of an empty-set
  instantiation, never erased into and never dispatched) is legal
  and emits nothing.
- **Downcast in the set**: `v.(Buffer(f32))` compiles to one
  immediate compare against the known constant tag — no table load.
  The checked/soft/chained assertion temperaments apply as on any
  postfix assertion.
- **Downcast out of the set** — a non-conformer, or a conformer of a
  different instantiation — is a compile error, not a runtime false:

  ```
  v.(Timer)         // error: 'Timer' does not implement 'Series(f32)'
  v.(Buffer(i64))   // error: 'Buffer(i64)' does not implement 'Series(f32)'
  ```

- **Type switch** on a tagged subject matches concrete conformer
  arms; an arm naming a non-conformer is warned dead. User code
  cannot spell "all conformers" (the set is open to extension at
  the source level).

### 6.9 Recursion

A conformer may contain the protocol type; the 16-byte handle is the
indirection, so no size equation arises:

```sx
Scaled :: struct($T: Type) {
    inner: Series(T);         // a handle — not an inline payload
    factor: T;
}
impl Series($T) for Scaled(T) {
    count :: (self: *Scaled(T)) -> i64 { self.inner.count() }
    at    :: (self: *Scaled(T), i: i64) -> T { self.inner.at(i) * self.factor }
}
```

```
┌────────────┐    ┌────────────┐    ┌────────┐
│ Scaled(f32)│    │ Scaled(f32)│    │ Buffer │
│ inner.ctx *┼───►│ inner.ctx *┼───►│ (f32)  │
│ inner.tag 2│    │ inner.tag 0│    └────────┘
└────────────┘    └────────────┘
   arbitrary depth; each hop is one 16-byte handle
```

## 7. Cross-kind semantics

### 7.1 RTTI: `type_of`, downcast, type switch

Every protocol value answers `type_of` with its receiver's concrete
type id — read from slot 1 on the erased kinds, from the
`tag → type_id` table on `tagged`. The downcast `p.(T)` and the type
switch on a protocol subject follow the same source: runtime
type_id compare for erased values, compile-time-constant tag compare
for tagged values. There is no implicit opening of a protocol value;
the type switch is the opening construct.

### 7.2 `ProtocolRaw`

```sx
ProtocolRaw :: struct { ctx: *void; type_id: Type; }
```

`p.(ProtocolRaw)` (and `xx p` at a `ProtocolRaw` target) builds the
pair **field-wise per the operand's layout — never a bit
reinterpret**: a prefix copy on the erased kinds, `{ctx,
table[tag]}` on tagged (one indexed load). Reflection consumers stay
kind-agnostic. The dense tag itself has no raw view.

### 7.3 The `any` bridge

Boxing a protocol value into `any` yields a view of the **concrete
receiver**: `{data = ctx, type_id = concrete}` — the byte prefix on
erased kinds, synthesized through the table on tagged. The reverse
direction is refused: a postfix assertion with a *protocol* target
on an `any` receiver is a compile error (an `any`'s tag is always a
concrete type; the assertion could only ever fail) — assert the
concrete type or use a type switch.

### 7.4 Re-erasure — `p.(Q)` between protocols

Re-erasure to a different protocol is a direct conversion (a
recovery target of the postfix engine), never a manual
downcast-then-erase — the concrete type behind `p` is not statically
known, so only the compiler can perform it. Semantics:

- **Conformance check**: whether `p`'s concrete type implements `Q`
  is a runtime fact; the assertion temperaments apply (`p.(Q)` hard,
  `p.(?Q)` soft, `try p.(Q)` failable). For a tagged `Q`, "conforms"
  means "is in `Q`'s conformer set"; the check maps
  `type_id → Q-tag` through a link-time table.
- **Result ownership follows `Q`'s kind**: value/own `Q` → an
  owning copy of the receiver (`rt_size_of` via the concrete type
  id); `#identity` `Q` → a borrow of `p`'s ctx; tagged `Q` → a
  borrow of `p`'s ctx with `Q`'s tag. A borrow result ties its
  lifetime to `p`'s referent.
- `Q == P` degenerates to the same-protocol rows of §5.3 (erased)
  or the identity coercion (tagged).

### 7.5 Equality

`==`/`!=` are not defined on protocol values of any kind (compile
error, as on `any`): two handles may reference one object, equal
bytes may be distinct objects. Compare `type_of`, downcast and
compare concretely, or define a protocol method. Map keys follow
from `==`: refused.

### 7.6 Protocol values in aggregates, generics, and the Context

Protocol types with values (erased and tagged) are ordinary storable
types: struct fields, array elements, returns, and **generic type
arguments** — `List(View)` is a list of 16-byte handles,
`List(Show)` a list of 3-word owning values, and `size_of` answers
per §5.1/§6.1. A protocol type may itself be an instantiation
argument of another protocol (`Series(View)`). Constraint protocols
are refused in every storable position (§4).

Context fields may be protocol-typed. A **default** on such a field
requires a borrow-kind protocol (`#identity` or tagged): the
default-context fold is the identity erasure of a named instance
global — a borrow, never null (null ctx is exclusively the `?P`
absent sentinel). A value/own protocol-typed context field takes no
folded default (an owning constant cannot exist before `main`); it
is populated by `push` at runtime. Threads and fibers inherit the
context by snapshot; a snapshot copies handles, not referents — a
borrow outliving its referent is the standard hazard.

### 7.7 Packs and variadics

- `..xs: []P` (runtime variadic, erased or tagged element): each
  trailing argument erases per its kind's rules and packs into a
  runtime `[N]P`; `xs[i].method()` dispatches dynamically.
- `..xs: P` (comptime heterogeneous pack): each element keeps its
  concrete type; calls monomorphize — all kinds, including
  `constraint`, participate.

### 7.8 UFCS

A protocol-typed receiver dispatches its own members first and falls
through to `ufcs` functions only for **non-members**
(`context.allocator.create(Session)` — `create` takes the protocol
value as its first parameter). A member excluded from dispatch is
still a member: the call diagnoses per §5.6/§6.4 rather than falling
through. Constraint-bound receivers resolve at monomorphization.

### 7.9 Compile-time execution

Protocol *values* do not exist during compile-time execution
(`#run`, comptime folds): vtables and tag tables are link-time
artifacts, and a comptime-invented tag would renumber. Erasure
inside comptime-executed code is a compile error; constraint bounds,
`protocol_kind`, `is_identity`, and all monomorphized protocol
machinery work fully.

## 8. Reflection

- `protocol_kind(P) -> {constraint, vtable, inline, tagged}` —
  compile-time only; folds in `inline if`.
- `is_identity(P)` — true only for `#identity` erased protocols;
  false for every other type. Compile-time only.
- A runtime `Type` value always tags a concrete type, never a bare
  protocol type. Composites *containing* protocol types (`*Show`,
  `[]View`) are concrete types and get tags like any other
  composite.

## 9. Internals walkthrough

**Symbols.** Vtables: one global constant per
`(protocol-instantiation, concrete type, impl)`, every identity
spelled in full — `Conv(f32)`/`Conv(i64)` never share a vtable
symbol (their slot types differ), and neither do two
visibility-disjoint impls of one pair (their bodies differ; the
impl's declaring module is part of the symbol). Tagged tables and dispatch
routines: named by the protocol's canonical identity including
complete instantiation arguments. Canonical identity is structural
on the argument tuple after alias resolution — no display-name
truncation participates in any symbol or cache key.

**Emission points.** Vtables and inline fn-ptr sets emit on first
erasure of a pair. Tagged tables and dispatch routines emit at
whole-program link, after the conformer fixpoint converges — they
cannot emit per-module, because any module may still add impls.
Marker/empty vtables are emitted like any other (a protocol always
erases on the erased kinds).

**Dispatch call sequences** (backend pseudocode, not sx syntax):

```
vtable:  load p.vtable → load slot k → indirect call(ctx, args…)
inline:  load p.fn_k               → indirect call(ctx, args…)
tagged:  call __sx_tags_P_m(v, args…)      — outlined switch on v.tag
         (single-arm sets fold to a direct call; small sets to
          compare chains; large sets to jump tables)
tagged, bare-Self-returning method:
         the switch expands INLINE at the call site; each arm
         materializes its concrete result in the caller's frame
```

**`free`.** One function, compile-time kind-dispatched by an inline
type match: a protocol arm (ctx via `ProtocolRaw`, one body for both
erased layouts, gated on the ownership class — `#identity` and
tagged refuse), a closure arm, a slice arm; every other argument
kind is a compile error.

**The collection pass.** Tagged membership runs as an SCC fixpoint
over the whole monomorphized program (the same machinery family as
inferred error sets), keyed by `(protocol, canonical args)`, seeded
from value-use reachability (§6.6), closed under blanket-impl
unification, admitted-conformer field/method mentions, and the
instantiations produced by monomorphizing admitted impl bodies
(§6.5, bounded by the generic instantiation-depth diagnostic).
Deterministic tag order falls out of sorting the converged set by
conformer identity.

## 10. Edge-case catalog

| case | disposition |
|---|---|
| marker protocol (empty body) | constraint: free partition. erased: erases with empty vtable; RTTI/free work. tagged: erases; downcast/type switch are its whole interface |
| all methods `Self`-excluded (erased kind) | erases fine; every method call through the value diagnoses; concrete/bound calls fine |
| single-conformer tagged protocol | fully devirtualizes: dispatch is a direct call; downcast to that conformer folds to true |
| zero-conformer tagged instantiation | type-position use legal; erasure, method call, or downcast at it is a compile error naming the implemented instantiations |
| duplicate impl `(P-instantiation, T)` | constraint/erased: import-scoped (§3). tagged: global coherence — error at the first reached colliding instantiation, naming both impl sites; unreached collisions are not diagnosed |
| impl for a protocol type itself (`impl P for Q`) | protocols are not concrete types; refused |
| impl for a structural type (`impl DataSource($T) for []T`) | legal — conformer identity is canonical type identity |
| impl bounded by a constraint (`impl Show for $T/Ord`) | not a supported form; the `for` target names a type constructor |
| protocol-typed protocol member (`m :: (self: *Self, v: View)`) | ordinary — the parameter erases per `View`'s kind at the call |
| bare `Self` later parameter | erased: excluded. tagged: dispatchable — caller passes a `P`; the arm tag-checks (checked runtime failure on mismatch) |
| `Self` at depth in parameter or return (`[]Self`, `?Self`, `Box(Self)`) | excluded from dynamic dispatch on every kind; concrete/bound calls fine |
| bare `-> Self` through a tagged value | call-site-inlined switch; caller-frame temp per call + warn-note (§6.4), no fixit |
| rvalue at `*P` (erased) | compile error — nothing durable to borrow |
| rvalue at `P` (tagged), non-return position | frame-scoped temp, borrow — the `any`-box placement rule |
| rvalue at `P` (tagged), `return` position | compile error — nothing durable to borrow beyond the frame |
| returning a tagged borrow of a callee local | legal, unchecked, dangles — the slice-of-local doctrine |
| rvalue at `P` (`#identity`) | compile error — identity objects need a name |
| `free` on: view / identity / tagged / constraint-typed anything | compile error in each case (distinct wordings; constraint has no values at all) |
| `p.(ProtocolRaw)` | field-wise build per layout; tagged inserts one table load |
| `p.(Q)`, different protocol | direct re-erasure conversion (§7.4); temperaments apply; result ownership per `Q`'s kind |
| `s.(P)`, operand already `P` | erased value/own: independent owning copy of the receiver. tagged: identity coercion |
| `any` holding a protocol value | never arises from boxing a protocol value (that boxes the receiver); `xx *s` boxes a `*Show` — a concrete composite type with its own tag |
| `av.(P)` — protocol target on `any` receiver | compile error, every kind with values; constraint refuses as constraint |
| `==` on protocol values / protocol map keys | compile error, every kind |
| `?P` | null ctx = absent, all value kinds; tag/vtable words meaningless while null |
| `*P` where `P` is tagged | ordinary pointer to a 16-byte value; `pv.method()` auto-derefs the handle and dispatches; no implicit view-building exists (tagged values are already borrows — pass `P` itself) |
| tagged value in a struct copied by value | the handle copies; both copies reference one object (borrow semantics, like copying a `*T` field) |
| generic type argument `List(P)` | erased/tagged: legal, element = the protocol value layout. constraint: refused at the instantiation site |
| protocol as a protocol-instantiation argument (`Series(View)`) | legal — a type argument like any other; conformer sets keyed accordingly |
| value parameters in a protocol head (`protocol(N: u32) tagged`) | as generic structs; canonicalized by folded value equality |
| type switch arm naming a non-conformer (tagged subject) | warned dead; never matches |
| erasure inside `#run` / comptime execution | compile error (§7.9); constraint machinery fully available |
| conformer method name colliding with an existing member of the type | exact protocol signature: the existing method satisfies conformance (impl may omit; providing it duplicates). anything else (field, different signature): compile error at the impl |
| default method calling an excluded method | legal — defaults compile per conformer against concrete `Self` (§2); exclusion binds only calls through erased values |

## Appendix: rationale notes

- **Why the tagged value is a borrow, not an inline payload.** An
  inline existential sized to the largest conformer has no finite
  solution once any conformer contains the protocol type
  (`size(P) ≥ tag + size(C) ≥ tag + k + size(P)`), and recursive
  containment is the normal shape of tree-building conformers. The
  handle is the indirection; referent placement belongs to the
  owner.
- **Why the tag is unobservable.** It renumbers whenever any impl is
  added anywhere in the program; exposing it would mint an unstable
  ABI.
- **Why `constraint` is the default.** The zero-cost kind sits in
  the unmarked position; dynamic dispatch is a property a program
  asks for by name.
- **Why dispatchability differs by kind — and only at bare `Self`.**
  Vtable slots must be typable with `Self` unknown; a tag switch
  knows `Self` per arm, which pays for exactly the direct positions
  (a `Self` argument can arrive as a checked `P`, a `Self` result
  can leave as a fresh borrow). Composites of `Self` are excluded
  everywhere because no caller-side type exists for them — `[]P`
  and `[]Buffer(f32)` are different layouts, and inventing
  per-element coercions would smuggle allocation and failure into a
  call boundary.
- **Why defaults compile per conformer.** One shared erased body
  would silently forbid defaults from calling excluded methods and
  split method semantics by call path; per-conformer compilation
  makes a default indistinguishable from a hand-written impl
  method, at the cost the impl-registration model already pays.
- **Why coherence differs by kind.** sx has no orphan rule —
  conformance is fully retroactive — so global coherence for every
  kind would make two independent libraries that both conform the
  same pair permanently un-linkable into one program. Import-scoped
  visibility is the composability mechanism in place of an orphan
  rule: an erased value carries its dispatch info, chosen at the
  erasure site, so "which impl" is answerable site-locally and
  conflicts matter only where both are visible. A tagged value
  carries only `{ctx, tag}` and dispatches through ONE shared
  switch per instantiation for the whole program — there is no site
  left to consult, so the arm per conformer must be unique and
  coherence is necessarily global. Consequence, stated plainly:
  respelling a protocol from an erased kind to `tagged` can turn a
  program with visibility-disjoint duplicate impls into a coherence
  error — the kind decides which programs are well-formed, not only
  what they cost.
