# sx

A programming language with compile-time execution, generics, closures,
protocols, and an LLVM backend — compiled to fast native code.

## At a Glance

```sx
#import "modules/std.sx";

Point :: struct {
    x, y: i32;
    magnitude :: (self: *Point) -> f32 { sqrt(self.x * self.x + self.y * self.y); }
}

main :: () {
    p := Point.{ x = 3, y = 4 };
    print("point: {}, magnitude: {}\n", p, p.magnitude());
}
```

**Highlights:**

- Clean declaration syntax: `name :: value` for constants, `name := value` for variables
- Compiles to native code via LLVM
- Compile-time execution with `#run`, code generation with `#insert`, and compile-time diagnostics with `#error("msg")`
- Generics via monomorphization
- First-class closures with value capture
- Protocol-based polymorphism (traits) with optional inline dispatch
- Pattern matching on enums, optionals, and type categories
- C interop via `extern` / `export` and `#import c`
- Inline assembly as a first-class expression
- Colorblind async via a pure-sx cooperative fiber runtime (no function coloring)
- Targets: macOS (ARM64, x86_64), Linux (x86_64, ARM64), Windows (x86_64), WebAssembly

## Usage

```sh
sx run file.sx           # compile and run
sx build file.sx         # compile to binary
sx build file.sx -o out  # compile with output path
sx ir file.sx            # emit LLVM IR
sx lsp                   # start language server
```

Options:
```
--target <triple>   target platform (shortcuts: macos, linux, windows, wasm)
--opt <level>       optimization: none, less, default, aggressive
--cpu <name>        target CPU
-o <path>           output path
```

## Standard library guides

- [Compression, PNG, and ZIP](docs/compression.md)
- [Compression migration coverage](docs/compression-coverage.md)

Third-party attributions for stdlib-derived code are recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Language Overview

### Types

| Type | Description |
|------|-------------|
| `i8`..`i64`, `u8`..`u64` | Signed/unsigned integers (default: `i64`) |
| `f32`, `f64` | Floating point (default: `f32`) |
| `bool` | `true` / `false` |
| `string` | UTF-8 fat pointer `{ptr, len}` |
| `[N]T` | Fixed-size array |
| `[]T` | Slice (fat pointer) |
| `*T`, `[*]T` | Single / many pointer |
| `?T` | Optional |
| `struct`, `enum`, `union` | Composite types |
| `Closure(args) -> ret` | Closure type |

A fixed array `[N]T` coerces to a slice `[]T` (its length is known); a `[*]T`
many-pointer carries no length, so slice it explicitly with `ptr[0..len]`.

Storing a value into a typed slot (a `:`-annotated binding, a field, an array
element, a deref, an assignment target) requires a coercion to exist. A value
with no coercion to the slot type *and* a different byte width — e.g.
`x : i32 = "hi"` — is a **compile error** rather than a silent reinterpreting
store. Same-width reinterpretations (`*T → [*]T`, `i64 → isize`) are allowed, and
an explicit `xx` / `x.(T)` is always the escape hatch for a deliberate
reinterpretation.

**Postfix cast.** `expr.(T)` converts to the written type through the same
engine as `xx` — one coercion ladder. A protocol target is the OWNING
erasure: `dog.(Speaker)` copies, `dog.(Speaker, alloc)` copies through a
named allocator, a `*Speaker` view receiver promotes to owned.
Well-defined, not value-preserving: `1000.(i8)` truncates. Chains
left-to-right (`x.(u8).(i64)`), binds tighter than unary (`-x.(i8)`). On an
`any` receiver it is the checked assertion, three temperaments:
`try av.(i64)` propagates a mismatch, bare `av.(i64)` panics on one, and
`av.(?i64)` is the soft form — `null` on mismatch, composing with `??` and
`if v := … { }`. Optional receivers chain: `o?.(T)` maps the cast over the
optional (null propagates; a `?any` payload asserts with the same
temperaments — `try o?.(i64)` yields null / value / raises).

