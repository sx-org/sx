# Protocols

A protocol names a set of method signatures. A type conforms by
providing those methods in an `impl` block; the protocol then serves
as a generic constraint, and — depending on its **kind** — as a
runtime value with dynamic dispatch.

```
protocol-decl := Name '::' 'protocol' [ '(' params ')' ] [ kind ] [ attrs ] '{' body '}'
kind          := 'constraint' | 'vtable' | 'inline' | 'tagged'     (absent ⇒ constraint)
attrs         := ( '#identity' | '#expand' )*                       (order free)
                  '#identity' — erased and tagged kinds
                  '#expand'   — tagged kind only (§6.3a)
```

Three of the kind words — `constraint`, `vtable`, `tagged` — are
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
| `tagged` | tagged borrow, 2 words | generated switch | whole program, per instantiation | always a borrow; `#identity` adds the naming discipline |

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
Hasher    :: protocol inline {                 // few methods, call-heavy
    put :: (self: *Self, bytes: []u8);
    sum :: (self: *Self) -> u64;
}
Allocator :: protocol inline #identity {        // unique stateful conformers
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

The examples throughout describe one notional program built from
the five protocols above; every snippet restates the declarations
it touches, so each reads in place.

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
`?Self`, `[]Self`, `Buffer(Self)`); what that does to dispatch depends
on the kind (§5.6, §6.4).

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

**Comptime-expanded conformance.** `impl` blocks participate in the
ordinary top-level comptime declaration forms. An `inline if` gates
conformance on comptime facts — the dead branch's impl never
exists, joins no set, and emits nothing:

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

Serialize :: protocol tagged {
    write :: (self: *Self, out: *Buf);
}

SERIALIZABLE :: .[Point, Rect, Color, Widget];

