# sx

A programming language with compile-time execution, generics, closures,
interfaces, and an LLVM backend — compiled to native code.

## At a Glance

```sx
@import "modules/std.sx";

Point :: struct {
    x, y: i32;
    magnitude :: (self: *Point) -> f32 { @sqrt(self.x * self.x + self.y * self.y); }
}

main :: () {
    p := Point{ x = 3, y = 4 };
    print("point: {}, magnitude: {}\n", p, p.magnitude());
}
```

- `name :: value` constants, `name := value` variables
- LLVM native code; `@run` / `@insert` / `@error` at compile time
- Monomorphized generics, first-class closures, interface polymorphism
- Pattern matching, C interop (`extern` / `export` / `@import c`), inline `asm`
- Colorblind async (cooperative fibers, no function coloring)
- Targets: macOS (ARM64, x86_64), Linux (x86_64, ARM64), Windows (x86_64), WebAssembly

The language contract is [specs.md](specs.md).

## Usage

```sh
sx run file.sx           # compile and run
sx build file.sx         # compile to binary
sx build file.sx -o out  # compile with output path
sx ir file.sx            # emit LLVM IR
sx lsp                   # start language server
```

```
--target <triple>   macos, linux, windows, wasm (or a full triple)
--opt <level>       none, less, default, aggressive
--cpu <name>        target CPU
-o <path>           output path
```

## Standard library guides

- [Compression, PNG, and ZIP](docs/compression.md)
- [Miniz-to-stdlib crosswalk](docs/compression-miniz-crosswalk.md)
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## Language Overview

### Types

| Type | Description |
|------|-------------|
| `i8` `i16` `i32` `i64`, `u8` `u16` `u32` `u64` | Integers (default `i64`) |
| `@int(N, .signed)` / `@int(N, .unsigned)` | The integer of width `N`, 1 to 64 — `@int(8, .signed)` is `i8` |
| `f32`, `f64` | Floats (default `f64`) |
| `bool` | `true` / `false` |
| `string` | UTF-8 `{ptr, len}` |
| `[N]T` / `[]T` | Array / slice |
| `*T` / `[*]T` | Single / many pointer |
| `?T` | Optional |
| `struct` / `enum` / `union` | Aggregates |
| `Closure(args) -> ret` | Erased callable — `closure(\|params\|_{ caps } body)` |

`[N]T` coerces to `[]T`. A `[*]T` has no length — slice it with `ptr[0..len]`.

A typed store needs a coercion. Different width with no coercion (`x : i32 = "hi"`) is an error. Same-width reinterpret (`*T → [*]T`) is allowed. `xx` / `x.(T)` is the explicit ladder: `1000.(i8)` truncates; `dog.(Speaker)` builds an interface handle over `dog`. On `any`: `try av.(i64)` / `av.(i64)` / `av.(?i64)`. `o?.(T)` maps over an optional.

Limits fold: `i64.max`, `u8.min`, `f64.inf`. See specs → Numeric Limits.

### Declarations

```sx
PI :: 3.14159;
MAX : i32 : 100;
x := 42;
y : i32 = 0;
z : i32 = ---;

m := 1_000_000;          // 0x / 0o / 0b; `_` is grouping
c : u8 = 'A';            // code point; no `char` type
cp : u32 = '\u{1F980}';
K : [4]i64 : .[11, 22, 33, 44];
N :: K[0] + K[3];        // folds
```

`::` is the only const spelling — writes through the name are errors. A float into an integer slot must be integral at comptime (`4.0` → `4`; `1.5` errors) unless `xx` / `.(i64)`. Bare builtin type names are reserved; `` `i32 `` escapes one.

### Multiple return values

`-> (A, B)` or `-> (x: A, y: B)`. A multi-return is only a return signature — a parameter or field uses a named `struct { x: A; y: B }` or a positional `.{1, 2}`. Trailing `!` is the error channel: `-> (A, B, !)`.

```sx
divmod :: (a: i64, b: i64) -> (i64, i64) { return a / b, a % b; }
q, r := divmod(17, 5);

stats :: (a: i32, b: i32) -> (sum: i32, big: bool) { return sum = a + b, big = a > b; }
c := stats(40, 2);               // c.sum, c.big

classify :: (n: i32) -> (doubled: i32, big: bool, !) { … }
d, b := classify(7) catch |e| { … };