**Numeric limits.** A field access on a builtin integer type folds to a
compile-time constant: `i64.max`, `u8.min`, `[u8.max]T` (a 255-element array).
Floats expose `.min` / `.max` plus `.epsilon`, `.min_positive`, `.true_min`,
`.inf`, and `.nan`. See `specs.md` → Numeric Limits.

### Declarations

```sx
// Constants (compile-time when possible)
PI :: 3.14159;
MAX : i32 : 100;

// Variables (mutable)
x := 42;               // inferred type
y : i32 = 0;           // explicit type
z : i32 = ---;         // uninitialized
```

**Number literals.** Integers are written in four bases: decimal (`1000`),
hex `0x`/`0X` (`0xFF`), octal `0o`/`0O` (`0o755`), and binary `0b`/`0B`
(`0b1010`). Any integer base — and a float's fraction — may carry `_` digit
separators as pure visual grouping; they are stripped before the value is
computed, so `0xFF_FF == 0xFFFF`, `1_000 == 1000`, and `3.14_159 == 3.14159`.
Separators are permissive: repeated (`1__0`) and trailing (`1000_`) underscores
are accepted. (A leading `_` before the first digit reads as an identifier, not
a number.)

```sx
m := 1_000_000;        // decimal grouping
o := 0o755;            // octal → 493
h := 0xFF_FF;          // hex → 65535
b := 0b1010_1010;      // binary → 170
```

**Char literals.** `'A'` decodes to its integer code point and behaves exactly
like an integer literal — default type `i64`, coerces to any int/float type in
context. There is no `char` type; storage is whatever the binding declares
(`u8`, `u32`, `i64`, …). Escapes: `\n \t \r \\ \' \0 \xNN \u{XXXX}` (the last
two accept any byte / any Unicode scalar up to `U+10FFFF`):

```sx
c : u8 = 'A';                 // 65
cp : u32 = '\u{1F980}';       // 129408 (a crab emoji)
buf : [3]u8 = .['H', 'i', 0];
arr : ['Z']u8 = ---;          // array dim folds — 90 elements
Esc :: enum { esc :: '\x1b'; nl :: '\n'; }   // char as explicit enum value
```

Anywhere an integer literal is accepted, a char literal is too — explicit enum
values, compile-time value args to a parametrized type (`Buf('A')`), array
dimensions, and `match` / `#if` const comparisons.

A char literal whose code point is too wide for the target type is a compile
error (not a silent truncate): `c : u8 = '🦀';` diagnoses `char literal '🦀'
(value 129408) does not fit in u8 (range 0..255) — use a wider type such as u32`.

A typed constant's initializer must be compatible with its annotation (checked at
compile time for both literals and constant expressions). Mixed int+float
arithmetic promotes to float in either operand order.

**Aggregate constants.** Array- and struct-typed `::` constants are immutable
globals — one storage, reads index directly, whole-value uses copy by value,
unused tables are dropped from the binary. `::` is the one and only const
spelling:

```sx
K : [4]i64 : .[11, 22, 33, 44];   // typed array const
A :: .[1, 2, 3];                  // untyped — infers [3]i64
M :: .[1, 2.2, 3];                // numeric mix promotes — [3]f64
LIT :: Color.{ r = 255, g = 0, b = 0 };   // struct const

N :: K[0] + K[3];     // 55 — const element reads fold at compile time
D : [K.len]u8 = ---;  // .len folds in dimensions too
K[0] = 5;             // error: cannot assign through constant 'K'
```

Writes through a constant's name are compile errors; a local copy (`k := K`)
stays writable.

**Float → integer narrowing.** A float flowing into an integer binding without a
cast must be integral: an integral compile-time float folds to its integer, a
non-integral one is a compile error (`y : i64 = 4.0` → `4`; `y : i64 = 1.5`
errors). This is uniform across locals, defaults, arguments, constants, and array
dimensions. An explicit `xx` / `x.(i64)` is the escape hatch and always
truncates.