inline for SERIALIZABLE (T) {
    impl Serialize for T {
        write :: (self: *T, out: *Buf) {
            inline for 0..struct_field_count(T) (i) {
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
$T/Ord`, §6.5) is refused precisely because a list keeps the set
intentional.

**Expansion is monotone and deterministic.** Expansion only *adds*
conformances — nothing retracts. Expansion-driving comptime may
consult per-pair membership facts (a probe, `has_impl`, a dispatch,
a conversion), under the scheduling discipline of §7.9: positive
facts answer immediately, negative answers wait for the queried set
to be final, and an expansion that depends negatively on a set it
can still feed is the expansion-deadlock error. No reflection
enumerates a protocol's conformers, at comptime or runtime — sets
are unobservable as collections. The conformer fixpoint (§6.5) runs
on the fully expanded program; tags are assigned at link, after
every expansion is complete.

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
Choose `inline` for few-method, call-heavy protocols (hashers,
writers); `vtable` keeps many-method values small.

### 5.2 Ownership classes

Every erased protocol belongs to one of two classes:

- **value/own** (unmarked): erasure creates manually managed,
  allocation-backed storage — a heap copy of the receiver, made at
  erasure through `context.allocator`. The handles over that storage
  may ALIAS it (§5.3a); "owning erasure" names the operation and the
  storage's discipline, not a per-handle claim. `*P` is the borrowed
  view.
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

### 5.3a Copies alias; conversion allocates

Only a CONVERSION allocates: the concrete-to-`P` rows of §5.3 and
the re-erasures of §7.4. An ordinary same-protocol copy — `q := p`,
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
values, tagged values, and `*P` views copy as borrowed handles over
storage they never own (§5.2, §5.5, §6.2) — there is nothing to
free, and `free` refuses them (§5.4).

The demand diagnostic exists because an implicit erasure of named
storage would silently heap-copy (or silently alias) something the
reader believes is shared:

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
call does NOT fall through to UFCS (§7.8) — members win, then the
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
  directly at `return` — anywhere within the returned expression,
  aggregate literals included — is a compile error ("nothing
  durable to borrow beyond this frame; bind it, or place it in
  storage the caller owns"). Returning a tagged value whose referent is a
  callee LOCAL is legal and unchecked — the same doctrine as
  returning a slice of a local array: the borrow dangles, and the
  caller must not use it. Sound component patterns return values
  whose referents outlive the frame (arena placements, globals,
  fields).

There is no owning form, hence: no demand diagnostic (nothing
hidden happens), no `free` (compile error, same gate class as
`#identity` erased values), and no `.(P, alloc)` (refused). The
postfix `v.(P)` at a tagged target is legal and identical to the
implicit coercion — never required.

**`#identity` on tagged.** Borrow semantics and the `free` refusal
are structural to the kind, so the attribute contributes exactly
the **naming discipline**: rvalue erasure refuses ("identity
objects need a name; bind it first") instead of materializing a
frame temp. Declare it for protocols whose conformers are unique
stateful objects — an allocator whose state lives in a frame temp,
handing out allocations that outlive the frame, is exactly the
accident the discipline refuses. `Allocator` appears below at its
TAGGED representation, because this is the section about tagged;
std ships the `inline` one (§1), and the naming discipline the
attribute contributes is identical on either — only the value layout
and the dispatch differ:

```sx
Allocator :: protocol tagged #identity {       // the tagged variant
    alloc_bytes   :: (self: *Self, size: i64) -> *void;
    dealloc_bytes :: (self: *Self, ptr: *void);
}
GPA :: struct { … }
impl Allocator for GPA { … }

ArenaChunk :: struct { … }
Arena :: struct {
    first: *ArenaChunk;
    end_index: i64;
    parent: Allocator;
    init :: (parent_alloc: Allocator, size: i64) -> Arena { … }
}
impl Allocator for Arena { … }

gpa := GPA{ … };
arena := Arena.init(gpa, 4096);
push .{ allocator = arena } { … }              // borrow of a named arena
push .{ allocator = Arena.init(gpa, 4096) } { … }
// error: identity objects need a name; bind it first
```

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
; Series(T) declares  at :: (self: *Self, i: i64) -> T   (§1);
; set(Series(f32)) = {Buffer(f32), Sine, Scaled(f32)}    (§3, §6.9)

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
materializations land in the caller's frame. That expansion is
set-dependent codegen — §9's fingerprint-keyed caching consequence
applies to the containing function.

### 6.3a `#expand` — the switch at the call site

```
attrs  := ( '#identity' | '#expand' )*                        (protocol header)
method := Name '::' '(' params ')' [ '->' type ] [ '#expand' ] ( ';' | body )
```

`#expand` says **where a dispatch switch stands**, and nothing else.
On the header it reaches every method of the protocol; on a method it
reaches that method alone. It is a `tagged` attribute: `#expand` on
any other kind is a compile error, on the header and on a method
alike, because no other kind generates a switch to place. A
method-level `#expand` under a header-level one is also an error —
the header already said it, and which of the two is the leftover is
not the compiler's guess to make.

```sx
Slab :: protocol tagged #identity #expand {        // every method
    take :: (self: *Self, size: i64) -> *void;
    drop :: (self: *Self, ptr: *void);
}
Gauge :: protocol tagged {
    hot  :: (self: *Self, n: i64) -> i64 #expand;  // this method only
    cold :: (self: *Self, n: i64) -> i64;          // outlined, as usual
}
```

An `#expand` method's switch expands **at each call site** instead of
standing behind the outlined `__sx_tags_<P>_<m>` routine. The arms,
the totality, the tag order, and the computed result are the outlined
routine's exactly — what changes is that each caller holds its own
copy of the switch, so the caller's own facts fold it: a site whose
receiver is a statically known conformer keeps one arm and drops the
switch entirely, and every site in a one-conformer program folds to a
direct call. The cost paid for that is code size — one switch per
call site rather than one per program.

The consequence is the `-> Self` consequence class (§6.3): an expanded
call site is **set-dependent codegen**, so §9's fingerprint-keyed
caching covers the containing function. Un-annotated tagged dispatch
is untouched: its callers see one symbol call and stay
set-independent.

`#expand` is not observable. No builtin reports it, `protocol_kind`
and `is_identity` are unaffected (§8), and the two spellings of a
protocol compute the same values — a program cannot branch on where
its switches live.

*Implementation note.* The routine is still generated, once; the
expansion is forced inlining of it, emitted as LLVM's `alwaysinline`.
The contract is a guarantee, not the cost-model preference an inlining
hint would express. Whether an un-annotated routine happens to be
inlined anyway is the backend's ordinary business and no part of this
design.

#### The `Allocator` trade — the measured record

The standard `Allocator` was carried through all three
representations and measured, because it is the one protocol every
program dispatches on a hot path. `tests/bench_allocator_dispatch.sx`
holds the harness: one bump-allocation workload, 61 trials per lane,
medians, quartile spread as the noise bound. Per-allocation cost in
picoseconds, arm64, `--opt 3`:

| lane | `inline #identity` | `tagged` | `tagged #expand` |
|---|---|---|---|
| direct (concrete receiver — the floor) | 1074 | 1055 | 1070 |
| borrow (conformer known at the site) | 1049 | 2076 | **912** |
| ctx (`push`ed handle, one conformer) | 2064 | 2079 | **905** |
| rotate20 (20 conformers, predictable) | 2423 | 2478 | **1845** |
| inter2 (2 conformers, unpredictable) | **5463** | 6524 | 5719 |
| inter20 (20 conformers, unpredictable) | **7986** | 10094 | 9461 |

The unpredictable lanes draw their receiver from a heap index array
filled at runtime by an xorshift stream: unfoldable by the compiler,
unlearnable by the branch predictor.

Three things the numbers say. **`#expand` earns the predictable
regime outright** — it takes tagged dispatch from 2.0x the concrete
receiver's cost down to the concrete receiver's cost, and beats
`inline` even at 20 conformers walked in rotation, because a switch
whose selection the predictor learns costs less than an indirect call
it must still fetch through. **The cost is prediction failure, not
switch width** — rotate20 (20 arms, predictable) is 1845, while inter2
(2 arms, unpredictable) is 5719: a mispredicted switch pays for the
whole arm it guessed wrong, where an indirect call pays one fetch. The
25-member set lowers to a compressed jump table, not a compare tree,
so width itself is nearly free. **And `#expand` costs text** — the
13-dispatch-site benchmark takes +45% `__text` over the outlined
routine (14320 vs 9844 bytes); the 7-dispatch-site version, 0.3%. One switch per call site is
the price.

An allocator's conformer population is exactly what a library cannot
predict: a program with one arena and a program interleaving twenty
both link against this declaration. So std ships `inline #identity`,
which is flat across both regimes, and `tagged #expand` stands as the
proven alternative — the decoupling invariant (§9) makes it one
stdlib line for a program that knows its allocators are predictable,
with no compiler change of any kind.

### 6.4 Dispatchability on tagged values

Tagged dispatch extends the erased rule by exactly the *direct*
`Self` positions — because each switch arm knows `Self`, a bare
`Self` parameter or a bare `Self` return is expressible:

| position | erased kinds | tagged |
|---|---|---|
| receiver | yes | yes |
| bare `Self` later parameter | no | **yes** — caller passes a `P` value; the arm checks its tag against the arm's own (mismatch is a checked runtime failure — the one runtime check in tagged dispatch) and passes the referent |
| bare `Self` return | no | **yes** — see placement below |
| `Self` at depth (`*Self`, `?Self`, `[]Self`, `Buffer(Self)`, fn types) | no | **no** — excluded, same rule: a composite of `Self` has no caller-side type (a `[]P` of 16-byte handles is not a `[]Buffer(f32)`), and no per-element coercion exists |
| protocol's own parameters, any depth | yes (concrete per instantiation) | yes |

An excluded method behaves exactly as on the erased kinds:
required of impls, callable concretely and through bounds, compile
error through the value, members-win over UFCS.

On a **`#identity` tagged protocol**, bare-`Self`-**returning**
methods are additionally excluded from dispatch through values: an
arm would materialize precisely the anonymous frame-temp instance
the naming discipline refuses. They stay callable concretely and
through bounds. Bare `Self` *parameters* remain dispatchable — the
arm receives an existing referent; nothing anonymous is created.

**Bare `Self` return — placement.**

```sx
Shape :: protocol tagged {
    area    :: (self: *Self) -> f64;
    resized :: (self: Self, k: f64) -> Self;   // bare Self in and out
}
Circle :: struct { r: f64; }
impl Shape for Circle {
    area    :: (self: *Circle) -> f64 { 3.14159 * self.r * self.r }
    resized :: (self: Circle, k: f64) -> Circle { .{ r = self.r * k } }
}

c := Circle{ r = 1.0 };
s : Shape = c;
big := s.resized(2.0);     // ← the note below fires here
```

The dispatch switch for a
`Self`-returning method expands inline at the call site (§6.3), and
each arm materializes its concrete result as a temporary in the
**calling function's frame**, yielding a tagged borrow of it. Two
consequences the caller owns: the value dies with the caller's
frame, and a loop accumulates one temporary per iteration until the
frame ends. The compiler emits a warning at each such call site:

```
warning: 'resized' returns 'Self' through a tagged value — the
result materializes a frame-scoped temporary (one per call; lives
to end of frame). See design/protocols.md §6.4, "-> Self placement".
```

No fixit is offered: the right restructure (bind the receiver
concretely, place the result into owned storage, hoist out of the
loop) depends on intent.

Returning the result directly (`return s.resized(2.0)`) is the same
compile error as erasing an rvalue at `return` (§6.2): the borrow's
referent is a same-statement temporary of the dying frame, and the
site is syntactically evident.

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
Spelling a concrete type is instantiation wherever it appears:
an impl HEAD counts (`impl Serialize for Buffer(f64)` admits
`Buffer(f64)` even when nothing else mentions it), an expansion
list element counts (§3), and comptime bodies count — a type
instantiated only inside `#run` code is instantiated for admission,
so comptime-carried values (§7.9) always reference real members.
Mention through a probe counts **in scheduled comptime only**
(§7.9): there, probing a pair whose type only that probe spells
instantiates the type — with a blanket impl in scope, the probe
both admits the member (enlarging the shipped set) and answers
true by construction. Post-fixpoint comptime cannot admit (§7.9's
phase law). Reaching a protocol
instantiation and monomorphizing admitted impl bodies CAN
instantiate new types (an impl body may spell `Nest(Nest(T))`);
such chains fall under the ordinary generic instantiation-depth
diagnostic, exactly like a generic function recursing with a
growing type argument. With that guard, admission draws from a
finite type population and each iteration only adds sets or
members, so the fixpoint terminates.

Argument tuples are canonicalized (aliases resolved, value args
folded) before keying, so `Series(Sample)` and `Series(f32)` are one
entry when `Sample :: f32`. Blanket impls over parameters the head
does not mention (`impl Series(f32) for Repeat($U)`) contribute one
member per *instantiated* `Repeat(U)` — never an open-ended family.
Blanket impls bounded by constraint protocols
(`impl Show for $T/Ord`) are not a supported form: an impl's `for`
target must name a type constructor, not a bound — enumerate a
curated list with a top-level `inline for` instead (§3).

### 6.6 Reached instantiations only

Constraint-position use (`$S/Series(f32)`) is monomorphized and
reaches nothing. **Value use** — an erasure site, protocol-typed
field or array-element declaration, protocol-typed return or
parameter, or a comptime escape (§7.9) — reaches the instantiation
and materializes its tables.
Reachability is judged over the **monomorphized program**: every
compiled function body counts, called or not; generic bodies count
once instantiated and not otherwise. An instantiation nobody
value-uses emits nothing at all; a tagged protocol used only as a
bound costs exactly what a constraint protocol costs.

Membership is stable: it does not depend on which code
executes, so dead-code edits never change what typechecks. Every
member receives a tag, switch arm, and table row. (A stricter
emission-level shake is possible without touching these semantics —
see the appendix note on liveness shaking.)

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

The examples below share this context: `Series(T)` (§1, tagged:
`count`, `at`); conformers `Sine`/`Buffer($T)`/`Counter` (§3) and
`Scaled($T)` (§6.9); `Timer :: struct { deadline: i64; }` conforms
to nothing; no impl anywhere names `Series(bool)`.

```sx
v : Series(f32) = Sine{ freq = 0.5 };
```

- **Empty set**: any value-consuming operation — erasure, method
  call, downcast — at an instantiation whose computed set is empty
  is a compile error at that site (no value of the type can exist):

  ```sx
  count_flags :: (s: Series(bool)) -> i64 { s.count() }
  //                                        ^^^^^^^^^ ← the error
  ```
  ```
  error: no impl of 'Series(bool)' exists in this program — 'Series'
         is implemented for f32 (3 impls) and i64 (2 impls)
  ```

  A merely-*reaching* use — a field or parameter of an empty-set
  instantiation, never erased into and never dispatched — is legal
  and emits nothing: reaching (§6.6) materializes the instantiation
  and arms its diagnostics (coherence, §3); only value-CONSUMING
  operations demand a member. A comptime **soft probe** against a
  final empty set answers null rather than erroring — the bootstrap
  path for conformance-conditional expansion (§7.9); hard and
  consuming operations error identically at comptime and runtime.
- **Downcast in the set**: `v.(Buffer(f32))` compiles to one
  immediate compare against the known constant tag — no table load.
  The assertion temperaments apply as on any postfix assertion:
  graceful when consumed via the error channel, panic when
  unconsumed, soft for the `?T` target.
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
Series :: protocol(T: Type) tagged {       // restated from §1
    count :: (self: *Self) -> i64;
    at    :: (self: *Self, i: i64) -> T;
}

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
  is a runtime fact; the assertion temperaments apply (unconsumed
  `p.(Q)` panics, `try p.(Q)` is graceful, `p.(?Q)` is soft). For a
  tagged `Q`, "conforms" means "is in `Q`'s conformer set"; the
  check maps `type_id → Q-tag` through a link-time table.
- **Erased `Q`**: the check and the result's vtable/fn-ptr words
  come from a link-time `type_id → Q-dispatch` table holding
  exactly the pairs with a **program-unique** impl. A pair with
  visibility-disjoint duplicate impls (§3) is absent from the
  table: the conversion fails as non-conforming — the site-local
  visibility that arbitrates ordinary erasure does not exist at a
  dynamic conversion, and no other arbiter would be sound.
- **`#identity` `Q`** — either representation — **refuses at
  compile time**: identity conformers are named objects, and a
  dynamic conversion cannot prove the referent is one.
- **Result ownership follows `Q`'s kind**: value/own `Q` → an
  owning copy of the receiver (`rt_size_of` via the concrete type
  id) through `context.allocator`; the two-argument `p.(Q, alloc)`
  routes it explicitly and pairs with `free(q, alloc)`. Tagged `Q`
  (non-identity) → a borrow of `p`'s ctx with `Q`'s tag; a borrow
  result ties its lifetime to `p`'s referent.
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

Context fields may be protocol-typed only at a borrow-kind protocol
(`#identity` or tagged): context defaults are mandatory and
comptime-evaluable, the fold of a protocol-typed default is the
identity erasure of a named instance global — a borrow, never null
(null ctx is exclusively the `?P` absent sentinel) — and an owning
constant cannot exist before `main`, so a value/own protocol-typed
context field is refused at its declaration. Threads and fibers inherit the
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

**Scheduling.** Comptime entangled with membership — the conditions
and iterables of top-level `inline if`/`inline for`, any `#run`
they transitively reference, and body-level comptime reached by the
fixpoint's monomorphization of admitted impls — evaluates under one
dataflow discipline:

- **Tagged-target membership only grows**, so a *positive* fact —
  a dispatch finding its impl, a probe answering true — is readable
  the moment it exists and can never be invalidated. A *negative*
  answer — a soft probe yielding null, an erasure meeting an empty
  set — is utterable only once the queried set is **final**: no
  unexpanded `inline if`/`inline for` branch can still contribute
  to it. Contribution is judged syntactically and conservatively:
  an unexpanded body mentioning `impl P for …` contributes to `P`'s
  sets, and one holding an `#import` contributes the whole surface
  of the module it names — the impls, declaration names and
  `#context_extend`s that module authors, transitively through its
  own imports and branches — because selecting the branch is what
  brings them in.
- **Erased-target conversion facts depend on impl multiplicity**
  (the program-unique rule, §7.4), and uniqueness is not monotone —
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
  Serialize :: protocol tagged { write :: (self: *Self, out: *Buf); }
  HAS :: #run { g := GPA{ … }; g.(?Serialize) != null };
  inline if !HAS { impl Serialize for GPA { … } }
  ```
  ```
  error: expansion deadlock — 'HAS' needs 'Serialize' membership to
         be final, but 'inline if !HAS' can still add 'impl
         Serialize for GPA'; the expansion depends negatively on a
         set it feeds
  ```

- A suspended **hard** operation — a dispatch, an unconsumed
  conversion, an erasure — whose awaited fact never arrives
  diagnoses at finality with the ordinary §6.8-family error at the
  operation's site. A suspended **soft** probe answers null.

**The probe.** A soft protocol target on a *concrete* receiver —
`gpa.(?Serialize)` — answers conformance directly, no value
ceremony; `has_impl(P, T)` is the same probe spelled at type level,
under the same rules. What a probe answers is **per kind**:

- `constraint` and the erased kinds: **site-local impl
  visibility** — the same static fact that decides whether the site
  could erase. (For erased kinds this is a different question from the
  dynamic re-erasure check, which consults program-wide uniqueness, §7.4.) Under the discipline, a negative
  gates on declaration-space finality — impls are declarations.
- `tagged`: whole-program membership of the instantiation's set,
  under the discipline's polarity rules.

A probe **queries** an instantiation: its set is computed on demand
and its coherence diagnostics arm (§3) — but a probe is *not* a
value use: it reaches nothing for emission and ships no tables
(§6.6).

**The phase law.** All comptime execution not under the discipline
runs **after the conformer fixpoint**, against the final sets —
every such `#run` sees the same converged world, and **cannot
enlarge it**: an operation that would require admitting a new
member — a probe, erasure, dispatch, or escape of a pair outside
the final set, blanket-unifiable or not — is a compile error
("would enlarge a final conformer set; move this into
expansion-scheduled code, or spell the type in runtime code").
Post-fixpoint code may instantiate types freely for every
non-protocol purpose. Conformer sets remain unobservable as
*collections* at every phase (no enumeration reflection exists,
§3); the granted facility is per-pair facts — a probe, `has_impl`,
a dispatch, a conversion — under the discipline above.

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
- the value's numeric word resolves at link — a tag, or for an
  erased value the `(protocol, type, impl)` vtable of the impl
  carried from its erasure site;
- an **owning** erased value cannot escape — no runtime allocator
  owns a compile-time copy, so carrying one into the image is a
  compile error ("bind the concrete value; owning erasure happens
  at runtime");
- an escape is a **value use** of its instantiation (§6.6).

## 8. Reflection

- `protocol_kind(P) -> {constraint, vtable, inline, tagged}` —
  compile-time only; folds in `inline if`.
- `is_identity(P)` — true for `#identity` protocols of either value
  representation (erased or tagged); false for every other type.
  Compile-time only.
- `#expand` has no reflection form. It places switches; it changes no
  value, type, or result, so nothing observes it (§6.3a).
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

**Tag references in module objects.** No numeric tag is ever baked
into per-module compiled code: a downcast's compare constant emits
as a link-resolved absolute symbol (`__sx_tag_<P>_<T>`),
materialized when the converged set is numbered. Most module
objects therefore survive impl additions unchanged — plain dispatch
is a symbol call, compare constants relocate; adding a conformer
renumbers tags and regenerates the link-stage tables and routines
without recompiling them. Downcasts always emit as symbol compares
— never constant-folded caller-side — so ordinary callers stay
set-independent; single-conformer folding happens inside the
link-stage outlined routine only. The exceptions are the functions
that carry a switch of their own: one containing a call-site-inlined
`Self`-switch (§6.3, one arm and one temp slot per member), and one
calling an `#expand` method (§6.3a, one arm per member). Their
object-cache keys include the membership fingerprint of exactly the
protocols they expand a switch over — those whose `Self`-returning
methods they dispatch, plus those whose `#expand` methods they call —
and adding a conformer recompiles those functions and relinks the
rest. The second exception is conditional on the annotation, not on
the kind: a tagged protocol with no `#expand` method puts its
membership in no cache key at all.

The fixpoint precedes codegen, so every membership diagnostic —
empty-set errors, out-of-set downcasts, coherence (§3, §6.8) — is
an ordinary compile error, never a link error; only *numbering* and
table emission are link-stage.

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
tagged, #expand method:
         the same switch, expanded INLINE at the call site, where the
         caller's own facts fold it (§6.3a)
```

**`free`.** One function, compile-time kind-dispatched by an inline
type match: a protocol arm (ctx via `ProtocolRaw`, one body for both
erased layouts, gated on the ownership class — `#identity` and
tagged refuse), a closure arm, a slice arm; every other argument
kind is a compile error.

**The standard `Allocator` is stdlib-owned.** Its declaration —
kind, attributes, method set — belongs to `std/core.sx`, not to the
compiler. The compiler-driven heap paths (an owning erasure's copy,
the implicit-context allocation, the Obj-C `+alloc`/`-dealloc` IMPs)
find the allocator by NAME on the assembled `Context` and go through
the ordinary protocol dispatch for whatever kind they find there, so
respelling `Allocator` — a different kind, `#expand` added or removed
— is a library edit that requires no compiler change.

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
| single-conformer tagged protocol | fully devirtualizes inside the link-stage routine (single arm → direct call); downcasts stay symbol compares; module objects unaffected (§9) |
| zero-conformer tagged instantiation | reaching use legal; erasure, method call, or downcast errors naming the implemented instantiations; a comptime SOFT probe against the final empty set answers null (§7.9) |
| duplicate impl `(P-instantiation, T)` | constraint/erased: import-scoped (§3). tagged: global coherence — error at the first reached colliding instantiation, naming both impl sites; unreached collisions are not diagnosed |
| impl for a protocol type itself (`impl P for Q`) | protocols are not concrete types; refused |
| impl for a structural type (`impl Series($T) for []T`) | legal — conformer identity is canonical type identity |
| impl bounded by a constraint (`impl Show for $T/Ord`) | not a supported form; the `for` target names a type constructor |
| protocol-typed protocol member (`m :: (self: *Self, v: View)`) | ordinary — the parameter erases per `View`'s kind at the call |
| bare `Self` later parameter | erased: excluded. tagged: dispatchable — caller passes a `P`; the arm tag-checks (checked runtime failure on mismatch) |
| `Self` at depth in parameter or return (`[]Self`, `?Self`, `Buffer(Self)`) | excluded from dynamic dispatch on every kind; concrete/bound calls fine |
| bare `-> Self` through a tagged value | call-site-inlined switch; caller-frame temp per call + warn-note (§6.4), no fixit; returning the result directly is the §6.2 return error; EXCLUDED from dispatch on `#identity` tagged protocols (would mint an anonymous instance) |
| rvalue at `*P` (erased) | compile error — nothing durable to borrow |
| rvalue at `P` (tagged), non-return position | frame-scoped temp, borrow — the `any`-box placement rule |
| rvalue at `P` (tagged), `return` position | compile error — nothing durable to borrow beyond the frame |
| returning a tagged borrow of a callee local | legal, unchecked, dangles — the slice-of-local doctrine |
| rvalue at `P` (`#identity`, erased or tagged) | compile error — identity objects need a name |
| `#identity` on `tagged` | legal — contributes exactly the naming discipline (rvalue erasure refuses); borrow and `free` refusal are structural to the kind |
| `#expand` on a non-tagged kind (header or method) | compile error at the attribute — no other kind generates a switch to place |
| method `#expand` under a header `#expand` | compile error — the header already reaches every method; which spelling is the leftover is not the compiler's guess |
| `#expand` on a single-conformer tagged protocol | legal and redundant in effect: the routine already folds to a direct call, and expanding it moves that call to the site |
| `#expand` under comptime execution | invisible — the VM devirtualizes by the carried concrete type either way (§7.9); the annotation only places the runtime switch |
| `free` on: view / identity / tagged / constraint-typed anything | compile error in each case (distinct wordings; constraint has no values at all) |
| `p.(ProtocolRaw)` | field-wise build per layout; tagged inserts one table load |
| `p.(Q)`, different protocol | direct re-erasure conversion (§7.4); temperaments apply; result ownership per `Q`'s kind; `#identity` targets refuse at compile time; erased targets resolve through the unique-impl table — a duplicated pair converts as non-conforming |
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
| protocol values inside `#run` / comptime execution | legal, symbolic — `{ctx, concrete type[, impl]}`, VM-devirtualized dispatch; under the §7.9 discipline, negative tagged answers, erased-target conversions (both polarities), and name-lookup misses suspend until finality |
| scheduler quiesces with parked evaluations (self-feeding or mutual) | compile error — expansion deadlock, every parked evaluation and its awaited facts named (§7.9) |
| comptime protocol value escaping into the image | declared-global referents relocate in place (mutable); comptime temporaries become writable anonymous image globals, deduped by object identity, nested handles recursing; OWNING erased values cannot escape — compile error (§7.9) |
| type declared inside a top-level `inline for` body | flattens to module scope — duplicate across iterations diagnoses; parameterize the type (`Vec :: struct($N: u32)`) instead of re-declaring per iteration |
| `inline for` conformance-list elements | concrete types only (a `Type` never tags a protocol, §8); `#run`-computed lists are legal but expansion-driving (§7.9 scheduling); duplicate elements and nested unrolls diagnose with cursor provenance ("T = Point, i = 1") |
| conformer method name colliding with an existing member of the type | exact protocol signature: the existing method satisfies conformance (impl may omit; providing it duplicates). anything else (field, different signature): compile error at the impl |
| default method calling an excluded method | legal — defaults compile per conformer against concrete `Self` (§2); exclusion binds only calls through erased values |
| impl inside a dead `inline if` branch | never exists — joins no set, emits nothing |
| `inline for`-generated impls | ordinary impls of the expanded program; a colliding pair is the ordinary coherence error, naming the unrolled sites |
| comptime observation of a conformer set | no enumeration exists at any phase — sets are unobservable as collections; per-pair facts (probe, `has_impl`, dispatch, conversion) are legal under the §7.9 discipline |
| the probe (`x.(?P)` on a concrete receiver / `has_impl(P, T)`) | constraint/erased: site-local impl visibility; tagged: whole-program membership; queries compute the set and arm coherence but reach nothing for emission (§7.9) |
| post-fixpoint comptime touching an out-of-set pair | compile error — would enlarge a final conformer set; only scheduled comptime admits (§7.9 phase law) |

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
  membership only grows; negative facts wait for finality; the only
  new error is the wait cycle — precisely the program whose meaning
  is genuinely circular. Cost is localized to one subsystem (the
  VM's ability to park and resume an evaluation).
- **Liveness shaking (a compatible refinement).** The operations
  that produce a tagged value form a closed, statically enumerable
  set: direct erasure sites, re-erasure (§7.4), `Self`-returning
  dispatch (which only reproduces present types), and
  comptime-carried values escaping into the image (§7.9), whose
  members seed liveness without any runtime erasure site — nothing
  conjures a value from a runtime type id. Emission may therefore drop
  members no execution path can produce (seeding from erasure sites
  in call-graph-reachable code, address-taken functions and closure
  literals as roots; propagating across re-erasure edges): shaken
  members keep their tag numbers (numbering stays
  membership-driven) but emit no rows in link-stage tables and no
  arms in link-stage outlined routines; an outlined dispatch whose
  instantiation has no producible member lowers to unreachable. The
  shake applies to **link-stage artifacts only** — call-site-inlined
  switches and every other module-object artifact key on
  membership, never liveness, so cached objects cannot depend on
  the liveness result. The refinement is semantics-neutral by
  construction — a producer-less member's downcast can only ever be
  false at runtime — which is why membership (typechecking,
  diagnostics) never reads it. **The design as specified does not
  perform the shake**; this note is rationale for a possible future
  design change, not an emission mode — there is exactly one
  shipping behavior at any time.
