# Protocols

A protocol names a set of method signatures. A type conforms by
providing those methods in an `impl` block; the protocol then serves
as a generic constraint, and — depending on its **kind** — as a
runtime value with dynamic dispatch.

```
protocol-decl := Name '::' 'protocol' [ '(' params ')' ] [ kind ] [ attrs ] '{' body '}'
kind          := 'constraint' | 'vtable' | 'inline'                 (absent ⇒ constraint)
attrs         := '#identity'*                                       (erased kinds)
```

Two of the kind words — `constraint` and `vtable` — are
contextual: ordinary identifiers everywhere else, read as kinds
only in this position. `inline` is the language's existing keyword,
serving here as a kind. Exactly one kind may appear. Each attribute
may appear at most once.

## 1. The kind ladder

| kind | runtime values | dispatch | membership known | ownership |
|---|---|---|---|---|
| `constraint` (default) | none | monomorphized per use site | per call site | — |
| `vtable` | erased, 3 words | vtable pointer | open world | value/own or `#identity` |
| `inline` | erased, 2 + N words | fn-ptrs in the value | open world | value/own or `#identity` |

The ladder is ordered by cost. The default is the kind that emits
nothing; a program opts *into* paying for dynamic dispatch by
naming an erased kind. Every kind supports the full
constraint-position vocabulary (`$T/P` bounds, UFCS fall-through,
default methods); the kinds differ only in what a protocol-typed
**value** is and costs.

```sx
Into      :: protocol(Target: Type) constraint {
    convert :: (self: *Self) -> Target;
}
Show      :: protocol vtable   { fmt :: (self: *Self) -> string; }
Hasher    :: protocol inline {                 // few methods, call-heavy
    put :: (self: *Self, bytes: []u8);
    sum :: (self: *Self) -> u64;
}
Allocator :: protocol inline #identity {        // unique stateful conformers
    alloc_bytes   :: (self: *Self, size: i64) -> *void;
    dealloc_bytes :: (self: *Self, ptr: *void);
}
View      :: protocol vtable {
    size_that_fits :: (self: *Self, proposal: ProposedSize) -> Size;
    layout         :: (self: *Self, bounds: Frame);
    render         :: (self: *Self, ctx: *RenderContext, frame: Frame);
}
Series    :: protocol(T: Type) vtable {
    count :: (self: *Self) -> i64;
    at    :: (self: *Self, i: i64) -> T;
}
```

The examples throughout describe one notional program built from
the protocols above; every snippet restates the declarations it
touches, so each reads in place.

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
`?Self`, `[]Self`, `Buffer(Self)`); what that does to dispatch is
§5.6.