**Reserved names.** Builtin type names (`i32`, `u8`, `bool`, `string`, …) can't
be used bare as identifiers at value-binding or declaration sites. Member
positions (struct fields, union tags, protocol methods) are exempt, as is any
name after a leading `.`. A leading backtick escapes one into a raw identifier
(`` `i2 ``), usable in every position:

```sx
`i2 := 2.5;                  // identifier "i2", distinct from the i2 type
`i2 :: struct { x: i64; }    // a type named with a reserved spelling
v : `i2 = ---;               // referenced as a type
x : i2  = 3;                 // bare `i2` in type position is still the int type
```

### Multiple return values

A function can return several values with a bare-paren return signature —
positional `-> (A, B)` or named `-> (x: A, y: B)`. The empty `-> ()` is `void`,
and a trailing `!` is the error channel (always the last slot): `-> (A, B, !)`. A
multi-return is **not** a tuple value — it is a distinct return shape (so a
parameter / field / variable annotation `x: (A, B)` is rejected; use `Tuple(…)`
for an actual tuple value).

```sx
divmod :: (a: i64, b: i64) -> (i64, i64) {
    return a / b, a % b;          // bare comma return — no literal needed
}

stats :: (a: i32, b: i32) -> (sum: i32, big: bool) {
    return sum = a + b, big = a > b;   // named, in slot order
}
```

Consume the result by **destructuring** or by binding it once and reaching the
value slots by **field**:

```sx
q, r := divmod(17, 5);            // q = 3, r = 2
c := stats(40, 2);               // c.sum = 42, c.big = true
```

For a **failable** multi-return, the error rides the separate `!` channel — a
bound value holds only the value slots, never the error:

```sx
classify :: (n: i32) -> (doubled: i32, big: bool, !) {
    if n < 0 { raise error.Bad; }
    return doubled = n * 2, big = n > 10;
}
d, b := classify(7) catch (e) { … };   // error stripped by `catch`; d, b are the values
```

**Named returns as locals.** Named slots are in-scope assignable locals; assigning
them *is* the return (no explicit `return` needed). A slot may carry a default,
which exempts it from the must-set rule:

```sx
combine :: (a: i32, b: i32) -> (sum: i32 = 0, good: bool) {
    good = a > b;
    sum = a + b;                  // both slots set → implicit return
}
```

A named slot that is **not assigned on every path** and has no default is a
compile error (definite-assignment) — rather than returning an uninitialized
value.

### Named arguments

Call-site sugar over positional parameters — positional args first, then
`name = value` in any order. Named arguments reach defaults **anywhere** in
the list (positional skipping stays end-only), and arguments always evaluate
in written order:

```sx
scaffold :: (top_bar: ?Closure() = null, fab: ?Closure() = null, content: Closure()) { … }

scaffold(content = chat_list);                    // skip middle defaults by name
scaffold(top_bar = toolbar, content = chat_list); // bare fns promote into ?Closure slots
"ab".pad(4, fill = "--");                         // composes with ufcs
```

Names are not part of a function's identity (no overloading) — but they are
public API: renaming a parameter breaks named call sites.

### Trailing blocks

A block after a call binds the callee's **last** parameter as a zero-param
closure — `f(args) { body }` is exactly `f(args, content = () => { body })`:

```sx
vstack :: (spacing: f32, content: Closure()) -> View { … }

vstack(8.0) {
    text("hello");
    text("world");
}

scaffold(top_bar = toolbar) { chat_list(); }   // named slots + block
```

The `{` must sit on the same line as the `)`; one block per call; the block
ends the call chain (pass modifiers inside the call). A capture-free block
promotes to a null-env thunk — zero allocation.

### Structs

```sx
Vec3 :: struct {
    x, y, z: f32;

    length :: (self: *Vec3) -> f32 {
        sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }
}

v := Vec3.{ x = 1, y = 2, z = 3 };
v2 := Vec3.{ 1, 2, 3 };              // positional
print("{}\n", v.length());
```

Structs support field defaults, `#using` for composition, and methods defined in
the body.

### Enums (Tagged Unions)

```sx
Shape :: enum {
    circle: f32;
    rect: struct { w, h: f32; };
    none;
}

area :: (s: Shape) -> f32 {
    if s == {
        case .circle: (r) => 3.14159 * r * r;
        case .rect: (r) => r.w * r.h;
        case .none: 0;
    }
}
```

Flag enums with power-of-2 values:
```sx
Perms :: enum flags { read; write; execute; }
rw := Perms.read | Perms.write;
```

Set a variant by construction (`s = .circle(2.0)`), which writes the tag and
payload together. Direct member assignment to a variant (`s.circle = 2.0`) is
rejected; mutating a sub-field of the active variant in place (`s.rect.w = 9.0`)
is fine.

### Optionals

```sx
x: ?i32 = 42;
y: ?i32 = null;

val := x ?? 0;          // null coalescing
forced := x!;           // force unwrap (traps on null)

if v := x {             // safe unwrap
    print("{}\n", v);
}

// Optional chaining
node: ?Node = get_node();
name := node?.name ?? "unknown";

// Flow-sensitive narrowing: a `!= null` guard proves the value present.
n: ?i32 = maybe();
if n != null { take_i32(n); }       // `n` is i32 here
```

A `?T` never implicitly unwraps to `T` in a value position — a bare `take_i32(n)`
without a guard, `!`, `??`, or binding is a compile error.

### Generics

```sx
max :: (a: $T, b: T) -> T {
    if a > b then a else b;
}

List :: struct ($T: Type) {
    items: []T;          // a slice; items.len is the live count, so a List is
    cap: i64;            // directly iterable: `for xs.items (e) { ... }`

    append :: (self: *List(T), item: T) { ... }

    // `#get` / `#set` property accessors: read/write via field syntax
    // (`xs.len`, `xs.len = n`) rather than method calls.
    len :: (self: *List(T)) -> i64 #get => self.items.len;
    len :: (self: *List(T), v: i64) #set { self.items.len = v; }
}
```

Generic constraints via protocols:
```sx
are_equal :: ($T: Type/Eq, a: T, b: T) -> bool { a.eq(b); }
```

### Closures

```sx
make_adder :: (n: i64) -> Closure(i64) -> i64 {
    (x: i64) -> i64 => x + n
}