combine :: (a: i32, b: i32) -> (sum: i32 = 0, good: bool) {
    good = a > b;
    sum = a + b;                 // named slots are locals; assigning them returns
}
```

### Named arguments and trailing blocks

Positional first, then `name = value` in any order. A block after a call is the last parameter as a closure literal: `f(args) { body }` ≡ `f(args, content = || { body })`. The last parameter takes it when it is `$F/(…) -> R` or `@BuildBlock(P)`.

```sx
scaffold(content = chat_list);
scaffold(top_bar = toolbar) { chat_list(); };
each(items) { |item| text(item.name); };
each(items) { |item|_{ pad } text(item.name, pad); };
vstack(8.0) { text("hello"); }.padded();
```

### Structs, enums, optionals

```sx
Vec3 :: struct {
    x, y, z: f32 = 0;
    length :: (self: *Vec3) -> f32 { @sqrt(self.x * self.x + self.y * self.y + self.z * self.z); }
}
v := Vec3{ x = 1, y = 2, z = 3 };
v2 := Vec3{ 1, 2, 3 };

Shape :: enum { circle: f32; rect: struct { w, h: f32; }; none; }
area :: (s: Shape) -> f32 {
    match s {
        case .circle: |r| 3.14159 * r * r;
        case .rect: |r| r.w * r.h;
        case .none: 0;
    }
}
s = .circle(2.0);                // construct; `s.circle = 2.0` is refused
s.rect.w = 9.0;                  // in-place subfield of the active variant

Perms :: enum flags { read; write; execute; }

x: ?i32 = 42;
val := x ?? 0;
forced := x?!;
if v := x { print("{}\n", v); }
name := node?.name ?? "unknown";
if n != null { take_i32(n); }    // narrowed; a bare `take_i32(n)` is an error
```

`@using` composes structs. Methods live in the body.

### Generics and closures

```sx
max :: (a: $T, b: T) -> T { if a > b then a else b; }
are_equal :: ($T: Type/Eq, a: T, b: T) -> bool { a.eq(b); }

List :: struct ($T: Type) {
    items: []T = .[];
    cap: i64 = 0;
    append :: (list: *List(T), item: T, alloc: Allocator = context.allocator,
               site: @SourceSite = @caller) { … }
    len :: (self: *List(T)) -> i64 @get => self.items.len;
}

apply :: (f: $F/(i64) -> i64, x: i64) -> i64 { f(x) }

make_adder :: (n: i64) -> $F/(i64) -> i64 { return |x|_{ n } x + n; }
add5 := make_adder(5);

boxed :: (n: i64) -> Closure(i64) -> i64 { return closure(|x|_{ n } x + n); }
```

A `|…|` literal IS its env struct. The body sees its parameters, its locals, and module-level names; enclosing locals only through `_{ … }`, by value. Copies fork; `*$F/(…) -> R` shares. `Closure` is the erased `{ fn_ptr, env }`: function pointers and empty-env literals promote to it with a null env, and a capturing one gets there through `closure(f, alloc = context.allocator)`, which `free(cl)` / `free(cl, alloc)` releases. A nominal is callable through `impl (i64) -> i64 for T { call :: … }`.

### Constraints and interfaces

```sx
Drawable :: interface {
    draw :: (self: *Self, x: i32, y: i32);
}
impl Drawable for Circle {
    draw :: (self: *Circle, x: i32, y: i32) { … }
}
shape : Drawable = my_circle;
shape.draw(10, 20);
```

- `constraint`: bounds only, no runtime value.
- `interface`: an erased `{ctx, type_id, vtable}` handle, dynamic dispatch. `type_of(shape)` is the concrete type.
- A handle borrows its referent: copies alias it, nothing owns it, and `free` refuses one.
- An interface-typed target coerces an lvalue in place, a `*T` to its pointee, or copies an existing handle; a concrete rvalue is a compile error. `a.make(v)` writes the value into allocated storage.
- `Self` past the receiver belongs to a `constraint` — bind through `$T/Eq`.

### Open Sets

Members join by declaring themselves. No allocator, no registry.

```sx
View :: @OpenSet(.{ max = 256 }) { render :: (self: *Self) -> string; }
Label :: @OpenVariant(View) {
    text: string = "";
    render :: (self: *Label) -> string => self.text;
}
v: View = Label{ text = "hi" };
v.render();
match v { case Label: |l| { print("{}\n", l.text); } else: { } }
```

`max` is a payload ceiling. `$V/View` is the membership bound.

### Match and control

```sx
match shape {
    case .circle: |r| print("radius: {}\n", r);
    case .none: print("nothing\n");
}
match av {
    case i64: |v| print("int {}\n", v);
    case []u8: |b| print("{} bytes\n", b.len);
    else: print("{}\n", @typeName(type_of(av)));
}

if 0 <= x <= 100 { … }
while i < 10 { i += 1; }
for val in items { print("{}\n", val); }
for val, idx in items, 0.. { print("[{}] = {}\n", idx, val); }
for i in 0<..<n { }              // 1 .. n-1
defer close(f);
a, b = b, a;
```

### Compile time and C

```sx
FIBONACCI_10 :: @run fib(10);
@insert @run generate_lookup_table();

libc :: @library "c";
printf :: (fmt: [:0]u8, args: ..any) -> i32 extern libc;
abs       :: (x: i32) -> i32 extern;
sx_square :: (x: i32) -> i32 export { x * x }
__stdinp  : *void extern;

