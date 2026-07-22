# sx language specification

## 1. Lexical Structure

### Comments
Line comments start with `//` and extend to end of line.
```sx
// this is a comment
```

### Identifiers
- Lowercase or mixed-case for variables, functions: `x`, `compute`, `main`
- UPPER_SNAKE_CASE for constants: `SOME_INT`, `SOME_STR`
- PascalCase for types: `Foo`

#### Reserved type names

A spelling that names a builtin type — the arbitrary-width integers `i1`..`i64` /
`u1`..`u64`, plus `bool`, `string`, `cstring`, `void`, `f32`, `f64`, `usize`, `isize`, `any` —
is reserved. A bare reserved spelling is rejected at **value-binding and
declaration-name sites**: a value binding (`:=` / typed local / parameter), a
`::` **constant** or **function** declaration, an `impl` method **definition**,
and a `::` **type** declaration (`struct` / `enum` / `union` / `error` / type
alias / `protocol` / runtime class / ufcs alias / namespaced import). A
value-spelled-as-type parses as a *type*, not a value, so its address-of /
autoref paths would mis-lower; a type / const / function / method name spelled as
a builtin would shadow the builtin. The exemptions are the backtick escape
(below), `#import c` extern decls, and **member-name positions** (next) — it is
**not** rejected at every place a name appears.

**Member-name positions are exempt.** A struct **field** name, a union **tag**
name, and a protocol **method-signature** name may be a bare reserved spelling.
These sit in a member slot (`name: T` / `name :: (…)`) and are reached only via
`obj.name` (or dispatched by string), so they are never type-classified and never
mis-lower. The backtick form is optional there and names the same member — `obj.i2`
and `` obj.`i2 `` both resolve. The exemption covers member *signatures* only: an
`impl` method **definition** is a real function (a declaration site, not a member
slot), so a reserved-spelled impl method still needs the backtick
(`` `i2 :: (self) ``), exactly like a free function. See `examples/0158`.