add5 := make_adder(5);
print("{}\n", add5(100));   // 105
```

Closures capture by value. Bare functions auto-promote to closures when
needed. A capturing literal heap-allocates its environment through
`context.allocator`; `free(cl)` / `free(cl, allocator)` releases it (a
capture-free closure holds nothing — its free is a no-op).

### Protocols

```sx
Drawable :: protocol {
    draw :: (self: *Self, x: i32, y: i32);   // receiver is explicit + required
}

impl Drawable for Circle {
    draw :: (self: *Circle, x: i32, y: i32) { ... }
}

shape := my_circle.(Drawable);     // type erasure — an owned copy
shape.draw(10, 20);                // dynamic dispatch
```

**A protocol value owns its data; `*P` is the borrowed view.** Erasing
an **rvalue** heap-copies it through `context.allocator`; an **lvalue**
must say what it means — `my_circle.(Drawable)` copies (also
`.(Drawable, alloc)` through a named allocator), while a `*Drawable`
position borrows a transient view (mutations reach the original). An
implicit `shape : Drawable = my_circle` is a compile error with those
fixits. Release owned values with `free(shape)` (context allocator
current at the free) or `free(shape, allocator)` (explicit pairing,
immune to context drift).

Every protocol value knows its concrete type (a `type_id` word stamped at
erasure): `type_of(shape)` answers `Circle`, the checked downcast
`shape.(Circle)` has the same three temperaments as `any` assertions
(panic / `or`·`catch` / soft `.(?T)`), and the type switch takes protocol
subjects directly — `if shape == { case Circle: (c) {…} else: {…} }`.

Erasability is **per-method**: a method whose signature mentions `Self`
beyond the receiver (`eq :: (self: *Self, other: Self) -> bool`) can't be
called through an erased value — the compiler refuses with a fixit
pointing at the generic-bound spelling (`$T/Eq`), where it stays
fully usable.

`#inline` protocols store function pointers directly (no vtable
indirection), and `#identity` marks the borrow-only ownership class —
values of an identity protocol only ever borrow a *named* object (an
allocator, an Io runtime): rvalue erasure and `free` of the value refuse
at compile time, and `is_identity(T)` reflects the class. The std
`Allocator` and `Io` are both:
```sx
Allocator :: protocol #inline #identity {
    alloc_bytes :: (self: *Self, size: i64) -> *void;
    dealloc_bytes :: (self: *Self, ptr: *void);
}
```