@import c {
    @include "vendors/mylib/api.h";
    @source "vendors/mylib/impl.c";
};
```

### Inline assembly

`asm { template, [name] "constraint" -> Type | = expr, clobbers(.…) }`. Zero outputs → `void` (`volatile`); one → that type; N → multi-return `-> (T0, T1, …)`. See [docs/inline-assembly.md](docs/inline-assembly.md).

```sx
add :: (a: i64, b: i64) -> i64 {
    return asm { "add %[out], %[a], %[b]", [out] "=r" -> i64, [a] "r" = a, [b] "r" = b };
}
```

### Modules

```sx
@import "modules/std.sx";              // flat — bare names
math :: @import "modules/math";        // namespaced — math.name
r :: @import "rich.sx";
helper :: r.helper;                    // re-export
private helper :: (x: i64) -> i64 { x * 2 }
Box :: struct { private secret: i64 = 0; }
```

Visibility does not chain. Two flat imports of the same name are ambiguous; an own declaration wins. `private` is file-local on a top-level identifier or a struct field.

`@import "modules/std.sx"` is the prelude (`print`, `List`, `Context`, …) plus `mem`, `fs`, `process`, `socket`, `json`, `cli`, `hash`, `xml`, `log`, `test`.

### Implicit Context

```sx
main :: () {
    list : List(i64) = .{};
    list.append(42);
    list.deinit();
}
push .{ allocator = my_arena } { do_work(); }

@context_extend logger: ?*Logger = null;
push .{ logger = *my_logger } { serve(); }
```

`Context` is assembled from every `@context_extend`. Defaults are required and comptime.

## Quick Sort Example

```sx
@import "modules/std.sx";

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
}
```

## Runtime Reflection

`Type` is a runtime tag (`type_of(x)`). `size_of` / `type_info` / field tables are emitted only if used. `any` is `{tag, pointer}` — a borrow of the referent. `is` classifies a type or a value's type — `x is int`, `t is unsigned`, `t is struct`, `h is Drawable` — while `==` / `type_eq` ask identity.

```sx
describe :: (tp: Type) {
    print("{} (size {})\n", @typeName(tp), size_of(tp));
    match type_info(tp) {
        case .struct: |si| { for i, f in si.fields { print("  +{} {}\n", f.offset, f.name); } }
        else: {}
    }
}
describe(type_of(av));
print_any(pkt);   // walk with struct_field_value / any_element — no copies
```

`xx av` is an unchecked load. `==` on `any` is an error — unbox or compare `type_of`.

## Standard Library

`modules/std.sx`: `print` / `out`, `List($T)`, string helpers, the `Allocator` interface / `GPA` / `Arena`, `sqrt` / `sin` / `cos`, `type_of` / `size_of` / field reflection.

**Atomics** — `@import "modules/std/atomic.sx"`. `Atomic($T)` with `Ordering` (`.relaxed` … `.seq_cst`). `compare_exchange` returns `?T` (`null` = success).

**Volatile** — `@volatile_load(T, addr)` / `@volatile_store(T, addr, v)` from `core.sx`. Not atomic.

**C-variadic** — a trailing `..` on an `abi(.c)` / `extern` / `export` signature. Read with `@VaList` / `@va_start` / `@va_arg` / `@va_end` / `@va_copy`. Promotions apply (`f32` → `f64`). See specs.

**Async** — `context.io.async` / `await` / `sleep`. Default `Io` is blocking. A `Scheduler` as `context.io` is fibers (aarch64, M:1):

```sx
@import "modules/std.sx";
sched :: @import "modules/std/sched.sx";

main :: () {
    s := sched.Scheduler.init();
    push .{ io = s } {
        s.spawn(|| {
            a := context.io.async(|| -> (i64, !) { try context.io.sleep(10); 1 });
            print("{}\n", a.await() ?? 0);
        });
        s.run();
    }
}
```

`await` parks the current fiber, so the coordinator is `s.spawn`ed.

**CLI** — `modules/std/cli.sx`: `os_args`, `parse`, `EX_OK` / `EX_USAGE`.

## Cross-Compilation

```sh
sx build app.sx --target linux          # Linux x86_64 (glibc)
sx build app.sx --target linux-musl     # Linux x86_64 (musl, static)
sx build app.sx --target macos-arm      # macOS ARM64
sx build app.sx --target windows        # Windows x86_64 (MSVC)
sx build app.sx --target windows-gnu    # Windows x86_64 (MinGW)
sx build app.sx --target wasm           # WebAssembly

sx build app.sx --target linux-musl --self-contained
sx build app.sx --self-contained
sx build app.sx --no-self-contained
```

`--self-contained` links with a bundled toolchain (lld, CRT, libc). Default Linux is static musl.

## License

MIT