**Statement keywords are member names too (issue 0345, decided 2026-07-22).**
Every keyword except `inline` — `if`, `push`, `while`, `for`, `case`, `return`,
`f32`, `f64`, `try`, `defer`, … — may bare-name a struct **field**, a struct
**method or constant**, and a protocol **method**, and is reachable through
every member position: literal init (`.{ push = 1, if = 2 }`), field access
(`q.push(…)`, `q.for`), and optional chaining (`o?.if`). Declaration position
is unambiguous — struct, protocol, and `impl` bodies hold only declarations —
and access is dot-disambiguated. Unlike the type-spelling rule above, keyword
names are bare-legal in `impl` method **definitions** as well: a keyword-named
protocol method must be implementable without ceremony, and a keyword has no
builtin to shadow. The one exception is **`inline`**, which stays
backtick-only (`` `inline ``); a bare `inline` in member position rejects with
a targeted escape-hint. In a struct literal, a keyword field name takes only
the `name = value` form — without the `=`, the token reads as a positional
expression head, so `.{ if x > 1 then 10 else 20, 2 }` stays an if-expression
element. Value-binding positions (locals, params, function names) are
unchanged: keywords stay rejected there.

**`Tuple(` and `Closure(` are reserved in expression head position.** The
type constructors `Tuple(...)` and `Closure(...) -> R` parse as TYPE
expressions wherever the exact token pair `Tuple`+`(` / `Closure`+`(`
opens a primary expression (this is what makes `NT :: Tuple(a: i64)` and
`CB :: Closure(i32) -> i32` aliases work). Declaring a function or value
named `Tuple`/`Closure` is permitted, but CALLING it in head position is
hijacked by the type parse; use the backtick escape (`` `Closure(5) ``)
to call such a value. Prefer different names.

The bare member-name exemption applies only to the **identifier-classified**
reserved spellings — `i1`..`i64`, `u1`..`u64`, `bool`, `string`, `cstring`, `void`,
`usize`, `isize`, `any` — which all lex as ordinary identifiers. The two
**keyword-classified** reserved spellings, `f32` and `f64`, are lexer keywords, and
member-name slots require an identifier token; a bare `f32` / `f64` is therefore
rejected at parse (`expected field name in struct`) even in a member position. Use
the backtick there too — `` struct { `f32: i64; } `` / `` union { `f64: … } `` /
`` protocol { `f32 :: (self: *Self) -> i64; } `` work as field / tag / method names.

```sx
i2 := 2.5;                          // ERROR: 'i2' is a reserved type name and cannot be used as an identifier
i2 :: 5;                            // ERROR — a `::` constant name is a binding site too
i2 :: (n: i64) -> i64 { n }         // ERROR — so is a function name
i2 :: struct { x: i64; }            // ERROR — and a type-declaration name
```

(There is no exception for the stdlib: a reserved type name is reserved
everywhere. `string` and `Vector` are language primitives — the compiler resolves
them by name, they are declared nowhere, and they cannot be re-bound.)

#### Backtick raw-identifier escape

A leading backtick makes the following token a **raw identifier**: `` `name `` is
the **literal identifier** `name` — "treat this token as a plain identifier, never
the reserved keyword/type." The backtick is not part of the name's text (the text
is `name`), and the escape is usable in **every position**: value, declaration,
**and type**. It is the only way handwritten sx can spell a reserved name.

```sx
`i2 := 2.5;            // OK — identifier "i2", distinct from the i2 type
print("{}\n", `i2);    // 2.5  (backtick reference)
print("{}\n", i2);     // 2.5  (bare reference in value position → the binding)
x : i2 = 3;            // bare `i2` in TYPE position is still the i2 int type
```

**Type position.** A backtick in type position is the literal name used as a type
reference: it resolves to a `` `i2 ``-declared type (struct / enum / union / type
alias / …), and never the builtin. A bare `i2` in type position stays the builtin
int; a backtick name with no matching declaration is a normal `unknown type 'i2'`
error. A raw type reference flows through the **same continuations** as a bare type
name, so it parameterizes a reserved-spelled generic template (`` `i2(i64) ``) and
composes under the pointer / optional / slice wrappers (`` *`i2 ``, `` ?`i2 ``).

```sx
`i2 :: struct($T: Type) { x: $T; }   // generic template with a reserved-spelled name
v : `i2(i64) = ---;                  // parameterized raw type reference
v.x = 7;
p : *`i2(i64) = *v;                  // wrappers compose over a raw type
x : i2 = 3;                          // bare `i2` is still the 2-bit signed int
```

**Declaration position.** A *bare* reserved-name declaration of every kind still
errors (a value binding, a `::` constant / function, and a `::` type / alias /
protocol / runtime-class / ufcs / namespaced-import name); the backtick form is
exempt. The escape works in **every identifier position** — local, global,
parameter, struct field, union tag, function name, type/alias/import name, a later
reference, and every control-flow / capture / binding form (destructure name,
`if` / `while` optional binding, `for` capture and index, match-arm capture, and a
`catch` / `onfail` tag binding):

```sx
`u8 := 100;                       // global
`i2 :: 2.5;                       // constant declaration
`i2 : i64 : 5;                    // typed constant declaration
`u8 :: (`i1: i64) -> i64 { `i1 }  // function name + parameter
P :: struct { `i2: f64; }         // struct field
H :: struct { `i2 :: 5; }         // struct-body constant (untyped + `: T :` typed)
M :: union { `i1: i32; }          // union tag
`u16 :: enum { A; B; }            // type-declaration name
`u8, rest := pair();              // destructure name
if `i16 := maybe() { }            // optional binding
for xs, 0.. (`bool, `u16) { }     // for captures
x catch (`i2) { }                   // catch tag binding
```

In the **member-name positions** among these — struct field, union tag, and
protocol method signature — the backtick is *optional*: the bare reserved
spelling is already legal there (see "Member-name positions are exempt" above).
Everywhere else (value bindings and declaration names, including an `impl` method
definition) the backtick is *required* to spell a reserved name.

A reserved-spelled **function** is bare-callable: `` `i2 :: (n: i64) -> i64 { … } ``
can be invoked as `i2(10)` (the bare callee spelling parses as a type but resolves
to the function when one of that name is in scope; `TypeName(val)` is not a cast).

A backtick may also escape a keyword spelling (`` `for ``, `` `struct ``), yielding
an identifier with that text.

**`#import c` exemption.** Extern declarations synthesized by an `#import c { … }`
block are treated as raw automatically: a generated C parameter or function name
that collides with a reserved type name (e.g. `i1`, `i2`) imports unedited, with no
backticks and no reserved-name error, and an extern reserved-name function is
bare-callable by its C name. The exemption is scoped to the extern decls — it does
not make an extern `i2` usable as the sx `i2` type, nor relax the rule for
hand-written sx code.

### Literals

| Kind      | Examples            | Type    |
|-----------|---------------------|---------|
| Integer   | `0`, `42`, `0xFF`, `0o755`, `0b1010` | `i64`   |
| Float     | `0.3`, `0.9`        | `f32`   |
| String    | `"Hello"`, `"z: {z}"` | `string` (may span multiple lines) |
| Heredoc String | `#string END`...`END` | `string` |
| Boolean   | `true`, `false`     | `bool`  |
| Enum      | `.variant1`         | inferred from context |
| Undefined | `---`               | context-dependent |

**Integer bases.** Integers are written in four bases: decimal (`1000`), hex
`0x`/`0X` (`0xFF`), octal `0o`/`0O` (`0o755` == 493), and binary `0b`/`0B`
(`0b1010`). Any integer base — and a float's fraction — may carry `_` digit
separators as pure visual grouping; they are stripped before the value is
computed, so `0xFF_FF` == `0xFFFF`, `1_000` == `1000`, and `3.14_159` ==
`3.14159`. Separators are permissive — repeated (`1__0`) and trailing (`1000_`)
underscores are accepted and stripped. A leading `_` before the first digit is
not a number (it lexes as an identifier). There is no scientific-exponent
(`1e10`) float form.

String literals support escape sequences (`\n`, `\t`, `\r`, `\\`, `\"`, `\0`) and may span multiple lines directly:
```sx
shader_src := "#version 330 core
void main() {
    gl_Position = vec4(0.0);
}
";
```

**Heredoc strings** use `#string DELIMITER` syntax (inspired by Jai). Content is completely raw — no escape processing. The delimiter is any identifier. Content starts after the newline following the delimiter and ends when the delimiter appears at column 0 of a line.
```sx
vert_src := #string GLSL
#version 330 core
void main() {
    gl_Position = vec4(aPos, 1.0);
}
GLSL;
```

### Keywords
`if`, `else`, `then`, `while`, `for`, `break`, `continue`, `true`, `false`, `enum`, `struct`, `union`, `case`, `return`, `defer`, `push`, `ufcs`, `in`, `xx`, `and`, `or`, `raise`, `try`, `catch`, `onfail`, `error`, `private`

> Note: `enum` is used for both payload-less and payload-bearing sum types (tagged unions). `union` is reserved for C-style untagged unions (memory overlays).

> Note: `raise`, `try`, `catch`, `onfail`, and `error` are the error-handling keywords. `or` is reused as the failable-fallback / chain operator. See [§12 Error Handling](#12-error-handling).

> Note: `private` is the module-scope declaration visibility modifier — see
> [§9 Module-Scope Visibility](#9-modules--imports). `` `private `` (backtick
> raw identifier) and the `.private` member spelling remain legal.

### Operators

| Operator | Meaning          |
|----------|------------------|
| `+`      | addition         |
| `-`      | subtraction / negation |
| `*`      | multiplication   |
| `/`      | division         |
| `==`     | equality         |
| `!=`     | inequality       |
| `<`      | less than        |
| `>`      | greater than     |
| `<=`     | less or equal    |
| `>=`     | greater or equal |
| `&`      | bitwise AND      |
| `\|`     | bitwise OR       |
| `^`      | bitwise XOR      |
| `~`      | bitwise NOT (unary) |
| `<<`     | left shift       |
| `>>`     | right shift (arithmetic for signed, logical for unsigned) |
| `and`    | logical AND (short-circuit) |
| `or`     | logical OR (short-circuit)  |
| `in`     | membership test (tuples)    |
| `\|>`    | pipe (function application) |
| `+=`     | add-assign       |
| `-=`     | sub-assign       |
| `*=`     | mul-assign       |
| `/=`     | div-assign       |
| `&=`     | bitwise AND assign |
| `\|=`    | bitwise OR assign  |
| `^=`     | bitwise XOR assign |
| `<<=`    | left shift assign  |
| `>>=`    | right shift assign |

**Float comparison and NaN.** Float `==` is *ordered* and `!=` is *unordered*,
matching IEEE 754: `==` is false whenever either operand is NaN (`nan == x` is
false for every `x`, including `nan`), and `!=` is true whenever either operand
is NaN (`nan != x` is true for every `x`, including `nan`). So `!=` is the exact
complement of `==` for all float inputs, and the canonical NaN test `x != x` is
true exactly when `x` is NaN. The ordered relations `<`, `<=`, `>`, `>=` are all
false when either operand is NaN. For all non-NaN operands these reduce to the
ordinary comparisons. Native codegen and the comptime interpreter agree on this.

### Delimiters and Punctuation

| Token  | Meaning                              |
|--------|--------------------------------------|
| `::`   | constant binding / definition        |
| `:=`   | variable binding (mutable, inferred) |
| `:`    | type annotation                      |
| `=`    | assignment (in typed var decl)       |
| `;`    | statement terminator                 |
| `,`    | separator (trailing commas allowed)   |
| `.`    | field access / enum literal prefix   |
| `->`   | return type annotation               |
| `=>`   | lambda arrow                         |
| `$`    | generic type parameter introduction   |
| `---`  | undefined value                      |
| `()`   | grouping / params                    |
| `{}`   | blocks / bodies                      |

---

## 2. Type System

### Primitive Types
- `i1`..`i64` — signed integers (1 to 64 bits). `i64` is the default for integer literals.
- `u1`..`u64` — unsigned integers (1 to 64 bits).
- `f32` — 32-bit floating point
- `f64` — 64-bit floating point
- `bool` — boolean (`true` / `false`)
- `string` — string of characters
- `any` — type-erased BORROW, represented as `{ data: pointer, type_id: i64 }` — the data word (word 0) is the ADDRESS of the value, the type_id word (word 1) its runtime type tag (Odin `Raw_Any` `{data, id}`, same order; the `{pointer, type_id}` prefix is shared with protocol values), never a copy of its bits. Used for variadic arguments, runtime type dispatch, and reflection views. Boxing an addressable lvalue points at its storage (zero copy — mutations of the source stay visible through a live view); boxing an rvalue materializes a temporary scoped to the enclosing frame. An `any` is valid only while the referenced value lives: do not store an `any` beyond its referent. Unboxing via `xx` is an UNCHECKED typed load through the view — the target must be the boxed type (`data` covers exactly `size_of(tag)` bytes; a wider target overreads); the checked forms are the postfix assertions (`av.(T)` / `try av.(T)` / `av.(?T)`). `==`/`!=` are NOT defined on `any` (compile error): unbox first, or compare `type_of(av)`.
- `Type` — compile-time type value. At runtime, represented as an `i64` type tag (same tag space as `any`).

### Char Literals

A `'...'` char literal decodes to its integer code point and behaves exactly
like an integer literal — default type `i64`, coerces to any int/float type in
context. There is no `char` type; storage is whatever the surrounding context
demands (`u8`, `u32`, `i64`, …). The body is a single Unicode scalar: either
one raw source character (UTF-8 decoded, so `'é'` and `'🦀'` work), or one
escape:

| Escape | Value |
|--------|-------|
| `\n` `\t` `\r` `\\` `\'` `\0` | the obvious control / punctuator |
| `\xNN` | one byte, `NN` is 1–2 hex digits (0x00–0xFF) |
| `\u{XXXX}` | a Unicode scalar, 1–6 hex digits, max `U+10FFFF` (surrogates `U+D800`–`U+DFFF` rejected) |

`''` (empty), `'ab'` (two scalars), a malformed escape, or an overlong
`\u{...}` value is a parse error. A char literal whose code point is too wide
for its target type is a compile error (not a silent truncate) — including in a
typed module-level `::` const: the diagnostic names it as a char literal and
suggests a wider storage type (`u32` holds any Unicode scalar), rather than
truncation.

Because a char literal *is* an integer code point, it is accepted anywhere an
integer literal is: as an explicit enum value (`esc :: '\x1b'` → tag 27), as a
compile-time value argument to a parametrized type (`Buf('A')` binds `$N = 65`),
as an array dimension (`['A']u8`), and in `match` / `#if` const comparisons.

### Numeric Limits

A field-like access on a builtin **integer** type name folds, at compile time, to
that type's smallest/largest representable value:

```sx
maxS64 := i64.max;   // 9223372036854775807
minS32 := i32.min;   // -2147483648
maxU8  := u8.max;    // 255
minU8  := u8.min;    // 0
m3     := i3.max;    // 3   (arbitrary width)
n      := u64.max;   // 18446744073709551615 (all-ones)
```

- **Receiver.** Any builtin integer type: every signed width `i1`..`i64`, every
  unsigned width `u1`..`u64` (arbitrary 1–64 bit widths, not only the
  power-of-two ones), plus `usize`/`isize` (target-width — `u64`/`i64` on a
  64-bit host).
- **Value.** Pure `(width, signedness)` arithmetic — never a per-name table:
  - `sN`: `min = -(2^(N-1))`, `max = 2^(N-1) - 1`
  - `uN`: `min = 0`, `max = 2^N - 1`
- **Result type.** The constant has the **queried** type: `i3.max` is an `i3`,
  `u64.max` is a `u64`. So it is usable anywhere a constant of that type is
  legal — initializers, `::` / `:=` bindings, and larger expressions — and in
  array-dimension / count position via the compile-time integer path
  (`[u8.max]T` is a 255-element array; `[i16.max]T` a 32767-element one). A
  count that does not fit (`[u64.max]T`) is rejected as an oversized dimension.
- **Representation note.** `u64.max` / `usize.max` is the all-ones 64-bit value
  (`18446744073709551615`), which exceeds the signed `i64` range used for
  integer constants; it is stored as that exact bit pattern carrying the `u64`
  type (it reinterprets to `-1` as an `i64`). It cannot be written as a decimal
  literal. The default integer formatter is signedness-aware:
  `print("{}", u64.max)` renders the full unsigned decimal
  `18446744073709551615` (and any unsigned value across all 64 bits), while a
  signed value — including `i64.min` — prints with all its digits. A bit
  reinterpret (`union { u: u64; s: i64 }`) is still a valid way to inspect the
  raw bits, but is no longer needed merely to print the value.
- **Non-numeric receivers.** `.min` / `.max` on a non-numeric type (`bool`,
  `string`, a pointer, a `struct`, `void`, an `enum`) is a compile error, never
  a silent value.

The **float** types `f32` and `f64` expose the same `.min` / `.max` plus a set of
float-only accessors. Each folds, at compile time, to a constant of the queried
float type (the same `lowerNumericLimit` intercept, via `builder.constFloat`):

```sx
hi  := f64.max;           // largest finite double
lo  := f64.min;           // most-NEGATIVE finite = -max  (NOT C's DBL_MIN)
eps := f64.epsilon;       // ULP of 1.0  (f64 = 2^-52, f32 = 2^-23)
mp  := f64.min_positive;  // smallest positive NORMAL  (= C DBL_MIN / Rust MIN_POSITIVE)
tm  := f64.true_min;      // smallest positive SUBNORMAL (next value above 0.0)
pin := f64.inf;           // +infinity
qn  := f64.nan;           // a quiet NaN
```

- **Receiver.** `f32` or `f64`.
- **Shared with integers.** `.min` / `.max` are valid on BOTH integer and float
  types. `.min` is the most-NEGATIVE finite value, i.e. `-max` — consistent with
  the integer `.min`, and deliberately **NOT** C's `DBL_MIN`/`FLT_MIN` (which is
  the smallest positive normal; that is `.min_positive` here).
- **Float-only accessors.**
  - `.epsilon` — the ULP of `1.0`: the gap between `1.0` and the next
    representable value (`f64 = 2^-52 ≈ 2.22e-16`, `f32 = 2^-23`). This is the
    **machine epsilon** used for relative-tolerance comparisons, **NOT** C#'s
    `Double.Epsilon` (which is the smallest denormal — that is `.true_min` here).
    Defining property: `1.0 + epsilon != 1.0` while `1.0 + epsilon/2.0 == 1.0`.
  - `.min_positive` — the smallest positive **NORMAL** value (`f64 = 2^-1022`,
    `f32 = 2^-126`). Equals C's `DBL_MIN` / Rust's `MIN_POSITIVE`.
  - `.true_min` — the smallest positive **SUBNORMAL**: the next value above `0.0`
    (`f64` bits `0x0000000000000001 = 2^-1074`, `f32` bits `0x00000001 = 2^-149`).
    Named `true_min` (after Zig's `floatTrueMin`) to avoid the Java/Go/JS
    `MIN_VALUE` footgun, where a bare `MIN_VALUE` names the smallest *subnormal*
    yet reads like the most-negative value.
    - **FTZ/DAZ caveat.** Subnormals are exactly the values that vanish under
      flush-to-zero (FTZ) / denormals-are-zero (DAZ) CPU modes. If such a mode is
      active, a loaded `.true_min` can flush to `0.0` on the **first arithmetic
      operation** that touches it. The folded constant always carries the exact
      subnormal bit pattern; read or store it through a bit reinterpret *before*
      any arithmetic if you need the true value to survive. Numerical-library
      authors who toggle FTZ/DAZ should not be surprised when `true_min * 1.0`
      reads back as `0.0`.
  - `.inf` — positive infinity (`inf > max`).
  - `.nan` — a quiet NaN. The exact mantissa bits are not pinned; the only
    guaranteed property is that it is unequal to everything, itself included
    (`nan != nan` is `true` — native float `!=` lowers unordered, issue 0091).
- **Float-only on an integer is an error.** `.epsilon` / `.min_positive` /
  `.true_min` / `.inf` / `.nan` applied to an integer type (`i32.epsilon`,
  `u8.inf`, `i64.true_min`) is a clean compile error — integer types expose only
  `.min` / `.max`.
- **Pinning the values.** The lexer has no exponent notation and the default
  float formatter is crude (issue 0090), so float limits can be asserted neither
  by literal comparison nor by printing. Reinterpret the bits through an untagged
  union (`union { f: f64; bits: u64 }`) and compare against the exact IEEE-754
  pattern — `f64.max = 0x7FEFFFFFFFFFFFFF`, `min = 0xFFEFFFFFFFFFFFFF`,
  `epsilon = 0x3CB0000000000000`, `min_positive = 0x0010000000000000`,
  `true_min = 0x0000000000000001`, `inf = 0x7FF0000000000000`; the `f32` set is
  `0x7F7FFFFF` / `0xFF7FFFFF` / `0x34000000` / `0x00800000` / `0x00000001` /
  `0x7F800000`.
- **Type receiver vs. a shadowing value binding.** A numeric-limit access folds
  only when the receiver is a builtin numeric **type name** (`f64.epsilon`,
  `i32.max`, `u8.max`). A backtick raw identifier that binds a *value* whose
  spelling shadows a type name (F0.6) is an ordinary value: `` `f64.epsilon ``
  reads that value's `epsilon` field — it does **not** fold to the limit. This
  holds for **every** value-binding kind — a `` `f64 := … `` local, a module-scope
  global, or a `` `f64 :: … `` module constant — so the fold can never silently
  hijack a raw value, whatever its scope. The two never collide: a bare builtin
  name in expression position is always a type, and only the raw `` `…` `` spelling
  can bind a value under it. The same rule governs the compile-time **narrowing
  and count** contexts: a raw value-shadow field read is an ordinary *runtime*
  read there too — never a compile-time numeric-limit leaf — so `` `f64.epsilon ``
  narrowing into an integer binding truncates like any runtime float (its field
  value, not the limit), and `` `i8.max `` used as an array dimension is rejected
  as a non-constant count rather than folding to the builtin `127`.

### Enum Types
User-defined sum types with named variants. Variants may optionally carry typed data (tagged unions). Internally, payload-less enums are represented as `i64` (variant index). Enums with payloads are represented as `{ i64, [max_payload_size x i8] }` (tag + data).

#### Declaration
```sx
// Payload-less enum
Color :: enum {
  red;
  green;
  blue;
}

// Enum with payloads (tagged union)
Shape :: enum {
    circle: f32;    // typed variant
    rect: i32;      // typed variant
    none;           // void variant
}
```
Variants are referenced with dot-prefix syntax: `.variant1`

#### Construction
```sx
c := Color.red;                  // payload-less
s :Shape = .circle(3.14);       // inferred from context
s = .none;                       // void variant
s = Shape.rect(42);              // explicit prefix
```

#### Payload Access
```sx
r := s.circle;   // load payload as f32 (undefined behavior if wrong variant active)
```

#### Setting a Variant
A variant is set by construction — `s = .rect(payload)` — which writes both the
tag and the payload together. Direct member assignment to a variant
(`s.rect = payload`) is **rejected at compile time**: it would store the payload
but not the tag, leaving the two desynced so a later `match` takes the wrong arm.
Mutating a sub-field of the *active* variant's payload in place is allowed
(`s.rect.w = 9.0`).

#### Pattern Matching
```sx
if s == {
    case .circle: print("circle\n");
    case .rect: print("rect\n");
    case .none: print("none\n");
}
```

#### Payload Capture
Match arms can capture the variant's payload into a local variable:
```sx
if s == {
    case .circle: (radius) { print("radius: {}\n", radius); }
    case .rect: (size) => print("size: {}\n", size);
}
```
The `(name)` after the colon binds the payload. Two forms:
- Block: `case .variant: (name) { body }`
- Short: `case .variant: (name) => expr;`

#### Enum Interpolation
Payload-less enums print as `.variant`. Enums with payloads print as `.variant(value)` or `<TypeName tag=N>`:
```sx
print("{}", s);  // .circle(3.140000)
```

### Union Types (Untagged)
C-style untagged unions for zero-cost memory overlays (type punning). All fields share the same memory — no tag, no runtime overhead. The LLVM representation is `[max_field_size x i8]`.

#### Declaration
```sx
Overlay :: union {
    f: f32;
    i: i32;
}
```
All fields must have types (unlike enums, which may have void variants).

#### Anonymous Struct Fields (Member Promotion)
Anonymous `struct` fields inside a union have their members promoted to the union namespace:
```sx
Vec2 :: union {
    data: [2]f32;
    struct { x, y: f32; };
}
```
Access promoted members directly: `v.x`, `v.y` — these are zero-cost GEPs into the same underlying memory as `v.data[0]`, `v.data[1]`.

#### Initialization
A union may be initialized either with `---` (undefined) then assigned
per-field, or with a struct literal that sets a **single arm**:
```sx
o :Overlay = ---;            // undefined, then set a member
o.f = 3.14;
print("{}\n", o.i);          // reinterpret bits as i32

p :Overlay = .{ f = 3.14 };  // equivalent single-member literal
```
Because a union's members overlay the same storage, a literal may name **only
one member** — or, for a union with an anonymous-struct arm, several members of
the *same* arm (they do not overlap each other):
```sx
v :Vec2 = .{ x = 1.0, y = 2.0 };   // OK — both belong to the { x, y } arm
```
Naming two overlapping members (`.{ f = 3.14, i = 7 }`) or members from
different arms (`.{ data = ..., x = ... }`) is a compile error — the literal
would otherwise silently let a later store clobber an earlier one. An empty
`.{}` yields an undefined union (same as `---`). A positional union literal
(`.{ 3.14 }`) is rejected as ambiguous.

#### Restrictions
- Pattern matching (`if x == { case ... }`) is not supported on unions.
- Unions cannot be printed directly via `print("{}", union_val)` — access individual fields instead.

### Struct Types
User-defined product types with named fields.
```sx
Vec4 :: struct {
  x, y, z, w: f32;
}
```
Fields are declared as `name1, name2: type;` (comma-separated names sharing a type, semicolon-terminated).

#### Field Defaults
Fields may have default values. Fields without an explicit default have a zero-value default. `---` marks a field as explicitly undefined.
```sx
Foo :: struct {
  a : u2;          // default is 0
  b : u8 = 42;     // default is 42
  c : u8 = ---;    // default is undefined
}
```

#### Struct Literals
```sx
// Positional (with type annotation — type inferred from annotation)
v1 : Vec4 = .{ 1, 2, 3, 0 };

// Positional (with type prefix)
v2 := Vec4.{ 4, 1, 1, 3 };

// Named fields (any order)
v3 := Vec4.{ w=0, x=2, y=3, z=4 };

// Mixed named + shorthand (bare identifier = field name matches variable name)
z := 5.0;
w := 6.0;
v4 := Vec4.{ y=3, x=9, w, z };

// Trailing commas are allowed in all comma-separated lists
v5 := Vec4.{
    x = 1.0,
    y = 2.0,
    z = 3.0,
    w = 4.0,
};
```

A named field must name a **declared field** of the struct. An explicit
`name = expr` that names no field is a compile error (`field 'X' not found on
type 'T'`) — it is never silently dropped, so a typo or a field removed by an
`inline if OS` branch is caught. (Bare-identifier shorthand that happens to match
no field is instead read as a *positional* element, not an error.)

#### Anonymous Structs

An **untyped** `.{ … }` literal — no annotation, no type prefix, no target —
self-types as an *anonymous structural struct*: named elements become fields;
positional elements get index names (`"0"`, `"1"`, …) readable via `.N` or a
comptime `[i]` index; `.{x}` shorthand is a NAMED field, `.{ (x) }` is the
positional escape; mixing named and positional elements is an error. Inline
anonymous type **annotations** (`a : struct { x: i64; }`, `u : union { … }`,
`e : enum { S: T; … }`) produce the same kind of type, in any type position —
including a function's return type (`make :: () -> struct { x: i64; } {
.{ x = 3 } }`; a bodyless `F :: () -> struct { … };` stays a function-type
alias).

Anonymous type identity is by **shape**, never by name: two anonymous types
with the same canonical field sequence (names + types, in order) are the SAME
type — across literal and annotation sites — and differently-shaped ones are
always distinct types (issue 0294):

```sx
a : struct { x: i64; } = .{ x = 1 };
b : struct { y: f64; } = .{ y = 2.5 };   // distinct type from a's — fine
type_eq(type_of(a), type_of(.{ x = 3 }))  // true — same shape, same type
```

#### Field Access and Assignment
```sx
v1.x        // read field x of struct v1
v1.x = 3.0; // assign to field x of struct v1
```

#### Struct Value Equality

`==` and `!=` on two struct values are **field-wise**: two structs are equal iff
every field is equal (the same element-wise policy as tuples, which share the
struct layout). Each field is compared against its own type — an `f64` field uses
the ordered IEEE compare (NaN semantics per §Operators — consequently a struct
containing a NaN field is NOT equal to itself), a `string` field uses
content equality (`str_eq`), a nested struct/tuple field recurses, a tagged-union
field compares by tag only (matching a bare tagged-union `==`), a slice /
pointer / cstring field compares by identity, and an `?T` field compares by the
optional value-equality rule (§Optional Types — both-null equal, one-null
unequal, both-present → payload compare). Because the comparison walks named
fields, **padding bytes are never read** — a byte-wise compare would be
non-deterministic for a struct with alignment gaps, which is precisely why the
compare is field-wise.

A struct is **not comparable** — the whole `==` / `!=` is a compile error — when
any field has no defined value-equality: an untagged `union` field (inactive-
variant bytes are unspecified) or a fixed `[N]T` array field (compare elements
individually). These mirror the rejection of the same shapes as bare top-level
`==` operands. `<`, `<=`, `>`, `>=` are not defined on structs.

#### `#using` — Struct Composition
`#using StructName;` inside a struct declaration embeds all fields from `StructName` at that position. The embedded fields are accessed directly, as if declared inline.

```sx
UBase :: struct { x: i32; y: i32; }
UExt :: struct { #using UBase; z: i32; }
e := UExt.{ x = 1, y = 2, z = 3 };
print("{}\n", e.x);  // 1
```

`#using` may appear at any field position (beginning, middle, end) and multiple `#using` entries are allowed:
```sx
UPos :: struct { px: i32; py: i32; }
UCol :: struct { r: i32; g: i32; }
USprite :: struct { #using UPos; #using UCol; scale: i32; }
s := USprite.{ px = 10, py = 20, r = 255, g = 128, scale = 1 };
```

The referenced struct must be declared before use. This is purely a compile-time field expansion — no runtime overhead.

#### Struct Interpolation
Struct values in string interpolation print their fields with no type-name
prefix (`Type` values keep their names):
```sx
print("{}", v1);  // {x: 1.0, y: 2.0, z: 3.0, w: 0.0}
```

### Struct Methods
Functions declared inside a struct body become methods, registered as `StructName.method`:
```sx
Point :: struct {
    x, y: i32;

    sum :: (self: *Point) -> i32 { self.x + self.y; }
}

p := Point.{ x = 3, y = 4 };
print("{}\n", p.sum());  // 7
```

Methods receive the struct (typically as a pointer) as their first parameter. Dot-call syntax `obj.method(args)` resolves struct methods — it is **not** UFCS for arbitrary free functions. The pipe operator `|>` remains the universal UFCS mechanism.

### Protocol Types

Protocols define a set of method signatures that types can implement. They enable:
- **Static dispatch**: compile-time checked constraints on generic type parameters.
- **Dynamic dispatch**: type-erased protocol values with runtime method dispatch through function pointers.

#### Declaration
```sx
Allocator :: protocol #inline {
    alloc :: (self: *Self, size: i64) -> *void;
    dealloc :: (self: *Self, ptr: *void);
}
```

Protocol methods declare their receiver **explicitly** as the first parameter — `self: *Self` (or `self: Self`) — matching the corresponding `impl` method signature. This is **required**: a protocol method whose first parameter is not `self: *Self`/`self: Self` is a parse error. (It removes the old implicit-receiver ambiguity over whether the first listed parameter was the receiver or an extra argument.) The receiver annotation is validated then erased — the dispatch ABI is unchanged, so existing `impl` blocks and call sites are unaffected. The `#inline` modifier embeds function pointers directly in the protocol value (no vtable indirection).

#### `#inline` vs default layout

| Layout | Declaration | Value layout | Dispatch cost |
|--------|-------------|--------------|---------------|
| `#inline` | `protocol #inline { ... }` | `{ ctx: *void, __type_id: Type, fn_ptr1, fn_ptr2, ... }` | Zero indirection |
| Default | `protocol { ... }` | `{ ctx: *void, __type_id: Type, __vtable: *Vtable }` | One pointer chase |

Every protocol value carries its CONCRETE type's id at slot 1 (RTTI),
stamped at erasure — so the value's first two words are byte-identical to
an `any` `{data, type_id}`. This is what `type_of(p)`, the downcast
`p.(T)`, and the type switch on protocol subjects read. (The field is
dunder-named so a protocol method called `type_id` cannot collide; the
public spelling is `ProtocolRaw`'s `type_id`.)

Use `#inline` for protocols with few methods where call overhead matters (e.g., allocators). Use the default layout for protocols with many methods to keep the value size small.

#### `impl` Blocks
```sx
impl Allocator for GPA {
    alloc :: (self: *GPA, size: i64) -> *void {
        self.alloc_count += 1;
        malloc(size);
    }
    dealloc :: (self: *GPA, ptr: *void) {
        self.alloc_count -= 1;
        free(ptr);
    }
}
```

- Top-level declarations (not inside struct bodies)
- Enable retroactive conformance — implement a protocol for types you don't own
- Impl methods are also registered as struct methods (`GPA.alloc`) for direct calls
- Duplicate `{Protocol, Type}` pair in the same compilation unit is a compile error

#### Protocol Values and `xx` Conversion
Convert a concrete type to a protocol value with `xx`:
```sx
gpa := GPA.init();
a : Allocator = xx gpa;       // concrete → protocol value
ptr := a.alloc(64);            // dynamic dispatch through fn-ptr
a.dealloc(ptr);
```

`xx` works at assignment, call sites, and return positions:
```sx
use_allocator(xx gpa);             // at call site
make_alloc :: () -> Allocator { xx gpa; }  // in return position
```

Erasure is always legal, but which methods the erased value can CALL is
per-method — a method whose signature mentions `Self` beyond the
receiver has no slot in the erased value (see Dispatchability below).

Protocol values can be stored in struct fields, arrays, and passed through function calls:
```sx
Arena :: struct {
    parent: Allocator;  // protocol value as struct field
    // ...
}

allocators : [2]Allocator = .[xx gpa, xx arena];  // protocol values in array
```

#### Ownership and Lifetime

**A protocol value `P` always OWNS its ctx; `*P` is the borrowed view**
(the pointer doctrine — no new type former). Which operation you get is
decided by the spelling and the receiver shape:

| Spelling | Receiver | Result |
|---|---|---|
| `xx <rvalue>` / implicit rvalue | struct literal, call result, … | **Owns** — heap copy via `context.allocator` (the invariant) |
| `expr.(P)` | concrete lvalue or rvalue | **Owns** — independent heap copy |
| `expr.(P)` | `*Concrete` | **Owns** — SNAPSHOT of the pointee |
| `expr.(P)` | `*P` (same protocol) | **Owns** — PROMOTION: the view's value with a fresh ctx copy (`rt_size_of(type_id)` bytes; vtable/fn words reused) |
| `expr.(P, alloc)` | any owning shape above | **Owns** — the copy allocates through `alloc` (an LVALUE naming an allocator); pairs with `free(p, alloc)` |
| `xx <lvalue>` / implicit lvalue / `xx *ptr` | at a `P` target | **Compile error** — the DEMAND diagnostic (below) |
| any lvalue / pointer | at a `*P` target | **View** — borrows storage (see Borrowed Views) |

An **implicit (or `xx`) erasure of an lvalue or pointer** to a value/own
protocol is refused — it would silently heap-copy (or silently alias)
storage the reader believes is shared:

```sx
w := Widget.{ value = 7 };
s : Sizable = w;      // error: 'w' is an lvalue and 'Sizable' values own
                      // their storage — an implicit erasure here would
                      // silently heap-copy it; write the copy
                      // ('w.(Sizable)' or 'w.(Sizable, <alloc>)') or pass
                      // a view ('*Sizable' parameter) for transient use
s := w.(Sizable);     // the explicit owning copy — independent of w
```

`#identity` protocols are the exception (see Ownership Classes below):
their values only ever borrow, in every spelling, and `.(P, alloc)` on
an identity target refuses — a borrow allocates nothing.

**Owning erasure** heap-copies the concrete data so the protocol value is
self-contained. It can be stored in containers, returned from functions,
and outlives the scope where it was created. Release the backing when
done — the two `free` forms sit side by side:

- **`free(p)`** releases through **`context.allocator`** — the allocator
  current **at the free**, not at the erasure. If a different allocator
  context has been pushed in between, the free is redirected to it (the
  context-drift hazard); pair the call with the same ambient allocator
  the erasure ran under.
- **`free(p, allocator)`** pairs the allocator **explicitly** and is
  immune to that drift — the symmetric dual for erasures made under a
  known allocator. Zero overhead: the protocol value carries no
  allocator slot; the caller supplies it.

`free` is ONE ordinary sx function (`std/mem.sx`), kind-dispatched at
compile time via the inline type match — a protocol arm (the ctx via
`x.(ProtocolRaw)`, one body for BOTH layouts, default and `#inline`), a
closure arm (the heap `env` captured at the literal; a capture-free
closure's env is null and the free is a no-op), and a slice arm (the
backing from `alloc`/`clone`/`resize`); any other argument kind is a
compile error. `free` is legal on every owned value/own `P`; freeing an
`#identity` value refuses at compile time, and `free(*P)` (a view) is
structurally the compile error already.
```sx
s : Sizable = xx Widget.{ value = 42 };  // rvalue — heap-copies via context.allocator
print("{}\n", s.size());
free(s);          // frees the copy via context.allocator (current at the free)

w := Widget.{ value = 7 };
u := w.(Sizable, my_arena);   // owning copy through a NAMED allocator
free(u, my_arena);            // explicit pairing — immune to context drift

t : Sizable = ---;
push .{ allocator = my_arena } {
    t = xx Widget.{ value = 7 };         // heap-copies via my_arena
}
free(t, my_arena);    // explicit pairing — correct even under a different context
```

The **shallow-copy caveat**: an owning erasure copies the concrete
value's BYTES. Interior pointers (slices, strings, pointers inside the
struct) are copied as pointers — the copy and the source then share
whatever those point at. A type whose deep state must not be shared
belongs behind `#identity` or a view.

For **transient use** — dispatch without taking ownership — pass a view:
`*P` positions build the borrow in place from any lvalue or pointer, and
mutations through the view reach the original (see Borrowed Views).

#### Ownership Classes: value/own vs `#identity`

Every protocol belongs to one of two **ownership classes**:

- **value/own** (the unmarked default) — protocol values OWN their ctx.
  Rvalue erasure and the postfix spellings heap-copy; implicit/`xx`
  lvalue erasure is the demand error; `free` releases the owned backing.
- **`#identity`** — the marked exception, for protocols whose runtime
  object *is* unique state that only ever gets **borrowed** (an
  allocator, an Io runtime). Declared with the bare attribute, freely
  combined with `#inline`:

```sx
Allocator :: protocol #inline #identity {
    alloc_bytes :: (self: *Self, size: i64) -> *void;
    dealloc_bytes :: (self: *Self, ptr: *void);
}
```

An identity protocol value borrows in **every** erasure spelling — `xx
gpa`, the target-explicit postfix `gpa.(Allocator)`, decl targets, call
arguments, struct-literal fields (`push .{ allocator = gpa }` borrows
`gpa` into the pushed Context) — and the class rules out ownership
entirely:

- **rvalue erasure refuses**: an rvalue has no durable storage to
  borrow, and an owning copy is exactly what the class forbids —
  "identity objects need a name; bind it first";
- **`free` on an identity value refuses at compile time**: there is no
  owned allocation (`free`'s protocol arm gates on `is_identity(T)`);
- the standard `Allocator` and `Io` protocols are `#identity`.

`is_identity(T)` reflects the class as a compile-time constant (`true`
only for `#identity` protocols; `false` for value/own protocols and
every non-protocol type). It is compile-time ONLY — a runtime `Type`
value always tags a concrete type, never a protocol — and it folds in
`inline if`, so a generic body can gate per-class behavior.

#### Borrowed Views: `*P`

A pointer-to-protocol is the **borrowed view** of erased state, under the
ordinary pointer doctrine (unchecked; valid while the pointee lives).
Protocol methods dispatch through `*P` directly, for both layouts. A view
is produced implicitly at `*P`-typed positions (parameters, annotated
locals):

- a concrete **lvalue** builds the view in place — `ctx` is the lvalue's
  own address, so mutations through the view reach the original;
- a **pointer-to-concrete** views its pointee;
- an owned protocol value lends a view by plain address-of (`*s`).

An **rvalue** has no durable storage to borrow — both the annotated-local
and the argument form are compile errors (never a silent reinterpretation
of the value's bytes into a pointer slot):

```sx
measure :: (v: *Sizable) -> i64 { v.size() }

w := Widget.{ value = 7 };
measure(w);                            // view in place — aliases w
pv : *Sizable = w;                     // decl-position view
pv : *Sizable = Widget.{ value = 1 };  // error: rvalue — nothing durable to borrow
```

`free` on a `*P` is a compile error (a view owns nothing — the pointer kind
never matches free's protocol arm).

**Vtables** are global constants — shared across all protocol values of the same `(Protocol, ConcreteType)` pair. They are never allocated or freed at runtime.

#### Default Methods
Protocol methods can have bodies. `self` dispatches through the vtable (dynamic dispatch):
```sx
Writer :: protocol {
    write :: (self: *Self, data: string) -> i64;          // required
    write_line :: (self: *Self, data: string) -> i64 {    // default
        n := self.write(data);
        n + self.write("\n");
    }
}
```

Default methods are used unless overridden in the impl. Default methods calling `self.method()` dispatch through the vtable, so they work correctly with any concrete type.

#### `Self` Type
`Self` is a contextual keyword in protocol declarations — resolves to the concrete type in impls:
```sx
Eq :: protocol { eq :: (self: *Self, other: Self) -> bool; }

impl Eq for Point {
    eq :: (self: *Point, other: Point) -> bool {
        self.x == other.x and self.y == other.y;
    }
}

// Static dispatch:
p1.eq(p2);   // calls Point.eq directly
```

A method that uses `Self` beyond the receiver is still fully usable
wherever the concrete type is known — concrete receivers and generic
bounds (`$T: Type/Eq`) — but it is **not dispatchable** through an erased
protocol value. See Dispatchability, next.

#### Dispatchability

Erased dispatch is **per-method**: a protocol method is *dispatchable*
iff its signature is expressible with `Self` unknown — that is, `Self`
appears **only as the receiver**. At an erased call site the concrete
type behind a `P` / `*P` value is gone; a parameter or return that
mentions `Self` would have no type the caller could produce or consume,
so such a method gets **no vtable/#inline slot** and calling it through
an erased value is a compile error. (Before this rule, a `Self`-typed
argument passed through an erased value entirely UNCHECKED — any value
of any type was reinterpreted as the impl's concrete type.)

Where `Self` may appear, per position:

| Position | `Self` allowed? | Effect |
|----------|-----------------|--------|
| Receiver (`self: *Self` / `self: Self`) | Yes | Required; erases to the ctx pointer |
| Later parameter — `Self` at any depth (`Self`, `*Self`, `?Self`, `[]Self`, `[N]Self`, `Box(Self)`, fn/closure types) | No | Method excluded from erased dispatch |
| Return type — `Self` at any depth | No | Method excluded from erased dispatch |

An excluded method:
- is **absent from the vtable / #inline fn-ptr fields** (slots index the
  dispatchable methods only, in declaration order);
- is **still required of every `impl`** — conformance is unchanged;
- **still works** on concrete receivers (static dispatch) and through
  generic bounds, where `Self` is the known bound type:

```sx
e : Eq = xx p1;
e.eq(p2);        // error: 'eq' is unavailable on an erased 'Eq' value —
                 // its parameter 'other: Self' has no expressible type here
                 // ('Self' denotes no type through erasure); call it through
                 // a generic bound instead:
                 // `f :: (a: $T/Eq, b: T) { a.eq(b); }`

are_equal :: (a: $T/Eq, b: T) -> bool { a.eq(b) }
are_equal(p1, p2);   // fine — Self is the bound T
```

A protocol **always erases**, whatever its methods: a marker protocol
(no methods) and an all-excluded protocol both produce a legal protocol
value with an empty vtable — `type_of`, the downcast `p.(T)`, the type
switch, the `ProtocolRaw` view, and `free` all work without any
dispatchable method. There is **no implicit opening** of an erased
value; the type switch is sx's opening construct.

For the methods that do dispatch dynamically, non-receiver parameters
keep their declared (concrete) types; only the receiver erases to the
ctx pointer.

Relatedly, a postfix **assertion with a protocol target on an `any`
receiver is refused** at compile time — an `any`'s type tag is always
the boxed value's concrete type, never an erased protocol, so
`av.(Sizable)` (checked, soft, or chained) could only ever fail; assert
the concrete type or use a type switch.

#### Generic Constraints
`$T/Protocol` syntax validates that a type parameter implements the required protocol(s):
```sx
are_equal :: (a: $T/Eq, b: T) -> bool { a.eq(b); }

// Multiple constraints:
eq_and_hash :: (a: $T/Eq/Hashable, b: T) -> bool { ... }
```

Constraints produce clear errors at monomorphization: `"i64 does not implement Hashable"`. Dispatch is static — same as unconstrained generics but with compile-time validation.

Constraints also work on struct type parameters:
```sx
SortedPair :: struct ($T: Type/Comparable) {
    lo: T;
    hi: T;
}
```

#### Generic Struct Impls
```sx
Pair :: struct ($T: Type) { a: T; b: T; }

impl Summable for Pair($T) {
    sum :: (self: *Pair(T)) -> i32 { xx self.a + xx self.b; }
}
```

The impl is instantiated per concrete type argument, like generic struct methods.

#### Dispatch Rules

| Usage | Dispatch | Cost |
|-------|----------|------|
| `gpa.alloc(64)` on `*GPA` | Static — direct call | Zero |
| `$T/Allocator` constraint | Static — monomorphized | Zero |
| `a : Allocator = xx gpa; a.alloc(64)` | Dynamic — fn-ptr / vtable | Indirect call |

Static dispatch is automatic when the concrete type is known. Dynamic dispatch only when explicitly type-erased via `xx` into a protocol value.

#### Parameterised Protocols (compile-time only)

A protocol with type parameters is compile-time only — it has no vtable
and no boxed instance shape. Each `impl` is monomorphised per
`(ProtocolArgs, Source)` pair. The canonical example is `Into`, declared
in `modules/std.sx`:

```sx
Into :: protocol(Target: Type) {
    convert :: (self: *Self) -> Target;
}
```

A user can then add conversions for any `(Source, Target)` pair:

```sx
MyString :: struct { tag: i64 = 0; }

impl Into(MyString) for i64 {
    convert :: (self: i64) -> MyString { .{ tag = self }; }
}

main :: () -> i32 {
    x : MyString = xx 42;   // direct call to monomorphised convert
    0;
}
```

The `xx` operator hooks into this mechanism: when an explicit target type
is provided and the built-in coercion ladder doesn't apply,
`xx val : T` lowers to `val.convert()` where `convert` comes from the
visible `impl Into(T) for typeof(val)`. The call is a direct call — no
vtable, no runtime dispatch.

**Source side is a TypeExpr.** Unlike nullary `impl P for SomeStruct`,
the `for`-side of a parameterised impl accepts any type expression,
including closure and function types:

```sx
impl Into(Block) for Closure() -> void { ... }
impl Into(MyBuf) for []u8 { ... }
```

**Lookup rules:**
- **Built-ins win.** The user-space fallback only fires when
  `coerceToType` made no progress (numeric narrow/widen, ptr↔int, etc.
  take priority).
- **Only at explicit `xx`.** Implicit conversions (assignment,
  parameter passing) never trigger user-space coercions.
- **Explicit target required.** `xx val` with no surrounding type
  context still defaults to `i64` for legacy reasons; the user-space
  fallback only fires when the target was named explicitly.
- **Import-scoped visibility.** An `impl` is visible from a file only
  if the file transitively imports the impl's defining module. An impl
  in an imported-but-not-directly-related module produces a clean
  diagnostic (`no visible xx conversion …`).
- **Duplicate impls error.** If two impls for the same
  `(Source, Target)` pair are both visible, the compiler emits a
  diagnostic naming both source modules. Same-file duplicates are
  caught at registration time. Cross-module duplicates are caught at
  the `xx` site.
- **No recursion.** A `convert` body that re-enters `xx self : Target`
  for the same `(Source, Target)` pair produces a "recursive xx
  conversion" diagnostic; the compiler does not try to monomorphise
  the convert into itself.

### Tuple Types
Anonymous product types with optional field names. Tuples are first-class values — they can be stored in variables, passed to functions, and returned. A **named tuple** `Tuple(x: A, y: B)` is sx's anonymous *structural* record — it carries field names but has no nominal identity (distinct from a `struct`, which is nominal). Tuples also support **spread** (`..tuple` / `.{..tuple}`) and **field projection** (`tuple.field` across all elements) — see "Variadic Heterogeneous Type Packs".

The tuple TYPE is always written `Tuple(...)`; a tuple VALUE is built with the
ONE aggregate literal `.{ ... }` against a tuple-typed target — an annotation,
a typed prefix, a call slot, or a return slot (aggregate ladder Step 1: the old
`.( )` spelling was removed). An UNTYPED `.{ ... }` is NOT a tuple — it
self-types as an anonymous structural STRUCT (see "Struct Literals"); tuples
are explicit-target-only. Bare parentheses `(...)` are **grouping only,
everywhere** — a comma inside bare parens is a hard error with a migration hint.

#### Construction
```sx
pair   : Tuple(i64, i64) = .{40, 2};           // positional tuple value
named  : Tuple(x: i64, y: i64) = .{x = 10, y = 20};  // named tuple value
single : Tuple(i64) = .{42};                   // 1-tuple value
empty  : Tuple() = .{};                        // empty tuple value
zeroed : Tuple(i32, i32) = ---;                // zero-initialized tuple

// Explicitly typed value (like `Point.{...}`):
p := Tuple(i64, i64).{40, 2};
n := Tuple(x: i64, y: i64).{x = 10, y = 20};
```

A named tuple value uses `=` for its fields (`.{x = a, y = b}`); a named tuple
type keeps `:` (`Tuple(x: A, y: B)`).

#### Type Syntax
The tuple type is `Tuple(...)`:
```sx
Tuple(i64)          // 1-tuple type
Tuple(i64, i64)     // 2-tuple type
Tuple(x: i64, y: i64)  // named tuple type
Tuple()             // empty tuple type
Tuple(..F(Ts))      // pack-spread tuple type (see Variadic Heterogeneous Type Packs)
```
`Tuple(...)` is strictly a **type** in every position — including `size_of(Tuple(...))`
and `type_info(...)` arguments. A tuple **value** comes only from a `.{ ... }`
literal against a tuple-typed target (`t : Tuple(A, B) = .{a, b}`) or the typed
prefix (`Tuple(A, B).{a, b}`); a bare `Tuple(1, 2)` (non-type elements) is
rejected as a tuple type with non-type elements.

Bare parentheses are grouping and never a tuple:
```sx
(i64)            // grouping: resolves to i64
(i64) -> i64     // function type: takes i64, returns i64
(i64, i64) -> i64  // function type: takes two i64, returns i64
?(?i64)          // grouping → a genuine nested optional
[1](Closure(i64,i64) -> i64)  // grouping → array of one closure
```
Grouping lets a closure/optional/function type be parenthesized for readability.
Function types `(A, B) -> R`, parameter lists, lambdas, and `match` bindings keep
using bare parens — they are unaffected by the tuple grammar.

#### Field Access
```sx
pair.0;      // 40 — numeric index
pair.1;      // 2
named.x;     // 10 — named field
named.0;     // 10 — numeric index also works on named tuples
```

#### As Return Type
```sx
swap :: (a: i64, b: i64) -> Tuple(i64, i64) { .{b, a} }
wrap :: (x: i64) -> Tuple(i64) { .{x} }   // 1-tuple return

s := swap(1, 2);  // s.0 = 2, s.1 = 1
t := wrap(42);    // t.0 = 42
```

#### Multiple Return Values (bare-paren return signature)

A function may return **multiple values** with a bare-paren return signature
(≥2 value slots) — positional `-> (A, B)` or named `-> (x: A, y: B)`, with an
optional trailing `!` error channel as the **last** slot (`-> (A, B, !)`). The
empty `-> ()` is `void`. A multi-return is a DISTINCT construct from a `Tuple(…)`
VALUE: it is represented internally by a reused tuple TypeId (same ABI), but it
is valid ONLY in a function/closure return position — a parameter, field, or
variable annotation `x: (A, B)` is rejected (use `Tuple(…)` for a tuple value).
A single-value `-> (T, !)` (one value + error) is NOT a multi-return; it is
exactly the failable `-> (T, !)`.

```sx
divmod :: (a: i64, b: i64) -> (i64, i64) { return a / b, a % b; }
stats  :: (a: i32, b: i32) -> (sum: i32, big: bool) { return sum = a + b, big = a > b; }
```

- **`return` forms.** Bare comma list — `return a, b` (positional) or
  `return x = a, y = b` (named, **in slot order**); no `.( … )` literal. A single
  positional `return v` is the ordinary single-value return. The list arity must
  match the value-slot count, and named elements must agree with the slots; a
  mismatch is a compile error (never a silent wrong result).
- **Consumption.** Destructure (`q, r := divmod(…)`) or single-bind + field
  access (`c := stats(…); c.sum`). For a failable multi-return the error rides
  the separate `!` channel — a bound value (`c := f() catch … `) holds only the
  value slots, never the error.
- **Named returns as locals.** Named slots are in-scope assignable locals;
  assigning them all *is* the implicit return (no explicit `return` needed). A
  slot may carry a default (`(sum: i32 = 0, good: bool)`), which seeds the local
  and exempts it from the must-set rule. A slot that is not assigned on every
  non-diverging path and has no default is a compile error (definite assignment),
  and a slot name may not collide with a parameter name.

#### Representation
Tuples are represented as anonymous LLVM struct types (same layout as named structs). A tuple `Tuple(i64, i64)` has LLVM type `{ i64, i64 }`.

#### Tuple Operators

**Equality and inequality** — element-wise comparison, both sides must have the same field count:
```sx
a : Tuple(i64, i64) = .{1, 2};
b : Tuple(i64, i64) = .{1, 3};
a == a   // true
a != b   // true
```

**Concatenation** (`+`) — creates a new tuple with fields from both sides:
```sx
c := a + Tuple(i64, i64).{3, 4};   // c : Tuple(i64, i64, i64, i64)
c.0;                       // 1
c.3;                       // 4
```

**Repetition** (`*`) — repeats a tuple N times (N must be a compile-time integer literal):
```sx
r := a * 3;   // r : Tuple(i64, i64, i64, i64, i64, i64)
r.0;                 // 1
r.5;                 // 2
```

**Lexicographic comparison** (`<`, `<=`, `>`, `>=`) — compares element-by-element left to right:
```sx
a < b                            // true  (first fields equal, 2 < 3)
Tuple(i64, i64).{2, 0} > Tuple(i64, i64).{1, 9}   // true  (2 > 1, rest ignored)
a <= a                           // true  (all equal, <= allows tie)
```

**Membership** (`in`) — checks if a value exists in a tuple:
```sx
m : Tuple(i64, i64, i64) = .{1, 2, 3};
3 in m     // true
5 in m     // false
```

### Array Types
Fixed-size arrays with element type and length.
```sx
buffer : [5]f32 = .[0, 2, 3.5, 4, 0];
val := buffer[2];  // 3.5
buffer.len         // 5 (compile-time constant, i64)
```

A `.[ … ]` literal takes its element type from the annotation or target
(`x : [3]i16 = .[1, 2, 3]`), or infers it from the elements when bare
(`.[1, 2, 3]` is `[3]i64`). A type prefix on the literal names the
**aggregate** type — `Vector(3, f32).[…]`, `([2]?i64).[…]`, or an alias
of an array type — never the element type: a prefix that resolves to a
non-array/vector/slice type (`i16.[…]`, `Point.[…]`) is a compile error
pointing at the annotated form.

Arrays can also be constructed programmatically with the `Array` builtin:
```sx
MyArr :: Array(5, i32);   // equivalent to [5]i32
```

A **count** is a compile-time integer used as an array dimension, a `Vector`
lane count, or a generic value-param count. Every count must be **integral**: an
integral compile-time float folds to its integer (`[4.0]i64` ≡ `[4]i64`), while a
non-integral float is rejected (an array dimension reports "array dimension must
be an integer, but '4.5' is a non-integral float"). This holds however the float
is written — a literal (`4.0`), a float-typed const (`N : f64 : 4.0`), or a
const **expression** whose value is integral, including one built from a
non-integral float-const leaf (`F : f64 : 2.5; [F + 1.5]i64` ≡ `[4]i64`, and
likewise through a const, `K : i64 : F + 1.5; [K]i64`), a builtin float
numeric-limit accessor (`[f64.max - f64.max]i64` → length 0), a float `%`, or a
float `/` whose quotient is integral (`[6.0 / 2.0]i64` ≡ `[3]i64`; a non-integral
quotient like `[5.0 / 2.0]i64` = 2.5 is rejected — a float `/` is always float
division, never integer truncation, even when both operands are integral). A
count and a typed
binding's float→integer initializer share the *same* compile-time float
evaluation, so they agree at every site — direct, through a const, or via a type
alias (see "Implicit float → integer", §2 Type Conversions).
The accepted *range* of a count is **context-dependent** — zero is legal for
some counts and not others:

- **Array dimension** — any compile-time integer ≥ 0. `[0]T` is a valid empty
  (zero-length) array; a negative dimension is rejected ("array dimension must
  be non-negative").
- **Generic value-param count** — bounded by the parameter's declared integer
  type. Zero is allowed (`Box(0)`, for `Box :: struct($N: u32)`, is a length-0
  instantiation); a value outside that type's range is rejected (`-1` or
  `5_000_000_000` for a `u32` param). A negative count is therefore accepted
  only when the declared type is signed.
- **`Vector` lane count** — any compile-time integer ≥ 1 (strictly positive). A
  zero-lane or negative vector (`Vector(0, f32)`) is rejected ("Vector lane
  count must be a positive compile-time integer constant").

A **range bound** — the start/end of an `inline for` or `for` range — is a
range *endpoint*, not a count, so the count rules above do not apply. A bound
accepts any compile-time **integer**, including a negative one; an integral
float (`-2.0`) folds to its integer. A non-integral float (`4.5`) is still
rejected, because the loop cursor must be a compile-time integer. Negative
endpoints are valid: `inline for -2..1` iterates `-2, -1, 0`. An empty or
inverted range (start ≥ end, e.g. `0..(-2.0)`) simply runs zero iterations
rather than being an error.

### Slice Types
A slice `[]T` is a fat pointer `{ptr, i64}` referencing a contiguous sequence of `T` elements. Same runtime layout as `string`.
```sx
// Arrays implicitly coerce to slices at call sites
arr : [5]i32 = .[3, 1, 4, 1, 5];
sortSlice(arr);   // [5]i32 → []i32 coercion

// Slice operations
items[i]           // read element at index
items[i] = val;    // write element at index
items.len          // length (i64)
items.ptr          // raw pointer
```

Slices support generic type parameters: `[]$T` introduces type parameter `T` inferred from the element type of the argument (array or slice).

### Subslicing
Arrays, slices, and strings support subslice syntax to create zero-copy views:
```sx
arr : [5]i32 = .[3, 1, 4, 1, 5];
sub := arr[1..4];    // []i32 → [1, 4, 1]
head := arr[..3];    // []i32 → [3, 1, 4]
tail := arr[2..];    // []i32 → [4, 1, 5]

msg := "hello world";
word := msg[6..11];  // string → "world"
```
- `expr[start..end]` — elements from `start` (inclusive) to `end` (exclusive)
- `expr[start..]` — elements from `start` to end
- `expr[..end]` — elements from beginning to `end`
- `expr[..]` — the whole collection as a slice
- Result type: `[]T` for arrays/slices, `string` for strings
- No memory allocation — the result points into the original backing storage

Slicing an array is a **zero-copy view**: for an *addressable* array (a
local, a global, a struct field, or a `*[N]T` dereference) the slice
aliases the array's live storage, so a write through the slice is visible
in the array and vice versa. Slicing a **temporary** array — the result of
a call returning `[N]T`, an array literal, or any other rvalue with no
persistent storage — is a **compile error** (`cannot slice a temporary
array …`): a slice of it would be a dangling view the moment the statement
ends. Bind the temporary to a local first (`a := makeArr(); a[..]`). (Zig
rejects slicing an rvalue array for the same reason.)

A view is valid only while its backing storage lives. Returning a slice of
a **local** array escapes a dangling view into the callee's dead frame —
this is *not* rejected (sx has no escape analysis, like Zig); the caller
must not outlive the array. Slicing a **by-value array parameter** aliases
the callee's own copy of the argument (parameters are pass-by-value), so a
write through such a slice is not visible to the caller.

**Implicit array→slice coercion** (passing a `[N]T` where a `[]T` is
expected — `fill(arr)` with `fill :: (s: []T)`, spreading `sum(..arr)`, or
binding `s : []T = arr`) follows the SAME aliasing rule as the explicit
`arr[0..]` subslice, so `fill(arr)` and `fill(arr[0..])` behave identically:
an *addressable* array coerces to a zero-copy VIEW over its storage, and a
write through the slice param lands in the caller's array. A
*non-addressable rvalue* array — a call result or an array literal — differs
by context:

- As a call ARGUMENT (`fill(makeArr())`, `sum(..makeArr())`) or as a
  slice-typed BINDING (`s : []T = makeArr()`, `s : []T = .[a, b]`), the
  coercion COPIES the array into fresh storage that lives at least as long
  as the slice (a call-duration temporary for an argument; a function-entry
  slot for a binding). The copy is sound — nothing else aliases it, and it
  is never dangling. This is why the ubiquitous `argv : []string = .[…]`
  form is accepted, unlike the *subslice* of a temporary above: a subslice
  aliases the temp directly (dangling), whereas the coercion materializes a
  persistent copy first.

A `::` **const** array coerces to a *mutable* `[]T` as a view exactly like
the explicit `constArr[0..]` subslice; a write through such a slice is not
yet diagnosed (there is no `[]const T` slice type yet — const-slice
propagation is future work). The direct `constArr[i] = …` write IS rejected.

Slice ranges take the same bound markers as for-header ranges — `=`
inclusive / `<` exclusive on either side of `..`, defaulting to
start-inclusive, end-exclusive:
```sx
arr[1..=3]    // elements 1, 2, 3
arr[0<..<4]   // elements 1, 2, 3
arr[..=2]     // elements 0, 1, 2 (prefix form takes markers too)
arr[2<..]     // elements 3 .. len-1
```
An explicit end marker (`..=` / `..<`) requires an end expression. Bounds
are arbitrary expressions (`arr[x-1..=x+1]`).

### Pointer Types

| Syntax | Meaning | `.len` | `[i]` |
|--------|---------|--------|-------|
| `*T` | pointer to one T | no | no |
| `[*]T` | many-pointer (buffer) | no | yes |
| `*[N]T` | pointer to array of N T | yes | yes |
| `*[]T` | pointer to slice | yes | yes |

**Address-of**: `*x` returns a pointer to the variable. One glyph, three
positions: prefix `*` TAKES a pointer, postfix `.*` FOLLOWS one, and in a
type position `*T` is the pointer type. In the value grammar a prefix `*`
resolves by the KIND of its operand: a value operand is address-of; an
operand that denotes a type yields the pointer TYPE as a Type value
(`size_of(*T)`, generic `Type` arguments, `**T` nested inside-out). A
local or global VALUE shadowing a type name stays a value — taking an
address never silently becomes a type. Infix `*` (multiplication) is
untouched: after an operand `*` is binary, at expression head it is
address-of (`a * *b` multiplies `a` by the address of `b`).
```sx
v := Vec2.{ 1.0, 2.0 };
ptr := *v;             // *Vec2
```

**Dereference**: `p.*` loads the value through the pointer.
```sx
copy := ptr.*;          // Vec2
```

**Auto-deref**: `p.field` is sugar for `p.*.field`.
```sx
set_x :: (p: *Vec2, val: f32) {
    p.x = val;          // auto-deref: p.*.x = val
}
set_x(*v, 99.0);
```

**Null**: Pointer types are nullable by default — permanently; this is part
of the pointer contract, not a transitional state. `null` is the null pointer
literal and any `*T` may hold it. The compiler does not police it: like
writes, null-ness is unchecked — dereferencing a null pointer is a runtime
crash, never a compile error. Nullability **checking is opt-in** via the
optional spelling `?*T`: same bare-pointer representation (see Optional
Types), but use-sites must prove presence (`!`, `??`, `if v := p`,
flow-sensitive narrowing) before touching the payload. Pick `*T` when null is
a normal, locally handled sentinel; pick `?*T` when the type should force
every consumer to handle absence.
```sx
np : *Vec2 = null;     // fine — nullable, unchecked
op : ?*Vec2 = null;    // same layout; deref demands proof of presence
```

**Many-pointer**: `[*]T` supports indexing for buffers of unknown size.
```sx
arr : [5]i32 = .[10, 20, 30, 40, 50];
mp : [*]i32 = *arr[0];   // *i32 → [*]i32 implicit
val := mp[2];             // 30
```

**Implicit conversions**:
- `*T` → `[*]T` (pointer to element → many-pointer)
- `*[N]T` → `[*]T` (pointer to array → many-pointer)
- `[N]T` → `[*]T` at call sites (array decays to many-pointer)
- `[]T` → `[*]T` (slice decays to many-pointer, extracts `.ptr`)
- `T` → `*T` at call sites (implicit address-of)
- `null` (`*void`) → any `*T`

**Unchecked writes (the pointer contract)**: pointers carry no
read-only qualifier — there is no `const` pointer type in sx (`const` is
not a keyword). Taking the address of constant storage yields a plain
pointer: `*K` on an array constant `K : [4]i64 : .[...]` is `*[4]i64`.
Reads through it are fine; **writes through any pointer are unchecked**,
and writing into constant storage through a pointer is undefined behavior
(the storage is marked constant in the emitted binary). The compile-time
guard on constants protects their *name* — every assignment whose target
chain is rooted at a constant is rejected (see
[Constant-Write Rejection](#constant-write-rejection)); a dereference in
the chain leaves the checked zone.

**Fat pointer layout**: `[:0]u8`, `string`, and `[]T` are `{ptr, i64}` structs. The raw pointer is always the first field at offset 0. This means `*[:0]u8` works as C's `char**` — a C function dereferences through the outer pointer and reads the raw `char*` from offset 0.

### cstring

`cstring` is the C-boundary string: ONE pointer to a null-terminated u8
buffer — exactly C's `char *`. It is thin (8 bytes, no length field;
`cstring_len` walks to the terminator, O(n)) and crosses `extern`
boundaries verbatim in BOTH directions. `?cstring` is the nullable case
and lowers to the same bare pointer (null = absent) — the natural type
for `getenv`-style returns and optional `char *` parameters.

Conversion discipline (Odin's model):

- A string **literal** coerces to `cstring` implicitly — literal bytes
  are terminated constants in the binary, so the conversion is free.
- Any **other** `string` does NOT coerce: it may be an unterminated view
  (`string.{ptr, len}` windows, writer output). Materialize an owned,
  terminated copy with `to_cstring(s)`.
- `cstring` does not coerce to `string` implicitly — the length is an
  O(n) strlen the code must ask for. `from_cstring(c)` is the zero-copy
  view (shares C's buffer); `substr(from_cstring(c), 0, n)` the owned
  copy.
- `xx` bit-casts `cstring` ↔ `*u8` / `[*]u8` / integer-pointer values
  for low-level interop.

### Optional Types

Optional types represent values that may or may not be present.

#### Type Syntax
```sx
x: ?i32 = 42;        // optional i32, has value
y: ?i32 = null;      // optional i32, no value
```

Any type `T` can be made optional: `?i32`, `?string`, `?Point`, `?*T`, `?[]T`.

#### LLVM Representation
- Non-pointer optionals (`?i32`, `?Point`): `{ T, i1 }` struct — payload + has_value flag
- Pointer optionals (`?*T`): bare pointer — null represents absence

#### Implicit Wrapping
A value of type `T` implicitly converts to `?T`:
```sx
wrap :: (n: i32) -> ?i32 {
    if n > 0 { return n; }    // i32 → ?i32 (wraps)
    return null;               // null → ?i32
}
```

The reverse is **not** implicit: a `?T` never silently unwraps to its payload
`T` in a value position (call argument, field initializer, `return`, assignment).
Such a use is a compile error — extract the payload explicitly with `!` / `??` /
a binding (`if v := opt`) / a `case` match, or rely on flow-sensitive narrowing
after a `!= null` guard (below). Unwrapping a null optional implicitly would
yield its zero payload with no diagnostic, so the conversion is rejected rather
than allowed.

#### Value Equality

`==` / `!=` are defined on optionals whenever the payload type has
value-equality (issue 0344). Equality extracts nothing — null is a legitimate
comparison value — so this is not an exception to the no-implicit-unwrap rule,
and arithmetic / ordering on un-narrowed optionals stay rejected.

- `?T == ?T`: equal iff both are null, or both are present with `==`-equal
  payloads. The payload compares by its own type's rule (a float payload uses
  the IEEE ordered compare — a present NaN is not equal to itself; a string
  payload compares by content; a struct payload recurses field-wise; a
  tagged-union payload compares by tag only). A null payload is never read.
- `?T == T` (either order): false when the optional is null, otherwise the
  payload compare. A literal on the concrete side types at the payload
  (`opt_width == 40.0` against a `?f32`).
- `?T == null` keeps its meaning as the presence test (subsumed by the
  general rule).
- Two distinct optional types (`?f32` vs `?f64`) do not compare, and a payload
  without value-equality (e.g. a fixed array) keeps the usual rejection.

```sx
a : ?f32 = 1.5;
b : ?f32 = null;
a == b        // false — present vs null
b == null     // true
a == 1.5      // true — mixed compare, no unwrap spelling needed
```

#### Force Unwrap (`!`)
Extracts the payload, traps at runtime if null:
```sx
x: ?i32 = 42;
val := x!;             // val : i32 = 42
```

#### Null Coalescing (`??`)
Returns the payload if present, otherwise evaluates the right-hand side:
```sx
x: ?i32 = 42;
y: ?i32 = null;
a := x ?? 0;           // 42
b := y ?? 99;          // 99
```

#### Safe Unwrap (`if val := expr`)
Binds the payload to a variable if present:
```sx
x: ?i32 = 42;
if val := x {
    print("{}\n", val);     // val : i32 = 42
} else {
    print("none\n");
}
```

#### While-Optional Binding
```sx
while val := get_next() {
    // val is the unwrapped value
}
```

#### Pattern Matching
Optionals support `.some` and `.none` virtual enum variants:
```sx
result := if opt == {
    case .some: (val) { val * 2; }
    case .none: { 0; }
};
```

#### Optional Chaining (`?.`)
Short-circuits field access on optionals:
```sx
x: ?Point = Point.{ x = 1, y = 2 };
y: ?Point = null;
a := x?.x ?? 0;       // 1
b := y?.x ?? 0;       // 0
```

Result type of `x?.field` is always `?FieldType`.

#### Flow-Sensitive Narrowing
The compiler narrows `?T` to `T` in control flow branches:
```sx
x: ?i32 = 42;
if x != null {
    print("{}\n", x);       // x is i32 here (narrowed)
}
if x == null { return; }
print("{}\n", x);           // x is i32 here (guard narrowing)
```

Compound conditions:
```sx
if a != null and b != null {
    // both a and b are narrowed to their inner types
}
if a == null or b == null { return; }
// both a and b are narrowed after the guard
```

Reassignment kills narrowing.

#### Struct Field Defaults
Optional fields in structs default to `null`:
```sx
Node :: struct { value: i32; next: ?i32; }
n := Node.{ value = 10 };    // n.next is null
```

#### Printing
`print("{}", opt)` prints the payload value if present, or `"null"`.

#### Comptime
Optionals work in `#run` blocks — `??`, `!`, `if val :=`, null checks all supported.

### C Interop

C linkage is expressed with the postfix `extern` (import) and `export` (define +
expose) keywords. `extern` declares a symbol defined elsewhere — a C function or
data global resolved at link time; `export` is its dual — **define** a symbol in
sx and expose it under the C ABI so C (or asm, or another language) can call it.
Both imply `abi(.c)`, carry external linkage, and suppress the implicit sx
context parameter. They are postfix modifiers, written in the slot after the
`abi(...)` annotation.

```sx
// Declare a named library constant
libc :: #library "c";
sdl  :: #library "SDL3";

// Functions — `extern` imports, `export` defines + exposes
socket    :: (domain: i32, type: i32, protocol: i32) -> i32 extern libc;
SDL_Init  :: (flags: u32) -> bool extern sdl;
abs       :: (x: i32) -> i32 extern;            // no LIB: resolves from a framework / auto-linked lib
write_fd  :: (fd: i32, buf: [*]u8, n: u64) -> i64 extern libc "write";  // [LIB] ["csym"] rename
sx_square :: (x: i32) -> i32 export { x * x }   // define; C can call `sx_square`
triple_c  :: (x: i32) -> i32 export "triple_c" { x * 3 }  // export under a C name

// Data globals — `extern` imports an external global
__stdinp  : *void extern;

// Aggregates (Obj-C / JNI runtime classes) — postfix after the directive
NSObject  :: #objc_class("NSObject") extern { alloc :: () -> *NSObject; }  // reference
SxFoo     :: #objc_class("SxFoo")    export { counter: i32; bump :: (self: *Self) { … } }  // define
```

- `#library "name"` must be assigned to a named constant. The library is passed
  to the linker (`-lname` on Unix, `name.lib` on Windows).
- `extern lib_ref` declares a function (or `<name> : <type> extern;` a data
  global) as an external C symbol. The library reference is optional: when present
  it is passed to the linker (`-lname` on Unix); when omitted, the symbol must
  resolve at link time from a framework or an already-linked / auto-detected
  library. The `#library` declaration + build-flag linking mechanism is a separate
  axis — `extern` *references* a library, it does not declare one.
- `extern lib_ref "c_symbol"` (and `export "c_symbol"`) renames the binding: the
  sx name differs from the C symbol. This avoids name collisions (e.g. POSIX
  `write` vs an sx builtin) and gives an export a stable C-visible name.

### C Interop Type Mapping

| C type | sx type | Notes |
|--------|---------|-------|
| `const char*` (input) | `cstring` | the pointer, verbatim; literals coerce |
| `const char*` (input, legacy) | `[:0]u8` | compiler extracts `.ptr` at call site |
| `const char*` (return) | `cstring` | the pointer, verbatim; `from_cstring` to view |
| nullable `const char*` (both directions) | `?cstring` | null pointer = `null` |
| `char*` (output buffer) | `[*]u8` | raw buffer, no length |
| `const char**` | `*[:0]u8` | address of `[:0]u8` — `.ptr` at offset 0 |
| `int*` (single out) | `*i32` | |
| `unsigned*` (single out) | `*u32` | |
| `float*` (buffer) | `[*]f32` | |
| `void*` (generic) | `*void` | only for truly opaque/generic data |

### Vector Types (SIMD)
LLVM SIMD vectors, parameterized by length and element type.
```sx
v := vec3(1, 3, 2);  // Vector(3, f32)
```

**Arithmetic**: Element-wise `+`, `-`, `*`, `/` on vectors of same dimensions.
```sx
add := v1 + v2;     // element-wise addition
```

**Scalar broadcast**: Scalar operands are broadcast to match the vector.
```sx
scaled := v * 2.0;  // [2.0, 6.0, 4.0]
```

**Negation**: Unary `-` negates each element.
```sx
neg := -v;           // [-1.0, -3.0, -2.0]
```

**Element access**: `.x`, `.y`, `.z`, `.w` (aliases `.r`, `.g`, `.b`, `.a`) extract single components.
```sx
v.x     // first element
v.z     // third element
```

**Element assignment**: the same lane names are assignable l-values; plain and
compound assignment write a single component in place.
```sx
v.x = 1.0;    // write the first lane
v.y += 2.0;   // compound assignment to a lane
```

**Index access**: `v[i]` extracts by index.
```sx
v[0]    // first element
```

**Built-in `sqrt`**: Calls LLVM `llvm.sqrt.f32`/`.f64` intrinsic.
```sx
s := sqrt(9.0);     // 3.0
```

### Function Types
Expressed as `(param_types) -> return_type`.
A function with no return type annotation returns void.
```sx
// type is (i32) -> i32
compute :: (x: i32) -> i32 { x * x; }

// type is () -> void
main :: () { }
```

### Type Aliases
A name bound to an existing type.
```sx
SOME_TYPE :: f64;
```

A generic struct HEAD can be aliased too — the alias binds to the same
template, so instantiation, methods, annotations, and alias chains resolve
through it:

```sx
Box :: struct ($T: Type) { item: T; }
BoxAlias :: Box;                          // same template
b := BoxAlias(i64).{ item = 3 };
b2 : BoxAlias(string) = .{ item = "x" };  // annotation head too
```

The RHS may be a namespace member (`Box :: r.Box;`) — the alias is an
ordinary OWN declaration of the aliasing file, so it is visible to that
file's direct flat importers like any other declaration (this is how a
facade re-exports another module's generic struct). Each hop of an alias
chain resolves with the visibility of the file that declares THAT hop,
not the use site's. Not yet supported: a qualified head whose namespace
member is itself an alias (`ns.BoxAlias(..)`).

### Function Aliases

Functions alias the same way — bare or namespace-member RHS, renamed or
same-name — and the alias dispatches exactly like the target. This covers
every fn kind: plain, runtime-generic (`[]$T` / `$T: Type`), and
comptime-pack (`..$args`, e.g. `print` / `format`):

```sx
s :: #import "modules/std.sx";
my_print :: s.print;          // comptime-pack fn through a namespace
helper2  :: r.helper;         // renamed plain fn
my_print("x = {}\n", helper2());
```

(For making an alias *dot-callable*, see `name :: ufcs target;` in the
UFCS section — that is a separate, explicit opt-in.)

### Generic Functions (Monomorphization)
Functions can be parameterized over types using `$T` syntax. The `$` prefix introduces a type parameter; subsequent uses of the name reference it.
```sx
sum :: (a: $T, b: T) -> T {
    return a + b;
}
```
- `$T` in a parameter type **introduces** type parameter `T`
- Bare `T` (without `$`) **references** the introduced type parameter
- At call sites, type arguments are **inferred** from actual argument types:
  ```sx
  sum(40, 2)       // T = i32
  sum(1.5, 2.5)    // T = f32
  ```
- Each unique set of concrete types produces a **separate specialized function** (monomorphization)
- Multiple type parameters are supported: `(a: $T, b: $U) -> T`

### Variadic Functions
Functions can accept a variable number of arguments using `..name: []Type` syntax:
```sx
print :: (fmt: string, ..args: []any) { ... }
path_join :: (..parts: []string) -> string { ... }
```
- The leading `..` marks the parameter as variadic; the declared type is the
  slice the body sees (so `..parts: []string` makes `parts` a `[]string` inside).
- The variadic parameter must be the last positional parameter.
- For homogeneous element types (`[]i32`, `[]string`, ...), the call site packs the
  trailing args into a stack-allocated `[N x T]` and passes a slice over it.
- For `[]any`, each trailing arg is boxed into an `any` view (type tag +
  pointer; an lvalue arg is borrowed, an rvalue spills to a call-scoped temp)
  before packing; `args[i]` reads back the view.
- For `[]Protocol` (the element type is a protocol, e.g. `..xs: []Show`), each
  trailing arg is `xx`-erased to a protocol value `{ctx, vtable}` (impl-driven,
  like `xx`) and packed into a runtime `[N]Protocol`. `xs[runtime_i].method()`
  then dispatches through the protocol — this is the **runtime** counterpart to
  the comptime heterogeneous pack `..xs: Protocol`.
- A `..` spread at the call site unpacks an existing slice/array into the variadic
  tail: `sum(..arr)`.
- The heterogeneous comptime-pack form `..$args: []Type` binds per-position
  comptime types — see "Variadic Heterogeneous Type Packs" below.

### Variadic Heterogeneous Type Packs

A **pack** is a comptime sequence of per-position-typed arguments. Unlike a
slice variadic (`..xs: []T`, one uniform element type, a runtime slice), a pack
binds a *distinct* type to each position and exists only at compile time.

The full family of variadic/pack forms and how they differ:

| Form | Element types | Lives at | `xs[i]` index | `xs[i]` yields | `xs.len` |
|---|---|---|---|---|---|
| `..xs: []T` | one uniform `T` | **runtime** (slice) | runtime or comptime | `T` | runtime |
| `..xs: []any` | mixed, **boxed** to `any` | **runtime** (slice) | runtime or comptime | `any` (match/unwrap to use) | runtime |
| `..xs: []P` *(P a protocol)* | mixed, **erased** to `P` `{ctx,vtable}` | **runtime** (slice) | runtime or comptime | `P` (call protocol methods) | runtime |
| `..xs: P` *(pack)* | per-position **concrete**, each conforms to `P` | **comptime** (no runtime value) | comptime only (literal / `inline for` cursor) | the concrete element, **viewed through `P`** | comptime int |
| `..$args` / `..$xs: []Type` | per-position comptime **types** | **comptime** | comptime only | element value/type (reflection) | comptime int |

Key axis — **concrete vs erased, comptime vs runtime**:
- `..xs: P` (pack) keeps each element's *concrete* type but is **comptime-only**:
  `xs[i]` needs a compile-time index (a literal or an `inline for` cursor); a
  runtime index is an error (a pack has no runtime representation). Use it when
  you need per-position types (monomorphization, `xs.T` / `xs.value` projection).
- `..xs: []P` (slice of protocol) **erases** each element to the protocol value
  but is **runtime**: `xs[runtime_i].method()` works in an ordinary loop. Use it
  when you need to iterate the args at runtime and only the protocol interface
  matters. It is the runtime counterpart to the pack.

The heterogeneous pack (`..xs: P`) is what powers `map :: (mapper: ...,
..sources: ValueListenable) -> ...`: it accepts any number of trailing args,
each some `ValueListenable(T)` for a possibly-different `T`.

A pack is **not a runtime value** — it lowers to N typed positional parameters
(zero overhead). The body refers to elements only through the comptime forms
below; using the pack name where a runtime value is required is an error (see
"Pack as value").

**Element access is through the protocol, not the concrete type.** Although the
pack monomorphizes per call shape and each element has a known concrete type,
`xs[i]` is viewed **through the constraint protocol**: only the protocol's own
interface (its methods, and the projections `xs.T` / `xs.value`) is accessible.
Reaching a concrete member that isn't part of the protocol — e.g. `xs[i].v`
where `v` is a field of the concrete `IntBox` but not declared on `Show` — is an
error, exactly as it would be for a constrained generic `T: Show`. The protocol
constraint is enforced (each trailing arg must conform) and bounds what the body
may do, regardless of the concrete arg types at any particular call site.

#### Pack operations

| Use | Spelling | Meaning |
|---|---|---|
| Length | `xs.len` | comptime int (field-style, not `len(xs)`) |
| Index | `xs[i]` | i-th element; `i` must be comptime |
| Comptime unroll (index) | `inline for 0..xs.len (i) { ... }` | unrolled loop; cursor `i` is a comptime constant per iteration; not `#for` |
| Comptime unroll (element) | `inline for xs (x) { ... }` | unrolled loop; `x` is the concrete i-th element, viewed through the constraint protocol (≡ `xs[i]`) |
| Comptime unroll (element + index) | `inline for xs, 0.. (x, i) { ... }` | multi-iterable parity with the runtime `for`: position 0 drives the count, a trailing open range pairs the cursor |
| Projection | `xs.field` | see "Pack projection" |
| Spread → call args | `..xs` / `..xs.field` | expands to N positional args |
| Spread → aggregate value | `.{..xs}` / `.{..xs.field}` | materializes the pack (anonymous positional struct; a tuple against a `Tuple(…)` target) |
| Spread → tuple type | `Tuple(..F(Ts))` / `Tuple(..F(Ts.Arg))` | tuple type with per-element type application |
| Spread → callable sig | `Closure(..Ts) -> R` / `Closure(..Ts.Arg) -> R` | positional params of the callable |

#### Pack projection

`xs.field` projects the same member out of every element, preserving order.
Resolution is **position-driven** (no cross-namespace shadowing):

- In **type** position, `..xs.field` looks `field` up in the pack constraint's
  **type-arg** namespace. `ValueListenable :: protocol($T: Type) { ... }` declares
  type-arg `T`, so `..xs.T` is the pack of element value-types.
- In **value** position, `xs.field` looks `field` up in the constraint's
  **runtime-field** namespace and yields a *tuple* of the projected values
  (e.g. `xs.value` → `.{xs[0].value, xs[1].value, ...}`).

A protocol that declares a type-arg and a runtime field with the **same name**
compiles, but emits a soft warning at the protocol declaration (the human is
alerted; resolution still proceeds by position).

#### Tuple parallels

The same spread/projection syntax applies to a **tuple value** whose source is a
tuple rather than a pack:

- `..tuple` / `..tuple.field` spreads a tuple's fields into call args.
- `tuple.field` projects `field` out of every element (when all elements have a
  same-named field), returning a tuple of the projected values.

This lets a pack be materialized once (`stored := .{..xs}`) and later re-spread
(`f(..stored)`) or re-projected (`stored.value`).

#### Pack of zero (N = 0)

`xs.len == 0` is valid: `inline for` over an empty range doesn't execute, spreads
are no-ops, and `.{..xs}` is the empty aggregate. A library built on packs (e.g.
`map`) must handle N=0 — typically by producing a constant result that never
changes.

#### Pack as value

Because a pack has no runtime representation, using the **bare pack name** where
a runtime value is required is a compile error with a context-tailored
suggestion:

- storing/binding it (`x := xs;`, `self.f = xs;`) → materialize it (`.{..xs}`);
- passing it to a runtime call (`f(xs)`) → declare the parameter as a *slice*
  variadic `..xs: []P` (a runtime slice) instead of a pack `..xs: P`;
- returning it (`return xs;`) → return a materialized `.{..xs}` (and make the return
  type that tuple);
- iterating it (`for xs (x)`, `xs[runtime_i]`) → `inline for xs (x)` (or
  `inline for 0..xs.len (i)` for the index) for a comptime unroll, or take
  `..xs: []P` for a runtime loop.

The recurring runtime escape hatch is the **slice-of-protocol variadic**
`..xs: []P` (see "Variadic Functions"): it is the runtime, protocol-erased
counterpart to the comptime pack. A pack indexed/iterated/forwarded at runtime
is almost always better expressed by declaring `xs` as `..xs: []P` in the first
place.

#### Storage and protocol conformance

To **store** a pack, materialize a tuple: a pack-shaped struct field is
tuple-typed, `sources: Tuple(..ValueListenable(Ts))`, assigned `self.sources =
.{..sources}`. To **return** a struct as a protocol value, `xx` requires an
explicit impl (protocol erasure is impl-driven, not structural) — e.g.
`impl ValueListenable($R) for Combined($R, ..$Ts) { ... }`.

#### Canonical example

```sx
Combined :: struct($R: Type, ..$Ts: []Type) {
  sources:       Tuple(..ValueListenable(Ts));   // pack-spread in tuple type position
  mapper:        Closure(..Ts) -> $R;       // pack-spread in callable sig
  value:         $R;
  own_allocator: Allocator;

  recompute :: (self: *Combined) {
    new_val := self.mapper(..self.sources.value);  // tuple projection + spread
    if new_val == self.value  return;
    self.value = new_val;
  }
}

map :: (mapper: Closure(..sources.T) -> $R, ..sources: ValueListenable)
       -> ValueListenable($R) {
  c := context.allocator.alloc(Combined($R, ..sources.T));
  c.own_allocator = context.allocator;
  c.mapper        = mapper;
  c.sources       = .{..sources};           // pack-to-tuple materialization
  inline for 0..sources.len (i) {           // comptime unroll over the pack
    sources[i].addListener((_) => c.recompute());
  }
  c.value = mapper(..sources.value);        // pack spread + projection in a call
  return xx c;                              // needs impl ValueListenable for Combined
}

isReady : ValueListenable(bool) = map(
  (va, vb, vc) => va and vb > 10 and vc == "cool",
  a, b, c);                                 // a,b,c : ValueListenable(bool/i32/string)
```

### Type Inference
- `::` bindings infer type from the right-hand side
- `:=` bindings infer type from the right-hand side
- Explicit annotation overrides inference: `NAME : f64 : 0.9;`
- Integer literals default to `i64`
- Float literals default to `f64`
- Enum literals (`.variant`) infer their enum type from context (expected type)

### Type Conversions

**Implicit (widening)** — allowed without annotation:
- Integer to wider integer of same signedness (`u8` → `u16`, `i8` → `i32`)
- Unsigned to strictly wider signed (`u8` → `i16`)
- Any integer to any float (`u8` → `f32`, `i32` → `f64`)
- Float to wider float (`f32` → `f64`)
- Integer literals can convert to any numeric type implicitly

**Implicit float → integer (the unified narrowing rule)** — a float flowing into
an integer-typed binding without `xx`/`.(T)` is governed by the SAME rule an
array dimension / lane count uses (see "Array dimensions are integral", §2):

- An **integral** compile-time float **folds** to its integer, whether written
  as a literal or a const expression: `y : i64 = 4.0` ≡ `y : i64 = 4`,
  `n : i64 = -2.0` ≡ `-2`, `y : i64 = M + 2.0` → 4 (`M :: 2`). A const expression
  here is *any* compile-time-constant float expression — an integer-const leaf
  (`M + 2.0`), a float-typed const leaf (`F : f64 : 2.5; y : i64 = F + 1.5` → 4),
  a builtin float numeric-limit accessor (`f64.max - f64.max` → 0), a float `%`
  (`6.0 % 4.0` → 2), or a float `/` whose quotient is integral (`6.0 / 2.0` → 3),
  or any combination of them. The compile-time float evaluator recognises every
  leaf/operator shape the integer evaluator does (literal, named const,
  numeric-limit accessor, `+ - * / %`, unary negate), so no constant float form
  folds at one site while truncating at another. A float `/` is always FLOAT
  division even when both operands are integral — `6.0 / 2.0` is `3.0` (folds),
  but `5.0 / 2.0` is `2.5` (errors) — never integer truncating division.
- A **non-integral** compile-time float — literal OR const expression — is a
  **compile error** with one uniform wording at every site:
  `y : i64 = 1.5`, `y : i64 = M + 0.5`, `y : i64 = F + 0.25` (= 2.75),
  `y : i64 = f64.true_min + 0.5` (= 0.5), `y : i64 = 5.5 % 2.0` (= 1.5), and
  `y : i64 = 5.0 / 2.0` (= 2.5) all →
  "cannot implicitly narrow non-integral float '…' to 'i64'; use an explicit
  cast (`xx`/`.(T)`)".
- This applies uniformly to a typed **local**, a function **param default**, a
  struct **field default**, a call **argument**, a typed module **constant**
  (`K : i64 : 4.0` → 4; `K : i64 : M + 2.0` → 4; `N : i64 : 1.5` and
  `N : i64 : M + 0.5` → error), and an array **dimension** / count (`[F + 1.5]i64`
  ≡ `[4]i64`; `[F + 0.25]i64` → error). All five sites fold the *same* set of
  compile-time float expressions through one evaluator — only the dimension/count
  site phrases its rejection as "array dimension must be an integer, but '…' is a
  non-integral float", since the `xx`/`.(T)` escape does not apply in a count
  position. A **runtime** float (one with no compile-time value) is unaffected —
  narrow it explicitly with `xx` / postfix `.(T)`.

**Explicit (narrowing)** — requires `xx` prefix (or postfix `x.(T)`):
- Integer to narrower integer (`i32` → `u8`)
- Signed to unsigned (`i32` → `u32`)
- Float to narrower float (`f64` → `f32`)
- Float to any integer (`f64` → `u16`) — always **truncates**, integral or not
  (`y : i64 = xx 1.5` → 1); this is the escape hatch from the implicit rule above
- Unsigned to signed of same or narrower width (`u8` → `i8`)

The `xx` prefix operator marks an expression for auto-conversion to the expected type from context (assignment, declaration, argument, return):
```sx
large: f64 = 5999.5;
x : u16 = xx large;       // f64 → u16
d : u8 = #run xx resolve(5); // i32 → u8 at compile time
```

Using `xx` outside a typed context (where the target type is known) is a compile error.

When an explicit cast pair has **no modeled conversion** (and no user `Into`
applies), the cast is a raw bit-reinterpretation. Between two same-shaped
types (scalar↔scalar, aggregate↔aggregate — e.g. `string` ↔ `SliceRaw`) the
value passes through unchanged. Between an **aggregate-shaped value and a
scalar/pointer** the reinterpretation is **spill-mediated**: the value
passes through a zero-initialized memory slot typed as the larger side and
is loaded back as the target, so the result is a genuinely target-typed
value in every position (comparisons, call arguments, arithmetic — not just
stores). A width mismatch is deterministic: the smaller side covers/reads
its bytes and the rest are zero. User `Into` conversions always take
precedence over the reinterpretation fallback.

### Postfix Cast `expr.(T)`

`expr.(T)` converts `expr` to the written compile-time type `T` — the
explicit-target form of `xx`, sharing its entire engine: the same coercion
ladder, one engine rather than a second cast. "Safe" means
**well-defined**, not value-preserving: `1000.(i8)` truncates by definition.

A PROTOCOL target is the **owning erasure**: the postfix form always
produces an owned value — an independent heap copy for concrete
receivers (lvalue and rvalue alike), a SNAPSHOT of the pointee for a
`*Concrete` receiver, and a PROMOTION for a `*P` view (the pointee
protocol value with a fresh ctx copy of `rt_size_of(type_id)` bytes).
The two-argument form `expr.(P, alloc)` routes the copy through a named
allocator (the argument must be an LVALUE naming an allocator; pair with
`free(p, alloc)`). `#identity` targets keep the borrow (`gpa.(Allocator)`)
and refuse the allocator form. See Ownership and Lifetime.

```sx
b := a.(i8);            // narrow (truncates)
v := f.(i64);           // float → int
p := raw.(*Point);      // pointer bitcast; composite targets parse: *T, []u8, ?T
o := 5.(?i64);          // optional wrap
s := dog.(Speaker);     // protocol erasure — an OWNED, independent copy
u := dog.(Speaker, a);  // the same, allocated through `a`
x.(u8).(i64)            // postfix chains left to right
-x.(i8)                 // postfix binds tighter: -(x.(i8))
```

The target is exactly one **compile-time** type (a runtime-`Type` target
would make the expression untypeable). `56.(i8)` lexes as a cast (never a
float); `0..(5)` stays a range.

**Raw-view retrieval.** The fat-value raw views (`std.sx`: `ClosureRaw`
`{fn_ptr, env}`, `SliceRaw` `{ptr, len}` for slices AND strings,
`ProtocolRaw` `{ctx, type_id}`, and `AnyRaw` `{data, type_id}`) are
retrieved through this same engine — `c.(ClosureRaw)`, `name.(SliceRaw)`,
`p.(ProtocolRaw)` (or the `xx` spelling), `av.(AnyRaw)` (postfix ONLY —
see below). The protocol case is a MODELED conversion built field-wise, not
a bit reinterpret: `{ctx, __type_id}` is the prefix **both** protocol
layouts share (default `{ctx, __type_id, vtable}` and `#inline`
`{ctx, __type_id, fn_ptrs…}`), so the view is correct for either and the
result is a real value usable in any position (argument, return, store).
`ProtocolRaw` mirrors exactly that shared prefix — byte-identical to an
`any` `{data, type_id}`; an `#inline` value is wider, which is why the
build is field-wise and never a reinterpret. A protocol receiver with any
other concrete target is the checked DOWNCAST (see the assertion
temperaments — the receiver reads as its `{ctx, type_id}` prefix view);
the recovery targets — a pointer type (`p.(*T)`, the typed ctx read; `T`
must be a CONCRETE type or `void` — a pointer-to-protocol target is refused,
since ctx addresses the concrete value: lend a view of the protocol value
itself with `*p` instead),
`ProtocolRaw`, `any` (the explicit concrete view `xx p : any`), and
another protocol (re-erasure) — are conversions and pass through.

On an **`any` receiver** the assertion has three temperaments:

- **`.(T)` consumed via the error channel = graceful**: the assertion is
  failable `(T, !CastError)`; `try av.(i64)` propagates (the global
  `mismatch` tag is absorbed by an inferred `!` caller or any named set
  containing a `mismatch` tag), `av.(i64) or 0` falls back,
  `av.(i64) catch (e) { … }` binds the tag. Only a DIRECT assertion operand
  is consumed — an assertion nested in a call argument stays unconsumed.
- **`.(T)` unconsumed = panic on mismatch**: `v := av.(i64);` yields the
  value on a tag match and otherwise prints `type assertion failed at
  file:line: expected T, got U` (runtime type names) and exits 1. This is
  a deliberate carve-out from the unconsumed-failable rule, scoped to
  assertion forms — the implicit handler is `catch { panic }`, never a
  silent default.
- **`.(?T)` = soft**: mismatch is a *value* — `null` — never a failure or
  panic; the optional IS the check (comma-ok parity). The asserted type is
  the inner `T`, the result exactly `?T`, composing with the optional
  toolbox: `av.(?f64) ?? 9.5`, `if v := av.(?i64) { … }`, `== null`.

**`av.(AnyRaw)` is the raw-view retrieval, not an assertion** — the one
target exempt from the three temperaments: it answers the view's own
`{data, type_id}` pair, built field-wise (name-AND-shape gated, so only
the std `AnyRaw` shape triggers). The exemption is the bare postfix
target only: the soft form `.(?AnyRaw)` still asserts the boxed payload,
and `xx av` keeps its unchecked-unbox meaning for EVERY target, `AnyRaw`
included (the assert helpers' generic `xx av` depends on it).
`raw_make_any(r.type_id, r.data)` reassembles a working view from the
pair.

**Optional chaining**: `o?.(T)` maps the cast over an optional receiver —
chain-null is ALWAYS a value (`null` result, type `?T`), never a failure;
the regime applies to the payload. A typed `?U` receiver maps the
conversion (never fails: `ap?.(i64)` is `?i64`); a `?any` receiver maps the
assertion with the same three temperaments, each judging only a PRESENT
payload: `try o?.(i64)` is `(?i64, !CastError)` (null → null, match →
value, present mismatch → raises), unconsumed `o?.(i64)` panics only on a
present mismatch, and `o?.(?i64)` conflates chain-null and mismatch-null.
An optional TARGET flattens — `ap?.(?i64)` is `?i64`, one null level, never
`??i64`. An unchained `.(T)` on an optional receiver is a compile error
pointing at `?.(T)` / unwrap-first, and `x?.(T)` on a non-optional receiver
is likewise refused. Unchecked unboxing stays `xx`.
A **protocol-value** receiver's checked downcast (`p.(Square)`) is live:
every protocol value carries its concrete `type_id` word (RTTI Option B),
the receiver reads as its `{ctx, type_id}` prefix view, and the same
three temperaments apply (`try p.(Square)` / unconsumed panic /
`p.(?Square)` soft). See the protocol-receiver paragraph above for the
recovery targets that bypass the downcast.

---

## 3. Declarations

### Constant Binding (immutable)

```sx
// inferred type
NAME :: value;

// explicit type
NAME : type : value;
```

The `::` operator creates an immutable binding. The value is evaluated at
compile time when possible.

`::` is the one and only constant spelling in sx. `const` is not a keyword
and never will be — it is an ordinary identifier.

Examples:
```sx
SOME_INT    :: 0;           // i64
SOME_STR    :: "Hello";     // string
SOME_FLOAT  :: 0.3;         // f64
SOME_DOUBLE : f64 : 0.9;   // f64 (explicit)
SOME_FUNC   :: () => 42;    // () -> i64
SOME_TYPE   :: f64;         // type alias
SOME_ALIAS  :: SOME_INT;    // const alias — the target's type and value
```

A constant may alias another constant by bare name (`B :: A`), in any
declaration order and to any chain depth; the alias carries the target's type
and folds everywhere the target folds (values, `if` conditions, array
dimensions, `inline if` branch elimination). A cyclic alias never resolves and
diagnoses at the use site.

With an explicit annotation, the initializer must be compatible with the
annotated type, or the declaration is a compile-time `type mismatch` error: an
integer fits any integer or float type (`W : f32 : 800`), a float a float type, a
boolean `bool`, a string `string`, `null` a pointer or optional, and `---` any
type. The check is type-based, so it applies equally to a literal and to a
constant expression: both `N : string : 4` and `N : string : M + 2` (with
`M :: 2`) are rejected at the declaration — neither registers a usable constant.
A constant expression's type is its promoted result type (see
[Arithmetic](#arithmetic)), so a mixed int+float initializer is a float in either
operand order: `C : i64 : M + 0.5` and `C : i64 : 0.5 + M` are both rejected, and
`F : f64 : M + 0.5` is accepted and folds to `2.5`.

#### Array Constants

An array-typed `::` constant is an **immutable global**: one storage,
registered once, marked constant in the emitted binary. Indexed reads GEP
into that storage directly — no per-use copies. Unused array constants are
dropped by dead-global elimination.

```sx
K : [4]i64 : .[11, 22, 33, 44];   // typed
A :: .[1, 2, 3];                  // untyped — infers [3]i64
M :: .[1, 2.2, 3];                // untyped — infers [3]f64

x := K[i];      // GEP into the global — no copy
y := K;         // by-value copy (normal array-value semantics);
                // mutating y does not touch K
f(K);           // by-value param — copy at the call
p := *K;        // *[4]i64 — address of the const storage (reads)
```

Untyped inference unifies the element types: all ints → `i64`; any float
present promotes the whole element type to `f64` (int elements convert
exactly, mirroring "an integer fits any integer or float"); all floats →
`f64`; `bool` / `string` elements must be homogeneous. Element shapes may
nest (array-of-structs, array-of-arrays, struct-containing-array). The
length comes from the element count.

Diagnostics (each rejects the declaration):
- A non-numeric element mix (string + int, bool + int):
  `constant 'X' mixes incompatible element types — annotate the array type`.
- A runtime element (a call, a variable read):
  `constant 'X' must be initialized by compile-time constant elements`.
- A typed declaration whose length disagrees with the initializer:
  `constant 'X' declares [3] elements but its initializer has 2`.

#### Struct Constants

A struct-typed constant whose every field **serializes** — literals, enum
literals, bools, strings, nested aggregates, named-const leaves, constant
expressions (`K + 1`), another constant's field (`LIT.r`), a const array's
element (`A[1]`) — becomes an immutable global exactly like an array
constant: one storage, field reads GEP it, `*LIT` is addressable, copies
are independent. The same constant-expression forms are accepted as
elements of array constants.

```sx
Color :: struct { r, g, b: i64; }
LIT  :: Color.{ r = 255, g = 0, b = 0 };        // one global; uses GEP it
EXPR :: Color.{ r = K + 1, g = K * 2, b = 0 };  // folds, also one global
W : Color : Color.{ r = 1, g = 2, b = 3 };      // typed form, same storage
```

A struct constant with a **non-serializable** initializer field (a call, a
runtime-global read, `*x`, `context`) keeps **inline re-lowering**
semantics: the initializer is evaluated **at each use**. This is the
documented contract for this class — side effects run per use and the
value may differ between reads:

```sx
counter : i64 = 0;
bump :: () -> i64 { counter += 1; counter }
CALL :: Color.{ r = bump(), g = 0, b = 0 };

print("{} {}\n", CALL.r, CALL.r);   // prints '1 2'; counter is now 2
```

For evaluate-once semantics use `NAME :: #run f();` (see
[Compile-time Evaluation](#8-compile-time-evaluation)).

#### Constant Folding over Aggregates

An array constant's `.len` and `K[<const idx>]` element reads, and a
struct constant's field (`LIT.r`), are compile-time integer leaves —
usable in array dimensions and in other constants' initializers,
source-aware like every const fold:

```sx
N :: K[0] + K[3];    // 55 — folds
L :: K.len;          // 4
D : [K[1]]u8 = ---;  // [22]u8 — const-index read in a dimension
E :: K[9];           // error: index 9 is out of bounds for constant 'K'
                     //        (4 elements) — diagnosed at fold time
```

#### Constant-Write Rejection

An assignment or compound assignment whose target chain is **rooted at a
constant** is a compile error — scalar consts, array-const elements, and
struct-const fields alike:

```sx
N = 9;          // error: cannot assign through constant 'N' —
K[0] = 5;       //   constants are immutable (use a '=' global or a
K[1] += 2;      //   local copy for mutable data)
WHITE.r = 0;    // same — struct field
```

Two boundaries:
- A **local that shadows** the constant's name is an ordinary variable and
  stays writable.
- A **dereference along the chain breaks the root**: `p.*` writes through a
  pointer, and pointer writes are unchecked (see
  [Pointer Types](#pointer-types) — writing into constant storage through
  a pointer is undefined behavior).

### Variable Binding (mutable)

```sx
// inferred type
name := value;

// explicit type
name : type = value;

// default-initialized (type required)
name : type;

// undefined (type required)
name : type = ---;
```

The `:=` operator creates a mutable binding. The type is inferred unless explicitly annotated.

`name : type;` initializes using the type's defaults: zero for primitives, per-field defaults for structs (see Field Defaults).

`name : type = ---;` leaves the value undefined (uninitialized memory). Reading before writing is undefined behavior.

Examples:
```sx
x := 42;              // i32, mutable
x := if true then 1 else 2;
z : Foo = .variant2;  // Foo, mutable, explicit type
a : Foo;              // Foo, default-initialized (a=0, b=42, c=undef)
b : Foo = ---;        // Foo, entirely undefined
```

### Function Definition

```sx
name :: (params) -> return_type {
  body
}
```

- Parameters: `name: type` separated by commas
- Return type: `-> type` (omit for void). A multi-value return is a tuple: `-> Tuple(T1, T2)`.
- Body: a block whose **value** is its last statement when that statement is a
  trailing expression with **no** `;` (see [Block values](#block-values)). That
  value is the implicit return; an explicit `return` works too.

A trailing `!` in the return type marks the function **failable** — it adds a
separate error channel alongside the normal returns. The `!` sits **outside**
the tuple: `-> (T, !)` (one value), `-> (T1, T2, !)` (multi value), `-> !`
(void). The `!` is not a wrapper around the value; it is one more return slot.
See [§12 Error Handling](#12-error-handling).

Examples:
```sx
compute :: (x: i32) -> i32 {
  x * x          // trailing expression, no `;` → the return value
}

square :: (x: i32) -> i32 {
  return x * x;  // explicit return is equivalent
}

main :: () {
  // void return, no -> annotation
}
```

#### Block values

A block's **value** is its last statement, but only when that statement is a
trailing expression with **no** trailing `;`. A trailing `;` discards the value,
leaving the block void. This applies uniformly to every block used in value
position: function bodies, `if` / `else` branches, value-bound blocks
(`x := { … }`), and `catch` bodies.

```sx
a := { f(); g() };    // value is g()
b := { f(); g(); };   // void — the `;` discards g()'s value
```

A block in **value position** that produces no value is a compile error (rather
than silently returning a zero default):

```sx
double :: (n: i32) -> i32 {
  n * 2;   // error: value discarded by `;` — drop it, or use `return`
}
```

**Match arms are exempt.** In `case .x: expr;` the `;` is an arm terminator, not
a value-discard, so the arm still yields `expr`. Only an explicit inner braced
block inside an arm follows the rule:

```sx
classify :: (n: i32) -> i32 {
  if n == {
    case 0: 100;            // arm value is 100 (the `;` is just the separator)
    case 1: { x := 5; x*2 } // braced block, no trailing `;` → value 10
    else:   7;
  }
}
```

A `defer` / `onfail` cleanup body and loop bodies are statement (void) contexts,
so a trailing `;` there is fine and changes nothing.

#### Default Parameter Values

A parameter can declare a default value with `name: type = expr`. When a
caller omits the trailing positional argument, the compiler substitutes
the default expression at the call site:

```sx
greet :: (name: string, prefix: string = "Hello") {
    print("{} {}!\n", prefix, name);
}

greet("world");                 // prints "Hello world!"
greet("world", "Good morning"); // prints "Good morning world!"
```

The default expression is captured as an AST node at parse time and
re-lowered fresh at each call site, so runtime expressions like
`context.allocator` resolve in the **caller's** scope, not the callee's
definition site. This is the mechanism that lets stdlib containers like
`List(T)` expose an optional allocator argument that defaults to
`context.allocator` without requiring callers to thread one through:

```sx
// In std.sx:
List :: struct ($T: Type) {
    append :: (list: *List(T), item: T, alloc: Allocator = context.allocator) {
        // ... grows via `alloc.alloc(...)` ...
    }
}

// Call sites:
list.append(42);                         // alloc = current context.allocator
list.append(42, self.parent_allocator);  // alloc = the named long-lived owner
```

Defaults are only consulted for **trailing** missing positional args; once
a position is provided, all earlier positions must also be provided. There
is no named-argument syntax for skipping middle defaults.

### Enum Definition

```sx
Name :: enum {
  variant1;
  variant2;
}
```

Defines a new enum type with the given variants. Trailing comma is allowed.

### Enum Backing Type

An optional backing type can be specified after the `enum` keyword (Jai-style):

```sx
Color :: enum u8 { red; green; blue; }
Status :: enum i16 { ok; error; timeout; }
```

Syntax: `Name :: enum [flags] [type] { ... }`

The backing type must be an integer type (`u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `i64`, etc.). When omitted, the default is `i64`. This is useful for C interop (matching C enum sizes) and memory efficiency.

### Enum Layout Struct

For C interop with tagged unions (e.g. SDL_Event), a struct can be used as the backing type to specify the exact memory layout:

```sx
// Inline layout
SDL_Event :: enum struct { tag: u32; _: u32; payload: [30]u32; } {
    quit :: 0x100;
    key_down :: 0x300: SDL_KeyData;
    key_up :: 0x301: SDL_KeyData;
}

// Named layout
EventLayout :: struct { tag: u32; _: u32; payload: [30]u32; }
SDL_Event :: enum EventLayout {
    quit :: 0x100;
    key_down :: 0x300: SDL_KeyData;
}
```

The layout struct must have:
- A field named `tag` — integer type, the discriminant. Its type becomes the enum's backing type.
- A field named `payload` — array type, the variant data area. Its size determines the maximum payload capacity.
- Any other fields are treated as padding/reserved and positioned by the struct layout.

This gives explicit control over the memory layout instead of relying on automatic alignment. The total size equals the struct size. Without a layout struct, tagged enums use `{ tag, [max_payload_size x i8] }` with no padding.

### Enum Flags

```sx
Perms :: enum flags {
    read;       // 1
    write;      // 2
    execute;    // 4
}
```

Flags can also specify a backing type:

```sx
SDL_InitFlags :: enum flags u32 {
    video :: 0x20;
    audio :: 0x10;
}
```

The `flags` modifier assigns auto power-of-2 values (1, 2, 4, 8, ...) instead of sequential indices (0, 1, 2, ...). Flags can be combined with `|` and tested with `&`:

```sx
p :Perms = .read | .write;
if p & .execute { ... }
print("{}\n", p);   // .read | .write
```

Explicit values use `::` syntax (Jai-style):

```sx
WindowFlags :: enum flags {
    vsync     :: 64;
    resizable :: 4;
    hidden    :: 128;
}
```

Restrictions:
- Flags enum variants cannot have payloads
- `flags` is a contextual identifier, not a keyword

### Bitwise Operators

All bitwise operators work on integer types. `>>` is arithmetic (sign-extending) for signed types and logical (zero-filling) for unsigned types.

```sx
x := 0xFF & 0x0F;   // 15  — AND
y := 1 | 2 | 4;     // 7   — OR
z := 0xFF ^ 0x0F;   // 240 — XOR
w := ~0;             // -1  — NOT
a := 1 << 4;         // 16  — left shift
b := 256 >> 4;       // 16  — right shift
```

Compound assignment forms: `&=`, `|=`, `^=`, `<<=`, `>>=`.

```sx
x := 0xFF;
x &= 0x0F;   // 15
x |= 0xF0;   // 255
x ^= 0x0F;   // 240
y := 1;
y <<= 8;     // 256
y >>= 4;     // 16
```

---

## 4. Expressions

Everything in `sx` is expression-oriented where possible.

### Operator Precedence

| Prec | Operators | Notes |
|------|-----------|-------|
| 9 (highest) | `*`, `/`, `%` | multiplication, division, modulo |
| 8 | `+`, `-` | addition, subtraction |
| 7 | `<<`, `>>` | shifts |
| 6 | `<`, `<=`, `>`, `>=`, `==`, `!=` | comparisons (chainable) |
| 5 | `&` | bitwise AND |
| 4 | `^` | bitwise XOR |
| 3 | `\|` | bitwise OR |
| 2 | `and` | logical AND (short-circuit) |
| 1 (lowest) | `or` | logical OR (short-circuit) / failable fallback (§12) |

`try` is a unary prefix in the same tier as `xx` / `*` / `-` / `!` / `~`
(tighter than every binary operator, including `or`); `catch` is a postfix
attached to a failable expression. So `try foo() or try boo()` parses as
`(try foo()) or (try boo())`. See [§12 Error Handling](#12-error-handling).

### Arithmetic
Standard infix: `+`, `-`, `*`, `/` with usual precedence (`*`/`/` before `+`/`-`).
```sx
x * x
x + 2
```

**Numeric promotion.** When the two operands of an arithmetic op have different
numeric types, the result is the promoted type: an integer operand combined with
a floating-point operand yields the **float**, regardless of operand order
(`n + 0.5` and `0.5 + n` both produce an `f64`). This holds for the expression's
static type as well as its value, so `print("{}", n + 0.5)` formats a float and a
typed binding `x : f64 = n + 0.5` is exact (not truncated). A mixed-numeric
expression therefore does not satisfy an integer annotation — `C : i64 : n + 0.5`
is a `type mismatch` in either operand order.

### Chained Comparisons
Comparison operators can be chained. Each operand is evaluated exactly once.
```sx
0 <= x <= 100          // equivalent to: 0 <= x and x <= 100
1000 > x >= -100       // equivalent to: 1000 > x and x >= -100
a == b == c            // equivalent to: a == b and b == c
```
Mixed operators are allowed: `a < b <= c > d` means `a < b and b <= c and c > d`.

### Logical Operators
`and` and `or` are short-circuit boolean operators. The right operand is not evaluated if the left operand determines the result.
```sx
if 0 <= x <= 100 and 0 <= y <= 100 {
    print("contained");
}
```

### If Expression (inline form)
```sx
if condition then consequent else alternate
```
Both branches are single expressions. The whole form produces a value.
```sx
x := if true then 1 else 2;
```
The `else` branch is optional. Without it, the form is a statement (no value):
```sx
if i == 2 then continue;
if done then break;
if err then return;
```

### If Expression (block form)
```sx
if condition {
  stmts
} else {
  stmts
}
```
Each branch is a block. The last expression in each block is the branch's value. Can be used inline within other expressions:
```sx
y := x + if false {
  7;
} else {
  12;
};
```

### Pattern Matching
```sx
if subject == {
  case pattern: body
  case pattern: body
  else: body          // optional default arm
}
```
Matches `subject` against each `case`. Patterns can be:
- **Enum literals**: `.variant` — matches a specific enum variant.
- **Integer/bool literals**: `42`, `true` — matches a specific value.
- **Type categories**: `struct`, `enum`, `union` — matches all types in that category (used with `type_of` values).

`break` exits a case arm without producing a value. The optional `else:` arm matches when no `case` pattern matches.
```sx
if z == {
  case .variant1: break;
  case .variant2:
    print("z: {z}");
  else:
    print("unknown");
}
```

#### Type Category Matching
When switching on a `Type` value (from `type_of`), category keywords match all registered types of that category:
```sx
type := type_of(val);
if type == {
    case int: {
        if is_unsigned(type) { result = uint_to_string(xx val); }
        else { result = int_to_string(xx val); }
    }
    case struct: result = struct_to_string_over_views(type, val);
    case enum: result = enum_walk_over_tables(type, val);
}
```
Available categories: `int`, `float`, `bool`, `string`, `void`, `struct`, `enum`, `union`, `vector`, `array`, `slice`, `pointer`, `optional`, `error_set`, `closure`, `type`. The `int` arm branches on signedness — `is_unsigned(type)` routes unsigned types to their unsigned-decimal formatter, so values like `u64.max` print as `18446744073709551615` rather than `-1`.

> Note: `case enum:` matches payload-less enums AND tagged enums (enums
> with payloads); `case union:` matches C-style untagged unions AND
> tagged enums — the same split as the static `inline if T ==`
> classifier, arm for arm. Arms claim tags **first-wins with the loud
> unreachable-arm error**, exactly like the type switch: overlapping
> categories resolve by order, a specific type — user-named
> (`case Point:`), builtin (`case i64:`), or a composite type expression
> (`case ?i64:`, `case []u8:`) — must come before the category that
> contains it, and an arm left with no tags is a compile error, never a
> silently dead arm. Unknown names and value patterns are pointed
> compile errors.

Inside a category arm the subject stays an `any` and the matched `type` a runtime `Type` — arms handle the value through the runtime reflection surface (the table-backed builtins, `any` views like `struct_field_value` / `variant_payload` / `any_element`, `raw_make_any`) with ONE compiled body per arm; `xx val` in the `int`/`float` arms width-dispatches over the arm's tag set. An EXACT-tag walk asserts with `val.(T)`. (The old `cast(type, val)` per-type monomorphizing fan-out is removed with `cast`.)

#### Type Switch (`any` subjects)

Matching directly on an **`any`** value dispatches on its runtime type
TAG — never the payload (Go's `switch v := x.(type)` / Odin's
`switch v in x` parity):

```sx
if av == {
    case i64: (v)   { print("int {}\n", v + 1); }      // v: i64 — the typed value
    case Point: (p) { plot(p); }                       // named types
    case []u8: (b)  { print("{} bytes\n", b.len); }    // composite types are real tags
    case ?i64: (o)  { print("{}\n", o ?? 0); }         // tags are EXACT — no flattening
    case struct:    { walk_fields(av); }               // categories: tag SETS, no binding
    case int:       { print("{}\n", xx av); }          // xx width-dispatches over the set
    else:           { print("{}\n", type_name(type_of(av))); }   // av stays `any`
}
```

- **Concrete arms** name one type — named, builtin, or a composite type
  expression — resolved by the same resolver every type position uses
  (aliases are transparent). An optional `(v)` capture binds exactly what
  `v := av.(T)` produces, with the tag pre-proven by the switch: no panic
  path. Works in value position.
- **Category arms** (`int`, `float`, `struct`, `enum`, `union`, `slice`,
  `array`, `pointer`, `vector`, `optional`, `error_set`, `closure`,
  `type`) are tag SETS and cannot bind `(v)` — a kind names many types;
  read the value through the reflection views, or `xx av` in the
  `int`/`float` arms (per-tag width dispatch). `string`/`bool`/`void`
  are single types and take the concrete path, so their arms CAN bind.
- **Arms overlap first-wins, loudly**: a tag belongs to the first arm that
  names it, so a concrete arm must come BEFORE the category that contains
  it (`case i64:` above `case int:`). An arm left with no tags — the
  reverse order, or a duplicate — is a compile error, never a silently
  dead arm. Value patterns (`case 5:`) are a compile error: the payload is
  never the scrutinee.
- **Subjects**: `any` and PROTOCOL values. A protocol subject switches
  through its `{ctx, type_id}` prefix view — same arms, same captures,
  over the concrete value the protocol erases. A `?any` composes through
  the optional match (`case .some: (av) { … }`).
- Division of labor: the type switch dispatches on CONCRETE types and
  binds typed values; kind-only dispatch also exists as the category match
  on `type_of(av)` and as the static `inline if T == { … }` fold in
  generic bodies.

#### Inline Type Match (static pruning)

`inline if T == { case <category|Type>: … else: … }` over a **bound generic
type param** selects its arm at lower time — the siblings are dropped
whole, exactly like `inline if` branch elimination. Each kind arm may
therefore use kind-specific operations that would not type-check for other
kinds (`x.len` in a slice arm, `x.(ProtocolRaw)` in a protocol arm):

```sx
free :: ufcs (x: $T, a: Allocator = context.allocator) {
    inline if T == {
        case protocol: a.dealloc_bytes(x.(ProtocolRaw).ctx);
        case closure:  { env := x.(ClosureRaw).env; if env != null { a.dealloc_bytes(env); } }
        case slice:    a.dealloc_bytes(xx x.ptr);
        else:          #error("free expects a protocol value, a closure, or a slice");
    }
}
```

Arms select in order (a specific type name may precede its category);
`else:` matches when nothing else does; with no match and no `else:` the
match lowers to nothing (the runtime form's skip-to-merge, statically). A
`#error(…)` arm fires only when SELECTED — the un-selected case is
the OS-match discipline. The static classifier mirrors the runtime tag
switch arm for arm, **plus the `protocol` category** (default and
`#inline` protocol values alike), which exists ONLY here: a protocol value
carries no runtime type tag, so a runtime `case protocol:` is a pointed
compile error rather than a silently dead arm. Inline branches lower in
statement position (like `inline if OS`), so value-producing arms use
explicit `return`. A NON-inline type match keeps its runtime tag-switch
semantics unchanged.

### While Loop
```sx
while condition {
  body
}
```
Repeats `body` as long as `condition` is true. `break;` exits the loop. `continue;` skips to the next iteration.
```sx
i := 0;
while i < 10 {
    i += 1;
    if i == 5 { continue; }
    if i == 8 { break; }
    print("{i}\n");
}
```

### For Loop

```sx
for it1, it2, ... (c1, c2, ...) { }   // parallel iteration, one capture per iterable
for it1, it2, ... (c1, c2, ...) => stmt;   // arrow body — a single statement
```

A `for` header is a comma-separated list of **iterables** followed by an
optional **capture group** and the body. Each iterable is a collection
(array, slice, string, `List(T)`-like struct) or a range:

```sx
for xs (x) { }                      // collection, element capture
for 0..n (i) { }                    // range, `end` exclusive; cursor i (i64)
for 1..=5 (a) { }                   // `..=` — end inclusive: 1 2 3 4 5
for 0..5 { }                        // no captures — body runs 5 times
for xs { }                          // no captures — body runs xs.len times
for xs, 0.. (x, i) { }              // THE index idiom: open range follows along
for xs, ys (x, y) { }               // parallel (zip) iteration
for 1..=5, 0.. (a, b) { }           // a: 1..5, b: 0..4 (end inferred)
for a4, b4, 100.. (p, q, k) { }     // any number of positions
for xs (x) => sum += x;             // arrow body
inline for 0..n (i) { }             // comptime unroll; first range bounded
inline for xs, 0.. (x, i) { }       // comptime unroll over a PACK: x = the
                                    // concrete i-th element (see "Variadic
                                    // Heterogeneous Type Packs")
```

**Range bound markers.** Each side of `..` takes an optional marker — `=`
inclusive, `<` exclusive — with defaults start-inclusive, end-exclusive
(`a..b` ≡ `a=..<b`; `a..=b` is the short end-inclusive spelling):

```sx
for 0<..<5 (i) { }    // 1 2 3 4      — both ends exclusive
for 0=..=5 (i) { }    // 0 1 2 3 4 5  — both ends inclusive
for 0<..=5 (i) { }    // 1 2 3 4 5
for 0=..<5 (i) { }    // 0 1 2 3 4    — explicit spelling of `0..5`
for 0..<5  (i) { }    // 0 1 2 3 4    — explicit spelling of `0..5`
for xs, 2<.. (x, i) { }  // open range with an exclusive start: i = 3, 4, …
```

A marker after the dots (`..=` / `..<`) makes the end expression mandatory;
the open form is `a..` (or `a<..` / `a=..`). The lexemes are single tokens —
no whitespace inside (`0 <..< N` is fine, `0 < ..` is not a range).

**First-iterable-wins.** The FIRST iterable's length drives the loop: a
bounded range runs `end - start` times (`..=`: `end - start + 1`), a
collection runs `len` times. The first iterable must be bounded — an open
range `a..` may only follow it. Every other position simply follows along by
its own cursor; consequences:
- a non-first range's end is **not consulted** (and not evaluated — write
  `start..` for clarity);
- a non-first collection shorter than the first is read **past its length**
  on mismatch — the first iterable is the authoritative one.

**Captures are positional**: the group binds one name per iterable, in
order — range positions bind the cursor value (i64), collection positions
bind the element. An empty group is omitted entirely (no parens). Capture
names shadow outer bindings, like any inner declaration. Use `_` to discard
a position. The old single-iterable index form `for xs: (x, i)` is gone —
write `for xs, 0.. (x, i)`.

**The capture/call rule.** In a for header, the parenthesized group
immediately before `{` or `=>` is the capture; every earlier top-level paren
group is ordinary call syntax. So `for zip(a, b) (x, y) { }` calls
`zip(a, b)` and captures `(x, y)`, while `for f(n) { }` reads `(n)` as the
capture — making the iterable `f` itself, which errors ("cannot iterate")
with a hint. A call iterable therefore always needs a capture group; to
iterate a call result without one, parenthesize (`for (f(n)) { }`) or bind
it to a local first. A leading paren group is a normal grouped expression
(`for (a ++ b) (x)` iterates the grouped value).

**By-value captures are immutable** (issue 0219). This rule is not
specific to for-loop element captures — it holds for *every* by-value
capture binding: the for-loop element and the paired range index
(`for xs, 0.. (x, i)` — both `x` and `i`), a match-arm payload capture
(`case .circle: (r)`), a `catch` / `onfail` error binding
(`f() catch (e)`), and an `inline for` pack-element alias
(`inline for xs (x)`). A capture is a read-only alias into storage the
loop/match/error machinery owns, not a fresh mutable local; assigning to
it bare (`x = v`, `i = 99`, `r = 5.0`, `e = error.Bad`) is a compile
error rather than a silent no-op. To mutate, copy the capture into a
`:=` local (`v := x; v += 100;`) — the copy is yours to change and
cannot accidentally look like it writes back. To write *through* into
the container, use a for-loop **by-reference** capture (`for xs (*x)`,
below) and store via the pointer (`x.* = v`); range positions and
match/catch payloads have no container storage to write back into, so
they are copy-into-a-local only. The diagnostic is shape-aware: only the
for-loop element form suggests `(*x)`; the storage-less shapes get the
copy-into-a-`:=`-local advice alone. A **function-local `::` constant**
(`c :: 5`) is enforced by the same mechanism — assigning to it is a
compile error with the constant-family message, mirroring module-level
`::` consts. (Rationale: mutating a per-iteration
copy that vanishes at the next iteration is almost always a bug — the
author meant `(*x)`. This also matches the copy-semantics chosen for the
issue-0214 `xx`-erasure materialization, where a by-value capture is
likewise snapshotted into a fresh temp rather than written back.)

**By-reference capture (`*elem`)** binds the element to a *pointer* into the collection (`*T`) instead of a value — no per-element copy. It GEPs straight into the array/slice backing, so:
- Passing it onward is zero-copy — `f(elem)` where `f` takes `*T` hands over the pointer, not a copy.
- Writes through it land in the original: `elem.* = v` (or `elem.field = v`).
- In a value position the pointer auto-derefs to the element: `elem + 1` reads the value, and `if elem == { … }` matches the pointee (a pointer subject matches through the deref). Where a `*T` is expected, the pointer is passed as-is.
- Range positions have no storage — `*` on a range capture is a compile error.

```sx
events := plat.poll_events();        // []Event
for events (*ev) {                   // ev : *Event — no copy
    pipeline.dispatch_event(ev);     // passes the pointer
}
```

The `inline` variant requires a single bounded range with comptime-known
bounds and unrolls the body once per value, binding the cursor as a
compile-time constant (so it can index a pack:
`inline for 0..xs.len (i) { xs[i].m() }`).

`break;` exits the loop. `continue;` skips to the next iteration. Both run
the iteration's pending `defer`s first (see Defer).
```sx
arr : [5]i32 = .[1, 2, 3, 4, 5];
for arr, 0.. (val, ix) {
    if ix == 2 { continue; }
    print("{}\n", val);
}
```

### Lambda
```sx
(params) => expr
(params) -> return_type => expr
```
Anonymous function. Produces a function value. Supports the same parameter features as named functions: `$` generic type params, `..` variadic params, and optional return type annotation.
```sx
SOME_FUNC :: () => 42;                    // () -> i32
double :: (x: $T) -> T => x + x;         // generic lambda with return type
```

### Closures

A **closure** is a function bundled with captured state. It is represented as a fat pointer `{ fn_ptr, env }` (16 bytes), unlike a bare function pointer which is 8 bytes.

#### Closure Type
```sx
Closure(param_types) -> R     // e.g. Closure(i32, i32) -> i32
Closure(param_types)          // void return: Closure(i64) -> void
?Closure(i32) -> i32          // optional closure (null = none)
Closure(..Ts) -> R            // pack-expanded params (see Variadic Heterogeneous Type Packs)
```

#### Creating Closures — `closure()` intrinsic
```sx
offset := 50;
f := closure((x: i32) -> i32 => x + offset);  // expression body
g := closure((x: i32) -> i32 {                 // block body
    if x < 0 { return 0; }
    return x + offset;
});
```

The `closure()` intrinsic:
1. Analyzes the lambda body for free variables (variables from outer scope)
2. Allocates an env struct on the heap (via `malloc`) containing captured values
3. Generates a trampoline function with signature `(env: *void, params...) -> R`
4. Returns a `Closure` value `{ trampoline, env_ptr }`

**Capture semantics**: capture by value (snapshot at creation time). Mutating the original variable after creating the closure does not affect the captured value.
```sx
n := 10;
f := closure((x: i64) -> i64 => x + n);
n = 999;
print("{}\n", f(5));  // 15, not 1004
```

#### Calling Closures
Closures are called with normal function call syntax:
```sx
result := f(10);
```
The compiler prepends the env pointer to the argument list and does an indirect call through the fn_ptr.

#### Auto-Promotion
A bare function can be implicitly promoted to a `Closure` where one is expected. The compiler generates a static thunk that ignores the env parameter, with a null env pointer.
```sx
double :: (x: i32) -> i32 { return x * 2; }
apply :: (f: Closure(i32) -> i32, x: i32) -> i32 { return f(x); }
apply(double, 10);  // double auto-promoted to Closure
```

#### Factory Functions
Functions can return closures, enabling the factory pattern:
```sx
make_adder :: (n: i32) -> Closure(i32) -> i32 {
    return closure((x: i32) -> i32 => x + n);
}
add5 := make_adder(5);
print("{}\n", add5(100));  // 105
```

#### Optional Closures
`?Closure` is supported for nullable callbacks. Uses `fn_ptr == null` as the none sentinel (zero overhead — same layout as `Closure`).
```sx
Button :: struct {
    label: string;
    on_click: ?Closure(i64) -> void;
}
btn := Button.{ label = "OK", on_click = null };
if handler := btn.on_click {
    handler(1);
}
```

#### Memory
Closure env is allocated via `context.allocator`. The compiler auto-initializes `context` with a default GPA (malloc/free wrapper) at the start of `main()`. Use `push Context` to override with a custom allocator. Auto-promoted closures have a null env and require no allocation.
```sx
f := closure((x: i64) -> i64 => x + 10);  // env allocated via default GPA
print("{}\n", f(5));
```

### Function Call
```sx
callee(args)
```
```sx
compute(6)
print("hello")
```

### Named Arguments
```sx
callee(positional..., name = value, ...)
```
Call-site sugar over positional parameters. Names are **not** part of a
function's identity (no Swift-style labels, nothing to overload on); a named
argument binds a value to a declared parameter name, and the spelling matches
struct literals exactly (`name = value` — the argument slot is free because
assignment is statement-only).

```sx
scaffold :: (top_bar: ?Closure() = null, fab: ?Closure() = null, content: Closure()) { ... }

scaffold(content = chat_list);                       // reach past defaults by name
scaffold(top_bar = toolbar, content = chat_list);    // any order among named
scaffold(chat_list_closure, fab = fab_button);       // positional, then named
```

- **Order**: positional arguments first, then named ones. A positional
  argument after a named one is an error ("positional argument after a named
  argument — name it or move it before the named arguments").
- **Binding**: a named argument binds by the callee's declared parameter
  name; named arguments may appear in any order among themselves. Each
  parameter binds **at most once** — naming a parameter a positional argument
  already filled is the duplicate-binding error.
- **Evaluation order is written order**: arguments evaluate left-to-right
  exactly as written; mapping to parameter positions happens afterwards.
  Side effects observe the call site's textual order, never the declaration
  order.
- **Defaults become reachable anywhere**: a named argument can skip any
  defaulted parameter, including ones in the middle of the list. Purely
  positional calls keep the existing rule — only a *trailing* run of
  defaulted parameters may be omitted.
- **Positional-only zones**: three parameter kinds never bind by name —
  closure-typed *values'* parameters (`Closure(i64) -> i64` declares types,
  not names), variadic tails, and comptime `$` parameters (bound by the
  type/value argument machinery). Naming one is an error.
- **Unknown / missing names**: an unknown argument name is an error with a
  did-you-mean suggestion; missing required parameters are reported by name.

UFCS calls compose: the receiver binds the FIRST parameter positionally, and
named arguments may bind the rest (`buf.write_all(data, flush = true)`). A
ufcs **alias** resolves names against the *target* function's declared
parameter names. Extern functions accept named arguments when their
declaration declares parameter names.

Parameter names are **public API** under this feature: renaming a parameter
breaks named call sites. Treat parameter renames in published modules as
breaking changes.

### Trailing Blocks
```sx
callee(args) { body }
```
A block after a call's closing `)` passes the block as a **zero-param closure
literal bound to the callee's last declared parameter**. The equivalence is
definitional — every other rule (duplicates, defaults, evaluation order)
follows from it; the block is not a special argument kind:

```sx
vstack(8.0) { text("a"); text("b"); }
// ≡
vstack(8.0, content = () => { text("a"); text("b"); });

scaffold(top_bar = toolbar) { chat_list(); }   // named slots + trailing block
scaffold() { chat_list(); }                    // defaults skipped, block binds `content`
```

- **Binding**: the block binds the last declared parameter, which must be a
  non-variadic `Closure` type — otherwise a targeted error names the
  parameter ("'f' cannot take a trailing block — its last parameter 'x' is
  not a `Closure`", or "… its last parameter '..xs' is variadic").
- **One block**: at most one trailing block per call. Other closure
  arguments are named args or ordinary positional slots.
- **Zero-param only**: the block is a `Closure()` literal; a parameterized
  closure argument is spelled explicitly (`f(x, (a) => { … })`).
- **Same line**: the `{` must sit on the same line as the call's `)`. A `{`
  on the next line is an ordinary scope block statement, never a trailing
  block.
- **Header position**: inside an `if`/`while`/`for` header the form is
  disabled — `{` terminates the condition and opens the statement body;
  bind the closure explicitly there.
- **`return` is local**: a `return` inside the block returns from the
  closure, never from the enclosing function (no non-local return).
- **Chain termination**: a trailing block ENDS the postfix chain —
  `f(x) { … }.modifier()` is a parse error ("a trailing block ends the call
  chain — pass the modifier inside the call: `f(x, m = .{ … }) { … }`").
  Chaining onto the emitted result would silently modify a discarded copy.
- **Duplicate with a named argument**: a trailing block binds the last
  parameter, so also naming that parameter is the duplicate-binding error
  ("parameter 'content' is bound both by a named argument and by the
  trailing block").

No `inline` keyword exists or is needed: a capture-free block promotes to a
null-env static thunk (zero allocation); a capturing block allocates its
environment through `context.allocator` like any closure literal.

### UFCS (Uniform Function Call Syntax)
```sx
object.func(args)    // equivalent to func(object, args) — for OPT-IN functions
```
Free-function dot-calls are **opt-in**: a plain function never dispatches
via dot. The `ufcs` keyword opts a function in, with two spellings —
marking the function itself, or declaring a (renaming) alias:

```sx
create  :: (x: i32) -> void {}        // plain — NOT dot-callable
create2 :: ufcs (x: i32) -> void {}   // ufcs-marked — dot-callable
create3 :: ufcs create;               // ufcs alias — dot-callable

f : i32 = 4;
f.create();    // error: 'create' is not a ufcs function (help: call it
               //   directly, pipe it, or declare it `create :: ufcs (...)`)
f.create2();   // works — calls create2(f)
f.create3();   // works — calls create(f) through the alias
create2(f);    // a ufcs fn is still an ordinary fn: direct calls work
f |> create(); // the pipe works on ANY fn (parse-time desugar, no opt-in)
```

When `object.func(args)` names an opted-in function and `func` is not a
field or method of `object`'s type, the compiler rewrites the call to
`func(object, args)`. Fields and methods take priority over ufcs
functions; a protocol-typed receiver dispatches its own methods first and
falls through to ufcs functions for non-members
(`context.allocator.create(Session)` — `create` is a ufcs fn taking the
protocol value as its first param).

UFCS works with pointer receivers (auto-deref, and auto address-of when
the first param is `*T` and the receiver is a value) and with **generic**
functions — the receiver participates in `$T` binding and the call
monomorphizes exactly like the direct spelling:

```sx
first_of :: ufcs (xs: []$T) -> T { xs[0] }

xs.first_of();       // dot — binds $T from the receiver
first_of(xs);        // direct
xs |> first_of();    // pipe — desugars to first_of(xs)
```

#### UFCS Aliases
The alias form decouples the method name from the function name —
useful when the bare name reads poorly in dot position:
```sx
arena_alloc :: (arena: *Arena, size: i64) -> *void { ... }
alloc :: ufcs arena_alloc;

myArena.alloc(42);        // calls arena_alloc(myArena, 42)
alloc(myArena, 42);       // also works as a direct call
```

This avoids the naming redundancy of `myArena.arena_alloc(42)`.

### Pipe Operator

The pipe operator `|>` inserts the left-hand side as the first argument of the right-hand side call. It is desugared at parse time.

```sx
a |> f(b, c)        // → f(a, b, c)
a |> f              // → f(a)
a |> f(b) |> g(c)   // → g(f(a, b), c)
```

The pipe is left-associative with the lowest precedence of all binary operators, so expressions like `x + 1 |> f(2)` are parsed as `f(x + 1, 2)`.

This is especially useful with namespaced imports:
```sx
pkg :: #import "modules/math";

3 |> pkg.add(4)                    // → pkg.add(3, 4) → 7
3 |> pkg.add(4) |> pkg.mul(2)     // → pkg.mul(pkg.add(3, 4), 2) → 14
```

### Field Access
```sx
object.field
```
Used for module access (`std.print`) and struct member access.

### Enum Literal
```sx
.variant_name
```
The enum type is inferred from context (expected type from declaration or parameter).

---

## 5. Statements

Statements are terminated by `;`.

- **Declaration**: `name :: value;` / `name := value;`
- **Assignment**: `name = value;` / `name += value;` (and other compound assignments). Also supports field targets: `obj.field = value;`
- **Multi-target assignment**: `a, b = b, a;` — all RHS values are evaluated before any stores, enabling swaps without temporaries. Target count must equal value count. Only plain `=` is supported (no compound operators). Each target must be a valid lvalue (variable, field, index, dereference).
- **Expression statement**: `expr;` — evaluates the expression (last in a block = return value)
- **Return**: `return expr;` — returns from the enclosing function with the given value. `return;` returns void.
- **Break**: `break;` — exits a match arm or while loop
- **Continue**: `continue;` — skips to the next iteration of a while loop
- **Defer**: `defer expr;` — defers execution of `expr` until the enclosing block exits (LIFO order)
- **Push**: `push expr { body }` — scoped context override (see below)

### `push` Statement and Implicit `context`

The `push` statement installs a new implicit context for the duration of a block. The context is CALL-CARRIED (a hidden `*Context` parameter threaded through every sx call, never a global): `push` allocates the new Context on the pushing frame's stack, and the body — including every function it calls — reads through it. On exit the previous context is back in force.

```sx
push .{ allocator = arena.allocator(), logger = *my_logger } {
    handle(client);   // inside here, `context` has the new value
}
// context is restored to its previous value here
```

A `push .{ ... }` literal is spread+patch: fields the literal does NOT name are inherited from the ambient context (never zero-initialized); the named fields are overwritten. Pushing a whole `Context` VALUE (`push some_ctx { … }`) stores it as-is — seed it from `context` first to inherit.

**`Context` struct** — assembled PER PROGRAM, 100% from `#context_extend` declarations. The struct itself is declared EMPTY in `modules/std/core.sx` (the declaration doubles as the implicit-context mode marker); the stdlib's own capabilities are ordinary declarations in their owning modules:
```sx
// std/mem.sx
c_allocator : CAllocator = .{};
#context_extend allocator: Allocator = c_allocator;

// std/io.sx
c_blocking_io : CBlockingIo = .{};
#context_extend io: Io = c_blocking_io;
```
Before any `push`, code runs under `__sx_default_context`, a static constant holding every field's folded default. A protocol-typed default like the two above is the identity ERASURE of the named instance global — a BORROW: the constant's receiver is the global's real address, never null (null ctx is the `?Protocol` absent sentinel). The same fold works for any user global (`fallback : Allocator = my_impl_global;` — no `xx` needed, the declared type states the erasure). Threads and fibers inherit by snapshotting the spawner's whole context value.

`push` and `context` require the `Context` type to be declared (import `std.sx` or any module that imports it). In a build without it, both error — and the diagnostic enumerates the program's registered `#context_extend` fields with their declaring modules, so the demand is traceable.

### `#context_extend` — extending the Context

Any module — stdlib or user — can declare a field the program's Context carries:

```sx
#context_extend ui: *Ui = null;      // bare nullable pointer — the default idiom
#context_extend frame_stats: FrameStats = .{};
```

`?*Ui` works too and opts the field into checked nullability (consumers must
prove presence before use); the bare spelling keeps null as an unchecked
sentinel, per the pointer contract.

- **Grammar**: `#context_extend <name> : <type> = <default> ;` at top level only.
- **Assembly**: the compiler assembles the program's `Context` from every declaration in the compilation — there is no builtin prefix — in a deterministic order (sorted by declaring module path, then field name). Field offsets are program-specific — never rely on them across programs.
- **Access is global and unconditional**: after assembly, `context.field` works in ANY module of the program with no import requirement. Imports gate existence only (an uncompiled module contributes nothing); there is no per-source scoping of context fields.
- **One flat namespace, loud collisions**: two declarations with the same field name (or colliding with a builtin field) are a hard compile error naming both declaration sites.
- **Defaults are mandatory and comptime-evaluable**: a declaration without a default — or with one that doesn't fold to a compile-time constant — is a compile error; the default context must be constructible before `main` runs. Defaults fold into `__sx_default_context`. `*T = null` is the idiom for handle fields (`?*T = null` where checked absence is wanted); the root `push` in `main` is the idiom for wiring real values.
- **`push` semantics unchanged**: added fields patch exactly like builtin ones.
- **Comptime**: `#run` bodies execute under the same assembled default context, so an added field's default is readable at comptime.
- **Cost guideline** (not enforced): reads are a constant-offset load and calls share the pusher's slot — the only growth cost is the spread-copy at `push` (and the per-fiber snapshot). Prefer one POINTER per concern (`*Ui`, `*Logger`) over fat inline values; a 2 KB inline field makes every push a 2 KB memcpy. Small inline value fields are fine.

There is no untyped escape slot: a module that wants to carry a payload declares its own typed field (`#context_extend logger: *Logger = null;` replaces the old `data: *void` idiom).

---

## 6. Blocks, Scoping, and Implicit Returns

A block `{ ... }` contains zero or more statements. The last expression in a block is its value (implicit return).

In function bodies, the last expression becomes the return value:
```sx
compute :: (x: i32) -> i32 {
  x * x;   // this is returned
}
```

### Scope Blocks

Bare blocks can be used as statements to introduce a new lexical scope. Variables declared inside a scope block are local to that block. No trailing `;` is required.

```sx
main :: () {
  x := 42;
  {
    x := 6;                        // shadows outer x
    print("inner: {x}"); // prints 6
  }
  print("outer: {x}");   // prints 42
}
```

### Variable Shadowing

A variable declaration (`name :=`) inside an inner scope shadows any variable with the same name from outer scopes. The outer variable is restored when the inner scope exits.

### Defer

`defer expr;` schedules `expr` to execute when the enclosing scope block exits. Multiple defers in the same scope execute in reverse order (LIFO).

```sx
{
  defer print("second");
  defer print("first");
}
// prints: first, then second
```

`break` and `continue` exit the loop body's scope: the iteration's pending
defers run (LIFO, including entries from nested blocks between the loop and
the jump) before control transfers — exactly as on the fall-through end of an
iteration. `return` runs all pending defers of the function. A `break` or
`continue` outside a loop is a compile-time error.

---

## 7. Intrinsics

An **intrinsic** is a declaration whose implementation lives in the compiler. It
is written with the reserved word `intrinsic` in body position, where a `{ ... }`
body would otherwise go:

```sx
size_of :: ($T: Type) -> i64 intrinsic;
```

`intrinsic` is a keyword, not a directive: `#intrinsic` is not a spelling of it
and does not parse.

An intrinsic binds to the compiler's registry by **(module, name)** — the
declaring module is part of its identity. `size_of` is an intrinsic because
`modules/std/core.sx` declares it, not because the name is magic; the same
spelling in another module names an ordinary function and is rejected:

```sx
size_of :: ($T: Type) -> i64 intrinsic;   // ERROR outside std/core.sx:
                                          // 'size_of' is declared by
                                          // modules/std/core.sx
```

A name the registry does not carry (`unknown intrinsic 'foo'`) or a wrong
parameter count is a compile-time error at the declaration itself — never a
fallback to a runtime symbol lookup.

Each intrinsic is dispatched one of three ways. Most are handled at **lowering** —
folded to a constant (`size_of`, `struct_field_count`), or lowered to dedicated IR ops
(the atomics). Three — `type_name`, `is_unsigned`, `type_info` — are
**dual**: folded at lowering when the type argument is statically resolvable, and
serviced by the comptime evaluator when it is only known at evaluation time. The
compiler-API surface (`raw_intern`, `raw_find_type`, the `BuildOptions` methods, …) is
**evaluate**: the comptime evaluator services it and there is no runtime form at
all. Calling one from the runtime call graph is a compile-time error that prints
the path from the root that reached it.

Dispatch is not the same as stage-availability. `sqrt` and `atomic_load` are both
lowered, yet `atomic_load` evaluates under `#run` and `sqrt` does not: the
evaluator interprets the atomic ops, but has no arm for the math call `sqrt`
lowers to. A `#run sqrt(x)` fails loudly rather than folding to a wrong value.

Two categories are deliberately **not** intrinsics. `string` and `Vector` are
language primitives, resolved by name by the type system like `int` / `bool` /
`f64`. And a handful of keywords (`type_eq`, `has_impl`, `is_struct`,
`is_comptime`) are recognized bare, declared nowhere.

### Staging: functions belong to no stage

An ordinary sx function is **stage-polymorphic**. Nothing in a declaration says
whether it runs at compile time or at runtime; what decides is **reachability**.

- **Compile-time roots**: `#run`, constant and type evaluation, and a build
  callback registered with `on_build`.
- **Runtime roots**: `main`, exported definitions, and anything named by global
  data (a protocol vtable, the default `Context`).

A function reached from the compile-time roots is evaluated by the comptime
evaluator. A function reached from the runtime roots is emitted into the binary.
A function reached from **both** does both, and must agree with itself:

```sx
shared :: (n: i64) -> i64 { return n * 2 + size_of(P); }

CT :: #run shared(10);          // evaluated by the comptime evaluator
main :: () { rt := shared(10); } // and emitted into the binary
```

Two consequences follow, and neither needs an annotation:

- A function nothing runtime-reachable calls is **not emitted**. This is what
  keeps a build callback out of the binary — not its signature, and no longer
  any ABI marker.
- Calling an `evaluate`-only intrinsic from the runtime graph is an error,
  reported with the path from the root that reached it:

```
error: 'intern' runs only at compile time — it cannot be called from the
       runtime call graph (use it inside #run or a comptime '::')
  reached from the runtime graph:
    main
    -> alpha
    -> beta
    -> intern   (compile-time only)
```

### I/O
- `out(str: string) -> void` — write a string to standard output
- `print(fmt: string, ..args: []any)` — formatted print. Parses `{}` placeholders in the format string and substitutes arguments. When all argument types are statically known, the compiler specializes the call at compile time (no `any` boxing).

### Math
- `sqrt(x: $T) -> T` — square root (maps to LLVM intrinsic)
- `sin(x: $T) -> T` — sine (maps to LLVM intrinsic)
- `cos(x: $T) -> T` — cosine (maps to LLVM intrinsic)

### Memory
- `malloc(size: i64) -> *void` — allocate `size` bytes of heap memory
- `free(ptr: *void) -> void` — free previously allocated memory
- `memcpy(dst: *void, src: *void, size: i64) -> *void` — copy `size` bytes from `src` to `dst`
- `memset(dst: *void, val: i64, size: i64) -> void` — fill `size` bytes at `dst` with `val`
- `size_of($T: Type) -> i64` — size of type `T` in bytes
- `align_of($T: Type) -> i64` — alignment of type `T` in bytes

### Type Introspection
- `type_of(val: $T) -> Type` — returns the runtime type tag of a value
- `type_name($T: Type) -> string` — returns the name of type `T` as a string (e.g., `"Point"`)
- `struct_field_count($T: Type) -> i64` — the number of fields of a struct/tuple (or arms of an untagged union). Scalars and other fieldless types fold to 0 (a leaf, so generic walkers can gate on it). An enum argument is a compile error naming `variant_count`; arrays/vectors are rejected — their lengths/lanes read as `.len` on the value.
- The whole field family — `struct_field_name` / `struct_field_type` / `struct_field_offset` / `variant_name` / `variant_type` — also accepts a **runtime `Type` value**: reads go through lazily-emitted master-index tables (`__sx_member_name_ptrs` / `__sx_member_type_ptrs` / `__sx_field_offset_ptrs`, `[N x ptr]` keyed by the tag → per-type arrays), emitted only when a dynamic call site exists. At runtime the kind gates do not apply, and an index ≥ the member count is **undefined behavior** (in-bounds GEP — the caller gates on the counts, exactly like the static per-type arrays). Offsets answer per kind: struct/tuple members give their field offset; a tagged union gives its PAYLOAD offset (the header size — the same for every variant); an untagged union's arms all give 0. `struct_field_value(av, i)` / `variant_payload(av, i)` on an **`any` receiver** compose these tables directly: the result is the view `{struct_field_type(tag, i), av.data + struct_field_offset(tag, i)}` — reads go through the view, so nested access chains by repeated calls with no copies, and a wrong-kind tag or out-of-range index is the same UB as the raw table reads. Arbitrary-width int fields read through an any-receiver view carry their TRUE (non-builtin) tag — dispatch consumers (`x.(struct_field_type(T,i))`) monomorphize exactly; the `{}` formatter's builtin-width int arm does not match such a tag and prints `<?>`. `type_info(tp)` likewise accepts a runtime `Type`: it loads the type's constant record from `__sx_type_infos` (one record per type, bytes matching the `TypeInfo` layout; requires `modules/std/meta.sx` in scope, which the compile-time form already does) — kind-first dispatch (`if type_info(tp) == { case .struct: (si) { … } }`) works identically on compile-time and runtime `Type`s.
- `struct_field_name($T: Type, idx: i64) -> string` — the name of the `idx`-th field of a struct/tuple (positional tuple elements have no name → `""`). Kind-gated like `struct_field_count`.
- `struct_field_type($T: Type, idx: i64) -> Type` — the `idx`-th field's type. Kind-gated; also resolves in type position.
- `struct_field_value(s: $T, idx: i64) -> any` — the `idx`-th field of a struct/tuple VALUE as an `any` VIEW: `{field type tag, pointer to the field inside `s`}` — an interior pointer, not a copy. For an addressable receiver the view borrows the struct's own storage (mutations of the struct stay visible through a live view); an rvalue receiver spills to a frame temp first. The view is valid only while the receiver's storage lives. Arrays/vectors/slices are rejected — index natively (`v[i]`, typed). Enum values are rejected — use `variant_payload`.
- `variant_count($E: Type) -> i64` / `variant_name($E: Type, idx: i64) -> string` / `variant_type($E: Type, idx: i64) -> Type` — the enum / tagged-union duals: variant count, the `idx`-th variant's name, and its payload type. A struct/tuple argument is a compile error naming the `struct_field_*` builtin.
- `variant_payload(u: $E, idx: i64) -> any` — the live payload of a tagged-union VALUE at variant index `idx`, as an `any` VIEW of the payload area (same borrow rules as `struct_field_value`).
- `any_element(av: any, elem: Type, idx: i64) -> any` — element view into an array/vector held by `av`: pure stride math, `{elem, raw_any_data(av) + idx * size_of(elem)}`. `elem` may be a compile-time type (the size folds to a constant) or a runtime `Type` (the size reads the runtime table). Bounds are the caller's responsibility (same OOB rule as the field family); vector lanes are packed, so the same stride walks both arrays and vectors.
- `raw_any_data(av: any) -> *void` / `raw_make_any(tp: Type, data: *void) -> any` — the raw layer over the `any` view's two words. The `{tag, data}` layout itself stays private; these are the stable contract, and `av.(AnyRaw)` retrieves both words as one `{data, type_id}` pair (see Raw-view retrieval, §Postfix Cast). `raw_make_any` is UNCHECKED at runtime — the caller asserts `data` points at a live, aligned value of `tp` covering `size_of(tp)` bytes — but a non-pointer `data` argument is a compile error. Three sharp edges: **tags are per-build values** (a serializer writes type names and re-resolves on load — never raw tags); **byte copies through the data pointer are shallow** (interior pointers — string/slice data, nested views — are not followed; a deep copy walks `type_info`); **a view carries no lifetime** (assembling or copying a view never transfers or extends ownership of the referent).
- `variant_value($E: Type, idx: i64) -> i64` — the `idx`-th variant's integer value: its explicit value / explicit tag when declared (custom values, flags, tagged-union tags), else its ordinal. Works on enums AND tagged unions. A runtime `Type` reads the `__sx_member_value_ptrs` tables (same master-index pattern as the name/type/offset families, same `memberValue` source as the static fold).
- `variant_index($E: Type, val: E) -> i64` — a value's sequential variant ordinal (the inverse of `variant_value`; explicit values reverse-map, an unmatched tag answers itself — the identity seed). With a **runtime** `Type` the value travels as an `any` view: `variant_index(t, av)` reads the tag word through the view (a signed backing sign-extends; a layout-struct union loads its narrow tag slot, not the wider header) and scans the value table — a typed second argument is impossible there and is a compile error.
- `is_flags($T: Type) -> bool` — returns `true` if `T` is a flags enum (declared with `#flags`)
- `vector_lanes($T: Type) -> i64` — a vector's lane count (`vector_lanes(Vector(3, f32))` is `3`). The one vector length the flat size tables cannot answer: a vector's ABI size is pow2-rounded, so `size_of / element size` over-counts (3 lanes read as 4). A static non-vector argument is a compile error (`.len` / `struct_field_count` are the right spellings elsewhere); a runtime `Type` reads the `__sx_vector_lanes` table, where a non-vector tag answers 0 (kind discrimination is `type_info`'s job, like the count tables).
- `type_eq($A: Type, $B: Type) -> bool` — structural TypeId equality (`type_eq(i64, i64)` is `true`, distinct shapes are `false`); folds at compile time, so `inline if type_eq(...)` is comptime-decidable
- `is_unsigned($T: Type) -> bool` — `true` if `T` is an unsigned integer (`u8`/`u16`/`u32`/`u64`/`usize`); used by `{}` formatting to print unsigned integers as unsigned decimal

The type-only builtins — `size_of`, `align_of`, `struct_field_count`, `variant_count`, `type_name`, `type_eq`, `is_unsigned`, `is_flags` — strictly require a **type** argument. A spelled type (`i64`, `*u8`, `Point`) or a generic type parameter (`T`) is accepted by all of them. A runtime `Type` value (`type_of(x)`, a `[]Type` element, a `Type`-typed local) is supported by the whole scalar family: `type_name` and `is_unsigned` (their original runtime paths), plus `size_of`, `align_of`, `struct_field_count`, `variant_count`, `is_flags`, and `vector_lanes` — each reads a lazily-emitted, tag-indexed table (`__sx_type_sizes` / `_aligns` / `_struct_field_counts` / `_variant_counts` / `_flag_bits` / `_vector_lanes`; built only when a dynamic call site exists, so programs without runtime reflection carry no tables) — and `type_eq`, which compares tags directly (no table). At runtime the kind gates do not apply: a wrong-kind tag reads its table row (0 for the other family) — runtime kind discrimination is `type_info`'s job. Passing a non-Type VALUE (`size_of(6)`, `is_unsigned(true)`) remains a compile-time error — `<builtin> expects a type, got '<type>'` — never a silent reinterpretation. Passing a value (`size_of(6)`, `is_unsigned(true)`) is a compile-time error — `<builtin> expects a type, got '<type>'` — not a silent reinterpretation of the value's bits as a type.

An `any` is accepted because it can hold either a value or a `Type`. `type_name` and `is_unsigned` consult the `any`'s runtime type-tag, not its payload: an `any` holding a *value* reports the type **of that value** (`av : any = 6` → `type_name(av)` is `"i64"`), while an `any` holding a *`Type` value* (e.g. `type_of(x)` stored in an `any`) names the **held type**. This is the same tag the `{}` formatter reads, so `print(av)` and `type_name(av)` agree on what `av` is.

### Type Conversion
- Conversions are spelled `xx expr` (target from context) or postfix `expr.(T)` (explicit target) — see §Postfix Cast. There is no `cast(Type, expr)` builtin; runtime-typed data travels as `any` and comes back through the assertion forms.

### Vectors
- `Vector($N: int, $T: Type) -> Type` — returns an LLVM vector type of `N` elements of type `T`

---

## 8. Compile-time Evaluation

### `#run` Directive

`#run expr` evaluates `expr` at compile time using lazy JIT execution. It can appear in two contexts:

**Compile-time constants** — bind a compile-time value to a name:
```sx
compute :: (x: i32) -> i32 { x * x; }
x :: #run compute(5);   // x = 25, evaluated at compile time
```

Comptime globals are resolved lazily: the JIT executes only when the value is first referenced during code generation. Chained dependencies are resolved automatically.

**Side effects** — execute code at compile time for its side effects:
```sx
#run print("compiling...");
```

### `#error` Directive

`#error("message");` emits `message` as a compile-time error and halts
compilation. It is valid as a top-level item or a statement, and it is THE
compile-time rejection spelling (the old `compile_error(...)` bare intrinsic
was consolidated into it).

The directive fires only when it is reached in **live** code, at every
level where code goes dead:

- The comptime conditional flatten pass drops non-taken module-scope
  `inline if` arms before the directive can fire — the idiomatic way to
  reject an unsupported target in an exhaustive `inline if OS`/`inline if
  ARCH` without a silent fallback:

```sx
inline if OS == {
    case .macos: errno_location :: () -> *i32 extern libc "__error";
    case .linux: errno_location :: () -> *i32 extern libc "__errno_location";
    else:        #error("errno_location: unsupported target — add its libc symbol.");
}
```

- Monomorphization prunes non-taken `inline if T ==` arms per instance —
  the same discipline rejects an unsupported TYPE in generic code, firing
  only for the instantiations that actually select the arm:

```sx
free :: ufcs (x: $T, a: Allocator = context.allocator) {
    inline if T == {
        case protocol: { ... }
        case closure:  { ... }
        case slice:    a.dealloc_bytes(xx x.ptr);
        else:          #error("free expects a protocol value, a closure, or a slice");
    }
}
```

- A bare top-level `#error("...");` always fires.

When a surviving `#error` fires inside a monomorphized body, the diagnostic
anchors at the OUTERMOST instantiation call site — the user call that
forced the instantiation — with the directive's own location attached as a
note. A library-internal anchor would read like a run-time panic's stack
bottom; the offending code is the caller's.

The message must be a string literal (it is consumed at compile time).

### `#insert` Directive

`#insert expr;` evaluates `expr` at compile time to obtain a string, then parses and compiles that string as inline code at the insertion point.

```sx
generate :: () -> string {
    return "print(\"hello from the other side\");";
}

main :: () {
    #insert #run generate();
    // equivalent to: print("hello from the other side");
}
```

The inserted string must contain valid `sx` statements (including semicolons). The statements are parsed and compiled in the same scope as the `#insert` site. Variables created by one `#insert` are visible to subsequent `#insert` directives in the same function.

### Comptime Call Evaluation

When a `::` constant binding is initialized with a function call and all arguments are comptime-known (literals or other `::` constants), the compiler attempts to evaluate the entire call at compile time using the bytecode VM. If evaluation succeeds, the result is baked into the binary as a static constant with zero runtime overhead.

```sx
body :: "<html><body><h1>Hello</h1></body></html>";
response :: format("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}", body.len, body);
// response is a static string constant — no runtime allocation
```

This works for any function, not just `format`. The mechanism is general: the VM compiles the function body (including `#insert` directives, variadic `..args: []any` args, and calls to other functions) and executes it entirely at compile time. If the VM encounters something it cannot evaluate (e.g., extern function calls, unsupported operations), it silently falls through to runtime codegen.

### Build Configuration

The `BuildOptions` struct (from `modules/build.sx`) provides compile-time build configuration via `#run`. Methods on `BuildOptions` are compiler builtins intercepted during compilation — they have no runtime cost.

```sx
#import "modules/build.sx";

configure_build :: () {
    opts := build_options();
    opts.add_link_flag("-lm");
    opts.set_output_path("out/my_program");

    inline if OS == .wasm {
        opts.set_output_path("sx-out/wasm/app.html");
        opts.add_link_flag("-sUSE_SDL=3");
        opts.add_link_flag("-sALLOW_MEMORY_GROWTH=1");
    }
}
#run configure_build();
```

**API:**

| Method | Description |
|--------|-------------|
| `build_options()` | Returns a `BuildOptions` value for the current compilation |
| `opts.add_link_flag(flag)` | Appends a linker flag (merged with CLI flags) |
| `opts.set_output_path(path)` | Sets the output binary path (overridden by CLI `-o`) |

Build flags from `add_link_flag` are merged with any flags passed on the command line. Duplicate library flags (e.g., `-lSDL3` from multiple imports) are automatically deduplicated.

### Compiler Constants

The `modules/build.sx` module provides compile-time constants set by the compiler based on the target:

| Constant | Type | Description |
|----------|------|-------------|
| `OS` | `OperatingSystem` | Target OS: `.macos`, `.linux`, `.windows`, `.wasm`, `.unknown` |
| `ARCH` | `Architecture` | Target arch: `.aarch64`, `.x86_64`, `.wasm32`, `.unknown` |
| `POINTER_SIZE` | `i64` | Pointer width in bytes (8 for 64-bit, 4 for wasm32) |

These are used with `inline if` for compile-time conditional compilation:

```sx
inline if OS == .wasm {
    // Only compiled when targeting wasm
}
inline if POINTER_SIZE == 8 {
    // Only compiled on 64-bit platforms
}
```

A statically-dead `inline if` branch is dropped **whole**: its statements are
not lowered and its type annotations are not resolved, so a type that exists
only on another target (or behind a disabled feature const) never errors from
a pruned branch (`inline if OS == .ios { u : *UIKitPlatform = …; }` compiles
for every target). The condition folds for `OS`/`ARCH`/`POINTER_SIZE`
comparisons, `and`/`or` combinations, bool literals, and module consts with a
bool-literal value (`ENABLED :: false`); an unfoldable condition falls back to
a runtime `if`, where both branches are checked as usual.

---

## 9. Modules / Imports

### `#import` Directive

The `#import` directive brings declarations from another `.sx` file or directory into the current file.

**Flat import** — splices all declarations from the imported file into the current scope:
```sx
#import "modules/std/fs.sx";
```

**Namespaced import** — wraps all declarations under a namespace name:
```sx
std :: #import "modules/std.sx";
```

**Directory import** — when the path refers to a directory, all `.sx` files in that directory are aggregated into a single module:
```sx
pkg :: #import "modules/math";   // namespaced — all .sx files merged under pkg
#import "modules/math";          // flat — all declarations spliced into scope
```

Directory imports scan only the top level of the specified directory (non-recursive). Files are processed in alphabetical order for deterministic builds. Files within the directory may `#import` each other or external files.

If an extensionless path matches both a file and a sibling directory of the same name (`modules/std.sx` next to `modules/std/`), the import is an error — write the `.sx` path to import the file. Exception: a file importing its own companion directory (`X.sx` importing `X/`) is not ambiguous; the directory is the only sensible target.

Namespaced declarations are accessed with dot notation:
```sx
std.print("hello");
```

### Namespace Alias Carry

A namespaced import is an ordinary declaration of the alias name. There is no
`pub` keyword: flat-importing a module carries the module's namespace aliases
**one level** — a file's aliases are usable by its DIRECT flat importers, with
declaration-like collision semantics.

```sx
// facade.sx
r :: #import "rich.sx";        // an ordinary declaration of `r`

// main.sx
#import "facade.sx";           // flat import carries facade's aliases

main :: () {
    r.helper();                // plain fn through the carried alias
    t := r.Thing.init();       // static method
    x : r.Thing = t;           // type annotation
    n := r.LIMIT;              // module const
    c := r.Color.green;        // enum variant
    b := r.Box(i64).{ item = 3 };  // generic struct head
}
```

Every qualified shape resolves through a carried alias exactly as through a
directly-declared one: function calls, `alias.Type.method()`, type
annotations, enum variants, module constants, and generic struct heads.

Collision rules mirror ordinary declarations:

- **Own wins** — a file's own declaration of a name (including its own
  `ns :: #import`) shadows any same-named alias carried from a flat import.
- **Ambiguity** — two direct flat imports each carrying a distinct alias of
  the same name make a bare use of that alias an error; declare the alias
  locally to disambiguate.
- **One level only** — carry does not chain: a flat import of a flat import
  does not surface the inner file's aliases. (The bare `alias.fn()` call path
  does not yet enforce this gate — issue 0114 tracks the tightening.)

`#import c { ... }` aliases (`tc :: #import c { ... }`) carry the same way.

### Module-Scope Visibility: `private`

`private` restricts a module-scope declaration to its declaring **source
file**. It is a prefix on identifier-headed top-level declarations:

```sx
private Helper :: (x: i64) -> i64 { return x * 2; }
private State  :: struct { n: i64; }
private LIMIT  :: 21;
private counter : i64 = 0;
private dep    :: #import "dependency.sx";
```

It applies to functions and type functions, structs/enums/unions/error sets,
protocols, constants and globals, aliases (including UFCS aliases), named
imports, `#library` handles, runtime classes, `extern`/`export` declarations,
and `main`.

Semantics:

- **Same-file use is unrestricted.** A private name works throughout its
  declaring file, forward references included, exactly like a public one.
- **Flat imports do not carry private names.** A flat importer referring to a
  private name gets a "private to its declaring module" (functions) or
  undeclared/unknown diagnostic — never the declaration.
- **Namespaces do not expose private members.** `ns.priv_member` reports
  "namespace 'ns' has no member 'priv_member'". Deep traversal keeps the
  ORIGINAL requester's authority: an intermediate private alias is not
  traversable from another file either.
- **A private named-import alias is not carried.** It binds only in its author
  file; flat importers do not receive it (the carry rule skips it).
- **No suppression, no ambiguity.** A private declaration never shadows or
  ambiguates a public same-name declaration from another module — for every
  other file it simply does not exist.
- **A public same-file alias may deliberately expose a private declaration**
  (`Public :: PrivateImpl;`) — resolution follows the alias in its author
  file, where the private name is legal.
- **Privacy authority is the exact declaring source file**, not a directory
  import: two files aggregated by a directory import cannot use each other's
  private names.
- **Identifier visibility only.** `private` does not make struct fields
  opaque; a value of a privately-declared type exposed through a public alias
  still has accessible fields.

Placement rules — `private` is rejected on: locals, parameters, struct/union/
runtime-class fields, enum cases and error tags, struct/protocol/impl methods
and requirements, flat `#import`, `impl` blocks, `#context_extend`, `#using`,
standalone `#run`, global `asm`, and `#framework`. Top-level `inline if`
branches MAY declare private globals (their statements are module-scope after
comptime flattening); function and method bodies may not.

`` `private `` (backtick raw identifier) remains a legal name, and the
`.private` member spelling remains legal after a dot.

### Import Resolution

- Imports are resolved after parsing and before code generation.
- Paths are resolved in three tiers, first hit wins:
  1. relative to the directory of the file containing the `#import`;
  2. relative to the working directory (cwd);
  3. relative to each stdlib search path — the `library/` directory discovered
     from the compiler binary's location (dev: `zig-out/bin/sx` →
     `<repo>/library`; install: `<prefix>/library`), overridable with the
     `SX_STDLIB_PATH` environment variable. This is how
     `#import "modules/std.sx"` resolves from any project.
- If the path resolves to a file, it is imported directly. If it resolves to a directory, all `.sx` files in that directory are aggregated.
- Nested imports are supported (imported files may themselves contain `#import`).
- Circular imports are detected and silently skipped (each file is imported at most once).
- Generic functions in namespaced imports are supported (e.g., `std.mul(5, 2)` where `mul` is generic).

**Example:** Given this project layout:
```
project/
  modules/std.sx
  modules/math/
    math.sx
    vector3.sx    ← contains: #import "modules/std.sx";
  main.sx         ← contains: #import "modules/std.sx";
```
When compiling from `project/`, both `main.sx` and `modules/math/vector3.sx` can use `#import "modules/std.sx"` — the root file resolves it relative to its own directory, and the nested file falls back to resolving relative to cwd.

### Intra-module References

Functions within a namespaced import can call each other without the namespace prefix. When generating code for a namespaced module, unresolved function names are automatically tried with the namespace prefix.

### Example

```sx
// modules/std/json.sx
parse :: (text: string) -> ?JsonValue { ... }

// main.sx
std :: #import "modules/std.sx";
#import "modules/std/json.sx";

main :: () -> i32 {
    std.print("hello there\n");
    v := parse("{}");
    0
}
```

### Standard Library Layout

```
modules/std.sx        the prelude — print/format, string ops (concat, substr,
                      path_join, ...), List(T), Context + push, the Allocator
                      protocol; plus the namespace tail: mem / xml / log /
                      fs / process / socket / json / cli / hash / test ::
                      #import "modules/std/<m>.sx"
modules/std/          mem.sx (CAllocator, GPA, Arena, TrackingAllocator),
                      fs.sx, process.sx, socket.sx, json.sx, cli.sx, hash.sx,
                      xml.sx, log.sx, trace.sx, test.sx
modules/ffi/          objc.sx, objc_block.sx, sdl3.sx, opengl.sx, raylib.sx,
                      stb.sx, stb_truetype.sx, wasm.sx
modules/math/         scalar.sx, vector2.sx, matrix44.sx — import the
                      directory: #import "modules/math"
modules/build.sx      BuildOptions — compile-time build configuration (§10.5)
modules/platform/     bundle.sx, uikit.sx, android.sx, sdl3.sx, ... —
                      windowing/bundling backends
modules/gpu/, modules/ui/   GPU protocol + retained UI toolkit
```

`#import "modules/std.sx"` gives every prelude name bare, plus `mem.GPA`,
`json.parse`, `fs.exists`, `hash.sha256_hex`, `log.warn`, ... through the
carried namespace tail (see Namespace Alias Carry). Direct file imports
(`#import "modules/std/json.sx"`) remain available for bare access.

---

## 10. CLI & Cross-Compilation

### Commands

```
sx run <file.sx>       Compile and run
sx build <file.sx>     Compile to binary
sx lsp                 Start language server (LSP)
```

### Options

| Flag | Description |
|------|-------------|
| `--target <target>` | Target triple or shorthand (default: host) |
| `--cpu <name>` | CPU name (default: generic) |
| `--opt <level>` | Optimization: `none`/`0`, `less`/`1`, `default`/`2`, `aggressive`/`3` |
| `-o <path>` | Output path (overrides `set_output_path`) |

### Target Shorthands

The `--target` flag accepts shorthand aliases for common targets:

| Shorthand | Expands to |
|-----------|-----------|
| `wasm`, `emscripten` | `wasm32-unknown-emscripten` |
| `macos`, `macos-arm` | `aarch64-apple-macos` |
| `macos-x86` | `x86_64-apple-macos` |
| `linux`, `linux-x86` | `x86_64-unknown-linux-gnu` |
| `linux-arm` | `aarch64-unknown-linux-gnu` |
| `windows` | `x86_64-windows-msvc` |

Full triples are also accepted and passed through as-is.

---

## 10.5 Bundling and Post-Link Callbacks

Platform-specific bundling (Apple `.app`, Android `.apk`) lives in
[library/modules/platform/bundle.sx](library/modules/platform/bundle.sx).
The compiler shrinks to: parse → IR → codegen → link → invoke a sx
function. Bundling, codesigning, manifest generation, Java compilation
(via `javac` + `d8`), etc. are all sx code running in the IR
interpreter post-link.

### Discovery

Users opt in **explicitly** from their own `#run` block:

```sx
#import "modules/build.sx";
#import "modules/platform/bundle.sx";

#run {
    opts := build_options();
    opts.set_bundle_path("MyApp.app");
    opts.set_bundle_id("com.example.app");
    opts.set_post_link_callback(bundle_main);
}
```

Programs that don't register a callback simply don't bundle — the
linked binary is produced and nothing further runs. There is no
stdlib default and no implicit prelude.

Two registration forms:

| Setter | Behavior |
|--------|----------|
| `BuildOptions.set_post_link_callback(cb: () -> bool)` | First-class function value. Preferred. |
| `BuildOptions.set_post_link_module(name: [:0]u8)` | Name-based fallback; compiler resolves `<name>.bundle_main` post-link. |

CLI `--bundle <path>` / `--apk <path>` are transitional aliases: if
`bundle_path` is set and no callback was registered, the compiler
auto-falls-back to `post_link_module = "platform.bundle"`. The sx
bundler reads `bundle_path()` regardless of which flag the user used.
The callback returns `false` to fail the build.

### BuildOptions surface

`BuildOptions` is an opaque, zero-field handle in
[library/modules/build.sx](library/modules/build.sx) — the state lives in the
compiler's `BuildConfig`, and the handle is only ever an ignored `self`. Its
methods are `intrinsic` declarations with mode `evaluate`: the comptime
evaluator services them, and they have no runtime form. Setters accumulate
config; accessors read it back inside the build callback.

The callback itself is an ordinary sx function — default ABI, implicit Context —
registered with `on_build`. Nothing marks it compile-time: it stays out of the
binary because no runtime root reaches it.

| Method | Read / write | Purpose |
|--------|--------------|---------|
| `add_link_flag(flag)` | write | extra linker flag |
| `add_framework(name)` | write | `-framework <name>` (Apple) |
| `set_output_path(path)` | write | linked binary path |
| `set_wasm_shell(path)` | write | custom WASM shell template |
| `add_asset_dir(src, dest)` | write | bundle a directory of runtime assets |
| `set_post_link_callback(cb)` | write | first-class callback (preferred) |
| `set_post_link_module(name)` | write | name-based callback fallback |
| `set_bundle_path(path)` | write | `.app` / `.apk` output |
| `set_bundle_id(id)` | write | iOS `CFBundleIdentifier` / Android package |
| `set_codesign_identity(name)` | write | Apple signing identity (`-` = ad-hoc) |
| `set_provisioning_profile(path)` | write | iOS device `.mobileprovision` |
| `set_manifest_path(path)` | write | Android AndroidManifest.xml override |
| `set_keystore_path(path)` | write | Android keystore override |
| `binary_path()` | read | path of the freshly-linked binary |
| `bundle_path() / bundle_id()` | read | mirror of the setters |
| `codesign_identity() / provisioning_profile()` | read | Apple codesign params |
| `manifest_path() / keystore_path()` | read | Android overrides |
| `target_triple()` | read | canonicalized target triple |
| `is_macos() / is_ios() / is_ios_device() / is_ios_simulator() / is_android()` | read | per-target predicates |
| `framework_count() / framework_at(i)` | read | linker `-framework` names (for `Frameworks/` embed) |
| `framework_path_count() / framework_path_at(i)` | read | linker `-F` search paths |
| `jni_main_count() / jni_main_runtime_path_at(i) / jni_main_java_source_at(i)` | read | `#jni_main` emissions for the APK bundler |
| `asset_dir_count() / asset_dir_src_at(i) / asset_dir_dest_at(i)` | read | iterate registered asset trees |

Returned strings are `""` when unset; integer counts are `0`. Accessors
that read after-the-fact (`binary_path`, `bundle_path`, etc.) return
the value that was either set in `#run` or forwarded from a CLI flag.

### `fs.sx` and `process.sx` stdlib modules

The bundler is implemented in sx; its calls into `fs.sx` / `process.sx`
work both at runtime through the dynamic linker and at `#run` / post-link
through the host-FFI dispatch in
[src/ir/host_ffi.zig](src/ir/host_ffi.zig) (a `dlsym(RTLD_DEFAULT)` +
arity-switched cdecl trampoline).

[library/modules/std/fs.sx](library/modules/std/fs.sx) (POSIX backend):

| Function | Purpose |
|----------|---------|
| `open_file(path, mode) -> ?File` | open a handle |
| `read_file(path) -> ?string` | one-shot slurp |
| `write_file(path, data) -> bool` | create / truncate / write |
| `append_file(path, data) -> bool` | append |
| `copy_file(src, dst) -> bool` | byte copy (streamed through 64 KB buffer) |
| `delete_file(path) -> bool` | `unlink` |
| `delete_dir(path) -> bool` | `rmdir` (empty only) |
| `create_dir(path) -> bool` / `create_dir_all(path) -> bool` | `mkdir` / `mkdir -p` |
| `move(old, new) -> bool` | `rename` |
| `set_mode(path, mode) -> bool` | `chmod` |
| `exists(path) -> bool` | `access(F_OK)` |
| `basename(p) -> string` / `dirname(p) -> string` | text-only path split |

`File` is a small value-typed handle wrapping a POSIX fd, with
methods `is_valid / close / read / write / seek`. Higher-level helpers
(`read_file`, `write_file`, `copy_file`) bypass `*File` methods and
call libc directly so they remain callable from the post-link IR
interpreter (which doesn't yet handle `*Self` method dispatch on
locally-unwrapped optionals).

[library/modules/std/process.sx](library/modules/std/process.sx) (POSIX backend):

| Function | Purpose |
|----------|---------|
| `run(cmd: [:0]u8) -> ?ProcessResult` | `popen` shell command, capture stdout + exit |
| `env(name: [:0]u8) -> ?string` | `getenv` (null if unset) |
| `find_executable(name) -> ?string` | `command -v <name>` via shell |

`ProcessResult` is `{ exit_code: i32, stdout: string }`. The post-link
bundler invokes `codesign`, `plutil`, `security`, `aapt2`, `javac`,
`d8`, `keytool`, `apksigner`, etc. through `run`.

### Apple `.app` flow (`bundle.sx::bundle_main`)

`bundle_main` branches on `is_android()` first; the remaining body is
the Apple path. Per target:

| Step | macOS | iOS sim | iOS device |
|------|-------|---------|------------|
| Stage `<bundle>` (rm-rf + mkdir + copy binary + set exe bit) | ✓ | ✓ | ✓ |
| Write `Info.plist` | minimal `CFBundle*` | + `UIDeviceFamily` + `LSRequiresIPhoneOS` + `UIApplicationSceneManifest` + `DTPlatformName=iPhoneSimulator` | + same with `DTPlatformName=iPhoneOS` |
| Embed provisioning profile to `<bundle>/embedded.mobileprovision` | — | — | when `provisioning_profile()` set |
| Embed `Frameworks/<Name>.framework/` (recursive `cp -R` per `-F` search path) | — | when present | when present |
| Extract entitlements (`security cms -D` + `plutil -extract Entitlements` + `plutil -extract ApplicationIdentifierPrefix.0` + `plutil -replace application-identifier` resolving `<TEAM>.*` → `<TEAM>.<bundle_id>`) | — | — | when `provisioning_profile()` set |
| Codesign | ad-hoc (`-`) | ad-hoc | `--sign <identity> --entitlements <ent>` |

### Android `.apk` flow (`bundle.sx::android_bundle_main`)

The Android branch:

1. **Discover SDK** — `$ANDROID_HOME` → `$ANDROID_SDK_ROOT` → `$HOME/Library/Android/sdk`.
2. **Find highest `build-tools` / `platforms` subdir** — `process.run("ls -1 <parent> | sort -V | tail -1")`.
3. **Stage `<apk>.stage/lib/arm64-v8a/<libfoo.so>`** — `copy_file` from the linked output.
4. **Manifest** — user-supplied via `set_manifest_path()`, or synthesized:
   - `NativeActivity` shape when no `#jni_main` is declared.
   - `#jni_main` Activity shape with `android:name="<runtime_path_with_dots>"` + `android:hasCode="true"` otherwise.
5. **Compile `#jni_main` Java sources** — write each entry's `java_source` to `<stage>/java/<pkg>/<Cls>.java`, run `javac --release 11 -classpath <android.jar>` to `<stage>/classes/`, run `d8 --release --lib <android.jar> --output <stage>` to produce `<stage>/classes.dex`. `javac` discovered via `$JAVA_HOME/bin/javac` then `command -v javac`.
6. **`aapt2 link -I <android.jar> --manifest <m> -o <unaligned>`**.
7. **Append archives** — `zip -q -r <unaligned> lib/`, then `zip -q <unaligned> classes.dex` (if dex was produced), then `zip` each registered asset dir at its `dest` path.
8. **`zipalign -f 4 <unaligned> <aligned>`**.
9. **Debug keystore** — `keytool -genkeypair -keystore <path>` on first use; defaults match Android Studio (`androiddebugkey` alias, password `android`).
10. **`apksigner sign --ks <ks> --ks-pass pass:android --key-pass pass:android --ks-key-alias androiddebugkey --out <apk> <aligned>`**.
11. Clean intermediates (keep `<apk>.stage/` for inspection if it lasts the build).

---

## 11. Program Structure

A program is a sequence of top-level declarations and `#import` directives. Execution begins at `main`.

```sx
main :: () {
  // entry point
}
```

`main` takes no arguments. Its return type may be any of: void (`()`,
`-> ()`, `-> void`, or no annotation), an integer type (POSIX exit code),
`-> !` (pure failable), or `-> (int_type, !)` (value-carrying failable).
The exit code is `0` for void / `-> !` success, the integer return
truncated to `u8` otherwise. An error that escapes a failable `main`
prints the unhandled-error header + return trace to stderr and exits `1`.
See [§12 Error Handling](#12-error-handling).

---

## 12. Error Handling

sx models recoverable errors as a **separate return channel**, not a wrapped
result type. A `!` as the **last slot** of the parenthesized result list adds one
extra return slot — a `u32` error tag — alongside the normal value slots. This
keeps sx's native multi-return ergonomics: `-> (i32, i64, !)` is a function
returning two values *and* an error, with no tuple-in-a-wrapper. A single-value
failable is `-> (T, !)`; an error-only failable is `-> !`. (There is no bare
`-> T !` spelling — the error channel always rides inside the `(…, !)` list.)

This section is the canonical surface reference. The design rationale,
trade-offs, and implementation breakdown live in `current/PLAN-ERR.md`.

### Failable signatures

```sx
parse_digit :: (s: string) -> (i32, !) { ... }         // one value + error
parse       :: (s: string) -> (i32, i64, !) { ... }    // multi-value + error
must_init   :: () -> ! { ... }                         // pure failable, no value
divide      :: (a: i32, b: i32) -> (i32, !MathErr) { ... } // named set
```

The `!` is always the **last** slot. `0` in the error slot means "no error";
non-zero is an interned global tag id.

### Error sets

Two forms of error set:

```sx
// Named set — declared once, referenced by name from signatures.
ParseErr :: error { BadDigit, Overflow, Empty };

// Inferred set — bare `!` collects whatever tags the body raises.
quick :: () -> (i32, !) {
  if cond raise error.SomeAdHocTag;   // mints into the inferred set
  return 0;
}
```

- An `error { ... }` set is an opaque type; tags are referenced as `error.X`.
- A declared empty set `error { }` is **rejected**.
- **Inferred sets are whole-program.** The compiler runs an SCC fix-point pass
  over the entire call graph to converge each bare-`!` function's set
  (matching sx's whole-program compilation model). Callers see the converged
  union, not bare `!`.
- A top-level (non-`main`) function declared `!` that never errors warns
  ("declared `!` but never errors — drop the `!`"). Closures and
  function-type slots with an empty `!` do **not** warn.

**Tag identity is the name, globally (Zig-style).** Two sets that both list
`NotFound` reference the *same* tag id; `if e == error.NotFound` matches every
`NotFound` regardless of which set raised it. Use distinct names
(`FsNotFound` / `HttpNotFound`) when subsystems must be distinguishable.

**Forwarding a failable result** (`return callee(...)` where the callee is
itself failable — value-carrying or pure) follows `raise`'s subset rule on
the error channel. Because tag identity is global, no tag translation is
involved — the compiler re-packs the value slots plus the raw tag:

- callee's set is the caller's set (named or bare) → forwards as-is;
- concrete `!E` → bare `!` → **legal** (the open channel absorbs any set);
- concrete `!A` → concrete `!B` → legal iff `A ⊆ B`; each escapee tag is
  diagnosed otherwise;
- bare `!` → named set → **rejected** (the callee's inferred set is not
  statically known at the forward site) — destructure and re-raise instead;
- value-slot arity must match, counting a pure failable as 0 value slots:
  `(T, !E)` cannot forward through `(T, U, !)`, `!E` cannot forward through
  `(T, !)` (nothing to fill the value slot), and `(T, !E)` cannot forward
  through a pure `!` (the value slot has nowhere to go) — each diagnosed.

**Arity tie-break.** A bang-less tuple whose last field is an error set
(`(T, ErrSet)`) is structurally identical to a failable result, so a returned
tuple is ambiguous between "my value list" and "a forwarded failable". The
VALUE interpretation wins when the tuple's field count matches the caller's
value arity AND each element fits its slot (per-slot error-set-ness matches
— an error-set element in a non-error-set slot has no implicit conversion,
and vice versa). So `return v, e` into `-> (i64, MyErr, !)` is the
two-value list; `return inner(x)` (an `(i64, !MyErr)` result) into
`-> (i64, i64, !)` is a forward and is diagnosed as a 1-vs-2 arity error.

A forward hop pushes **no** return-trace frame: like the matched-set
`return callee()` it is a plain data return, so the trace records the raise
site and any `try` propagation hops, not intermediate forwards.

### `raise`

Statement form. Terminates the immediately enclosing failable function (like
`return`), setting the error slot; value slots are left undefined.

```sx
if bad raise error.BadDigit;   // literal tag

v := foo() catch (e) {
  if e == error.Specific return default;
  raise e;                     // variable tag — re-raise
};
```

`raise EXPR` accepts any tag-typed expression. EXPR's set must be ⊆ the
enclosing function's error set (for a named set), or is absorbed into the
inferred set (for bare `!`). `raise` inside an inline expression is rejected
(`v := if cond raise error.X else 0;` — compile error). A closure body is its
own function boundary: `raise` inside a closure terminates the *closure*.

### `try`

Expression form. `try X` requires `X` to be failable; on `X`'s failure it
routes control to the nearest enclosing fallback target:

- inside an `or` chain → the next `or` operand;
- otherwise → the function's error return (propagation, like Zig's `try`).

```sx
v       := try parse_digit(s);          // propagate on failure
v2, n   := try parse(s);                // multi-value
try must_init();                        // statement form, discard values
v3      := try foo() or try bar();      // chain: foo fails → try bar
return try transform(try parse(s));     // nests in any value position
```

`try` works in any value-producing position (argument, struct/array literal,
`if`-condition); evaluation is left-to-right and short-circuits on the first
failure, so no partial aggregate is ever built. `try`'s body never binds the
tag — use `catch` for that.

### `catch`

Expression form. Handles the error inline. The binding is **parenthesized**
(`catch (e)`) — like a for-loop capture — and is **optional**. Four shapes,
disambiguated by the token after `catch`:

| Form | Binding | Body |
|---|---|---|
| `catch { ... }` | none (tag ignored) | block — braces required |
| `catch (e) { ... }` | `e` | block |
| `catch (e) EXPR` | `e` | bare expression (no braces) |
| `catch (e) == { case ... }` | `e` | match over `e` (sugar for `{ if e == { ... } }`) |

A bare binding (`catch (e) { }`) is a parse error with a migration hint.

```sx
v := parse_digit(s) catch (e) {
  log.warn("bad input: {}", e);
  return default;                       // noreturn body
};

v := parse_digit(s) catch (e) compute_fallback(e);   // value-producing body

v, n := parse(s) catch (e) {
  log.warn("parse failed: {}", e);
  .{0, 0}                               // tuple body for a multi-value failable
};

v := parse(s) catch (e) == {           // match-body form
  case .Empty:    0;
  case .BadDigit: -1;
  else:           raise e;
};

v := (try foo() or try boo()) catch (e) { return 0; };  // catch over an `or` chain
```

**Body type rule.** The body (block-as-expression) must produce the failable's
success tuple type, or be `noreturn` (the `noreturn` arm subsumes `return` /
`raise` / `break` / `continue` / `unreachable` / noreturn calls). For a
multi-value failable the body must produce a tuple of matching arity and
element types. A non-diverging body that produces no value is a compile error.

### `or` (fallback / chain)

Expression form (the same operator as optional-unwrap). LHS must be failable;
the RHS shape decides the result:

- **plain value of the success type** — terminate; the chain becomes
  non-failable; on LHS failure the result is the RHS value (LHS tag discarded);
- **`try EXPR`** — chain; on LHS failure, attempt the RHS (its `try` defines
  the next fallback target);
- **bare failable** — allowed only when its error path hits a marker
  downstream (see the path-marker rule).

`or` is **left-associative**, evaluated left-to-right with short-circuit.

```sx
v := parse_digit(s) or 0;                        // value terminator → non-failable
v := try foo() or try boo();                     // chain, propagate if both fail
v := foo() or boo() or 0;                        // bare operands, 0 absorbs all
v, n := parse_pair(s) or .{0, 0};                // tuple terminator (multi-value)
```

A **void** failable (`-> !`) rejects a plain-value RHS (no success type to
fall back to); `must_init() or must_other()` (chain) and `must_init() catch {}`
(absorb) are the legal forms.

### Path-marker rule

A failable expression `X` may appear **bare** (no `try`) iff its error path
passes through at least one explicit marker before reaching the function
boundary. The markers are: a `try` keyword, a `catch` handler, an `or` value
terminator, or a destructure binding (`v, err := X`). Otherwise `try` (or one
of the other markers directly on `X`) is required.

```sx
a := parse(s) or 0;          // OK — terminator on the path
a := parse(s) catch (e) {...}; // OK — catch marks
v, err := failable();        // OK — destructure marks
a := try foo() or try boo(); // OK — each try marks its own exit

a := foo() or boo();         // ERROR — no marker on the way to the function
a := foo();                  // ERROR — bare, no marker downstream
```

### Set widening

Widening is checked **only at subexpressions whose failure escapes to the
function** (propagation). For a **named** caller `!CallerErr`, the escape set
must be ⊆ `CallerErr` (no auto-widening). For an **inferred** caller `!`, the
escape set is absorbed into the converged union. Failures absorbed by a
downstream chain operand / `catch` / terminator / destructure don't contribute.

### `error.X` as a value

`error.X` is a first-class value outside `raise`:

```sx
default_err : ParseErr = error.BadDigit;  // typed as the named set
tag_id      : u32      = error.BadDigit;  // untyped context → global tag id
if e == error.Empty { ... }               // compare against a literal
```

- Against a **named-set** destination, `error.X` is valid only if `X ∈` the set
  (typo-checked). A comparison to a literal not in the set is a compile error
  (it could never be true). For **inferred** sets this check is skipped.
- An error-set value compares (`==` / `!=`) only with an `error.X` literal or
  another error-set value — **never a raw integer** (`e == 42` is rejected).
  Coerce explicitly (`(xx e) == id`) to use the raw id.
- **Interpolation renders the tag name.** `{}` on an error-set value prints the
  tag name (`BadDigit`), never the raw id, via a tag-name table that is
  **always linked, even in release builds**.

### Discard rejection & flow-check

Dropping the error slot is a compile error:

```sx
v, _ := failable();   // ERROR: the error slot cannot be dropped — handle it
```

Value slots may be discarded (`_, n := parse(s) catch (e) { return; }`). The
statement form `try foo();` is the explicit "propagate, use no value." On a
value-carrying failable, the value slot is live only where the compiler can
prove the error slot is null (path-sensitive flow-check).

### `onfail` (error-path cleanup)

Statement form. Block-rooted (Zig-aligned): legal in any block inside a
failable function. **Fires when an error propagates out of its enclosing
block**, regardless of whether an outer `catch` / terminator later absorbs it.
On success exit (fall-through, `return`, `break` / `continue` without an error)
it is skipped — only `defer` runs.

```sx
make_handle :: () -> (Handle, !) {
  h := try open();
  onfail close(h);          // close ONLY on a subsequent failure
  try configure(h);         // fails → onfail runs → close(h)
  return h;                 // success → onfail skipped; caller owns h
}

open :: (path: string) -> (Handle, !) {
  h := try sys_open(path);
  onfail (e) { log.warn("init failed for {}: {}", path, e); sys_close(h); }
  ...
}
```

**Ordering with `defer`.** Both run in reverse declaration order, interleaved.
On block-error exit both kinds run (newest-first); on block-success exit only
`defer`s run.

**Restrictions.** `raise` / `try` / `return` / `break` / `continue` are
rejected inside an `onfail` (and a `defer`) body — a cleanup body has no
control-transfer target. A failable call in cleanup must be absorbed locally
(`close(h) catch {};` or `flush(buf) or 0`). `onfail` outside a failable
function, or at top level, is rejected.

### Closures with `!`

- **Explicit annotation required.** A closure literal's value type is inferred
  as today, but if its body raises or `try`-escapes, the `!` channel is **not**
  inferred — declare it (`closure((x: i32) -> (i32, !) { ... })`). This keeps
  adding a `raise` from silently changing a lambda's type.
- **Program-wide union per shape.** All `Closure(<sig>) -> (T, !)` occurrences
  with the same signature share one inferred-set node; the SCC pass unions
  every closure flowing into any matching slot.
- **FFI boundary.** A failable closure cannot be assigned to a non-failable
  function-type slot — extern (C) code can't observe the error channel. Wrap and
  absorb the error instead.
- **Non-failable → failable widening is allowed** (∅ ⊆ any set). A
  non-failable closure assigned to a failable slot contributes ∅; a single
  coalesced adapter thunk `(v) → (v, 0)` reconciles the 1-slot vs 2-slot ABI at
  the crossing point.

### Return traces

A failable that reaches the function boundary unhandled carries a **return
trace** — the chain of `raise` / `try` sites the error passed through.

- **Storage:** a thread-local fixed-cap ring (32 frames; newest survive on
  overflow). `raise` and each failing `try` push a frame; every absorbing site
  (`catch`, a succeeding chain attempt, a value terminator, a destructure)
  clears the buffer.
- **Resolution is in-process — no DWARF, no OS symbolizer.** A runtime frame is
  a pointer to a compile-time-interned `Frame { file, line, col, func, line_text }`
  stamped at the push site; the formatter reads it directly (deterministic,
  identical across OS/target, works under the JIT and a signed iOS `.app`). A
  comptime frame is `(func_id, ir_offset)` resolved via the interpreter's
  in-memory IR/source tables.
- **Mode.** On by default in debug; release no-ops the push points
  (opt back in with `--release-traces`). **Comptime (`#run`) is always traced.**
- **Formatting** lives in `library/modules/trace.sx` (`trace.print_current()`),
  rendering `func at file:line:col` per frame plus the source line and a `^`
  caret. DWARF line-info is still emitted (debug, strippable) so `lldb` / `gdb`
  can step sx source — that is a debugger artifact, separate from trace
  resolution.

### ABI

The error slot is a `u32`, always the last slot of the multi-return tuple, in
both register- and stack-return conventions. `0` = no error; non-zero = an
interned global tag id (pool capacity ~4.3 billion; fixed 32-bit, no dynamic
widening across builds). Errors are a pure value channel — no coupling to the
implicit `context`.

---

## 13. Grammar (informal)

```
program         = top_level*
top_level       = decl | import_decl | context_extend
import_decl     = '#import' STRING ';'
                | IDENT '::' '#import' STRING ';'
context_extend  = '#context_extend' IDENT ':' type '=' expr ';'
decl            = const_decl | var_decl | fn_decl | enum_decl | struct_decl | error_decl
error_decl      = IDENT '::' 'error' '{' IDENT (',' IDENT)* ','? '}' ';'
const_decl      = IDENT '::' expr ';'
                | IDENT ':' type ':' expr ';'
var_decl        = IDENT ':=' expr ';'
                | IDENT ':' type '=' expr ';'
                | IDENT ':' type ';'
fn_decl         = IDENT '::' '(' params? ')' ('->' ret_type)? block
                | IDENT '::' block
ret_type        = type ('!' IDENT?)?    // trailing `!` = failable; channel outside any Tuple
enum_decl       = IDENT '::' 'enum' '{' (IDENT ';')* '}'
struct_decl     = IDENT '::' 'struct' '{' struct_member* '}'
struct_member   = field_group | '#using' IDENT ';'
field_group     = IDENT (',' IDENT)* ':' type ('=' expr)? ';'
params          = param (',' param)* ','?
param           = IDENT ':' type ('=' expr)?
block           = '{' stmt* '}'
stmt            = decl | assignment ';' | multi_assign ';' | return_stmt | defer_stmt | insert_stmt
                | push_stmt | break_stmt | continue_stmt | raise_stmt | onfail_stmt | expr ';'
return_stmt     = 'return' expr? ';'
break_stmt      = 'break' ';'
continue_stmt   = 'continue' ';'
raise_stmt      = 'raise' expr ';'
onfail_stmt     = 'onfail' ('(' IDENT ')')? (block | expr ';')
defer_stmt      = 'defer' expr ';'
insert_stmt     = '#insert' expr ';'
push_stmt       = 'push' expr block
assignment      = lvalue ('=' | '+=' | '-=' | '*=' | '/=') expr
multi_assign    = lvalue (',' lvalue)+ '=' expr (',' expr)+
lvalue          = IDENT | postfix '.' IDENT
expr            = if_expr | match_expr | while_expr | for_expr | lambda | binary
while_expr      = 'while' expr block
for_expr        = 'for' for_iter (',' for_iter)* [for_capture] (block | '=>' stmt)
for_iter        = expr [range_op [expr]]
range_op        = '..' | '..=' | '..<' | '<..' | '<..=' | '<..<' | '=..' | '=..=' | '=..<'
for_capture     = '(' ['*'] IDENT (',' ['*'] IDENT)* ')'
binary          = catch_expr (binop catch_expr)*    // binop includes `or` (fallback / chain)
catch_expr      = unary ('catch' ('(' IDENT ')')? (block | '==' '{' case_arm* else_arm? '}' | unary))?
unary           = ('-' | '!' | 'xx' | 'try') postfix
                | postfix
postfix         = primary ('(' args? ')' | '.' IDENT | '.{' field_init_list '}')*
primary         = INT | HEX_INT | OCT_INT | BIN_INT | FLOAT | STRING | BOOL | IDENT | '---'
                | '.' IDENT | '.' '{' field_init_list '}'
                | '(' expr ')' | block | '#run' expr    // bare parens = grouping ONLY
field_init_list = field_init (',' field_init)* ','?
field_init      = IDENT '=' expr | IDENT | '..' expr | expr
if_expr         = 'if' expr 'then' expr ('else' expr)?
                | 'if' expr block ('else' block)?
match_expr      = 'if' expr '==' '{' case_arm* else_arm? '}'
case_arm        = 'case' pattern ':' (stmt* | 'break' ';')
else_arm        = 'else' ':' stmt*
pattern         = '.' IDENT | INT | BOOL | IDENT
lambda          = '(' params? ')' ('->' type)? '=>' expr
args            = expr (',' expr)* ','?
type            = '$' IDENT | 'i32' | 'f32' | 'f64' | 'bool' | 'string'
                | 'any' | 'Type' | '..' type | '[' expr ']' type | IDENT
                | 'Tuple' '(' tuple_type_list? ')'           // tuple type: Tuple(A, B) / Tuple(x: A) / Tuple() / Tuple(..F(Ts))
                | '(' type ')'                               // grouping (bare parens never form a tuple)
                | '(' (type (',' type)*)? ')' '->' type ('!' IDENT?)?  // function type (params optional; optional error channel)
                | '!' IDENT?                                  // pure failable (`!` / `!Named`)
tuple_type_list = tuple_type_elem (',' tuple_type_elem)* ','?
tuple_type_elem = IDENT ':' type | '..' type | type
```

---

## 14. Open Questions

- **Nested functions**: Yes — a `f :: (…) { … }` declared inside another
  function is a *static* nested function (a plain top-level function, name-scoped
  to its enclosing block). It has NO environment, so it may reference: its own
  params/locals, SIBLING nested fns, itself (recursion), enclosing local *types*
  (`P :: struct {…}`), module-level consts/globals, and comptime constants. It
  may **not** reference an enclosing function's local, parameter, or local `::`
  const — a static fn has no captured frame to read it from, and doing so is a
  compile error ("a nested function cannot reference the enclosing local 'x' —
  use a closure ('x := () => …') to capture it"). Capturing enclosing locals is
  the CLOSURE's job — spell it `x := () => …` (`:=` + `=>`), which captures by
  pointer. (Enclosing local consts are rejected too rather than comptime-folded:
  a static nested fn's frame cannot carry them, and the closure spelling captures
  them uniformly.) Resolved: issue 0250.
- **Operator overloading**: Not shown — presumably no.
- **Top-level expressions**: Are bare expressions allowed at the top level or only declarations?