### Pattern Matching

```sx
// On enums
if shape == {
    case .circle: (r) => print("radius: {}\n", r);
    case .rect: (r) => print("{}x{}\n", r.w, r.h);
    case .none: print("nothing\n");
}

// On optionals
if opt == {
    case .some: (val) => use(val);
    case .none: fallback();
}

// On type categories (via any)
if type_of(val) == {
    case int: print("integer\n");
    case string: print("string\n");
    case struct: print("struct\n");
}

// Type switch — an `any` dispatches on its runtime type tag; concrete
// arms (composites included) bind the typed value, category arms don't
if av == {
    case i64: (v) print("int {}\n", v);
    case []u8: (b) print("{} bytes\n", b.len);
    case struct: print("some struct\n");
    else: print("{}\n", type_name(type_of(av)));
}
```

### Control Flow

```sx
// Chained comparisons
if 0 <= x <= 100 { ... }

// While
while i < 10 { i += 1; }

// For — collections, ranges, and parallel iteration
for items (val) { print("{}\n", val); }
for items, 0.. (val, idx) { print("[{}] = {}\n", idx, val); }
for 1..=5, 0.. (a, b) { print("{}:{}\n", a, b); }   // a: 1..5, b follows
for items (val) => total += val;                    // arrow body
for 0<..<n (i) { }                                  // bound markers: 1 .. n-1
sub := items[1..=3];                                // slices take them too

// Defer
f := open("file.txt");
defer close(f);

// Multi-target assignment (atomic swap)
a, b = b, a;
```

### Pipe Operator

```sx
result := data |> parse() |> transform() |> serialize();
// equivalent to: serialize(transform(parse(data)))
```

### Compile-Time Execution

```sx
// Evaluate at compile time
FIBONACCI_10 :: #run fib(10);

// Generate code at compile time
#insert #run generate_lookup_table();
```

### C Interop

```sx
libc :: #library "c";
printf :: (fmt: [:0]u8, args: ..any) -> i32 extern libc;
write_fd :: (fd: i32, buf: [*]u8, count: u64) -> i64 extern libc "write";
```

`extern` imports a symbol defined elsewhere; `export` is its dual — define a
function in sx and expose it under the C ABI so C can call back in. Both imply
`abi(.c)` and take an optional `[LIB] ["csym"]` rename tail:

```sx
abs       :: (x: i32) -> i32 extern;             // import an external C symbol
sx_square :: (x: i32) -> i32 export { x * x }    // define + expose to C
__stdinp  : *void extern;                        // extern data global
```

Direct C header import:
```sx
#import c {
    #include "vendors/mylib/api.h";
    #source "vendors/mylib/impl.c";
};
```

### Inline Assembly

`asm` is an expression. The body is a brace block: a template string first, then
operands and an optional `clobbers(.…)` clause. Each operand is
`[name]? "constraint" <role>`, where the role is `-> Type` (a value output) or
`= expr` (an input). It compiles to an LLVM inline-asm call (AT&T syntax).

```sx
// one value output, two register-class inputs
add :: (a: i64, b: i64) -> i64 {
    return asm { "add %[out], %[a], %[b]", [out] "=r" -> i64, [a] "r" = a, [b] "r" = b };
}
```

Outputs decide the result: **0** → `void` (asm must be `volatile`); **1** → that
type; **N** → a destructurable `Tuple` named by each operand. A top-level
`asm { … }` block is global (module-level) assembly. See
[docs/inline-assembly.md](docs/inline-assembly.md) for the full guide.

### Modules