**Keyword member names.** Every reserved word except `inline` is a
legal *bare* method name — including the keyword-classified type
names (`f32`, `f64`); `inline` alone is spellable only in backtick
form (`` `inline ``).

**Default methods.** A method with a body is a default; impls may
omit it (or override it by providing their own). Default bodies are
compiled **per conformer**, against the concrete `Self` — for every
kind. A call `self.method(…)` inside a default body therefore
resolves statically against the conformer, which means a default may
freely call methods that are excluded from erased dispatch (§5.6):
exclusion constrains call sites *through erased values*, and inside
a default the receiver is concrete. Dynamic dispatch happens at the
outer call site only — the vtable slot for a
defaulted method points at that conformer's compiled instance.

**Parameterized protocols.** The head may declare type and value
parameters, exactly as generic structs do (`protocol(T: Type) …`,
`protocol(N: u32) …`). Parameters are in scope throughout the body.
A parameterized protocol is a *family*; each canonical argument
tuple names one protocol. Canonicalization resolves type
aliases and folds value arguments to comparable constants.

## 3. Conformance — `impl`

```sx
Point   :: struct { x, y: f64; }
Sine    :: struct { freq: f32; }
Counter :: struct { n: i64; }
Buffer  :: struct($T: Type) { items: []T; }

impl Show for Point {
    fmt :: (self: *Point) -> string { … }
}

impl Series(f32) for Sine {                // conformance to one instantiation
    count :: (self: *Sine) -> i64 { 64 }
    at    :: (self: *Sine, i: i64) -> f32 { self.freq * xx i }
}
impl Series(i64) for Counter {
    count :: (self: *Counter) -> i64 { self.n }
    at    :: (self: *Counter, i: i64) -> i64 { i }
}
impl Series($T) for Buffer(T) {            // blanket: one impl, a family of conformances
    count :: (self: *Buffer(T)) -> i64 { self.items.len }
    at    :: (self: *Buffer(T), i: i64) -> T { self.items[i] }
}
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
- **Coherence.** Duplicate `(protocol-instantiation, concrete
  type)` pairs follow import-scoped visibility: a duplicate within
  one compilation unit is an error at the impls; duplicates across
  modules are diagnosed at a use site that sees both. Colliding
  blankets are not diagnosed (nothing exists to collide at).

**Comptime-expanded conformance.** `impl` blocks participate in the
ordinary top-level comptime declaration forms. An `inline if` gates
conformance on comptime facts — the dead branch's impl never
exists and emits nothing:

```sx
inline if OS == .ios {
    impl View for CameraButton { … }
}
```

A top-level `inline for` unrolls one declaration group per comptime
element — enumerated conformance over a curated list, with the
reflection builtins supplying field-wise bodies. The iterable here
is a comptime array of types; the capture binds each element as a
comptime `Type` constant, usable in type position (the impl head,
the receiver spelling) exactly like a `$T: Type` binding:

```sx
Point  :: struct { x, y: f64; }
Rect   :: struct { origin: Point; w, h: f64; }
Color  :: struct { r, g, b, a: f32; }
Widget :: struct { value: i64; }

Buf :: struct { … }
write_field :: (out: *Buf, name: string, v: any) { … }

Serialize :: protocol vtable {
    write :: (self: *Self, out: *Buf);
}

SERIALIZABLE :: .[Point, Rect, Color, Widget];

inline for T in SERIALIZABLE {
    impl Serialize for T {
        write :: (self: *T, out: *Buf) {
            inline for i in 0..struct_field_count(T) {
                write_field(out, struct_field_name(T, i),
                            struct_field_value(self.*, i));
            }
        }
    }
}
```

Each unrolled iteration is an ordinary impl with a concrete `T`:
membership, coherence (two iterations landing on one `(P, T)` pair
are the ordinary duplicate error, naming the unrolled sites), and
every downstream rule apply to the expanded program unchanged. The
curated-list form is the supported spelling for "one body, a
deliberate set of types" — the bound-blanket (`impl Show for
$T/Ord`) is refused precisely because a list keeps the set
intentional.

**Expansion is monotone and deterministic.** Expansion only *adds*
conformances — nothing retracts. Expansion-driving comptime may
consult per-pair conformance facts (a probe, `has_impl`, a
conversion), under the scheduling discipline of §6.9: positive
facts answer immediately, negative answers wait for the impls that
could answer them to be final, and an expansion that depends
negatively on a fact it can still feed is the expansion-deadlock
error. No reflection enumerates a protocol's conformers, at comptime
or runtime — conformances are unobservable as collections.

## 4. Constraint protocols (the default kind)

A constraint protocol has **no runtime values**. It exists to bound
generics and to serve as a compiler-recognized customization point.

```sx
Ord :: protocol {                             // constraint — the default kind
    less :: (self: *Self, other: Self) -> bool;
}
impl Ord for i64 {
    less :: (self: *i64, other: i64) -> bool { self.* < other }
}

largest :: (xs: []$T/Ord) -> T { … }          // bound: any T conforming to Ord

// Into, restated from §1:
Into :: protocol(Target: Type) constraint {
    convert :: (self: *Self) -> Target;
}
// `xx val : T` falls through the built-in conversion ladder to an
// `impl Into(T) for Source` lookup; the compiler monomorphizes
// `convert` for the (Source, T) pair and emits a direct call.
```

**Erasure refuses.** Every erasure spelling — implicit at a
protocol-typed position, `xx`, postfix `.(P)` — is a compile error:

```sx
o : Ord = 5;      // i64 conforms — but Ord has no values to make
```
```
error: cannot make a value of 'Ord' — a constraint protocol has no
       runtime values; use the concrete type, or a generic bound
       ('$T/Ord') where polymorphism is needed
```

The diagnostic guides the use site only: the ordinary fixes are
staying concrete or binding through a constraint. It never suggests
respelling the protocol's kind — whether `Ord` should have runtime
values is its author's design decision, made at the declaration; a
use site cannot judge it. The same refusal, with the same guidance,
applies wherever a constraint protocol is used as a *storable*
type: a field, array element, or generic type argument of a
constraint-protocol type diagnoses at the declaration or
instantiation site.

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
- `protocol_kind(P) == .constraint` (§7) lets a generic body reject
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
Choose `inline` for few-method, call-heavy protocols (hashers,
writers); `vtable` keeps many-method values small.

### 5.2 Ownership classes

Every erased protocol belongs to one of two classes:

- **value/own** (unmarked): erasure creates manually managed,
  allocation-backed storage — a heap copy of the receiver, made only
  under the explicit postfix spelling `.(P, alloc)`, through the named
  allocator (`context.allocator` is spelled out to use the ambient
  one). No other spelling allocates: an implicit erasure is the demand
  diagnostic for every operand shape, and the one-argument `.(P)` on
  an owning shape refuses — an owning erasure names its allocator. The handles over that storage may ALIAS it (§5.3a);
  "owning erasure" names the operation and the storage's discipline,
  not a per-handle claim. `*P` is the borrowed view.
- **`#identity`**: for protocols whose runtime object *is* unique
  state (an allocator, an io runtime). Values only ever borrow, in
  every spelling; there is nothing to free.

### 5.3 Erasure spellings (value/own)

| spelling | receiver | result |
|---|---|---|
| `expr.(P, alloc)` | concrete lvalue or rvalue | **owns** — independent heap copy |
| `expr.(P, alloc)` | `*Concrete` | **owns** — snapshot of the pointee |
| `expr.(P, alloc)` | `P` (same protocol, value) | **owns** — clone: independent copy of the receiver (`rt_size_of(type_id)` bytes; vtable/fn words reused) |
| `expr.(P, alloc)` | `*P` (same protocol) | **owns** — promotion: fresh ctx copy, vtable/fn words reused |
| `expr.(P)` | any owning shape | **compile error** — an owning erasure names its allocator |
| `expr.(P)` | `P` (same protocol, value) | no-op — an ordinary handle copy, aliasing |
| implicit / `xx` | any shape | **compile error** — the demand diagnostic |
| any lvalue / pointer | at a `*P` target | **view** — borrows storage (§5.5) |

Re-erasure to a *different* protocol (`p.(Q)`) is a conversion in
its own right — see §6.4.

### 5.3a Copies alias; conversion allocates

Only a CONVERSION allocates: the concrete-to-`P` rows of §5.3 and
the re-erasures of §6.4. An ordinary same-protocol copy — `q := p`,
argument passing, returning, struct/array/tuple copying, storing
into and reading out of containers, a generic body copying a `P` —
copies the handle itself and nothing else: no allocation, no second
erasure. Every handle so copied aliases the SAME backing allocation.
`p.(P)` (the same-protocol row of §5.3) is the explicit clone: a new
backing allocation holding an independent shallow byte-copy of the
concrete receiver.

There are no compiler-enforced moves: protocol values are ordinarily
copyable handles. A program may transfer responsibility by copying a
handle and ceasing to use the source — a convention, not a checked
property.

The free discipline follows from aliasing: each owning backing
allocation is freed exactly ONCE, through ANY one of its aliases,
and the free invalidates every alias to that backing. Double-free,
use-after-free, and allocator mismatch are unchecked errors under
the ordinary pointer/manual-memory doctrine. The handle carries no
allocator word and the allocation no header — pairing the free with
the right allocator is the program's job (§5.4).

```sx
p := circle.(Show);  // allocation A: concrete-to-Show erasure
q := p;              // aliases A; no allocation
r := p.(Show);       // allocation B: explicit shallow clone

free(q);             // releases A; p and q are now invalid
free(r);             // releases B
```

Borrowed representations sit outside this discipline: `#identity`
values and `*P` views copy as borrowed handles over
storage they never own (§5.2, §5.5) — there is nothing to
free, and `free` refuses them (§5.4).

The demand diagnostic exists because an implicit erasure would
allocate silently: a copy of named storage the reader believes is
shared, an alias of a pointee, or a fresh backing allocation for an
rvalue. Allocation happens only where a spelling names it:

```sx
Widget  :: struct { value: i64; }
Sizable :: protocol vtable { size :: (self: *Self) -> i64; }
impl Sizable for Widget {
    size :: (self: *Widget) -> i64 { self.value }
}

w := Widget{ value = 7 };
s : Sizable = w;      // error: 'w' is an lvalue and 'Sizable' values own
                      // their storage — write the copy ('w.(Sizable)')
                      // or pass a view ('*Sizable') for transient use
s := w.(Sizable);     // the explicit owning copy — independent of w
```

**Shallow-copy caveat.** Owning erasure copies the receiver's BYTES.
Interior pointers (slices, strings, pointers) are copied as
pointers; the copy and the source share their referents. Types whose
deep state must not be shared belong behind `#identity` or a view.

**`#identity` erasure** borrows in every spelling — decl targets,
call arguments, struct-literal fields alike:

```sx
Rng :: protocol inline #identity { next :: (self: *Self) -> u64; }
Xorshift :: struct { state: u64; }
impl Rng for Xorshift {
    next :: (self: *Xorshift) -> u64 {
        self.state = self.state ^ (self.state << 13);
        self.state = self.state ^ (self.state >> 7);
        self.state = self.state ^ (self.state << 17);
        self.state
    }
}

rng := Xorshift{ state = 42 };
a : Rng = rng;                      // borrow — no demand error, no copy
b := rng.(Rng);                     // borrow, same value shape
c : Rng = Xorshift{ state = 7 };   // error: identity objects need a
                                    // name; bind it first
```

The two-argument form `.(Rng, alloc)` refuses on an identity target
— a borrow allocates nothing.

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
- `free` on an `#identity` value or a `*P` view is
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
Widget  :: struct { value: i64; }
Sizable :: protocol vtable { size :: (self: *Self) -> i64; }
impl Sizable for Widget {
    size :: (self: *Widget) -> i64 { self.value }
}

measure :: (v: *Sizable) -> i64 { v.size() }
w := Widget{ value = 7 };
measure(w);                            // view in place — aliases w
pv : *Sizable = w;                     // view over w, valid to end of frame
pv : *Sizable = Widget{ value = 1 };  // error: rvalue — nothing durable to borrow
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
call does NOT fall through to UFCS (§6.8) — members win, then the
member's unavailability diagnoses:

```sx
Point :: struct { x, y: f64; }
Eq    :: protocol vtable { eq :: (self: *Self, other: Self) -> bool; }
impl Eq for Point {
    eq :: (self: *Point, other: Point) -> bool {
        self.x == other.x and self.y == other.y
    }
}

p1 := Point{ x = 1.0, y = 2.0 };
p2 := Point{ x = 3.0, y = 2.0 };
e := p1.(Eq);
e.eq(p2);            // error: 'eq' is unavailable on an erased 'Eq' value —
                     // its parameter 'other: Self' has no expressible type here
are_equal :: (a: $T/Eq, b: T) -> bool { a.eq(b) }    // fine
are_equal(p1, p2);   // Self is the bound Point
```

A protocol always erases, whatever its methods: a marker protocol
and an all-excluded protocol both produce legal values with an empty
vtable — `type_of`, downcast, type switch, `ProtocolRaw`, and `free`
work without any dispatchable method. Slots index the dispatchable
methods only, in declaration order. Non-receiver parameters keep
their declared concrete types; only the receiver erases.

## 6. Cross-kind semantics

### 6.1 RTTI: `type_of`, downcast, type switch

Every protocol value answers `type_of` with its receiver's concrete
type id, read from slot 1. The downcast `p.(T)` and the type switch
on a protocol subject follow the same source: a runtime type_id
compare. There is no implicit opening of a protocol value; the type
switch is the opening construct.

### 6.2 `ProtocolRaw`

```sx
ProtocolRaw :: struct { ctx: *void; type_id: Type; }
```

`p.(ProtocolRaw)` (and `xx p` at a `ProtocolRaw` target) builds the
pair **field-wise per the operand's layout — never a bit
reinterpret**: a prefix copy on both erased layouts. Reflection
consumers stay kind-agnostic.

### 6.3 The `any` bridge

Boxing a protocol value into `any` yields a view of the **concrete
receiver**: `{data = ctx, type_id = concrete}` — the value's byte
prefix. The reverse
direction is refused: a postfix assertion with a *protocol* target
on an `any` receiver is a compile error (an `any`'s tag is always a
concrete type; the assertion could only ever fail) — assert the
concrete type or use a type switch.

### 6.4 Re-erasure — `p.(Q)` between protocols

Re-erasure to a different protocol is a direct conversion (a
recovery target of the postfix engine), never a manual
downcast-then-erase — the concrete type behind `p` is not statically
known, so only the compiler can perform it. Semantics:

- **Conformance check**: whether `p`'s concrete type implements `Q`
  is a runtime fact; the assertion temperaments apply (unconsumed
  `p.(Q)` panics, `try p.(Q)` is graceful, `p.(?Q)` is soft). The
  check and the result's vtable/fn-ptr words come from a link-time
  `type_id → Q-dispatch` table holding exactly the pairs with a
  **program-unique** impl. A pair with visibility-disjoint duplicate
  impls (§3) is absent from the table: the conversion fails as
  non-conforming — the site-local visibility that arbitrates
  ordinary erasure does not exist at a dynamic conversion, and no
  other arbiter would be sound.
- **`#identity` `Q` refuses at compile time**: identity conformers
  are named objects, and a dynamic conversion cannot prove the
  referent is one.
- **Result ownership follows `Q`'s class**: value/own `Q` → an
  owning copy of the receiver (`rt_size_of` via the concrete type
  id) through `context.allocator`; the two-argument `p.(Q, alloc)`
  routes it explicitly and pairs with `free(q, alloc)`.
- `Q == P` degenerates to the same-protocol rows of §5.3.

### 6.5 Equality

`==`/`!=` are not defined on protocol values of any kind (compile
error, as on `any`): two handles may reference one object, equal
bytes may be distinct objects. Compare `type_of`, downcast and
compare concretely, or define a protocol method. Map keys follow
from `==`: refused.

### 6.6 Protocol values in aggregates, generics, and the Context

Erased protocol types are ordinary storable types: struct fields,
array elements, returns, and **generic type arguments** —
`List(Show)` is a list of 3-word owning values, `List(Hasher)` a
list of 2 + N-word ones, and `size_of` answers per §5.1. A protocol
type may itself be an instantiation
argument of another protocol (`Series(View)`). Constraint protocols
are refused in every storable position (§4).

Context fields may be protocol-typed only at an `#identity`
protocol: context defaults are mandatory and
comptime-evaluable, the fold of a protocol-typed default is the
identity erasure of a named instance global — a borrow, never null
(null ctx is exclusively the `?P` absent sentinel) — and an owning
constant cannot exist before `main`, so a value/own protocol-typed
context field is refused at its declaration. Threads and fibers inherit the
context by snapshot; a snapshot copies handles, not referents — a
borrow outliving its referent is the standard hazard.

### 6.7 Packs and variadics

- `..xs: []P` (runtime variadic, erased element): each trailing
  argument erases per its kind's rules and packs into a runtime
  `[N]P`; `xs[i].method()` dispatches dynamically.
- `..xs: P` (comptime heterogeneous pack): each element keeps its
  concrete type; calls monomorphize — all kinds, including
  `constraint`, participate.

### 6.8 UFCS

A protocol-typed receiver dispatches its own members first and falls
through to `ufcs` functions only for **non-members**
(`context.allocator.create(Session)` — `create` takes the protocol
value as its first parameter). A member excluded from dispatch is
still a member: the call diagnoses per §5.6 rather than falling
through. Constraint-bound receivers resolve at monomorphization.

### 6.9 Compile-time execution

Comptime protocol values are **symbolic**: the VM carries `{ctx,
concrete type}` — and, for the erased kinds, the **impl selected at
the erasure site** (`{ctx, concrete type, impl}`), since
visibility-disjoint duplicate impls (§3) make "the concrete type's
impl" ambiguous without it. Numeric tags and vtable addresses are
link-time artifacts that do not exist during compilation. Erasure
at comptime is legal for every value kind under each kind's own
rules; dispatch resolves directly against the carried impl — the VM
devirtualizes, exactly as constraint resolution does — including
through Context fields such as the ambient allocator.
`protocol_kind`, `is_identity`, and all monomorphized machinery
work unchanged.

Comptime execution is **per-evaluation**: each evaluation (a
driver, an ordinary `#run`) owns its VM, heap, and **VM-local
Context**; suspension parks and resumes *that* evaluation — its VM
state is never shared with or visible to another evaluation, so
scheduler order cannot leak through Context or heap state. The
Context's protocol-typed fields reference VM-owned instances, whose
mutations (an allocator's bookkeeping, an arena's cursor) are
execution-local and discarded when the evaluation completes —
comptime code cannot mutate globals: the VM reads globals into
VM-local copies and never writes back. A VM object **corresponds**
to a declared global by provenance: it is the object the VM created
to represent that global when first referenced (the context-default
fold included); correspondence survives borrows, not copies — a
struct copy is a new object and escapes through the temporary path.

**Scheduling.** Comptime entangled with conformance — the conditions
and iterables of top-level `inline if`/`inline for`, any `#run`
they transitively reference, and body-level comptime reached by
monomorphizing an impl — evaluates under one dataflow discipline:

- **Impl presence only grows**, so a *positive* fact — a probe
  answering true, a `has_impl` hit — is readable the moment it
  exists and can never be invalidated. A *negative* answer — a soft
  probe yielding null — is utterable only once the impls that could
  answer it are **final**: no unexpanded `inline if`/`inline for`
  branch can still contribute one. Contribution is judged
  syntactically and conservatively: an unexpanded body mentioning
  `impl P for …` contributes to `P`, and one holding an `#import`
  contributes the whole surface of the module it names — the impls,
  declaration names and `#context_extend`s that module authors,
  transitively through its own imports and branches — because
  selecting the branch is what brings them in.
- **Erased-target conversion facts depend on impl multiplicity**
  (the program-unique rule, §6.4), and uniqueness is not monotone —
  a later impl destroys it. An erased-target conversion therefore
  gates on finality of the target protocol's pairs in **both**
  polarities.
- **The declaration namespace follows the same rule**: a
  name-lookup hit is monotone-safe (declarations are never
  removed); a miss in code under this discipline suspends until the
  scope is final — no unexpanded branch can still declare the name.
- **The program Context is a single layout**, so an evaluation that
  reads it waits for that layout to settle: while any unexpanded
  branch could still declare a `#context_extend`, the field set is
  not final, and the evaluation suspends against Context-ready
  exactly as it suspends against an open conformer set.
  Contribution is judged syntactically, like an `impl`'s. Once
  nothing can contribute, the decided declaration space registers,
  the deterministic layout assembles, and the default context is
  built from the selected branches' defaults — an untaken branch
  contributes no field.
- An evaluation needing a not-yet-utterable answer **suspends** —
  its VM state parks as a bookmark against the facts it awaits
  (presence of a pair or name, finality of a set or scope) — and
  the scheduler proceeds; the bookmark resumes when a fact fires.
  Every instruction runs exactly once: nothing is speculative,
  nothing re-runs, no evaluation ever observes a fact that later
  changes.
- **Quiescence is the error**: if the scheduler stops with parked
  evaluations remaining — whether the wait runs through one
  expansion or several — the program is refused, naming every
  parked evaluation and the facts it awaits. The self-feeding
  expansion is the simplest instance; a parked state admitting more
  than one consistent outcome is genuinely ambiguous, and sx
  refuses rather than electing a fixpoint.

  ```sx
  GPA :: struct { … }
  Serialize :: protocol vtable { write :: (self: *Self, out: *Buf); }
  HAS :: #run { g := GPA{ … }; g.(?Serialize) != null };
  inline if !HAS { impl Serialize for GPA { … } }
  ```
  ```
  error: expansion deadlock — nothing can run: every compile-time
         unit still waiting needs a fact only another waiting unit
         could publish, so the expansion depends negatively on a set
         it feeds
  ```

- A suspended **hard** operation — a dispatch, an unconsumed
  conversion, an erasure — whose awaited fact never arrives
  diagnoses at finality with the ordinary error at the operation's
  site. A suspended **soft** probe answers null.

**The probe.** A soft protocol target on a *concrete* receiver —
`gpa.(?Serialize)` — answers conformance directly, no value
ceremony; `has_impl(P, T)` is the same probe spelled at type level,
under the same rules. What it answers is **site-local impl
visibility** — the same static fact that decides whether the site
could erase, and a different question from the dynamic re-erasure
check, which consults program-wide uniqueness (§6.4). Under the
discipline, a negative gates on declaration-space finality — impls
are declarations. A probe is not a value use: it arms the coherence
diagnostics of the instantiation it queries (§3) and reaches
nothing for emission.

**The phase law.** All comptime execution not under the discipline
runs **after the declaration space is final**, so every such `#run`
sees the same world and **cannot enlarge it**: an operation
requiring a conformance no impl provides is a compile error at the
operation's site rather than a fact the run publishes. Post-fixpoint
code may instantiate types freely for every non-protocol purpose.
Conformances remain unobservable as *collections* at every phase (no
enumeration reflection exists, §3); the granted facility is per-pair
facts — a probe, `has_impl`, a conversion — under the discipline
above.

**Escape.** A comptime result that carries a protocol value into
the runtime image resolves per the referent:

- a referent that *is* a declared global — a named instance, the
  object behind a context default — relocates `ctx` to that
  global's symbol: nothing is copied, mutability is preserved, and
  the global's runtime bytes are its declared initializer
  (comptime-era mutations were execution-local and vanish; two
  evaluations whose instances diverged both relocate to the one
  global, and neither state wins). An interior pointer *into* such
  an instance's VM state refuses to escape ("points into a global's
  compile-time state, which is discarded");
- a comptime **temporary** referent materializes as an anonymous
  image global in writable data, deduplicated by comptime object
  identity *within the evaluation* (cross-evaluation temporaries
  are distinct objects and never deduplicate) — two handles that
  shared one object share one global, so borrow semantics survive
  the escape. Escaped temporaries are literal-class static data:
  they belong to no allocator, and freeing one through any
  allocator is the ordinary mispairing hazard — an escaped
  structure carrying both an allocator handle and comptime-made
  allocations is self-inconsistent by construction, and the frees
  simply must not happen.
  Materialization is **type-directed** machinery this design
  requires: the referent's bytes are walked by its concrete
  layout; nested protocol handles recurse (their referents
  materialize and both of their words resolve), interior pointers
  recurse, function references resolve to their symbols; an escape
  whose carried value cannot be walked is refused;
- the value's dispatch words resolve at link, to the
  `(protocol, type, impl)` vtable of the impl carried from its
  erasure site;
- an **owning** erased value cannot escape — no runtime allocator
  owns a compile-time copy, so carrying one into the image is a
  compile error ("bind the concrete value; owning erasure happens
  at runtime");
- an escape erases through the impl its site selected.

## 7. Reflection

- `protocol_kind(P) -> {constraint, vtable, inline}` —
  compile-time only; folds in `inline if`.
- `is_identity(P)` — true for `#identity` protocols; false for
  every other type. Compile-time only.
- A runtime `Type` value always tags a concrete type, never a bare
  protocol type. Composites *containing* protocol types (`*Show`,
  `[]View`) are concrete types and get tags like any other
  composite.

## 8. Internals walkthrough

**Symbols.** Vtables: one global constant per
`(protocol-instantiation, concrete type, impl)`, every identity
spelled in full — `Conv(f32)`/`Conv(i64)` never share a vtable
symbol (their slot types differ), and neither do two
visibility-disjoint impls of one pair (their bodies differ; the
impl's declaring module is part of the symbol). Canonical identity
is structural on the argument tuple after alias resolution — no
display-name truncation participates in any symbol or cache key.

**Emission points.** Vtables and inline fn-ptr sets emit on first
erasure of a pair. Marker/empty vtables are emitted like any other
(a protocol always erases on the erased kinds).

Coherence (§3) is diagnosed before codegen, so every conformance
diagnostic is an ordinary compile error, never a link error.

**Dispatch call sequences** (backend pseudocode, not sx syntax):

```
vtable:  load p.vtable → load slot k → indirect call(ctx, args…)
inline:  load p.fn_k               → indirect call(ctx, args…)
```

**`free`.** One function, compile-time kind-dispatched by an inline
type match: a protocol arm (ctx via `ProtocolRaw`, one body for both
erased layouts, gated on the ownership class — `#identity` refuses),
a closure arm, a slice arm; every other argument kind is a compile
error.

**The standard `Allocator` is stdlib-owned.** Its declaration —
kind, attributes, method set — belongs to `std/core.sx`, not to the
compiler. The compiler-driven heap paths (an owning erasure's copy,
the implicit-context allocation, the Obj-C `+alloc`/`-dealloc` IMPs)
find the allocator by NAME on the assembled `Context` and go through
the ordinary protocol dispatch for whatever kind they find there, so
respelling `Allocator` with a different kind is a library edit that
requires no compiler change.


## 9. Edge-case catalog

| case | disposition |
|---|---|
| marker protocol (empty body) | constraint: free partition. erased: erases with empty vtable; RTTI/free work |
| all methods `Self`-excluded (erased kind) | erases fine; every method call through the value diagnoses; concrete/bound calls fine |
| duplicate impl `(P-instantiation, T)` | import-scoped (§3) |
| impl for a protocol type itself (`impl P for Q`) | protocols are not concrete types; refused |
| impl for a structural type (`impl Series($T) for []T`) | legal — conformer identity is canonical type identity |
| impl bounded by a constraint (`impl Show for $T/Ord`) | not a supported form; the `for` target names a type constructor |
| protocol-typed protocol member (`m :: (self: *Self, v: View)`) | ordinary — the parameter erases per `View`'s kind at the call |
| bare `Self` later parameter | excluded from erased dispatch |
| `Self` at depth in parameter or return (`[]Self`, `?Self`, `Buffer(Self)`) | excluded from dynamic dispatch on every kind; concrete/bound calls fine |
| rvalue at `*P` | compile error — nothing durable to borrow |
| rvalue at `P` (`#identity`) | compile error — identity objects need a name |
| `free` on: view / identity / constraint-typed anything | compile error in each case (distinct wordings; constraint has no values at all) |
| `p.(ProtocolRaw)` | field-wise build per layout |
| `p.(Q)`, different protocol | direct re-erasure conversion (§6.4); temperaments apply; result ownership per `Q`'s class; `#identity` targets refuse at compile time; the unique-impl table resolves the check — a duplicated pair converts as non-conforming |
| `s.(P)`, operand already `P` | value/own: independent owning copy of the receiver |
| `any` holding a protocol value | never arises from boxing a protocol value (that boxes the receiver); `xx *s` boxes a `*Show` — a concrete composite type with its own tag |
| `av.(P)` — protocol target on `any` receiver | compile error, every kind with values; constraint refuses as constraint |
| `==` on protocol values / protocol map keys | compile error, every kind |
| `?P` | null ctx = absent, all value kinds; vtable words meaningless while null |
| generic type argument `List(P)` | erased: legal, element = the protocol value layout. constraint: refused at the instantiation site |
| protocol as a protocol-instantiation argument (`Series(View)`) | legal — a type argument like any other |
| value parameters in a protocol head (`protocol(N: u32) vtable`) | as generic structs; canonicalized by folded value equality |
| protocol values inside `#run` / comptime execution | legal, symbolic — `{ctx, concrete type, impl}`, VM-devirtualized dispatch; under the §6.9 discipline, negative probes, erased-target conversions (both polarities), and name-lookup misses suspend until finality |
| scheduler quiesces with parked evaluations (self-feeding or mutual) | compile error — expansion deadlock, every parked evaluation and its awaited facts named (§6.9) |
| comptime protocol value escaping into the image | declared-global referents relocate in place (mutable); comptime temporaries become writable anonymous image globals, deduped by object identity, nested handles recursing; OWNING erased values cannot escape — compile error (§6.9) |
| type declared inside a top-level `inline for` body | flattens to module scope — duplicate across iterations diagnoses; parameterize the type (`Vec :: struct($N: u32)`) instead of re-declaring per iteration |
| type annotation on an `inline for` type-list cursor | compile error — the cursor binds a type, not a value of one |
| `inline for` conformance-list elements | concrete types only (a `Type` never tags a protocol, §7); `#run`-computed lists are legal but expansion-driving (§6.9 scheduling); duplicate elements and nested unrolls diagnose with cursor provenance ("T = Point, i = 1") |
| conformer method name colliding with an existing member of the type | exact protocol signature: the existing method satisfies conformance (impl may omit; providing it duplicates). anything else (field, different signature): compile error at the impl |
| default method calling an excluded method | legal — defaults compile per conformer against concrete `Self` (§2); exclusion binds only calls through erased values |

## Appendix: rationale notes

- **Why the erased value is a handle, not an inline payload.** An
  inline existential sized to the largest conformer has no finite
  solution once any conformer contains the protocol type
  (`size(P) ≥ hdr + size(C) ≥ hdr + k + size(P)`), and recursive
  containment is the normal shape of tree-building conformers. The
  handle is the indirection; referent placement belongs to the
  owner.
- **Why `constraint` is the default.** The zero-cost kind sits in
  the unmarked position; dynamic dispatch is a property a program
  asks for by name.
- **Why `Self` beyond the receiver is undispatchable.** Vtable
  slots must be typable with `Self` unknown, and no caller-side type
  exists for a `Self` argument, result, or composite — `[]P` and
  `[]Buffer(f32)` are different layouts, and inventing per-element
  coercions would smuggle allocation and failure into a call
  boundary.
- **Why defaults compile per conformer.** One shared erased body
  would silently forbid defaults from calling excluded methods and
  split method semantics by call path; per-conformer compilation
  makes a default indistinguishable from a hand-written impl
  method, at the cost the impl-registration model already pays.
- **Why coherence is import-scoped.** sx has no orphan rule —
  conformance is fully retroactive — so global coherence would make
  two independent libraries that both conform the same pair
  permanently un-linkable into one program. Import-scoped
  visibility is the composability mechanism in place of an orphan
  rule: an erased value carries its dispatch info, chosen at the
  erasure site, so "which impl" is answerable site-locally and
  conflicts matter only where both are visible.
- **Why suspension, not a refusal wall or speculation.** A wall
  (protocol values banned from expansion-driving comptime) is sound
  but forbids meaningful programs — "derive unless a hand-written
  impl exists" is a per-pair membership question with a legitimate
  answer. Speculation (run against current sets, invalidate,
  re-run) answers it but pays everywhere: re-executed VM waves,
  transactional retraction of speculative registrations, deferred
  diagnostics, and a "did not converge" failure class. Suspension
  runs every instruction exactly once against facts that never
  change afterward: positive facts are safe immediately because
  impl presence only grows; negative facts wait for finality; the only
  new error is the wait cycle — precisely the program whose meaning
  is genuinely circular. Cost is localized to one subsystem (the
  VM's ability to park and resume an evaluation).