```sx
#import "modules/std.sx";              // flat import
math :: #import "modules/math";        // namespaced import (directory: all .sx files merged)
```

A flat import makes a module's top-level names bare-visible; a namespaced import
binds only its alias, reached as `m.name`. Visibility does **not** chain — a flat
import of a flat import is not bare-visible two hops away; qualify it or
`#import` the module directly. Bare names that two flat imports both provide are
ambiguous and must be qualified. When a module declares its own same-name symbol,
that wins over any import.

A facade can re-export another module's members as its own declarations
(ordinary aliases), which its direct importers then see bare:

```sx
// facade.sx
r :: #import "rich.sx";
helper :: r.helper;       // fn re-export
Thing  :: r.Thing;        // struct re-export
Box    :: r.Box;          // generic head re-export — same template
```

A module-scope declaration prefixed `private` stays usable throughout its own
source file (forward references included) but is never carried by flat imports
and never reachable through a namespace — it simply does not exist for other
files:

```sx
// lib.sx
private helper :: (x: i64) -> i64 { return x * 2; }   // file-local
exposed :: () -> i64 { return helper(21); }           // public API

// main.sx
#import "lib.sx";
// exposed() ✓        helper() ✗ "'helper' is private to its declaring module"
```

`private` applies to any identifier-headed top-level declaration — functions,
types, constants, globals, aliases, named imports — and is rejected everywhere
else (locals, fields, methods, impl blocks, flat imports).

The stdlib prelude uses exactly this: `std.sx` is a pure re-export facade, so
`#import "modules/std.sx"` gives every bare prelude name (`print`, `List`,
`Context`, …) plus carried namespaces (`mem`, `fs`, `process`, `socket`, `json`,
`cli`, `hash`, `xml`, `log`, `test`):

```sx
#import "modules/std.sx";

main :: () {
    gpa := mem.GPA.init();          // mem :: #import — carried from std.sx
    log.warn("count = {}", 3);
    s := xml.escape("<a & b>");
}
```

### Implicit Context

Every program gets an implicit `context` with a default allocator:

```sx
// No boilerplate needed — context is auto-initialized
main :: () {
    list := List(i64).create();   // uses context.allocator
    list.append(42);
}

// Override allocator for a scope
push .{ allocator = my_arena } {
    do_work();  // all allocations use my_arena
}
```

Any module can extend the context with its own typed field — the compiler
assembles the program's `Context` from every `#context_extend` declaration
in the compilation. Defaults are mandatory (and comptime-folded); `push`
patches added fields exactly like builtin ones, and `context.field` reads
work in any module with no import required:

```sx
#context_extend logger: ?*Logger = null;   // declared by the logging module

push .{ logger = *my_logger } {
    serve();          // anything below reads context.logger
}
```

## Quick Sort Example

```sx
#import "modules/std.sx";

quick_sort :: (items: []$T) {
    partition :: (items: []T, lo: i64, hi: i64) -> i64 {
        pivot := items[hi];
        i := lo - 1;
        j := lo;
        while j < hi {
            if items[j] < pivot {
                i += 1;
                items[i], items[j] = items[j], items[i];
            }
            j += 1;
        }
        i += 1;
        items[i], items[hi] = items[hi], items[i];
        i;
    }

    sort :: (items: []T, lo: i64, hi: i64) {
        if lo < hi {
            pi := partition(items, lo, hi);
            sort(items, lo, pi - 1);
            sort(items, pi + 1, hi);
        }
    }

    sort(items, 0, items.len - 1);
}

main :: () {
    arr : []i64 = .[333, 2, 3, 5, 2, 2, 3, 4, 5, 6, 6, 1];
    quick_sort(arr);
    print("{}\n", arr);
    // [1, 2, 2, 2, 3, 3, 4, 5, 5, 6, 6, 333]
}
```

## Runtime Reflection

Reflection works on compile-time types AND runtime `Type` values (a `Type`
is an integer tag at runtime; `type_of(x)` and an `any`'s tag produce them).
The scalar family (`size_of`, `align_of`, `struct_field_count`,
`variant_count`, `is_flags`, `vector_lanes`, `type_eq`, `type_name`,
`is_unsigned`), the
field family (`struct_field_name/type/offset`, `variant_name/type`), and
kind-first `type_info` all answer for a runtime tag by reading lazily
emitted constant tables — a program that never reflects at runtime carries
none of them.

```sx
describe :: (tp: Type) {
    print("{} (size {})\n", type_name(tp), size_of(tp));
    ti := type_info(tp);                       // kind-first dispatch
    if ti == {
        case .struct: (si) {
            for si.fields (i, f) { print("  +{} {}\n", f.offset, f.name); }
        }
        case .enum: (ei) { print("  {} variants\n", ei.variants.len); }
        case .int:  (ii) { print("  int, {} bits\n", ii.bits); }
        else: {}
    }
}

av : any = Packet.{ … };
describe(type_of(av));                          // works on an any's tag
```

`any` itself is a type-erased *borrow* — `{type tag, pointer to the value}`
(Odin's `Raw_Any` analog). Boxing an addressable value points at its storage
(zero copy; mutations stay visible through a live view), boxing an rvalue
spills to a frame temp; an `any` is valid only while its referent lives.
`struct_field_value(s, i)` / `variant_payload(u, i)` return interior views
(`{field type tag, pointer into s}`), `any_element(av, elem, i)` strides
arrays and vectors, and the raw layer (`raw_any_data` / `raw_make_any`)
exposes the view's two words for containers and same-build serializers.
Unboxing (`xx av`) is an unchecked typed load through the
view; `==` on an `any` is a compile error — unbox first, or compare
`type_of(av)`.

Together they make ONE compiled walker that traverses any value without
copying a byte:

```sx
print_any :: (av: any) {
    if type_info(type_of(av)) == {
        case .struct: (si) {
            print("{");
            i := 0;
            while i < si.fields.len {
                if i > 0 { print(", "); }
                print("{}: ", si.fields[i].name);
                print_any(struct_field_value(av, i));   // interior view
                i += 1;
            }
            print("}");
        }
        case .array: (ai) {
            i := 0;
            while i < ai.len {
                print_any(any_element(av, ai.elem, i)); // stride view
                i += 1;
            }
        }
        case .int:    { print("{}", av); }
        // ... one arm per kind
        else: { print("<?>"); }
    }
}

print_any(xx pkt);   // one erasure at the root; every step is view math
```

## Standard Library

The standard library (`modules/std.sx`) provides:

- **I/O**: `print(fmt, args...)`, `out(str)`
- **Collections**: `List($T)` (dynamic array)
- **Strings**: `concat`, `substr`, `int_to_string`, `uint_to_string`, `float_to_string`, `cstring`
- **Memory**: `Allocator` protocol, `GPA` (general purpose), `Arena` (bump allocator)
- **Math**: `sqrt`, `sin`, `cos`
- **Introspection**: `type_of`, `type_name`, `size_of`, `align_of`, `field_count`, `field_name`, `field_value`, and more

### Atomics (`modules/std/atomic.sx`)

Opt-in import. `Atomic($T)` is a transparent wrapper over an integer/pointer-sized
`T`; the memory `Ordering` is an explicit compile-time value parameter:

```sx
#import "modules/std/atomic.sx";

counter : Atomic(i64) = .init(0);
counter.store(0, .relaxed);
n    := counter.load(.acquire);
prev := counter.fetch_add(1, .seq_cst);             // + fetch_sub/and/or/xor/min/max
old  := counter.swap(42, .acq_rel);

// compare-exchange returns ?T — null = SUCCESS; a present value is the actual
// current value on failure (for a retry loop).
got := counter.compare_exchange(old, 99, .acq_rel, .acquire);
if got == null { /* swapped */ } else { /* retry with got! */ }

fence(.seq_cst);   // standalone memory fence
```

`Ordering` = `relaxed`/`acquire`/`release`/`acq_rel`/`seq_cst`. Invalid
combinations are compile errors. The same operations run at compile time (`#run`)
under single-threaded semantics.

### Async / Concurrency (`context.io`, `modules/std/sched.sx`)

A pure-sx cooperative fiber runtime — **colorblind async**, with no function
coloring. The async API rides the `Io` capability carried implicitly in
`context`: `context.io.async` spawns a worker, `await` suspends until it
completes. The SAME code runs under the default blocking `Io` (workers run inline)
or under the fiber `Scheduler` installed as `context.io` (workers are real fibers
that interleave). A `Scheduler` drives any number of stackful fibers, each on its
own guard-paged stack:

```sx
#import "modules/std.sx";
sched :: #import "modules/std/sched.sx";

main :: () {
    s := sched.Scheduler.init();
    ps := *s;   // closures capture by value — capture a pointer to the scheduler

    // Install the fiber scheduler as `context.io`; the coordinator runs as a
    // fiber so `await` has a fiber to park.
    push .{ io = xx s } {
        ps.spawn(() => {
            a := context.io.async(() -> (i64, !) => { try context.io.sleep(30); 100 });
            b := context.io.async(() -> (i64, !) => { try context.io.sleep(10); 20  });
            c := context.io.async(() -> (i64, !) => { try context.io.sleep(20); 3   });

            sum := (a.await() or 0) + (b.await() or 0) + (c.await() or 0);  // 123
            print("sum: {}\n", sum);
        });
        ps.run();   // drive the scheduler until all fibers finish
    }
}
```

Workers complete in deadline order, not spawn or await order. The runtime offers:

- **`context.io.async(worker) -> *Future($R)`** / **`await() -> (R, !IoErr)`** /
  **`cancel()`** — the async layer over the `Io` protocol. `await` rides the `!`
  error channel; a `cancel` makes the worker abandon its body at its next suspend
  (true cancellation) and surfaces as `error.Canceled`.
- **`context.io.race(.{a = fa, b = fb, …})`** — structured first-wins over a named
  tuple of `*Future`s; returns a synthesized tagged-union of the winner, cancels
  the losers (which stop at their next suspend, so `race` returns at winner-time).
- **`context.io.sleep(ms)`** / **`context.io.now_ms()`** — timer-driven suspension
  on a virtual clock (deterministic, no real wall time).
- **`Scheduler.spawn`**, **`yield_now`**, **`suspend_self`**, **`wake`**,
  **`run`** — the raw fiber primitives + driver loop the async layer is built on.
- **`Scheduler.block_on_fd(fd, want_read)`** — suspend until a file descriptor is
  ready, backed by kqueue (darwin) or epoll (linux).

It's an M:1 model (cooperative, no preemption — so no data races between fibers
and no atomics needed across them), built on `abi(.naked)` context switching over
guarded `mmap` stacks. Currently aarch64-pinned (macOS + Linux).

### Command-line interface (`modules/std/cli.sx`)

`std.cli` builds command-line front-ends over an explicit logical argv: `os_args`
reads the real process argv, and `parse(args, commands, diag)` does subcommand
dispatch + `--flag` parsing, with named exit codes (`EX_OK`, `EX_USAGE`,
`EX_UNAVAILABLE`) and a `--json` machine-output convention.

## Cross-Compilation

```sh
sx build app.sx --target linux          # Linux x86_64 (glibc, dynamic)
sx build app.sx --target linux-musl     # Linux x86_64 (musl, static)
sx build app.sx --target macos-arm      # macOS ARM64
sx build app.sx --target windows        # Windows x86_64 (MSVC)
sx build app.sx --target windows-gnu    # Windows x86_64 (MinGW)
sx build app.sx --target wasm           # WebAssembly
```

### Self-contained builds

sx can link with a bundled toolchain instead of the host's system linker — it
supplies lld, the CRT, and libc (musl/glibc/mingw), so no `cc`/SDK needs to be
installed. The default Linux output is statically-linked musl, which runs on any
Linux.

```sh
sx build app.sx --target linux-musl --self-contained   # static, portable ELF
sx build app.sx --self-contained                       # host target, hermetic link
sx build app.sx --no-self-contained                    # force the system toolchain
```

## License

MIT
