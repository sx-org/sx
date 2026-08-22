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
alias / `constraint` / `interface` / runtime class / ufcs alias / namespaced
import). A
value-spelled-as-type parses as a *type*, not a value, so its address-of /
autoref paths would mis-lower; a type / const / function / method name spelled as
a builtin would shadow the builtin. The exemptions are the backtick escape
(below), `@import c` extern decls, and **member-name positions** (next) — it is
**not** rejected at every place a name appears.

**Member-name positions are exempt.** A struct **field** name, a union **tag**
name, and a **method-signature** name in a `constraint` or `interface` body may
be a bare reserved spelling.
These sit in a member slot (`name: T` / `name :: (…)`) and are reached only via
`obj.name` (or dispatched by string), so they are never type-classified and never
mis-lower. The backtick form is optional there and names the same member — `obj.i2`
and `` obj.`i2 `` both resolve. The exemption covers member *signatures* only: an
`impl` method **definition** is a real function (a declaration site, not a member
slot), so a reserved-spelled impl method still needs the backtick
(`` `i2 :: (self) ``), exactly like a free function. See `examples/0158`.

**Statement keywords are member names too.**
Every keyword except `inline` — `if`, `push`, `while`, `for`, `case`, `return`,
`f32`, `f64`, `try`, `defer`, … — may bare-name a struct **field**, a struct
**method or constant**, a `constraint` or `interface` **method**, and an
enum/tagged-union
**variant** (`enum { struct: StructInfo; bool; }` — std/meta.sx's `TypeInfo`
is the canonical case), and is reached bare after a dot: field access
(`q.push(…)`, `q.for`), enum literals and case patterns (`.enum`,
`case .struct:`), and optional chaining (`o?.if`). Declaration position
is unambiguous — struct, `constraint`, `interface`, and `impl` bodies hold only
declarations —
and access is dot-disambiguated. Unlike the type-spelling rule above, keyword
names are bare-legal in `impl` method **definitions** as well: a keyword-named
interface method must be implementable without ceremony, and a keyword has no
builtin to shadow. The one exception is **`inline`**, which stays
backtick-only (`` `inline ``); a bare `inline` in member position rejects with
a targeted escape-hint. A **literal field label** is an identifier: in `.{ … }`
and `T { … }` a keyword label takes the backtick raw escape
(`` .{ `push = 1, `if = 2 } ``), and a bare keyword there heads a positional
expression, so `.{ if x > 1 then 10 else 20, 2 }` is an if-expression element.
Value-binding positions (locals, params, function names) reject keywords.

**`Closure(` builds a type in type position only.** The type constructor
`Closure(...) -> R` is read wherever the grammar demands a type — an
annotation, a parameter, a field, a return, a type argument — and directly
after `::`, where the exact token pair `Closure`+`(` opens a type alias
(`CB :: Closure(i32) -> i32`). Everywhere else `Closure` is an ordinary
identifier: a function named `Closure` is called as `Closure(5)` with no
escape. `Tuple` is an ordinary identifier in every position.

Every reserved spelling except `inline` bare-names member slots — the
identifier-classified spellings (`i1`..`i64`, `u1`..`u64`, `bool`, `string`,
`cstring`, `void`, `usize`, `isize`, `any`) and the keyword-classified `f32` /
`f64` alike: `` struct { f32: i64; } `` and
`` interface { f32 :: (self: *Self) -> i64; } `` are legal as written; the
backtick forms remain available but are never required for them.

```sx
i2 := 2.5;                          // ERROR: 'i2' is a reserved type name and cannot be used as an identifier
i2 :: 5;                            // ERROR — a `::` constant name is a binding site too
i2 :: (n: i64) -> i64 { n }         // ERROR — so is a function name
i2 :: struct { x: i64; }            // ERROR — and a type-declaration name
```

(There is no exception for the stdlib: a reserved type name is reserved
everywhere. `string` is a language primitive — the compiler resolves it by
name, it is declared nowhere, and it cannot be re-bound.)

#### The `@` namespace

A leading `@` marks a **compiler-maintained contract**: a declaration whose
shape the compiler depends on, so changing it is a coordinated compiler and
stdlib revision. The sigil grants no privilege — an `@` declaration is
ordinary, source-visible sx, and user code constructs its values like any
other type:

```sx
site := @SourceSite{ file = "fake.sx", declaration = "tests.fake", line = 1 };
```

Which `@` names exist, and which module owns each canonical declaration, is a
compiler registry. An `@` declaration in any other file is rejected. The owning
module is the one resolved from a **library root**, matched by identity on disk
— never by a name-and-field-shape test, and never by what a path spells, so
neither a nested `…/modules/std/core.sx` nor a project-local file that shadows
the import can stand in for the canonical declaration:

```sx
@Site :: struct { … }         // ERROR: not a compiler-maintained contract
@SourceSite :: struct { … }   // ERROR: 'modules/std/core.sx' declares it
```

A contract need not be a type: an `@` name also declares a function, under the
same (module, name) identity rule. Most are a signature with no body, which the
compiler implements — `@volatile_load` and `@volatile_store` (§Intrinsics,
Memory), `@sqrt` / `@sin` / `@cos` / `@floor`, `@printf`, `@is_comptime`
(§Compile-time Evaluation, `@is_comptime()`).
`@panic` is ordinary sx: a body written in the owning module, over `@printf` and
`@is_comptime`.

`@printf($fmt: string, ..$args)` is an allocation-free formatted write to fd 1.
`$fmt` is a comptime string in the same `{}` vocabulary `print` takes — `{}`
consumes the next argument, `{{` and `}}` write a brace — and the compiler
expands the call into one write per segment and per argument, in source order.
An argument is a `string`, a `bool`, an integer or a float; any other type is a
compile error, because rendering it takes the allocating formatter, `print`.

`@panic(msg: string, site: @SourceSite = @caller) -> noreturn` writes
`file:line: msg` and stops the program; a site with `line == 0` writes bare
`msg`. A `@run` panic exits the COMPILER with code 1, a compiled panic raises
SIGABRT. It renders through `@printf`, so it reaches its message with a broken
or exhausted allocator behind it.

A contract name resolves program-wide. The registry admits exactly one canonical
declaration of it, so there is no second author for the import-visibility rule to
choose between: `@SourceSite` and `@VaList` are spelled bare wherever they are
written.

Separately, a few `@` names are **compiler-formed** — `@run`, `@insert`, `@Init(T)`,
`@BuildBlock(P)`, `@Vector(N, T)`, `@Array(N, T)` and `@Slice(T, Len)`. There is
no stdlib declaration to read, and declaring the name is an error. `@run` is
the compile-time evaluation prefix (`@run expr`); `@insert` splices a
compile-time string as sx (`@insert expr`); see
[§8](#8-compile-time-evaluation). `@Init` and `@BuildBlock` are constraints,
written only as a bound on the parameter (`value: $I/@Init(T)`,
`content: $B/@BuildBlock(P)`) and never as its type — see [`@Init(T)`](#initt)
and [`@BuildBlock(P)`](#buildblockp). `@Vector(N, T)` (§Vector Types),
`@Array(N, T)` (§Array Types) and `@Slice(T, Len)` (§Slice Types) are type
constructors, written wherever a type is.

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
constraint / interface / runtime-class / ufcs / namespaced-import name); the
backtick form is
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
for `bool, `u16 in xs, 0.. { }    // for captures
x catch |`i2| { }                   // catch tag binding
```

In the **member-name positions** among these — struct field, union tag, and
method signature in a `constraint` or `interface` body — the backtick is
*optional*: the bare reserved
spelling is already legal there (see "Member-name positions are exempt" above).
Everywhere else (value bindings and declaration names, including an `impl` method
definition) the backtick is *required* to spell a reserved name.

A reserved-spelled **function** is bare-callable: `` `i2 :: (n: i64) -> i64 { … } ``
can be invoked as `i2(10)` (the bare callee spelling parses as a type but resolves
to the function when one of that name is in scope; `TypeName(val)` is not a cast).

A backtick may also escape a keyword spelling (`` `for ``, `` `struct ``), yielding
an identifier with that text.

**`@import c` exemption.** Extern declarations synthesized by an `@import c { … }`
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
| Float     | `0.3`, `0.9`        | `f64`   |
| String    | `"Hello"`, `"z: {z}"` | `string` (may span multiple lines) |
| Heredoc String | `@string END`...`END` | `string` |
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

**Heredoc strings** use `@string DELIMITER` syntax (inspired by Jai). Content is completely raw — no escape processing. The delimiter is any identifier. Content starts after the newline following the delimiter and ends when the delimiter appears at column 0 of a line.
```sx
vert_src := @string GLSL
#version 330 core
void main() {
    gl_Position = vec4(aPos, 1.0);
}
GLSL;
```

### Keywords
`if`, `else`, `then`, `while`, `for`, `break`, `continue`, `true`, `false`, `enum`, `struct`, `union`, `case`, `return`, `defer`, `push`, `ufcs`, `in`, `is`, `xx`, `and`, `or`, `raise`, `try`, `catch`, `onfail`, `error`, `private`

> Note: `enum` is used for both payload-less and payload-bearing sum types (tagged unions). `union` is reserved for C-style untagged unions (memory overlays).

> Note: `raise`, `try`, `catch`, `onfail`, and `error` are the error-handling keywords. `??` supplies a failable's default, alongside its optional one. See [§12 Error Handling](#12-error-handling).

> Note: `private` is the file-local visibility modifier for module-scope
> declarations and struct fields — see
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
| `??`     | default: optional payload or failable success |
| `?!`     | force-unwrap optional |
| `!`      | logical NOT (prefix) |
| `in`     | membership test (tuples)    |
| `is`     | type classification (§The `is` Operator) |
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
| `=>`   | expression body of a function declaration |
| `$`    | generic type parameter introduction   |
| `---`  | undefined value                      |
| `()`   | grouping / params                    |
| `\|…\|` | closure literal parameters           |
| `{}`   | blocks / bodies                      |

### Spacing and terminators

`!` is prefix `not`. `?!` is postfix force-unwrap. `{` juxtaposes with the
expression before it wherever that statement is open. Everywhere else
whitespace is free. `;` is what ends a statement, and a line break is ordinary
space.

**Free — `(`, `[`, and a prefix `-` / `--` / `*` take any spacing.** A `(`
applies arguments and a `[` indexes however much space stands between it and
what precedes it, and a prefix operator binds its operand across a gap the same
way:

```sx
foo(2)      foo (2)      // both a call
Box(i64)    Box (i64)    // both a type application
xs[0]       xs [0]       // both an index
-b          - b          // both a negation
*p          * p          // both an address-of
```

The same holds in every type position that applies arguments (annotation, return
type, parameter type, struct field type, type alias, constant annotation, `.(T)`
cast target, type argument to a builtin, match-arm type pattern, an `impl`'s
constraint or interface arguments) and in the fixed forms whose argument list
the grammar
mandates — `Closure(i64) -> i64`, `@Init(P)` / `@BuildBlock(P)` (including in a
bound, `$B/@BuildBlock(Drawable)`), `@OpenVariant(View)`, `@OpenSet(.{ … })`. A
bracket that opens something *new* is free in the same way — grouping
(`(a + b)`), parameter and capture lists, array and slice types (`[3]i64`,
`[]u8`), and the `(…)` of a declaration form:

```sx
add    :: (a: i64, b: i64) -> i64 => a + b;   // fn declaration
scaled :: ufcs (v: i64) -> i64 => v * 2;      // ufcs declaration
Pair   :: struct ($T: Type) { a: $T; b: $T; } // struct type params
Show   :: interface (T) { render :: (self: *Self) -> T; }
Padded :: @OpenVariant(View) ($T: Type) { … } // generic open-set member
v := risky() catch |e| -1;                    // catch binding
onfail |e| { … }                              // onfail binding
```

**Position — `-` and `*` are infix wherever a left operand is complete.** Both
glyphs also have a prefix reading (negation, address-of), and position decides
between the two: after a completed operand the glyph is infix, whatever the gaps
around it are, and a slot with no left operand takes the prefix reading. A line
break changes nothing — the operand above it is still complete:

```sx
a - b       // infix subtraction
a-b         // infix subtraction
a -b        // infix subtraction
a- b        // infix subtraction
a - -b      // infix `-`, then a prefix `-b`
a
-b          // infix subtraction — the operand above is complete
g();
-b          // the `;` cut the operand — a prefix `-b`
```

`--` is a lexeme of its own with one reading, the prefix pre-decrement: `--b`
and `-- b` both decrement `b` and yield the new value, while `a--b` and `a --b`
have no reading at all — the operand `a` is complete and `--` is no infix
operator.

**Postfix — `?!` is force-unwrap.** It is one token (`? !` is not the symbol)
and binds wherever the statement is still open, across a gap or a break; the
`;` is what cuts. Prefix `!` is `not`:

```sx
print("{}\n", maybe?!);
print("{}\n", maybe ?!);
ready;
!ready;                       // prefix `not`
```

A `{` juxtaposes with the expression before it wherever that statement is still
open, across a break included; the `;` is what cuts:

```sx
p := Pair
{ a = 1, b = 2 };             // still open — the aggregate

Pair;
{ setup() }                   // the `;` cut — an expression and a block
```

The dot-led postfixes are the other camp. `.`, `?.`, and `catch` have no second
reading for a break to pick up, so each reads on down the page, and a leading
`.` chains whenever what it follows is an expression rather than a statement —
the line **Statements break, expressions chain** draws at the end of this
section.

**Terminators — `;` ends a statement.** A line break is ordinary space, so a
statement runs until its `;`:

```sx
a := 1;
b := compute(a);
print("{}\n", b);
```

One rule, applied wherever a statement or a declaration ENDS: top-level and
local bindings, expression statements, assignments, `return` / `raise` /
`break` / `continue` / `defer` / `onfail`, `@import` / `@insert` / `@error` and
the other directive forms, and a function's `extern` / `intrinsic` / `=> expr`
body. The value-less spellings take it the same way — a `return` with nothing to
return, and a `name : Type` declaration with no initializer:

```sx
counter : i64;
bump :: (by: i64) -> void {
    counter = counter + by;
    return;
}
```

This holds for a `return` in expression position too, so an early exit written
`if quiet then return;` takes the statement below it as the next one and not as
the value it returns:

```sx
report :: (quiet: bool) -> void {
    if quiet then return;
    print("loud\n");
}
```

The end of the file ends the declaration it lands on, so a file's last
declaration needs no terminator. Neither does the last statement before a `}`
(see below). A `match` arm body is an ordinary statement list, so every
statement in it takes its `;` — `case` and `else:` are statement heads, not
terminators — and only the last statement of the last arm sits before the
match's `}`:

```sx
match c {
    case .a:
        setup();
        report();
    case .b:
        if ready {
            report();
        }             // a statement that is a block ended at its `}`
    case .c: break;
    else:
        done()        // the match's `}` ends it
}
```

`else` reads two ways and a following `:` is what tells them apart: `else:`
heads the default arm, while every other `else` — before a block, an `if`, or an
expression — chains the `if` above it.

A statement whose last token is a `}` that closes a block form takes no
terminator: a statement that IS a block (`if`, `while`, `for`, `match`, a
`push` body, a bare scope), and a declaration whose INITIALIZER is one of those.
A statement ending in a juxtaposition — `expr { … }` — takes its `;` after the
`}` like any other expression statement.

```sx
kind := if c { "hot" } else { "cold" }   // block-form initializer — no `;`
row  := vstack(8.0) {
    body();
};                                       // a juxtaposition takes the `;`
n    := compute(3);                      // any other initializer takes the `;`
```

**`;` is a pure separator.** Ending a statement is all it does. It carries no
other meaning anywhere in the language: it never discards a value, never decides
what a block's value is, and never decides whether a build body's child
publishes. Wherever a value can flow, it flows the same with the `;` written and
with it left out — see [Block values](#block-values) and
[`@BuildBlock(P)`](#buildblockp).

An unterminated statement reads straight on through a line break, so an
expression spread over several lines is one statement:

```sx
mask := (hi << 16)
    | lo;
ok := ready
    and loaded
    or forced;
```

The same holds for the tails a declaration may still take, and for a form that
is simply still open — an unclosed `(`, an argument list, a `{` with no `}` yet:

```sx
LIMIT : i64
    : 9;                      // a typed constant
errno_loc : *i32
    extern libc "__error";    // an extern data global
mystery :: i64
    intrinsic;                // a typed intrinsic

sx_double :: (n: i32) -> i32 export
    "double_c"
    { n * 2 }                 // the linkage tail reads on to the body
```

An expression or a declaration written last before a `}` may leave its
terminator out; every other statement form takes its `;` there as anywhere
else. When that last statement is an expression it is the block's value, written
either way (see [Block values](#block-values)):

```sx
tight  :: () -> i64 { 41 }
spread :: () -> i64 {
    n := 41;
    n                         // no terminator — the block's value, as above
}
ended  :: () -> i64 { 41; }   // the `;` separates; the value is still 41
```

The rule does not reach inside a fixed form's own list — a runtime class's
members and the entries of `@import c { … }` each keep the `;` their grammar
asks for, in every position.

**Statements break, expressions chain.** Whether a `}` can be continued is
decided by what it closes. A statement that IS a block — `if`, `while`, `for`,
`match`, a `push` body, a bare scope `{ … }` — ends at its `}`, so what follows
starts a new statement. An expression that merely ENDS in a block — a
trailing-block call, an aggregate literal, a self-trailing `.{ }` — is still an
expression, and its postfix chain reads on:

```sx
{
    setup();
}
.unknown;                     // the scope ended; this is the next statement

if ready {
    setup();
}
else { … }                    // `else` continues the `if` above it

c := vstack(1.0) {
    body();
}
    .doubled()                // the call is an expression — the chain goes on
    .show();
```

---

## 2. Type System

### Primitive Types
- `i1`..`i64` — signed integers (1 to 64 bits). `i64` is the default for integer literals.
- `u1`..`u64` — unsigned integers (1 to 64 bits).
- `f32` — 32-bit floating point
- `f64` — 64-bit floating point
- `bool` — boolean (`true` / `false`)
- `string` — string of characters
- `any` — type-erased BORROW, represented as `{ data: pointer, type_id: i64 }` — the data word (word 0) is the ADDRESS of the value, the type_id word (word 1) its runtime type tag (Odin `Raw_Any` `{data, id}`, same order; the `{pointer, type_id}` prefix is shared with interface handles — see Constraints and Interfaces), never a copy of its bits. Used for variadic arguments, runtime type dispatch, and reflection views. Boxing an addressable lvalue points at its storage (zero copy — mutations of the source stay visible through a live view); boxing an rvalue materializes a temporary scoped to the enclosing frame. An `any` is valid only while the referenced value lives: do not store an `any` beyond its referent. Unboxing via `xx` is an UNCHECKED typed load through the view — the target must be the boxed type (`data` covers exactly `size_of(tag)` bytes; a wider target overreads); the checked forms are the postfix assertions (`av.(T)` / `try av.(T)` / `av.(?T)`). `==`/`!=` are NOT defined on `any` (compile error): unbox first, or compare `type_of(av)`.
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
as an array dimension (`['A']u8`), and in `match` / `inline if` const comparisons.

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
  reinterpret (`union { u: u64; s: i64; }`) is still a valid way to inspect the
  raw bits, but is not needed merely to print the value.
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
  the integer `.min`. It is **NOT** C's `DBL_MIN`/`FLT_MIN`, which is the
  smallest positive normal; that is `.min_positive` here.
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
    (`nan != nan` is `true` — native float `!=` lowers unordered).
- **Float-only on an integer is an error.** `.epsilon` / `.min_positive` /
  `.true_min` / `.inf` / `.nan` applied to an integer type (`i32.epsilon`,
  `u8.inf`, `i64.true_min`) is a clean compile error — integer types expose only
  `.min` / `.max`.
- **Pinning the values.** The lexer has no exponent notation and the default
  float formatter is crude, so float limits can be asserted neither
  by literal comparison nor by printing. Reinterpret the bits through an untagged
  union (`union { f: f64; bits: u64; }`) and compare against the exact IEEE-754
  pattern — `f64.max = 0x7FEFFFFFFFFFFFFF`, `min = 0xFFEFFFFFFFFFFFFF`,
  `epsilon = 0x3CB0000000000000`, `min_positive = 0x0010000000000000`,
  `true_min = 0x0000000000000001`, `inf = 0x7FF0000000000000`; the `f32` set is
  `0x7F7FFFFF` / `0xFF7FFFFF` / `0x34000000` / `0x00800000` / `0x00000001` /
  `0x7F800000`.
- **Type receiver vs. a shadowing value binding.** A numeric-limit access folds
  only when the receiver is a builtin numeric **type name** (`f64.epsilon`,
  `i32.max`, `u8.max`). A backtick raw identifier that binds a *value* whose
  spelling shadows a type name is an ordinary value: `` `f64.epsilon ``
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
match s {
    case .circle: print("circle\n");
    case .rect: print("rect\n");
    case .none: print("none\n");
}
```

#### Payload Capture
Match arms can capture the variant's payload into a local variable:
```sx
match s {
    case .circle: |radius| { print("radius: {}\n", radius); }
    case .rect: |size| print("size: {}\n", size);
}
```
The `|name|` after the colon binds the payload; an arm with no payload
carries no pipes (`case .none: 0`). The body that follows is a block
(`case .variant: |name| { body }`) or an expression
(`case .variant: |name| expr;`).

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
- Pattern matching (`match x { case ... }`) is not supported on unions.
- Unions cannot be printed directly via `print("{}", union_val)` — access individual fields instead.

### Struct Types
User-defined product types with named fields.
```sx
Vec4 :: struct {
  x, y, z, w: f32;
}
```
Fields are declared as `name1, name2: type` (comma-separated names sharing a type; members are `;`-separated, trailing `;` optional).

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
v2 := Vec4{4, 1, 1, 3 };

// Named fields (any order)
v3 := Vec4{w=0, x=2, y=3, z=4 };

// Mixed named + shorthand (bare identifier = field name matches variable name)
z := 5.0;
w := 6.0;
v4 := Vec4{y=3, x=9, w, z };

// Trailing commas are allowed in all comma-separated lists
v5 := Vec4{x = 1.0,
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

Named aggregates place `{` directly after the type designator: `Point{ x = 1 }`,
`List(i64){}`, `mod.Config{ port = 80 }`. The separator-dot form `Type.{…}`
is a hard error with a fix-it to the compact spelling. Contextual `.{…}` keeps
its leading-dot form.

A block after a completed aggregate is **dot-led**: it stores the value, binds
a pointer to it, runs the block, and yields the (possibly mutated) value. The
same form writes into a contextual `.{ … }` literal.

```sx
b := Button{ label = "Play" }.{
    self.label = "Go";
};

// A `|name|` header names that pointer instead of `self`; it binds exactly
// one name, and `*T` is its type.
b1 := Button{ label = "Play" }.{ |btn|
    btn.label = "Go";
};

// A bare second brace group is a scope of its own — the `;` ends the
// construction.
b2 := Button{ label = "Play" };
{
    print("built\n");
}
```

`push` context expressions may be named aggregates; the body brace is the push
scope (not a second competing trailing form):

```sx
push .{ allocator = a } { … }              // idiomatic
push Context{ allocator = a } { … }        // explicit Context literal
```

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
always distinct types:

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

#### `@using` — Struct Composition
`@using StructName;` inside a struct declaration embeds all fields from `StructName` at that position. The embedded fields are accessed directly, as if declared inline.

```sx
UBase :: struct { x: i32; y: i32; }
UExt :: struct { @using UBase; z: i32; }
e := UExt{x = 1, y = 2, z = 3 };
print("{}\n", e.x);  // 1
```

`@using` may appear at any field position (beginning, middle, end) and multiple `@using` entries are allowed:
```sx
UPos :: struct { px: i32; py: i32; }
UCol :: struct { r: i32; g: i32; }
USprite :: struct { @using UPos; @using UCol; scale: i32; }
s := USprite{px = 10, py = 20, r = 255, g = 128, scale = 1 };
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

p := Point{x = 3, y = 4 };
print("{}\n", p.sum());  // 7
```

Methods receive the struct (typically as a pointer) as their first parameter. Dot-call syntax `obj.method(args)` resolves struct methods — it is **not** UFCS for arbitrary free functions. A free function becomes dot-callable only by opting in with `ufcs`.

### Constraints and Interfaces

A **constraint** and an **interface** each name a set of method
signatures. A type conforms by providing those methods in an `impl`
block. A constraint bounds generic binders and has no runtime values; an
interface is additionally a runtime handle with dynamic dispatch.

```
decl := Name '::' ( 'constraint' | 'interface' ) [ '(' params ')' ] '{' body '}'
```

Both head words are contextual: ordinary identifiers everywhere else,
read as declaration heads only in this `::`-head slot. `protocol` is an
ordinary identifier.

#### 1. The two declarations

| declaration | runtime values | dispatch | conformance |
|---|---|---|---|
| `constraint` | none | monomorphized per use site | `impl` |
| `interface` | erased handle, 3 words, borrow-only | vtable pointer | `impl` |

```sx
Ord   :: constraint { less :: (self: *Self, other: Self) -> bool; }
Into  :: constraint(Target: Type) {
    convert :: (self: *Self, alloc: Allocator) -> Target;
}
Show      :: interface { fmt :: (self: *Self) -> string; }
Hasher    :: interface {
    put :: (self: *Self, bytes: []u8);
    sum :: (self: *Self) -> u64;
}
Allocator :: interface {
    alloc_bytes   :: (self: *Self, size: i64) -> *void;
    dealloc_bytes :: (self: *Self, ptr: *void);
}
View      :: interface {
    size_that_fits :: (self: *Self, proposal: ProposedSize) -> Size;
    layout         :: (self: *Self, bounds: Frame);
    render         :: (self: *Self, ctx: *RenderContext, frame: Frame);
}
Series    :: interface(T: Type) {
    count :: (self: *Self) -> i64;
    at    :: (self: *Self, i: i64) -> T;
}
```

The examples throughout describe one notional program built from the
declarations above; every snippet restates the declarations it touches,
so each reads in place.

#### 2. Declaration

**Body.** A body holds method signatures and default-method bodies —
nothing else (no fields, no constants).

**Receiver.** Every method declares its receiver explicitly as the first
parameter, `self: *Self` or `self: Self`. A first parameter of any other
shape is a parse error. An impl's receiver spelling must match the
declaration. Dispatch passes the receiver as the context pointer in the
ABI regardless of spelling; a `self: Self` receiver reached through
dynamic dispatch receives a **copy** of the referent (made by the
dispatch thunk or switch arm before the body runs), so mutations of a
by-value receiver are never visible through the handle, matching the
concrete call.

**`Self`.** A contextual keyword naming the conforming type. A
constraint method may mention it at any depth in later parameters and
returns (`Self`, `*Self`, `?Self`, `[]Self`, `Buffer(Self)`). An
**interface** body refuses such a signature at the declaration.

```sx
Eq :: interface { eq :: (self: *Self, other: Self) -> bool; }
```
```
error: 'eq' mentions 'Self' past the receiver, so an interface cannot
       carry it — declare 'Eq' as a constraint and bind through it
       ('$T/Eq')
```

An interface with an empty body is legal and erases with an empty
vtable. Slots index the methods in declaration order. Non-receiver
parameters keep their declared concrete types; only the receiver erases.

**Keyword member names.** Every reserved word except `inline` is a legal
*bare* method name — including the keyword-classified type names (`f32`,
`f64`); `inline` alone is spellable only in backtick form
(`` `inline ``).

**Default methods.** A method with a body is a default; impls may omit
it (or override it by providing their own). Default bodies are compiled
**per conformer**, against the concrete `Self`, so a call
`self.method(…)` inside a default body resolves statically against the
conformer. Dynamic dispatch happens at the outer call site only — the
vtable slot for a defaulted method points at that conformer's compiled
instance.

**Parameters.** The head may declare type and value parameters, exactly
as generic structs do (`constraint(T: Type) …`, `interface(N: u32) …`).
Parameters are in scope throughout the body. A parameterized declaration
is a *family*; each canonical argument tuple names one constraint or one
interface. Canonicalization resolves type aliases and folds value
arguments to comparable constants.

#### 3. Conformance — `impl`

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

- `impl` blocks are top-level declarations. Conformance is retroactive:
  any module may implement any constraint or interface for any type with
  canonical identity. Conformer identity is canonical type identity;
  structural types canonicalize structurally.
- A **constraint** head takes structs, untagged unions, enums, builtins,
  structural composites (`[]T`, `[N]T`, fn types), **and interface
  types** as conformers.
- An **interface** head takes concrete conformers. `impl Q for I` with
  both `Q` and `I` interfaces is refused — an interface handle is not a
  concrete type, and re-erasure (§6.4) is the conversion between them.
- In a blanket impl, `$T` introduces the parameter at its first mention;
  later mentions are bare references.
- Impl methods also register as ordinary methods of the type
  (`Point.fmt`), so concrete calls never pay dispatch. If the type
  already declares a member (method or field) with the same name: a
  method with the exact signature satisfies conformance and the impl may
  omit it (providing it anyway is a duplicate definition error); any
  other same-name member is a compile error at the impl — sx does not
  build overload sets across impl registration.
- An impl must provide every non-default method not already satisfied by
  an exact-signature existing method.
- **Coherence.** Duplicate `(instantiation, conformer)` pairs follow
  import-scoped visibility: a duplicate within one compilation unit is
  an error at the impls, naming both; duplicates across modules are
  diagnosed at a use site that sees both. Colliding blankets are not
  diagnosed (nothing exists to collide at).

**An interface type as a conformer.** An interface's own methods are
members, so exact-signature satisfaction covers them: where the
constraint's signatures are the interface's, the impl body is empty.

```sx
Sized :: constraint { size :: (self: *Self) -> i64; }
Boxed :: interface { size :: (self: *Self) -> i64; }

impl Sized for Boxed { }                   // 'size' is already a member
```

A constraint method mentioning `Self` past the receiver is not an
interface member, so it needs a real body in the impl:

```sx
impl Ord for Boxed {
    less :: (self: *Boxed, other: Boxed) -> bool { self.size() < other.size() }
}
```

**Comptime-expanded conformance.** `impl` blocks participate in the
ordinary top-level comptime declaration forms. An `inline if` gates
conformance on comptime facts — the dead branch's impl never exists,
joins no set, and emits nothing:

```sx
inline if OS == .ios {
    impl View for CameraButton { … }
}
```

A top-level `inline for` unrolls one declaration group per comptime
element — enumerated conformance over a curated list, with the
reflection builtins supplying field-wise bodies. The iterable here is a
comptime array of types; the capture binds each element as a comptime
`Type` constant, usable in type position (the impl head, the receiver
spelling) exactly like a `$T: Type` binding:

```sx
Point  :: struct { x, y: f64; }
Rect   :: struct { origin: Point; w, h: f64; }
Color  :: struct { r, g, b, a: f32; }
Widget :: struct { value: i64; }

Buf :: struct { … }
write_field :: (out: *Buf, name: string, v: any) { … }

Serialize :: interface {
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
membership, coherence (two iterations landing on one pair are the
ordinary duplicate error, naming the unrolled sites), and every
downstream rule apply to the expanded program unchanged. The
bound-blanket (`impl Show for $T/Ord`) is not a supported form — the
`for` target names a type constructor.

**Expansion is monotone and deterministic.** Expansion only *adds*
conformances — nothing retracts. Expansion-driving comptime may consult
per-pair conformance facts (a probe, `T is C`, a conversion), under the
scheduling discipline of §6.9: positive facts answer immediately,
negative answers wait for the impls that could answer them to be final,
and an expansion that depends negatively on a fact it can still feed is
the expansion-deadlock error. No reflection enumerates a conformer set,
at comptime or runtime — conformances are unobservable as collections.

#### 4. Constraints

A constraint has **no runtime values**. It bounds generics and serves as
a compiler-recognized customization point.

```sx
Ord :: constraint {
    less :: (self: *Self, other: Self) -> bool;
}
impl Ord for i64 {
    less :: (self: *i64, other: i64) -> bool { self.* < other }
}

largest :: (xs: []$T/Ord) -> T { … }          // bound: any T conforming to Ord

// Into, restated from §1:
Into :: constraint(Target: Type) {
    convert :: (self: *Self, alloc: Allocator) -> Target;
}
// Dest-inferred `xx val` at a `T` slot, or `val.(T)` / `val.(T, alloc)`,
// falls through the built-in conversion ladder to an `impl Into(T) for
// Source` lookup; the compiler monomorphizes `convert` for the (Source, T)
// pair and emits a direct call. `.(T)` funds from `context.allocator`.
```

**A constraint makes no value.** Every value spelling — a
constraint-typed position, `xx`, postfix `.(C)` — is a compile error:

```sx
o : Ord = 5;      // i64 conforms — but Ord has no values to make
```
```
error: cannot make a value of 'Ord' — a constraint has no runtime
       values; use the concrete type, a generic bound ('$T/Ord'), or an
       interface where a handle is needed
```

The same refusal applies wherever a constraint is used as a *storable*
type: a field, array element, or generic type argument of a constraint
type diagnoses at the declaration or instantiation site.

**Emission: none.** A constraint produces no vtables, no tables, no
metadata. Its methods exist only as monomorphized direct calls at use
sites. Default methods are shared code in source only; each bound
instantiation compiles them against the concrete `Self`.

**Edge cases.**
- A marker constraint (empty body) is legal; it partitions types for
  overload/bound purposes and costs nothing.
- `Self`-in-signature methods are unrestricted — every use site knows
  the concrete type.
- A constraint is a legal comptime `is` left operand: `Ord is interface`
  and `Ord is struct` are both false, and a constraint matches no
  category (§The `is` Operator).

#### 5. Interfaces

##### 5.1 Handle layout

```
interface:  { ctx: *void, __type_id: Type, __vtable: *Vtable }    3 words

            ┌──────────┬────────────┬───────────┐
Show handle │ ctx *────┼─►referent  │ vtable *──┼─► global constant,
            │          │  __type_id │           │    one per pair
            └──────────┴────────────┴───────────┘
```

Slot 0 is the referent's address; slot 1 is the referent's concrete type
id, stamped where the handle is built. The first two words are
byte-identical to an `any` `{data, type_id}` — an interface handle *is*
an `any` of its referent, extended with dispatch information. `type_of`,
the downcast, the type switch, and `@Interface` all read this prefix.

A handle **borrows**. The referent lives outside the handle, the handle
carries no allocator and no ownership word, and copying a handle — `q :=
p`, argument passing, returning, struct/array copying, storing into and
reading out of containers — copies the three words and aliases the same
referent. Nothing owns an interface value: no spelling allocates one,
and `free` refuses one (§5.3).

Vtables are global constants, one per `(instantiation, concrete type,
impl)` — a parameterized interface gets distinct vtables per
instantiation, and distinct impls of the same pair in
visibility-disjoint modules (§3) each get their own. Within any one
import scope exactly one impl is visible, so every coercion site selects
one vtable deterministically. They emit on first use of a pair and are
never allocated or freed at runtime.

##### 5.2 View coercion

An interface-typed **target position** coerces its operand into a handle
over the operand's own storage. The positions are: a call argument, a
binding, a struct- or array-literal field initializer, a `push` field,
an assignment, and the operand of a `?I` wrap.

| operand | result |
|---|---|
| lvalue of a conforming concrete type | handle borrowing that storage in place |
| `*T`, `T` conforming | handle borrowing the pointee |
| `*I` | loads the handle out of the pointee |
| a value already of type `I` | the handle, copied |

There is no rvalue arm. An I-typed target never invents a temp: a
concrete rvalue has no storage of its own to borrow, so every such
position is a compile error — including a `..xs: []I` element and the
operand of a `?I` wrap. Optional is not an escape hatch:
`g : ?Sizable = Widget{ value = 2 }` is the same error as
`t : Sizable = Widget{ value = 2 }`.

The `*I` arm is read before the pointer arm, so a `*I` operand yields
the stored handle rather than a handle over the pointer.

```sx
Widget  :: struct { value: i64; }
Sizable :: interface { size :: (self: *Self) -> i64; }
impl Sizable for Widget {
    size :: (self: *Widget) -> i64 { self.value }
}

measure :: (v: Sizable) -> i64 { v.size() }
pretty  :: (v: $T/Sizable) -> i64 { v.size() }

w  := Widget{ value = 7 };
s : Sizable = w;                    // borrows w in place
measure(w);                         // same coercion at the argument
measure(*w);                        // a pointer borrows its pointee
u : Sizable = s;                    // the handle, copied — one referent
pretty(Widget{ value = 8 });        // $T/I is not an I-typed target
p := a.make(Widget{ value = 9 });   // @Init argument, *T result
measure(p);                         // *T arm
```

```sx
t : Sizable = Widget{ value = 8 };          // error
measure(Widget{ value = 8 });               // error
g : ?Sizable = Widget{ value = 2 };         // error — wrap operand is an I target
return Widget{ value = 1 };                 // error at `-> Sizable`
return S{ inner = Widget{ value = 1 } };    // error — field init is an I target
```
```
error: cannot borrow a temporary into a 'Sizable' handle — bind the
       value where it lives, or write it through 'Allocator.make' and
       use the handle over that
```

`$T/I` is not an I-typed target. `pretty(v: $T/Sizable)` plus a concrete
literal is a Widget argument. `measure(v: Sizable)` plus a concrete
literal is the error.

**Explicit coercion.** `x.(I)` states the same coercion, over the same
arms, at any expression position. There is no allocating form: `.(I,
alloc)` is not a spelling. The postfix is optional when the destination
is already I-typed: `measure(w)` and `measure(w.(Sizable))` are the same
coercion. On a concrete rvalue it is the same error.

**`.{ }` is a struct literal.** It never forms a handle and is never
`?T` absence. `x : I = .{}` and `x : ?I = .{}` are compile errors.

**`?T` none is `null`.** Absence of `?I` is spelled `null`, the same as
`?i32` and `?Closure`. `null` does not type at a non-optional slot:
`x : I = null` and `x : i64 = null` are compile errors (the diagnostic
names `?I` / `?i64`). `*T = null` is the null pointer.

**`---` is uninit.** A non-optional I slot may be `---` (LLVM undef, no
handle). `parent_allocator: Allocator = ---` is the GPU dummy: `init`
writes the field. A statically-constructed struct cannot take `---` at
an I field — the operand of a static position names a module-scope
global (§6.6).

##### 5.3 `free`

`free` handles closures and slices. An interface handle owns nothing, so
`free` refuses one, as it refuses a constraint-typed anything (there are
no values at all) and any other argument kind.

##### 5.4 Dangling borrows

A handle borrows under the ordinary pointer doctrine: unchecked, valid
while the referent lives. A handle that outlives its referent dangles.

```sx
collect :: (out: *List(View)) {
    b := Button{ label = "ok" };
    out.append(b);       // the handle borrows `b`, which dies at the return
}
```

A `$T/I` callee that stores `v` as `I` borrows the parameter slot, which
dies at callee return — not policed.

Struct fields, containers, and the Context snapshot a thread or fiber
inherits all carry handles this way; keeping the referent alive is the
program's job.

#### 6. Semantics

##### 6.1 RTTI: `type_of`, downcast, type switch

Every handle answers `type_of` with its referent's concrete type id,
read from slot 1. The downcast `p.(T)` and the type switch on a handle
subject follow the same source: a runtime type_id compare. There is no
implicit opening of a handle; the type switch is the opening construct.

##### 6.2 `@Interface`

```sx
@Interface :: struct { ctx: *void; type_id: Type; }
```

`p.(@Interface)` (and `xx p` at an `@Interface` target) builds the pair
**field-wise per the operand's layout — never a bit reinterpret**: a
prefix copy of the handle.

##### 6.3 The `any` bridge

Boxing a handle into `any` yields a view of the **referent**: `{data =
ctx, type_id = concrete}` — the handle's byte prefix. The reverse
direction is refused: a postfix assertion with an *interface* target on
an `any` receiver is a compile error (an `any`'s tag is always a
concrete type, so the assertion could only ever fail) — assert the
concrete type or use a type switch.

##### 6.4 Re-erasure — `p.(Q)` between interfaces

Re-erasure to a different interface is a direct conversion (a recovery
target of the postfix engine), never a manual downcast-then-erase — the
concrete type behind `p` is not statically known, so only the compiler
can perform it.

The conformance check and the result's vtable word are one runtime read
of a link-time `(type_id, Q) → vtable-or-null` table over the pairs with
a **program-unique** impl. The result handle reuses `p`'s ctx and
type_id and takes the table's vtable-or-null (same referent, new
dispatch word). A pair with visibility-disjoint duplicate impls (§3) is
absent from the table and reads null: the site-local visibility that
arbitrates an ordinary coercion does not exist at a dynamic conversion.
The table is built per `Q` when a re-erasure to `Q`, a runtime
conformance `is` against `Q`, or a `p.(?Q)` probe on an erased
receiver exists; construction waits on the impl facts of §6.9.

All three temperaments read the same null: unconsumed `p.(Q)` panics,
`try p.(Q)` raises, `p.(?Q)` answers null. `Q == I` is the identity
handle copy of §5.2.

##### 6.5 Equality

`==`/`!=` are not defined on interface handles (compile error, as on
`any`): two handles may reference one referent, equal bytes may be
distinct referents. Compare `type_of`, downcast and compare concretely,
or define an interface method. Map keys follow from `==`: refused.

##### 6.6 Interfaces in aggregates, generics, statics, and the Context

Interface types are ordinary storable types: struct fields, array
elements, returns, and **generic type arguments** — `List(Show)` and
`List(Hasher)` are both lists of 3-word handles, and `size_of` answers
per §5.1. An interface type may itself be an instantiation argument of
another (`Series(View)`). Constraints are refused in every storable
position (§4).

**Static positions.** Four positions build their handle before `main`
runs: a module-scope global's initializer, an `@context_extend` default,
an interface-typed struct-field default, and a field or element of a
statically-constructed value. In each of them the one operand that
coerces names a **module-scope global**:

```sx
c_allocator : CAllocator = .{};
@context_extend allocator: Allocator = c_allocator;    // bare global
fallback : Allocator = mem.c_allocator;                // module-qualified
```

The initializer is a bare or module-qualified path whose **root** is a
module namespace, with `xx` recursing into it. A path rooted at a global
*value* (`g.field`) is refused — the coercion needs the global's own
symbol. Every other operand refuses, `@run` included: the position is
judged on the written shape. `.{ }` is a struct literal, never a handle,
and is refused here as at every other I-typed target. `---` is uninit and
is refused at a static I field: the operand names a module-scope global.

`push .{ allocator = arena }` is not a static position: a `push` field
is an ordinary interface-typed target over a frame-scoped Context.

**Context.** Context defaults are mandatory and comptime-evaluable, and
an interface-typed default folds to the handle over the named global — a
borrow, never null (a null ctx is exclusively the `?I` absent
sentinel). Threads and fibers inherit the context by snapshot; a
snapshot copies handles, not referents (§5.4). `context.allocator` rides
the same snapshot, so the spawning container — not the language — is
responsible for pushing an allocator that outlives the spawned fiber or
thread when the ambient one does not.

##### 6.7 Packs and variadics

- `..xs: []I` (runtime variadic, erased element): each trailing argument
  coerces per §5.2 and packs into a runtime `[N]I`;
  `xs[i].method()` dispatches dynamically. The array is call-scoped; the
  handles do not invent referents — each element is already an lvalue, a
  `*T`, or a handle.
- `..xs: I` and `..xs: C` (comptime heterogeneous pack): each element
  keeps its concrete type and calls monomorphize. A pack head may be
  either declaration. An element already typed as the head interface
  copies (identity); it does not require `impl I for I`.

##### 6.8 UFCS

An interface-typed receiver dispatches its own members first and falls
through to `ufcs` functions only for **non-members**
(`context.allocator.create(Session)` — `create` takes the handle as its
first parameter). Constraint-bound receivers resolve at
monomorphization.

##### 6.9 Compile-time execution

Comptime handles are **symbolic**: the VM carries `{ctx, concrete type,
impl}` — the **impl selected at the coercion site**, since
visibility-disjoint duplicate impls (§3) make "the concrete type's impl"
ambiguous without it. Vtable addresses are link-time artifacts that do
not exist during compilation. Coercion at comptime is legal under the
rules of §5.2; dispatch resolves directly against the carried impl — the
VM devirtualizes, exactly as constraint resolution does — including
through Context fields such as the ambient allocator.

Comptime execution is **per-evaluation**: each evaluation (a driver, an
ordinary `@run`) owns its VM, heap, and **VM-local Context**; suspension
parks and resumes *that* evaluation — its VM state is never shared with
or visible to another evaluation, so scheduler order cannot leak through
Context or heap state. The Context's interface-typed fields reference
VM-owned instances, whose mutations (an allocator's bookkeeping, an
arena's cursor) are execution-local and discarded when the evaluation
completes — comptime code cannot mutate globals: the VM reads globals
into VM-local copies and never writes back. A VM object **corresponds**
to a declared global by provenance: it is the object the VM created to
represent that global when first referenced (the context-default fold
included); correspondence survives borrows, not copies — a struct copy
is a new object and escapes through the temporary path.

**Scheduling.** Comptime entangled with conformance — the conditions and
iterables of top-level `inline if`/`inline for`, any `@run` they
transitively reference, and body-level comptime reached by
monomorphizing an impl — evaluates under one dataflow discipline:

- **Impl presence only grows**, so a *positive* fact — a probe answering
  true, a `T is C` hit — is readable the moment it exists and can never
  be invalidated. A *negative* answer — a soft probe yielding null — is
  utterable only once the impls that could answer it are **final**: no
  unexpanded `inline if`/`inline for` branch can still contribute one.
  Contribution is judged syntactically and conservatively: an unexpanded
  body mentioning `impl P for …` contributes to `P`, and one holding an
  `@import` contributes the whole surface of the module it names — the
  impls, declaration names and `@context_extend`s that module authors,
  transitively through its own imports and branches — because selecting
  the branch is what brings them in.
- **Re-erasure facts depend on impl multiplicity** (the program-unique
  rule, §6.4), and uniqueness is not monotone — a later impl destroys
  it. A re-erasure therefore gates on finality of the target interface's
  pairs in **both** polarities.
- **The declaration namespace follows the same rule**: a name-lookup hit
  is monotone-safe (declarations are never removed); a miss in code
  under this discipline suspends until the scope is final — no
  unexpanded branch can still declare the name.
- **The program Context is a single layout**, so an evaluation that
  reads it waits for that layout to settle: while any unexpanded branch
  could still declare a `@context_extend`, the field set is not final,
  and the evaluation suspends against Context-ready exactly as it
  suspends against an open conformer set. Contribution is judged
  syntactically, like an `impl`'s. Once nothing can contribute, the
  decided declaration space registers, the deterministic layout
  assembles, and the default context is built from the selected
  branches' defaults — an untaken branch contributes no field.
- An evaluation needing a not-yet-utterable answer **suspends** — its VM
  state parks as a bookmark against the facts it awaits (presence of a
  pair or name, finality of a set or scope) — and the scheduler
  proceeds; the bookmark resumes when a fact fires. Every instruction
  runs exactly once: nothing is speculative, nothing re-runs, no
  evaluation ever observes a fact that later changes.
- **Quiescence is the error**: if the scheduler stops with parked
  evaluations remaining — whether the wait runs through one expansion or
  several — the program is refused, naming every parked evaluation and
  the facts it awaits. The self-feeding expansion is the simplest
  instance; a parked state admitting more than one consistent outcome is
  genuinely ambiguous, and sx refuses rather than electing a fixpoint.

  ```sx
  GPA :: struct { … }
  Serialize :: interface { write :: (self: *Self, out: *Buf); }
  HAS :: @run { g := GPA{… }; g.(?Serialize) != null };
  inline if !HAS { impl Serialize for GPA { … } }
  ```
  ```
  error: expansion deadlock — nothing can run: every compile-time
         unit still waiting needs a fact only another waiting unit
         could publish, so the expansion depends negatively on a set
         it feeds
  ```

- A suspended **hard** operation — a dispatch, an unconsumed conversion,
  a coercion — whose awaited fact never arrives diagnoses at finality
  with the ordinary error at the operation's site. A suspended **soft**
  probe answers null.

**The probe.** A soft interface target on a *concrete* receiver —
`gpa.(?Serialize)` — answers conformance directly, no value ceremony.
What it answers is **site-local impl visibility** — the same static fact
that decides whether the site could coerce, and a different question
from the dynamic re-erasure check, which consults program-wide
uniqueness (§6.4). Under the discipline, a negative gates on
declaration-space finality — impls are declarations. A probe is not a
value use: it arms the coherence diagnostics of the instantiation it
queries (§3) and reaches nothing for emission.

**The phase law.** All comptime execution not under the discipline runs
**after the declaration space is final**, so every such `@run` sees the
same world and **cannot enlarge it**: an operation requiring a
conformance no impl provides is a compile error at the operation's site
rather than a fact the run publishes. Post-fixpoint code may instantiate
types freely for every other purpose. Conformances remain unobservable
as *collections* at every phase (no enumeration reflection exists, §3);
the granted facility is per-pair facts — a probe, `T is C`, a conversion
— under the discipline above.

**Escape.** A comptime result carries a handle into the runtime image at
a `::` comptime constant, and at an interface-typed field inside an
escaping comptime aggregate. A `:` global's own initializer is the
static position of §6.6 and never runs this path. The escape resolves
per the referent:

- a referent that *is* a declared global — a named instance, the object
  behind a context default — relocates `ctx` to that global's symbol:
  nothing is copied, mutability is preserved, and the global's runtime
  bytes are its declared initializer (comptime-era mutations were
  execution-local and vanish; two evaluations whose instances diverged
  both relocate to the one global, and neither state wins). An interior
  pointer *into* such an instance's VM state refuses to escape ("points
  into a global's compile-time state, which is discarded");
- a comptime **temporary** referent materializes as an anonymous image
  global in writable data, deduplicated by comptime object identity
  *within the evaluation* (cross-evaluation temporaries are distinct
  objects and never deduplicate) — two handles that shared one object
  share one global, so borrow semantics survive the escape. Escaped
  temporaries are literal-class static data: they belong to no
  allocator, and freeing one through any allocator is the ordinary
  mispairing hazard. Materialization is **type-directed**: the
  referent's bytes are walked by its concrete layout; nested handles
  recurse (their referents materialize and all of their words resolve),
  interior pointers recurse, function references resolve to their
  symbols; an escape whose carried value cannot be walked is refused;
- the handle's third word resolves at link to the `(interface, type,
  impl)` vtable of the impl carried from its coercion site;
- an escape is a **value use** of its instantiation (§6.6).

#### 7. Reflection

- A directly reified `Type` may name an **interface or a constraint**:
  `tv : Type = Show;` and `cv : Type = Ord;` are both valid. A `Type`
  derived from a value (`type_of`) always tags the concrete referent.
- A reified constraint answers `type_name`. `C is interface` is false,
  `C is struct` is false, and it matches no category.
- Composites *containing* an interface type (`*Show`, `[]View`) are
  concrete types and get tags like any other composite.

#### 8. Internals walkthrough

**Symbols.** Vtables: one global constant per `(instantiation, concrete
type, impl)`, every identity spelled in full — `Conv(f32)`/`Conv(i64)`
never share a vtable symbol (their slot types differ), and neither do
two visibility-disjoint impls of one pair (their bodies differ; the
impl's declaring module is part of the symbol). Canonical identity is
structural on the argument tuple after alias resolution — no
display-name truncation participates in any symbol or cache key.

**Emission points.** Vtables emit on first use of a pair. Marker/empty
vtables are emitted like any other. The `(type_id, Q) → vtable-or-null`
re-erasure table of §6.4 emits per target interface when a re-erasure
to `Q`, a runtime conformance `is` against `Q`, or a `p.(?Q)` probe on
an erased receiver exists. The result handle reuses `p`'s ctx and
type_id and takes the table's vtable-or-null (same referent, new
dispatch word).

Coherence (§3) is diagnosed before codegen, so every conformance
diagnostic is an ordinary compile error, never a link error.

**Dispatch call sequence** (backend pseudocode, not sx syntax):

```
load p.vtable → load slot k → indirect call(ctx, args…)
```

**The standard `Allocator` is stdlib-owned.** Its declaration — the
head word and the method set — belongs to `std/core.sx`, not to the
compiler. The compiler-driven paths (the implicit-context allocation,
the Obj-C `+alloc`/`-dealloc` IMPs) find the allocator by NAME on the
assembled `Context` and go through ordinary dispatch, so the library
owns the declaration and no compiler change follows an edit to it.


#### 9. Edge-case catalog

| case | disposition |
|---|---|
| marker declaration (empty body) | constraint: free partition. interface: erases with empty vtable; RTTI works |
| `Self` past the receiver in an interface body | compile error at the declaration; the constraint form carries it |
| duplicate impl `(instantiation, conformer)` | import-scoped (§3). Both impls in one module: error at the impls |
| impl for a structural type (`impl Series($T) for []T`) | legal — conformer identity is canonical type identity |
| `impl C for I` (`C` a constraint, `I` an interface) | legal; the interface's own methods satisfy exact-signature members, so the body may be empty |
| `impl Q for I` (both interfaces) | refused — an interface handle is not a concrete conformer; `p.(Q)` is the conversion |
| impl bounded by a constraint (`impl Show for $T/Ord`) | not a supported form; the `for` target names a type constructor |
| interface-typed member (`m :: (self: *Self, v: View)`) | ordinary — the parameter coerces per §5.2 at the call |
| rvalue at `I` | compile error — an I-typed target never invents a temp (§5.2) |
| rvalue at `?I` | compile error — the wrap operand is an I-typed target |
| `.{ }` at an I-typed target (`I` or `?I`) | compile error — `.{ }` is a struct literal, not a handle |
| `null` at a non-optional value (`I`, `i64`, …) | compile error — `null` is the absence of `?T`; `*T = null` stays |
| `.{ }` at a static interface position | compile error (§6.6) — same struct-literal refusal |
| `---` at a static I field | compile error — a static operand names a module-scope global |
| `---` at a runtime I slot | uninit (LLVM undef, no handle) |
| static interface position whose initializer is `g.field` | compile error — the path root must be a module namespace |
| `free` on: an interface handle / constraint-typed anything | compile error in each case (a handle owns nothing; a constraint has no values at all) |
| `p.(@Interface)` | field-wise build per layout |
| `p.(Q)`, different interface | runtime read of the `(type_id, Q)` table (§6.4); all three temperaments read the same null |
| `s.(I)`, operand already `I` | the handle, copied |
| `any` holding an interface handle | never arises from boxing a handle (that boxes the referent) |
| `av.(I)` — interface target on an `any` receiver | compile error; a constraint target refuses as a constraint |
| `==` on handles / handles as map keys | compile error |
| `?I` | null ctx = absent; the vtable word is meaningless while null |
| generic type argument `List(I)` | legal, element = the 3-word handle. `List(C)`: refused at the instantiation site |
| interface as an instantiation argument (`Series(View)`) | legal — a type argument like any other |
| value parameters in a head (`interface(N: u32)`) | as generic structs; canonicalized by folded value equality |
| handles inside `@run` / comptime execution | legal, symbolic — `{ctx, concrete type, impl}`, VM-devirtualized dispatch; under the §6.9 discipline, negative probes, re-erasures (both polarities), and name-lookup misses suspend until finality |
| scheduler quiesces with parked evaluations (self-feeding or mutual) | compile error — expansion deadlock, every parked evaluation and its awaited facts named (§6.9) |
| comptime handle escaping into the image | declared-global referents relocate in place (mutable); comptime temporaries become writable anonymous image globals, deduped by object identity, nested handles recursing (§6.9) |
| type declared inside a top-level `inline for` body | flattens to module scope — duplicate across iterations diagnoses; parameterize the type (`Vec :: struct($N: u32)`) instead of re-declaring per iteration |
| `inline for` conformance-list elements | concrete types only — a curated-list element resolves through the concrete-impl path; `@run`-computed lists are legal but expansion-driving (§6.9 scheduling); duplicate elements and nested unrolls diagnose with cursor provenance ("T = Point, i = 1") |
| conformer method name colliding with an existing member of the type | exact signature: the existing method satisfies conformance (impl may omit; providing it duplicates). anything else (field, different signature): compile error at the impl |
| default method on an interface conformer | legal — defaults compile per conformer against concrete `Self` (§2) |
| comptime observation of conformances | no conformer list exists at any phase; the askable facts are per-pair: `T is B` / `x is B`, the probe `x.(?I)`, a conversion — comptime under §6.9, runtime reading the impl tables |
| the probe (`x.(?I)` on a concrete receiver) | site-local impl visibility; arms the instantiation's coherence diagnostics but reaches nothing for emission (§6.9) |

Design notes and rejected directions: `design/protocols.md` (appendix).


### Anonymous products

A positional anonymous product is the type of `.{1, 2}`: an anonymous
structural struct whose fields are named `"0"`, `"1"`, …. Field access is
`t.0` / `t.1`. `type_info` on it is `.struct`. There is no writable type
spelling for a positional product other than `struct { ..P(Ts) }` (a pack
spread as the struct's one field — see "Variadic Heterogeneous Type Packs").
Named products are ordinary structs: `struct { x: A; y: B }`, accessed by
name only (`.x`, not `.0`).

`.{ … }` is the one aggregate literal. Untyped `.{1, 2}` infers the positional
product. Named `.{x = 10, y = 20}` against `struct { x: i64; y: i64 }` is a
named-struct value. Bare parentheses `(...)` are grouping only — a comma
inside bare parens is a hard error.

```sx
pair := .{40, 2};
pair.0;              // 40
pair.1;              // 2

named : struct { x: i64; y: i64 } = .{x = 10, y = 20};
named.x;             // 10

zeroed : struct { a: i32; b: i32 } = ---;
```

Equality on a positional product is field-wise `==` / `!=` (same as a struct).
There is no product concatenation, repetition, lexicographic compare, or
membership operator.

Bare parentheses are grouping:
```sx
(i64)            // grouping: resolves to i64
(i64) -> i64     // function type: takes i64, returns i64
(i64, i64) -> i64  // function type: takes two i64, returns i64
?(?i64)          // grouping → a genuine nested optional
[1](Closure(i64,i64) -> i64)  // grouping → array of one closure
```

#### Multiple Return Values (bare-paren return signature)

A function may return **multiple values** with a bare-paren return signature
(≥2 value slots) — positional `-> (A, B)` or named `-> (x: A, y: B)`, with an
optional trailing `!` error channel as the **last** slot (`-> (A, B, !)`). The
empty `-> ()` is `void`. A multi-return is interned as an anonymous structural
struct (fields `"0"` / `"1"`, or the named slots). It is valid ONLY as a
function/closure return type — a parameter, field, or variable annotation
`x: (A, B)` is rejected. A single-value `-> (T, !)` (one value + error) is NOT
a multi-return; it is the failable `-> (T, !)`, a dedicated kind, not a product
whose last field is an error set.

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

A multi-return is represented as an anonymous LLVM struct (same layout as a
named struct). `-> (i64, i64)` has LLVM type `{ i64, i64 }`. A value-carrying
failable `-> (T, !)` is a dedicated `{ value-slots…, u32 tag }` layout.

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
**aggregate** type — `@Vector(3, f32).[…]`, `([2]?i64).[…]`, or an alias
of an array type — never the element type: a prefix that resolves to a
non-array/vector/slice type (`i16.[…]`, `Point.[…]`) is a compile error
pointing at the annotated form.

`@Array(N, T)` is the named form of the same type, written wherever `[N]T` is:
```sx
MyArr :: @Array(5, i32);       // equivalent to [5]i32
grid : @Array(2, [3]f32);      // equivalent to [2][3]f32
```

A **count** is a compile-time integer used as an array dimension, a `@Vector`
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
- **`@Vector` lane count** — any compile-time integer ≥ 1 (strictly positive). A
  zero-lane or negative vector (`@Vector(0, f32)`) is rejected ("@Vector lane
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

`@Slice(T, Len)` names the same shape with the length word spelled out: `Len`
is an integer type and the fat pointer is `{ptr, Len}`. `@Slice(T, i64)` and
`[]T` are one type; any other `Len` is a distinct type with its own ABI, and
`.len` reads as that `Len`.
```sx
Bytes :: @Slice(u8, u32);      // {ptr, u32}; `.len` is a u32
Plain :: @Slice(i32, i64);     // the same type as []i32
```
Indexing, `.len`, `.ptr`, subslicing and array→slice coercion read the same on
every `Len`; a subslice keeps its base's length word. A length that does not
fit the destination's `Len` is refused at every header formation. Widening
the length word (`@Slice(T, u32)` → `[]T`) is implicit; implicit narrowing of
a non-constant length is not.

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
diagnosed (there is no `[]const T` slice type). The direct `constArr[i] = …`
write IS rejected.

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
v := Vec2{1.0, 2.0 };
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

**Pointer arithmetic**: `p + n` and `p - n` offset a pointer by whole
elements — the stride is the pointee's size, not one byte — and keep the
pointer type. The offset may lead (`n + p`), and `+=` / `-=` fold the same
way. Offsets require a sized pointee. `p - q`, over two pointers to the SAME
nonzero-sized element type, yields the signed count of elements between them
(`isize`). Every other pairing is a compile-time error: two addresses have no
sum, an unsized or zero-sized element has no element count, a difference
across distinct element types has no element count, only a pointer may stand
left of a pointer subtraction, and the offset must be an integer.
`* / % & | ^ << >>` have no pointer form at all.
```sx
values : [4]i32 = .[10, 20, 30, 40];
p : [*]i32 = *values[0];
q := p + 2;               // &values[2]
q -= 1;                   // &values[1]
d := q - p;               // 1 — elements, not bytes
```

**Implicit conversions**:
- `*T` → `[*]T` (pointer to element → many-pointer)
- `*[N]T` → `[*]T` (pointer to array → many-pointer)
- `[N]T` → `[*]T` at call sites (array decays to many-pointer)
- `[]T` → `[*]T` (slice decays to many-pointer, extracts `.ptr`)
- `T` → `*T` at call sites (implicit address-of)
- `null` (`*void`) → any `*T`
- `*T` / `[*]T` / `cstring` → `*void` (losing the pointee). `[]T.ptr` is a
  many-pointer, so it takes this arm. Gaining a pointee (`*void` → `*T`) is
  explicit: `raw.(*T)` or `xx raw` at a `*T` slot.

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
  (`string{ptr, len}` windows, writer output). Materialize an owned,
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
Such a use is a compile error — extract the payload explicitly with `?!` / `??` /
a binding (`if v := opt`) / a `case` match, or rely on flow-sensitive narrowing
after a `!= null` guard (below). Unwrapping a null optional implicitly would
yield its zero payload with no diagnostic, so the conversion is rejected rather
than allowed.

#### Value Equality

`==` / `!=` are defined on optionals whenever the payload type has
value-equality. Equality extracts nothing — null is a legitimate
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

#### Force Unwrap (`?!`)
Extracts the payload, traps at runtime if null:
```sx
x: ?i32 = 42;
val := x?!;            // val : i32 = 42
```

#### Default (`??`)
Returns the payload if present, otherwise evaluates the right-hand side:
```sx
x: ?i32 = 42;
y: ?i32 = null;
a := x ?? 0;           // 42
b := y ?? 99;          // 99
```
The same operator defaults a failable LHS — see
[§12 Error Handling](#12-error-handling).

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
result := match opt {
    case .some: |val| { val * 2; }
    case .none: { 0; }
};
```

#### Optional Chaining (`?.`)
Short-circuits field access on optionals:
```sx
x: ?Point = Point{x = 1, y = 2 };
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
n := Node{value = 10 };    // n.next is null
```

#### Printing
`print("{}", opt)` prints the payload value if present, or `"null"`.

#### Comptime
Optionals work in `@run` blocks — `??`, `!`, `if val :=`, null checks all supported.

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
libc :: @library "c";
sdl  :: @library "SDL3";

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
NSObject  :: @ObjcClass("NSObject") extern { alloc :: () -> *NSObject; }  // reference
SxFoo     :: @ObjcClass("SxFoo")    export { counter: i32; bump :: (self: *Self) { … } }  // define
```

- `@library "name"` must be assigned to a named constant. The library is passed
  to the linker (`-lname` on Unix, `name.lib` on Windows).
- `extern lib_ref` declares a function (or `<name> : <type> extern;` a data
  global) as an external C symbol. The library reference is optional: when present
  it is passed to the linker (`-lname` on Unix); when omitted, the symbol must
  resolve at link time from a framework or an already-linked / auto-detected
  library. The `@library` declaration + build-flag linking mechanism is a separate
  axis — `extern` *references* a library, it does not declare one.
- `extern lib_ref "c_symbol"` (and `export "c_symbol"`) renames the binding: the
  sx name differs from the C symbol. This avoids name collisions (e.g. POSIX
  `write` vs an sx builtin) and gives an export a stable C-visible name.

### C Interop Type Mapping

| C type | sx type | Notes |
|--------|---------|-------|
| `const char*` (input) | `cstring` | the pointer, verbatim; literals coerce |
| `const char*` (input, sentinel slice) | `[:0]u8` | compiler extracts `.ptr` at call site |
| `const char*` (return) | `cstring` | the pointer, verbatim; `from_cstring` to view |
| nullable `const char*` (both directions) | `?cstring` | null pointer = `null` |
| `char*` (output buffer) | `[*]u8` | raw buffer, no length |
| `const char**` | `*[:0]u8` | address of `[:0]u8` — `.ptr` at offset 0 |
| `int*` (single out) | `*i32` | |
| `unsigned*` (single out) | `*u32` | |
| `float*` (buffer) | `[*]f32` | |
| `void*` (generic) | `*void` | only for truly opaque/generic data |
| `va_list` | `@VaList` | the C-variadic boundary, place-only |

### Vector Types (SIMD)
LLVM SIMD vectors, written `@Vector(N, T)` — `N` lanes of element type `T`. The
compiler forms the type, so the name carries its `@` (§Lexical Structure, The
`@` namespace) and a bare `Vector` is an ordinary identifier.
```sx
a : @Vector(3, f32) = .[1.0, 3.0, 2.0];
v := vec3(1, 3, 2);  // @Vector(3, f32)
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

**Element access**: `.x`, `.y`, `.z`, `.w` (aliases `.r`, `.g`, `.b`, `.a`) extract single components. A string of those letters is a shuffle: one letter is a scalar; two or more letters on a `@Vector` yield `@Vector(N, T)` in letter order. Position letters (`xyzw`) and colour letters (`rgba`) are two sets — a name uses one set (`v.xy`, `v.rgba`; not `v.xr`). Letters may repeat on a read (`v.xx`). A letter past the receiver's length is a compile error.
```sx
v.x     // first element
v.z     // third element
v.xy    // @Vector(2, T) { v.x, v.y }
v.yx    // @Vector(2, T) { v.y, v.x }
```

The same shuffle names work on `[N]T` and `[]T`. One letter is the element; two or more yield `[N]T` in letter order. Letters name the first four elements (`x`/`r` is `[0]`, `w`/`a` is `[3]`). A slice shuffle does not check length at compile time.

**Element assignment**: the same names are assignable l-values. A one-letter write stores a scalar. A multi-letter write stores a `@Vector(N, T)` or `[N]T` of matching shape; each letter on the left must be unique (`v.xy = u` is fine, `v.xx = u` is not). Compound assignment applies per element. Address-of is only a one-letter shuffle (`*v.x`); `*v.xy` is an error.
```sx
v.x = 1.0;    // write the first lane
v.y += 2.0;   // compound assignment to a lane
v.xy = .[3.0, 4.0];
```

**Index access**: `v[i]` extracts by index.
```sx
v[0]    // first element
```

**Built-in `@sqrt`**: Calls LLVM `llvm.sqrt.f32`/`.f64` intrinsic.
```sx
s := @sqrt(9.0);     // 3.0
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
b := BoxAlias(i64){ item = 3 };
b2 : BoxAlias(string) = .{ item = "x" };  // annotation head too
```

The RHS may be a namespace member (`Box :: r.Box;`) — the alias is an
ordinary OWN declaration of the aliasing file, so it is visible to that
file's direct flat importers like any other declaration (this is how a
facade re-exports another module's generic struct). Each hop of an alias
chain resolves with the visibility of the file that declares THAT hop,
not the use site's. A qualified head whose namespace member is itself an
alias (`ns.BoxAlias(..)`) is unsupported.

### Function Aliases

Functions alias the same way — bare or namespace-member RHS, renamed or
same-name — and the alias dispatches exactly like the target. This covers
every fn kind: plain, runtime-generic (`[]$T` / `$T: Type`), and
comptime-pack (`..$args`, e.g. `print` / `format`):

```sx
s :: @import "modules/std.sx";
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
  sum(1.5, 2.5)    // T = f64
  ```
- Each unique set of concrete types produces a **separate specialized function** (monomorphization)
- Multiple type parameters are supported: `(a: $T, b: $U) -> T`

#### Generic bounds

A binder carries zero or more **bounds**, each introduced by `/`:

```
Bound        := '/' BoundHead [ '(' TypeExpr { ',' TypeExpr } ')' ]
BoundHead    := identifier | at_identifier | QualifiedHead
QualifiedHead:= identifier { '.' identifier }
```

```sx
largest   :: (xs: []$T/Ord) -> T { … }                  // one bound
are_equal :: (a: $T/Eq/Hashable, b: T) -> bool { … }    // several
lift      :: ($T: Type/Ord, x: T) -> T { … }            // explicit form
```

A head names what is required of the binder: a declared **constraint**, a
declared **interface**, an **open set** — where the requirement is MEMBERSHIP
rather than conformance (see Open Sets) — an enclosing type parameter, or a
compiler-owned `@` contract (`@Init`, `@BuildBlock`). A parameterized head takes
its type arguments in the bound — `$B/@BuildBlock(View)`, `$I/@Init(Button)`. An
argument is an ordinary type expression, so it may introduce a binder of its
own, with its own bounds: `$I/@Init($V/Drawable)`.

`is` is not bound-head grammar: a bound is written with `/`.

A head may be **qualified** by the module that owns it — `$V/compose.View`,
`$T/geometry.Ord` — naming a declaration a module reached by name makes. What
the bound asks is the DECLARATION's question, so a member joins the set it was
declared into however the head that names it is spelled.

Bounds belong to the binder, not to the type built around it, so a type
constructor may wrap a bound binder: `*$S/@BuildSink(P)` is a pointer to some
`S` conforming to `@BuildSink(P)`.

A `/` with no head, and an empty argument list (`$T/Eq()`), are errors.

**A bound constrains.** Each bound is checked per monomorphized instance,
against the concrete type that instance binds — the template itself constrains
nothing, so one call may satisfy a bound and another fail it. A head that names
nothing in scope is an unknown-name error, whichever way it is spelled.

Where the check lands depends on what the head names:

| Head | Satisfied when |
|---|---|
| a declared constraint or interface | the binding implements every method |
| a parameterized one (`Into(i32)`) | a visible `impl Into(i32) for <binding>` exists, or a **blanket** impl covers it |
| the declaration's own type parameter (`$V/P`) | deferred — asked again wherever `P` is bound: as **conformance** when `P` is a constraint or an interface, as **identity** when `P` is a concrete type |
| `@Init(T)` | the binder holds an initializer the compiler formed for `T` — see [`@Init(T)`](#initt) |
| `@BuildBlock(P)` | the binder holds a build block the compiler formed for `P` — see [`@BuildBlock(P)`](#buildblockp) |

**An interface head asks conformance, and the interface satisfies it.** `$V/View`
binds `View` itself by TypeId identity — the short-circuit that also makes
`View is View` true — so a parameter may be written `v: $T/View` or `v: View`
and both are legal. A bound carrying more than one head (`$T/View/Other`) has no
identity case: only a concrete conformer satisfies it.

**Inference never erases.** A concrete argument binds `T` to that concrete type;
a handle argument of type `I` binds `T = I`. Once `T` is bound, the parameter's
slot is `T` and the coercion rules of §5.2 apply to it.

A cross-interface failure diagnoses **at the bound**:

```sx
draw :: (v: $T/View) { … }
h : Show = widget;
draw(h);
```
```
error: 'Show' does not conform to the bound 'View' — a handle conforms
       through 'impl View for Show', and none is visible here
```

A sibling head bound to a **concrete** type collapses the bound's family to that
one member: `$V/P` with `P = i64` admits `i64` and nothing else. A bound's
type-argument list is validated against the arity of whatever the sibling landed
on, before the binding is considered.

**Blanket impls.** An impl may write the head's type arguments as its own
binders — `impl Series($T) for Buffer($T)` covers every instantiation of
`Buffer` at the matching argument. Such an impl has no concrete argument tuple
to be keyed by, so it is matched at the use site against the request's arguments
and the carrier's own instantiation. The binder is matched by POSITION, not by
name: `impl Series($U) for Buffer($U)` works without knowing what the template
calls its parameter. A carrier may mix binders with CONCRETE arguments, and each
constrains coverage equally — `impl Series($W) for Map2(i64, $W)` covers
`Map2(i64, W)` for any `W` and nothing whose first argument differs.

**One carrier, one impl.** A carrier covered by both a blanket impl and a
concrete impl of the same head at the same arguments is an error at the
overlap — nothing in either declaration says which body applies. Drop one.

An impl that could never be selected is refused where it is written. A binder in
the head's arguments needs a carrier instantiation to bind it from
(`impl P($T) for Plain` has none), and every such binder must appear among the
carrier's arguments to have a position to resolve through. A generic carrier
whose binder the head's arguments never mention (`impl P(i64) for Carrier($T)`)
is refused for a **constraint**, and is ordinary for an **interface** family,
which erases one conformance per instantiated carrier.

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
- For `[]I` (the element type is an interface, e.g. `..xs: []Show`), each
  trailing arg coerces to a handle per the view-coercion arms (see Constraints
  and Interfaces §5.2; a concrete rvalue is refused — the `[N]I` array does
  not invent referents — and a constraint element type is refused as a
  storable position) and is packed into a runtime `[N]I`.
  `xs[runtime_i].method()` then dispatches through the handle — this is the
  **runtime** counterpart to the comptime heterogeneous pack `..xs: I`. A
  `..` spread of an existing slice into `[]I` coerces per element the same
  way.
- A `..` spread at the call site unpacks an existing slice/array into the variadic
  tail: `sum(..arr)`.
- The heterogeneous comptime-pack form `..$args: []Type` binds per-position
  comptime types — see "Variadic Heterogeneous Type Packs" below.

### The C-Variadic Tail

A parameter list may end in a bare `..`, the C `...`:

```sx
printf :: (fmt: cstring, ..) -> i32 extern;
tally  :: (n: i32, ..) -> i64 abi(.c) { ... }
```

The tail binds no name and no type, so it is a property of the signature rather
than a parameter, and the **fixed count** is the number of entries before it —
zero when the list is just `(..)`. It is legal on an **effective-C signature**
only: a definition carrying `abi(.c)` or `export`, an `extern` declaration, or an
`abi(.c)` function type. Each states the C shape with no implicit sx context, so
the LLVM type is exactly what a C compiler builds for the same prototype.
`abi(.naked)` and a `Closure` literal carry no such shape and refuse the tail.

A C prototype imported by `@import c { @include … }` keeps its tail: a
declaration ending in `...` synthesizes an `extern` ending in `..`, over the
fixed parameters C wrote — none of them where C23 states no named parameter
before the tail.

Every argument at or past the fixed count crosses under the **C default argument
promotions**: `f32` widens to `f64`, and an integer narrower than 32 bits widens
to `i32` — every width, not just the builtin ones. `isize` and `usize` are the
target's address width and take the promotions at it. Past the promotions, a
tail argument must be something a C ABI can pass through `va_arg`: a 32- or
64-bit integer, `f64`, the pointer family or its nullable forms, or a function
value carrying the C convention. Anything else — an aggregate, a `string` or
slice (two words), a width C has no variadic slot for — is refused at the call,
naming the argument.

An `extern` declaration may instead end in `..name: []T`, the **homogeneous
constraint** over the tail: the author asserts every tail argument is a `T`.
Each argument at or past the fixed count takes the ordinary implicit conversion
to `T` — the one any typed parameter of `T` performs, so a string literal reaches
a `[]cstring` tail as its data pointer — and then the promotions above. The
emitted operand carries `T`'s width rather than the argument's written one, and
each crosses its own C variadic slot; nothing is packed into an sx slice.

The tail is part of a symbol's signature. Two declarations of one C symbol share
a registration only when their signatures match, the tail included: a fixed
prototype and a variadic one over the same fixed parameters state different ABIs
and are refused where the second is written.

#### A C-variadic function type

A function TYPE takes the same tail, and `abi(.c)` is the only spelling that
gives it its C signature — a type carries no linkage slot:

```sx
Callback :: (fixed: i32, ..) -> i64 abi(.c);
Zero     :: (..) -> i64 abi(.c);
```

A signature with a body is a definition and a bodyless one is a function-type
alias. `abi(...)` states a convention rather than a body, so it appears on
both.

The tail joins the type's identity. `(fixed: i32) -> i64 abi(.c)` and
`(fixed: i32, ..) -> i64 abi(.c)` are different types, and so are
`() -> i64 abi(.c)` and `(..) -> i64 abi(.c)`; a function binds only to the one
that states its own tail. A call through such a value states the fixed arguments
and then as many tail arguments as it likes, each crossing under the promotions
and the admissibility rule above. Every other function type is exact-arity.

#### Reading a tail: the `@VaList` cursor

A definition reads its own tail through a cursor. `@VaList` and the four
operations that walk it are compiler-maintained contracts declared by
`modules/std/core.sx` (§Lexical Structure, The `@` namespace):

```sx
@VaList :: struct { }

@va_start :: (list: *@VaList);
@va_arg   :: ($T: Type, list: *@VaList) -> T;
@va_copy  :: (dst: *@VaList, src: *@VaList);
@va_end   :: (list: *@VaList);
```

```sx
sum :: (n: i32, ..) -> i64 abi(.c) {
    ap: @VaList = ---;
    @va_start(*ap);
    defer @va_end(*ap);
    total: i64 = 0;
    for i in 0..n { total += xx @va_arg(i32, *ap); }
    return total;
}
```

`@va_start` opens a cursor over the arguments past the fixed count; it is legal
only inside a definition whose parameter list ends in `..`. `@va_arg` reads the
next argument and advances, `@va_copy` forks a second cursor at the first's
position, and `@va_end` closes one. Every cursor a `@va_start` or a `@va_copy`
opens is closed exactly once.

`@va_arg` asks for the type the promotions LEAVE in the slot, so `f32` and any
integer narrower than 32 bits are refused where they are written:
`@va_arg(f64, …)` is how an `f32` argument reads back, and `@va_arg(i32, …)` how
a `u8` does. The tail admissibility rule above applies unchanged.

`@VaList` is **opaque**. Its storage is the target's `va_list` and it has no
value form, so it cannot be constructed, inspected, measured (`size_of` /
`align_of` / the reflection builtins), or copied by assignment. A local
declaration and an incoming C parameter are the only things that give a cursor
storage, and `*name` is the only way to reach one.

The cursor is **owned by the function that declares it**: `@va_start`,
`@va_end`, and `@va_copy`'s destination each take the address of a local. A
`*@VaList` handed to another function is a **borrow** — it reads with `@va_arg`
and leaves the closing to the owner. A cursor cannot escape the frame whose tail
it reads: neither `@VaList` nor `*@VaList` may be returned, stored in a field or
a global, captured by a closure, or passed through a C-variadic tail.

Both rules follow the cursor into whatever carries it. A type whose own bytes
hold a list — `[1]@VaList`, `?@VaList`, a struct or tuple with such a field — is
the list's storage and is refused everywhere the bare spelling is; one that
addresses another frame's — `[]*@VaList`, a struct of borrows — is refused
everywhere the borrow is. A function type is a code address, so a parameter of
its own signature is the callee's storage and carries nothing.

#### Crossing the C boundary: a `va_list` parameter

C's own tail readers take the list as a parameter — `vprintf`, `vsnprintf`,
`sqlite3_vmprintf`. That parameter is written **by value** as `ap: @VaList`, and
only in an effective-C signature. The rule is independent of a bare `..` tail —
a signature that takes a list needs none of its own:

```sx
vmprintf :: (fmt: cstring, ap: @VaList) -> ?cstring extern;

sx_vsum :: (n: i32, ap: @VaList) -> i64 export {
    total: i64 = 0;
    for i in 0..n { total += xx @va_arg(i32, *ap); }
    return total;
}
```

An imported `va_list` parameter arrives as this one. The typedef names it, not
what it canonicalizes to — that is a pointer on one target and an array of
records on another, and neither shape is the boundary on its own.

Forwarding a list **inside sx** is `ap: *@VaList`, the same borrow a helper
reads through. Neither spelling stands in for the other: an ordinary non-C
`@VaList` parameter and a C-boundary `*@VaList` parameter are both refused.

The boundary parameter is **place-only**. A call names a live list — `f(fmt, ap)`
from an `ap: @VaList` local or parameter, `f(fmt, ap.*)` from an internal
`ap: *@VaList` — and the place crosses under the target's C ABI with no sx
value copy:

```sx
relay :: (fmt: cstring, ..) -> i32 abi(.c) {
    ap: @VaList = ---;
    @va_start(*ap);
    defer @va_end(*ap);
    return c_vformat(fmt, ap);
}

forward :: (fmt: cstring, ap: *@VaList) -> i32 {
    return c_vformat(fmt, ap.*);
}
```

An incoming list is **borrowed and already open**. The callee never calls
`@va_start` or `@va_end` on it — both belong to the frame that owns the list —
but reads it with `@va_arg` and forks it with `@va_copy`. A traversal may move
the caller-visible position, as C specifies, so a caller that needs a second
traversal copies first.

### Variadic Heterogeneous Type Packs

A **pack** is a comptime sequence of per-position-typed arguments. Unlike a
slice variadic (`..xs: []T`, one uniform element type, a runtime slice), a pack
binds a *distinct* type to each position and exists only at compile time.

The full family of variadic/pack forms and how they differ:

| Form | Element types | Lives at | `xs[i]` index | `xs[i]` yields | `xs.len` |
|---|---|---|---|---|---|
| `..xs: []T` | one uniform `T` | **runtime** (slice) | runtime or comptime | `T` | runtime |
| `..xs: []any` | mixed, **boxed** to `any` | **runtime** (slice) | runtime or comptime | `any` (match/unwrap to use) | runtime |
| `..xs: []I` *(I an interface)* | mixed, **erased** to the `I` handle | **runtime** (slice) | runtime or comptime | `I` (call interface methods) | runtime |
| `..xs: P` *(pack)* | per-position **concrete**, each conforms to `P` — a constraint or an interface | **comptime** (no runtime value) | comptime only (literal / `inline for` cursor) | the concrete element, **viewed through `P`** | comptime int |
| `..$args` / `..$xs: []Type` | per-position comptime **types** | **comptime** | comptime only | element value/type (reflection) | comptime int |
| `..` *(the C tail)* | none — the C ABI's variadic slots | **runtime** (the callee's frame) | no index | `@va_arg(T, *ap)` reads the next | no length |

Key axis — **concrete vs erased, comptime vs runtime**:
- `..xs: P` (pack) keeps each element's *concrete* type but is **comptime-only**:
  `xs[i]` needs a compile-time index (a literal or an `inline for` cursor); a
  runtime index is an error (a pack has no runtime representation). Use it when
  you need per-position types (monomorphization, `xs.T` / `xs.value` projection).
- `..xs: []I` (slice of interface) **erases** each element to a handle but is
  **runtime**: `xs[runtime_i].method()` works in an ordinary loop. Use it when
  you need to iterate the args at runtime and only the interface matters. It is
  the runtime counterpart to the pack.

The heterogeneous pack (`..xs: P`) is what powers `map :: (mapper: ...,
..sources: ValueListenable) -> ...`: it accepts any number of trailing args,
each some `ValueListenable(T)` for a possibly-different `T`.

A pack is **not a runtime value** — it lowers to N typed positional parameters
(zero overhead). The body refers to elements only through the comptime forms
below; using the pack name where a runtime value is required is an error (see
"Pack as value").

**Element access is through the pack head, not the concrete type.** Although the
pack monomorphizes per call shape and each element has a known concrete type,
`xs[i]` is viewed **through the head**: only the head's own methods and the
projections `xs.T` / `xs.value` are accessible. Reaching a concrete member the
head does not declare — e.g. `xs[i].v` where `v` is a field of the concrete
`IntBox` but not declared on `Show` — is an error, exactly as it would be for a
bound generic `$T/Show`. The head is enforced (each trailing arg must conform;
an element already typed as the head interface copies (identity); it does not
require `impl I for I`) and bounds what the body may do, regardless of the
concrete arg types at any particular call site.

#### Pack operations

| Use | Spelling | Meaning |
|---|---|---|
| Length | `xs.len` | comptime int (field-style, not `len(xs)`) |
| Index | `xs[i]` | i-th element; `i` must be comptime |
| Comptime unroll (index) | `inline for i in 0..xs.len { ... }` | unrolled loop; cursor `i` is a comptime constant per iteration; not `#for` |
| Comptime unroll (element) | `inline for x in xs { ... }` | unrolled loop; `x` is the concrete i-th element, viewed through the pack head (≡ `xs[i]`) |
| Comptime unroll (element + index) | `inline for x, i in xs, 0.. { ... }` | multi-iterable parity with the runtime `for`: position 0 drives the count, a trailing open range pairs the cursor |
| Projection | `xs.field` | see "Pack projection" |
| Spread → call args | `..xs` / `..xs.field` | expands to N positional args |
| Spread → aggregate value | `.{..xs}` / `.{..xs.field}` | materializes the pack as an anonymous positional struct |
| Spread → struct type | `struct { ..F(Ts) }` / `struct { ..F(Ts.Arg) }` | anonymous struct whose one field is the pack-spread product |
| Spread → callable sig | `Closure(..Ts) -> R` / `Closure(..Ts.Arg) -> R` | positional params of the callable |

#### Pack projection

`xs.field` projects the same member out of every element, preserving order.
Resolution is **position-driven** (no cross-namespace shadowing):

- In **type** position, `..xs.field` looks `field` up in the pack head's
  **type-arg** namespace. `ValueListenable :: constraint($T: Type) { ... }`
  declares type-arg `T`, so `..xs.T` is the pack of element value-types.
- In **value** position, `xs.field` looks `field` up among the head's
  **methods** and yields a positional product of the projected values
  (e.g. `xs.value` → `.{xs[0].value(), xs[1].value(), ...}`).

A head that declares a type-arg and a method with the **same name** compiles,
but emits a soft warning at the declaration (the human is alerted; resolution
still proceeds by position).

#### Product parallels

The same spread/projection syntax applies to a **positional product** whose
source is a materialized pack rather than the pack itself:

- `..stored` / `..stored.field` spreads the product's fields into call args.
- `stored.field` projects `field` out of every element (when all elements have
  a same-named field), returning a positional product of the projected values.

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
  variadic `..xs: []I` (a runtime slice) instead of a pack `..xs: P`;
- returning it (`return xs;`) → return a materialized `.{..xs}` (and make the
  return a multi-return of those slots, or a `struct { ..P(Ts) }` field);
- iterating it (`for x in xs`, `xs[runtime_i]`) → `inline for x in xs` (or
  `inline for i in 0..xs.len` for the index) for a comptime unroll, or take
  `..xs: []I` for a runtime loop.

The recurring runtime escape hatch is the **slice-of-interface variadic**
`..xs: []I` (see "Variadic Functions"): it is the runtime, erased counterpart to
the comptime pack. A pack indexed/iterated/forwarded at runtime is almost always
better expressed by declaring `xs` as `..xs: []I` in the first place.

#### Storage and conformance

To **store** a pack, put it in one ordinary field whose type is an anonymous
struct of the spread: `sources: struct { ..ValueListenable(Ts) }`, assigned
`self.sources = .{..sources}`. A struct reaches an interface-typed slot through
an explicit impl (conformance is impl-driven, not structural) — e.g.
`impl ValueListenable($R) for Combined($R, ..$Ts) { ... }`.

#### Canonical example

```sx
Combined :: struct($R: Type, ..$Ts: []Type) {
  sources:       struct { ..ValueListenable(Ts) };   // one field; pack-spread product
  mapper:        Closure(..Ts) -> $R;       // pack-spread in callable sig
  value:         $R;
  own_allocator: Allocator;

  recompute :: (self: *Combined) {
    new_val := self.mapper(..self.sources.value);  // product projection + spread
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
  inline for i in 0..sources.len {          // comptime unroll over the pack
    sources[i].addListener(|_| c.recompute());
  }
  c.value = mapper(..sources.value);        // pack spread + projection in a call
  return xx c;                              // needs impl ValueListenable for Combined
}

isReady : ValueListenable(bool) = map(
  |va, vb, vc| va and vb > 10 and vc == "cool",
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
- `*T` / `[*]T` / `cstring` → `*void`

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
d : u8 = @run xx resolve(5); // i32 → u8 at compile time
```

Using `xx` outside a typed context (where the target type is known) is a compile error.

Comparisons (`== != < <= > >=`) meet at a **comparison type**. They are not
stores: neither operand has to already be that type, and the converted values
are not written onward.

| Pair | Comparison type |
|---|---|
| Both numeric, same signedness or int↔float | the arithmetic common type (widen; int+float → float) |
| Signed vs unsigned, same width | error — write `a.(u64) < b` |
| Two pointers, any pointees (`*T`, `*void`, `[*]T`, fn-ptr, `cstring`) | address bits / address order |
| Pointer vs integer | the integer is an address-sized bit pattern: `region == -1`, `p != 0` |
| `?T == T` / `?T == null` / error-set vs tag | unchanged |

`any`, interface handles against a foreign type, and distinct structs are refused.

An explicit `xx` in a comparison still takes its target from the OTHER operand:
`a == xx b` converts `b` to `a`'s type, reading exactly as the hoisted
`t : <type of a> = xx b; a == t`. A comparison yields `bool`, and that `bool` is
the value the surrounding context expects — it is never the target of an
operand, so the comparison reads the same inferred, as an `if` condition, and
in a `bool` declaration, argument or return.

An explicit cast pair with **no conversion** is a compile error
(`no conversion from 'A' to 'B'`). Dest-inferred `xx` is also an error
when the value is already the slot type (`already 'i64'`) and when an
implicit conversion already applies (`already converts to '*void'`).
The remaining reinterprets are modeled: unchecked `any` unbox, pointer
↔ integer, same-size aggregate pun (e.g. `string` ↔ `@Slice`), pointer
or function-pointer pun, and same-width integer pun. There is no spill
fallback. User `Into` conversions run when the built-in ladder makes no
progress.

### Postfix Cast `expr.(T)`

`expr.(T)` converts `expr` to the written compile-time type `T` — the
explicit-target form of `xx`, sharing its entire engine: the same coercion
ladder, one engine rather than a second cast. "Safe" means
**well-defined**, not value-preserving: `1000.(i8)` truncates by definition.

An INTERFACE target `expr.(I)` is the explicit view coercion (see
Constraints and Interfaces §5.2): a conforming lvalue borrows in
place, a `*Concrete` receiver borrows its pointee, a `*I` receiver
loads the stored handle, an `I` receiver copies the handle. A
concrete rvalue is a compile error — the target never invents a temp.
The postfix is optional when the destination is already I-typed.
There is no allocating form. A CONSTRAINT target refuses (no runtime
values). A soft interface target on a concrete receiver is the
conformance PROBE; an interface-to-interface conversion is RE-ERASURE
— both defined in Constraints and Interfaces.

```sx
b := a.(i8);            // narrow (truncates)
v := f.(i64);           // float → int
p := raw.(*Point);      // pointer bitcast; composite targets parse: *T, []u8, ?T
o := 5.(?i64);          // optional wrap
s := dog.(Speaker);                    // handle over dog's own storage
x.(u8).(i64)            // postfix chains left to right
-x.(i8)                 // postfix binds tighter: -(x.(i8))
```

The target is exactly one **compile-time** type (a runtime-`Type` target
would make the expression untypeable). `56.(i8)` lexes as a cast (never a
float); `0..(5)` stays a range.

**Raw-view retrieval.** The fat-value raw views (`@Closure`
`{fn_ptr, env}`, `@Slice` `{ptr, len}` for slices AND strings,
`@Interface` `{ctx, type_id}`, and `@Any` `{data, type_id}`) are
retrieved through this same engine — `c.(@Closure)`, `name.(@Slice)`,
`p.(@Interface)` (or the `xx` spelling), `av.(@Any)` (postfix ONLY —
see below). The interface case is a MODELED conversion built field-wise, not
a bit reinterpret: `{ctx, __type_id}` is the leading prefix of a handle
`{ctx, __type_id, vtable}`, so the result is a real value usable in
any position (argument, return, store). `@Interface` mirrors exactly that
prefix — byte-identical to an `any` `{data, type_id}`; the handle
is wider, which is why the build is field-wise and never a reinterpret. A handle receiver with any
other concrete target is the checked DOWNCAST (see the assertion
temperaments — the receiver reads as its `{ctx, type_id}` prefix view);
the recovery targets — a pointer type (`p.(*T)`, the typed ctx read; `T`
must be a CONCRETE type or `void` — a pointer-to-interface target is refused,
since ctx addresses the referent),
`@Interface`, `any` (a handle boxes as its referent), and
another interface (re-erasure) — are conversions and pass through.

`p.(?*T)` is the SOFT ctx recovery — the pointer target under the soft
temperament. It asks the DOWNCAST's question (is the receiver a `T`?) and
answers it with a pointer: `*T` addressing the receiver's own ctx on a
match, `null` otherwise. It BORROWS where `p.(?T)` copies the value out,
and it CHECKS where `p.(*T)` reinterprets ctx unconditionally. The pointee
names the type to test, so it must be a concrete one: `?*void` and a
pointer-to-interface pointee are refused.

On an **`any` receiver** the assertion has three temperaments:

- **`.(T)` consumed via the error channel = graceful**: the assertion is
  failable `(T, !CastError)`; `try av.(i64)` propagates (the global
  `mismatch` tag is absorbed by an inferred `!` caller or any named set
  containing a `mismatch` tag), `av.(i64) ?? 0` falls back,
  `av.(i64) catch |e| { … }` binds the tag. Only a DIRECT assertion operand
  is consumed — an assertion nested in a call argument stays unconsumed.
- **`.(T)` unconsumed = panic on mismatch**: `v := av.(i64);` yields the
  value on a tag match and otherwise prints `type assertion failed at
  file:line: expected T, got U` (runtime type names) and exits 1. This is
  a carve-out from the unconsumed-failable rule, scoped to assertion
  forms — the implicit handler is `catch { panic }`, never a silent
  default.
- **`.(?T)` = soft**: mismatch is a *value* — `null` — never a failure or
  panic; the optional IS the check (comma-ok parity). The asserted type is
  the inner `T`, the result exactly `?T`, composing with the optional
  toolbox: `av.(?f64) ?? 9.5`, `if v := av.(?i64) { … }`, `== null`.

**`av.(@Any)` is the raw-view retrieval, not an assertion** — the one
target exempt from the three temperaments: it answers the view's own
`{data, type_id}` pair, built field-wise (name-AND-shape gated, so only
the std `@Any` shape triggers). The exemption is the bare postfix
target only: the soft form `.(?@Any)` still asserts the boxed payload,
and `xx av` keeps its unchecked-unbox meaning for EVERY target, `@Any`
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
An **interface-handle** receiver's checked downcast (`p.(Square)`) is live:
a handle carries its referent's `type_id` word and reads as its
`{ctx, type_id}` prefix view, and the check is a compare against that
word — a target the receiver's interface has no conformer for simply
never matches. The same three temperaments apply (`try p.(Square)` /
unconsumed panic / `p.(?Square)` soft). See the handle-receiver
paragraph above for the recovery targets that bypass the downcast.

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
and is not reserved — it is an ordinary identifier.

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
LIT  :: Color{r = 255, g = 0, b = 0 };        // one global; uses GEP it
EXPR :: Color{r = K + 1, g = K * 2, b = 0 };  // folds, also one global
W : Color : Color{r = 1, g = 2, b = 3 };      // typed form, same storage
```

A struct constant with a **non-serializable** initializer field (a call, a
runtime-global read, `*x`, `context`) keeps **inline re-lowering**
semantics: the initializer is evaluated **at each use**. This is the
documented contract for this class — side effects run per use and the
value may differ between reads:

```sx
counter : i64 = 0;
bump :: () -> i64 { counter += 1; counter }
CALL :: Color{r = bump(), g = 0, b = 0 };

print("{} {}\n", CALL.r, CALL.r);   // prints '1 2'; counter is now 2
```

For evaluate-once semantics use `NAME :: @run f();` (see
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
- Return type: `-> type` (omit for void). A multi-value return is `-> (T1, T2)`.
- Body: a block whose **value** is its last statement when that statement is an
  expression (see [Block values](#block-values)). That value is the implicit
  return; an explicit `return` works too.

A trailing `!` in the return type marks the function **failable** — it adds a
separate error channel alongside the normal returns. The `!` sits **outside**
the tuple: `-> (T, !)` (one value), `-> (T1, T2, !)` (multi value), `-> !`
(void). The `!` is not a wrapper around the value; it is one more return slot.
See [§12 Error Handling](#12-error-handling).

Examples:
```sx
compute :: (x: i32) -> i32 {
  x * x          // trailing expression → the return value
}

square :: (x: i32) -> i32 {
  return x * x;  // explicit return is equivalent
}

main :: () {
  // void return, no -> annotation
}
```

#### Block values

A block's **value** is its last statement, whenever that statement is an
expression. A last statement that is a declaration — or an empty block — leaves
the block with no value. The terminator plays no part: `;` separates statements
and decides nothing, so a block ends in the same value with it and without it.

```sx
a := { f(); g() };    // value is g()
b := { f(); g(); };   // value is g() — the `;` only separates
```

**The value flows to whatever the position demands.** A block's value is
demanded by a `-> T` function body (it becomes the return), by value position
(`x := { … }`, an `if`/`else` used as a value, a `catch` body, an argument), and
by a build body's statement position (it publishes — see
[`@BuildBlock(P)`](#buildblockp)). Where nothing demands a value — a `-> void`
body, a `defer` / `onfail` cleanup body, a loop body, a statement `if` — the
expression still runs and its value is silently discarded.

```sx
double :: (n: i32) -> i32 {
  n * 2;   // the return value; the `;` changes nothing
}

log_size :: () {
  measure();   // nothing demands the value — discarded
}
```

A **pure failable** (`-> !` / `-> !Named`) has no success value — its whole
return is the error channel — so only a trailing ERROR value is demanded there.
A tail of any other type is discarded like any other undemanded expression, and
the function takes the ordinary success exit. Because nothing in such a body is
in return position, the return-position restrictions do not reach its tail.

```sx
check :: (n: i32) -> !ParseErr {
  if n < 0 { raise error.BadDigit; }
  measure();          // undemanded — discarded, then the success exit
}

fail :: () -> !ParseErr {
  error.BadDigit;     // an ERROR tail IS the return
}
```

This is a property of the SIGNATURE, so every body form reads it the same way —
a closure body reads like a named one, and so do a generic instance, a nested
local function and an inlined comptime callee:

```sx
report := || -> !ParseErr measure();   // discarded, then the success exit
raise_it := || -> !ParseErr error.BadDigit;
```

It is also decided per live path: where the tail is an `if` or a `match`, each
arm is its own tail. An arm that yields an error returns it; an arm that yields
anything else is discarded and reaches the success exit, whichever order the
arms are written in.

```sx
pick :: (b: bool) -> !ParseErr {
  if b { fail() } else { measure() }   // error arm returns; value arm discards
}
```

A block in **value position** that produces no value is a compile error (rather
than silently returning a zero default). Both spellings of the ending are
refused, because both are the same statement:

```sx
double :: (n: i32) -> i32 {
  total := n * 2;   // error: the body produces no value — end it with a
}                   //        trailing expression, or use `return`

c := { f(); x := 1 };  // error: this block is used as a value but produces none
```

An EMPTY block is exempt — `{}` is how the void value itself is written, as in
`.{ {}, 9 }` for a positional product of `void` and `i32`.

An arm's last expression is the arm's value. Every arm statement takes its `;`;
the last statement of the last arm sits before the match's `}` and may drop it:

```sx
classify :: (n: i32) -> i32 {
  match n {
    case 0: 100;            // arm value is 100
    case 1: { x := 5; x*2 } // braced block → value 10
    else:   7
  }
}
```

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
// In modules/std/list.sx:
List :: struct ($T: Type) {
    append :: (list: *List(T), item: T, alloc: Allocator = context.allocator,
               site: @SourceSite = @caller) {
        list.grow_to(list.items.len + 1, alloc, site);
        // ... stores `item` ...
    }
}

// Call sites:
list.append(42);                         // alloc = current context.allocator
list.append(42, self.parent_allocator);  // alloc = the named long-lived owner
```

The trailing `site: @SourceSite = @caller` rides the same mechanism: a growth
that cannot allocate panics at the call site that asked for it, not inside
`list.sx`.

Defaults are only consulted for **trailing** missing positional args; once
a position is provided, all earlier positions must also be provided. There
is no named-argument syntax for skipping middle defaults.

#### `@caller`

`@caller` is a compiler-provided value legal **only inside a parameter's
default expression**, where it resolves to the CALL site's `@SourceSite`.
Written anywhere else there is no caller to name, and it is refused.

```sx
report :: (message: string, site: @SourceSite = @caller) {
    print("{}:{}:{}: {}\n", site.file, site.line, site.column, message);
}

report("invalid width");        // site = this line, in this declaration
```

A caller may pass the parameter explicitly, which is how a wrapper forwards
its own site inward and how a test supplies a fixed one:

```sx
report("from a test", @SourceSite{ file = "test.sx", declaration = "tests.report", line = 20 });
```

The fields the compiler fills:

| Field | Value |
|---|---|
| `file` | the call's module import path, independent of the working directory |
| `declaration` | fully qualified nearest named declaration containing the call; a generic specialization reports its **template**'s path |
| `line`, `column` | the call's one-based source position |
| `ordinal` | zero-based lexical occurrence within that declaration |
| `id` | compile-time fingerprint of (`file`, `declaration`, `ordinal`) |

`ordinal` and `id` are **lexical**, so a call in a loop reports one site
however many times it runs, and they are unchanged by instantiation order,
optimization level, or edits to unrelated declarations. A library that needs
per-iteration identity combines the site with an occurrence count or an
explicit key. `id` is exactly `source_site_key_id(source_site_key(site))` —
`modules/std/source_site.sx` states that computation in ordinary sx, and the
compiler must agree with it.

#### `@Init(T)`

`@Init(T)` is a compiler-maintained **constraint**: an initializer for `T`, a
recipe that fills a destination the receiver chooses. It is not a type, so it is
never a variable, field, or return type — a parameter accepts an initializer by
carrying it as a **bound**:

```sx
store :: (value: $I/@Init($T)) -> *T {
    dest := context.allocator.create(T);
    value.write(dest);
    dest
}

button := store(Button{ label = "Play" });
```

`Allocator` ships that shape as `make`:

```sx
make    :: ufcs (a: Allocator, value: $I/@Init($T)) -> *T;
create  :: ufcs (a: Allocator, $T: Type) -> *T;      // storage, uninitialised
destroy :: ufcs (a: Allocator, p: *$T);              // pairs with both
```

`make` allocates and writes in one step, so it is the spelling that gives an
rvalue a lifetime past the frame that wrote it. `create` hands back
uninitialised storage. Passing a type to `make` fails the `@Init` bound:

```sx
p := a.make(Session);
```
```
error: 'Session' is a type, and 'make' takes an initializer — use
       'create' for uninitialised storage
```

The argument is **not evaluated at the call**. The compiler forms an initializer
from the expression and binds `$I` to it; the expression runs when — and each
time — the receiver calls `write`. A receiver that never writes never evaluates
it at all. A `ufcs` first parameter carrying the bound is reached the same way
through a dot-call: the receiver **is** that first argument, and it forms exactly
as it would spelled as one (`v.publish()` and `publish(v)` form the same
initializer).

The bound's type argument is what a `write` fills. It may be **fixed**
(`$I/@Init(Button)`) or left open, inferred from the argument's own type
(`$I/@Init($T)`, `$I/@Init($V/View)` when the type must also satisfy `View`).

An argument that is **already** an initializer for the same type passes through
unchanged: a helper taking `$I/@Init($T)` may hand its own `value` to another
such parameter, which hands over the single write rather than wrapping it. A
binder bounded by `@Init` can hold nothing else — a binding that is not a formed
initializer fails the bound.

The source expression is an ordinary expression. Every conversion the language
models composes on the way to the target exactly as it does at any other store —
a member into its set, a value under an optional, anything into `any` — and
formation decides only where the composition runs out, at a target no modeled
conversion reaches.

There, the source decides. An open-set value carries its member inline, so a
target that declares membership in that set is a tag check over storage the value
already holds: `write` compares the slot tag and copies the payload on a match.
The target's own shape says what another tag answers — a member panics, an
optional of a member answers null — the same distinction `v.(Label)` and
`v.(?Label)` spell explicitly.

An **interface** target is one of the modeled conversions: the source coerces to
a handle per §5.2 and `write` fills the three words.

After ordinary modeled conversions, an interface-typed source that reaches an
unmodeled concrete leaf is refused. It is a handle to its referent, not the
referent's value, so no concrete value is available for the formation write. The
refusal is located where the expression is written, in both argument and
dot-receiver spellings. The explicit downcast reads the referent out
(`h.(Round)`, `h.(?Round)`), and what it yields forms like any other value.

A set target answers in the terms it decides by whatever the source is: a type
that never declared itself into the set is refused as a non-member.

Neither rule reaches inside the source. A conversion performed while evaluating
it — an argument of a call it makes — and a conversion of a part the write
structurally decomposes — an element of a tuple target — are ordinary
conversions, refused and performed as they are anywhere else.

The operations:

| Operation | Meaning |
|---|---|
| `write(destination: *T)` | evaluate the expression into `destination`, which is **exactly** `*T` |
| `site() -> ?@SourceSite` | the source site of the expression the initializer was formed from |

`write` may be called zero, one, or many times: each call re-evaluates the
expression, side effects included. The compiler does not count writes, does not
require one, and does not check that a receiver publishes only what it wrote —
that convention belongs to the library that accepts the initializer.

Each formation site is its own implementor type, so `write` and `site` are
resolved per site with nothing dispatched at runtime and no storage beyond the
expression's own captures. `site()` reports the site the way `@caller` does: a
lexical position, with a generic specialization reporting its **template**'s
declaration path.

#### `@BuildBlock(P)`

`@BuildBlock(P)` is a compiler-maintained **constraint**: a block of statements
the receiving call may **replay**, offering each statement whose type conforms to
`P` to a sink it chooses. Like `@Init`, it is not a type — a parameter accepts a
build block by carrying it as a **bound**, and it is the callee's **last**
parameter:

```sx
collect :: (content: $B/@BuildBlock(View)) -> List(View) {
    sink := Sink(View){ children = .{} };
    content.run(*sink);
    sink.children
}

rows := collect() {
    Label{ text = "Status" };
    for item in items { Row{ value = item }; }
};
```

The parameter is satisfied in **exactly one** of two ways per call:

1. **the call's trailing block** — the compiler forms a block from that body and
   binds `$B` to it; or
2. **a build block the caller already received** — passed as an ordinary
   argument, which is how a container forwards its own block inward.

Supplying both at once is the duplicate-binding error, and an ordinary value is
neither.

The operations:

| Operation | Meaning |
|---|---|
| `run(sink: *S)` | replay the body once, offering each conforming statement to `sink.expression` |
| `shape() -> @BuildShape` | side-effect-free static facts about the body |
| `site() -> ?@SourceSite` | where the block was written |

`run` may be called more than once: each call replays the body, so its side
effects repeat. Replay is ordinary code — an `if` or `for` in the body is a
runtime `if` or `for` wherever the block is replayed, and no part of it is
deferred to run time in the compiler.

**What publishes.** Only a standalone expression **statement** is offered to the
sink, and only when its type answers to `P`:

- `P` a **constraint** or an **interface**: the statement's type implements it —
  or **is** it, which is the identity case. A value that already is a `P` is
  written into the sink's slot as itself: no second formation, no re-erasure.
- `P` an **open set**: its **members** publish too. A set carries its member inside
  the slot, so a member statement type-checked at the expected `P` is a complete
  `P` value — the same allocator-free formation the expected type performs at a
  local, an argument, or a return, decided by membership rather than by shape.
- `P` any other type: the statement's type **is** `P`. A type that merely converts
  to `P` does not publish.

So `P` is not restricted to a constraint, an interface, or a set —
`$B/@BuildBlock(i64)` is a general list builder whose children are `i64`
statements. Everything else in the body is
ordinary code: a binding, an assignment, a call whose value is discarded, and a
statement of any other type all run where they are written and are not published.
A subexpression never publishes, whatever its type.

**A nested statement publishes too.** Publishing keys off statement POSITION and
type acceptance, never off a terminator. A statement-position block — an
`if`/`else` branch, a loop body, bare braces — is a statement, so its trailing
child publishes exactly like a child written at the body's own top level, with
or without a `;`:

```sx
collect() {
    if show { Label{ text = "in a branch" } }        // publishes
    for row in rows { Label{ text = row } }          // publishes, once per row
    { Label{ text = "in bare braces" }; }            // publishes; the `;` only separates
    Label{ text = "at the top level" }               // publishes
};
```

Three shapes mark the rule's edges. A void trailing expression has no child to
publish. A value-**position** block's tail is its value rather than a statement,
so it goes to the binding (`x := if c { … } else { … };`) and it is `x`, in
statement position, that publishes. And a value in statement position whose type
`P` does not accept is discarded like any other unused value.

**A build block is frame-bound.** What the value carries is the environment of
the frame that formed it, captured **by reference**: forming allocates nothing,
a replay further down the call chain reads those locals live, and a second `run`
observes what the first one changed. It is therefore valid only within the call
that received it — binding it to a local, capturing it in a closure, and
returning it are all refused. Take a `Closure()` parameter instead when the body
must be stored or run later; that is the model that copies its captures into an
allocated environment and outlives the frame.

**A block's names are asked of the file that wrote it.** A replay lowers in the
receiving function's instruction stream, but the body is resolved where it was
written: a block does not inherit the collector's namespace, and a collector does
not inherit the block's. That is what lets a collector live in its own module —
it accepts bodies naming types it has never heard of, and its own signature keeps
naming its own.

`P` is the type the body's statements are intercepted at, and the sink is not
part of the block's type: `run` takes any `*S` implementing `@BuildSink(P)`, so
one block can be replayed into two different sinks.

A type implements `@BuildSink(P)` in either of two ways, and `run` accepts both
by the same question:

- it **declares** `expression` itself, on the struct; or
- an `impl @BuildSink(P) for S` supplies it — including a **blanket** impl
  (`impl @BuildSink($T) for S($T)`), whose method spells the impl's own binder
  and is monomorphized with what the carrier's instantiation bound it to.

A method inherited from an impl of some OTHER head does not answer for this
one; the refusal names the requirement and the sink as the source spells it.
**The initializer's target — two shapes.** `expression` takes the published child as
an initializer, and the target that initializer names is what `write` fills. Which
shape a sink may spell follows from what `P` can carry:

- `$I/@Init(P)` — the **fixed** target — where `P` is a **by-value carrier**: it
  holds the value itself, so a complete `P` is what the initializer writes. An open
  set holds its member inline; a plain data type IS the value. `write` fills a `*P`
  and the sink keeps what it wrote.
- `$I/@Init($V/P)` — the **open** target — where `P` cannot carry the value: an
  interface handle's referent lives outside it, so the sink is told the member `V`
  the block reached and decides where that lives (`modules/fluent.sx` funds it from
  `context.allocator`, which is why its elements outlive the call). A
  **constraint** has no runtime values at all, so no `*P` exists for a write to
  fill — the fixed shape names a target that cannot exist and is refused, naming
  that fact.

`modules/fluent.sx` ships `Sink($T)` with a blanket impl covering both. Its
interface arm splits on whether the published value already IS the slot type:

```sx
inline match T {
    case interface: {
        inline if V == T { self.children.append(value); }
        else             { self.children.append(context.allocator.make(value)); }
    }
    else: { self.children.append(value); }
}
```

`V == T` is type identity. A `V is T` selector would route every conforming
concrete into the verbatim arm, storing handles over the block's frame; `==`
keeps that arm for values that are already handles the caller owns the lifetime
of, and funds every concrete through `make`.

### Open Sets

```sx
View :: @OpenSet(.{ max = 256, align = 8 }) {
    render :: (self: *Self) -> string;
}

Label :: @OpenVariant(View) {
    text: string = "";
    render :: (self: *Label) -> string => self.text;
}
```

An **open set** is an inline tagged slot whose members declare **themselves** into
it. It is neither a constraint nor an interface: `@OpenSet` states a payload
**ceiling** and the methods
every member must have, and `@OpenVariant(P)` is how a type joins `P`. There is no
registry API and no enrollment statement — the declarations are the registry, so a
plain `struct` stays out.

A set is its DECLARATION, so two modules may each declare one of the same name and
they are two sets: each is laid out on its own members, a member joins the one its
head reached, and a value of one is not a value of the other. Where a spelling has
more than one author, a diagnostic names the module that declares the one it means.

`P` is a **path**: a name the member's own module can see, or one **qualified** by
the module that declares the set — `Label :: @OpenVariant(compose.View) { … }`, so
a package's members live in their own modules. What a head reaches is a
DECLARATION, and that is what membership is: a member joins the set its head
reached, and whether a type is a member is asked about that declaration rather
than about the spelling either side wrote. A head that reaches nothing, or reaches
something that is not a set, is refused where the member is written — and a bare
head is an ordinary bare name: it reaches what the file that wrote it can SEE, so a
module that imported no such set is told so rather than handed one, and one that can
see two is asked which.

Every position that names a type asks that same question, and gets the same answer:
a member's head, a bound's head, a downcast's target — the soft form's and the hard
form's alike, whose refusal is about the member the target named. A module that declares a name
of its own reaches its own — asking `v.(?Panel)` where this module declares `Panel`
is asking about this module's, whatever other modules spell it. A qualified target
reaches the module it names, so a consumer that imported a package under a name asks
about that package's member with it (`v.(?compose.Row)`). A facade's
re-exported name reaches what it names, so a bound written on it asks the set's own
question.

A member is an ordinary standalone type: constructible (`Label{ text = "x" }`),
with its own `size_of`, its own methods, and no wrapper around it. `Self` inside
the set declaration denotes the member type; each required method is monomorphized
per member, and a member spells its own concrete receiver (`self: *Label`).

#### Declaring a set and its members

**Options.** `max` is the largest admitted member payload, in bytes, and has no
default. `align` is the payload's alignment and defaults to `8` — what ordinary
allocators guarantee, and therefore what a `List(P)` can honour. Raising `align`
above 8 is only safe if every storage path for those values honours it.

**Layout** is a function of the members the program declares, not of `max`:

```text
payload    = max(size_of(member))              // ≤ max; a ceiling, not a reservation
alignment  = max(declared align, align_of(tag))  // not a max over members
size_of(P) = align_up(align_up(size_of(tag), alignment) + payload, alignment)
```

The tag's own alignment is a **floor**: it lives in the same value, so a set
declared `align = 4` is laid out at 8. Above the floor the declared alignment is
delivered — `align_of(P)` is that value, and an array of `P` keeps every element's
payload on it.

So a set declared `max = 256` whose largest member is 24 bytes is 32 bytes, not
264, and a set with **no members** is just its tag word. Because layout follows the
declared members, **importing a module that declares a larger member grows the
set** — an accepted cost, stated here because it is observable in `size_of(P)` and
in every `List(P)`.

Growth is **transitive**: a member of one set may hold another set by value, so
growing the held set grows that member and re-lays-out the set it belongs to. A
member that outgrows its own ceiling that way is refused at its declaration,
naming the set whose growth exceeded it. (Two sets that each hold the
other by value have no finite layout and are refused.)

**Admission is checked at the member's declaration**, so a type that cannot be
represented is never a member and no conversion site needs a second check:

| Requirement | Refused when |
|---|---|
| `size_of(V) ≤ max` | the member is larger than the ceiling — the diagnostic names the field that accounts for it |
| `align_of(V) ≤ alignment` | the member needs more alignment than the payload has (the effective value above, not the raw option) |
| finite size | the member contains the set **by value** at any depth (a field, a nested struct, an array, an optional) |
| every required method | the member does not declare one |
| every required method's SIGNATURE | the member answers one at other types — arity, a parameter type, or the return type. The set's declaration states them once, and `Self` there denotes the member (`(self: *Self, other: Self) -> Self` is answered by `(self: *Ok, other: Ok) -> Ok`) |
| one set per type | a type is already a member of another set |

A member may hold the set behind a **pointer** (`child: *View`) or in a list whose
elements live outside the value (`kids: List(View)`) — neither embeds the set in
the member's own layout. Nothing is spilled to heap to make an oversize type fit:
either restructure it so the value is small and the bulk is borrowed, or raise
`max` on the set.

A **generic** member (`Padded :: @OpenVariant(View) ($T: Type) { … }`) is a
separate member per instantiation, and the checks run per instantiation — reported
at the instantiation site, since another instantiation may be admissible. An
instantiation the program never materializes is not a member: membership follows
what the program builds.

Every refusal a set earns inside a **generic body** reads the same way: the body is
written once and refused per instantiation, so it names the instantiation as the
program spells it and carries a note at the call that forced this one — the
OUTERMOST call, which for a caller in another module is the only span it can act on.

**When the layout is final.** Because growth follows the declarations, a set's last
member can arrive at any point up to the **freeze** — the point after every body
is lowered, since the same monomorphization that lowers a body can instantiate a
generic member. The
freeze also numbers each set's members densely from 0 in the set's **own** tag space
and writes its `tag → member Type` table.

So `size_of(P)` is **not a literal baked where it is written**. Wherever it is a
value — a body, a `@run`, an argument — it is answered from the frozen layout, and
one program therefore has **one** answer for it everywhere: a body lowered before a
generic member's instantiation and a body lowered after it agree. The same holds for
any type whose layout a set decides, such as a plain struct with a `P` field.

A position the compiler must fold **earlier** than the freeze is **refused** rather
than answered:

```sx
Slot :: struct {
    bytes: [size_of(View)]u8 = ---;   // error: the layout of the open set 'View'
}                                     //        is not final here
```

An array dimension is fixed where it is written, and the struct that carries it is
registered on the spot — a member declared later in the program (or in a module the
program imports) would contradict the number, in a layout that cannot be measured
again. Read the size where it is a value, or bind it with `@run size_of(P)`. A set
that **no generic member can reach** settles as soon as the declarations are
admitted, and a dimension over that set inside a body folds normally.

A compile-time evaluation that runs **during** lowering — `@insert`, a comptime type
construction — may ask for a set's size, and **waits** when nothing can answer yet
(§6.9). It is answered the moment nothing can grow the set. If the answer needs the
freeze and the freeze needs the program that evaluation is still writing, the drain
goes quiet with a bookmark down: that is the expansion deadlock, and sx refuses it
instead of electing one of the outcomes.

#### Forming a set value

**A member value becomes a set value.** Formation is **type-directed** and
allocator-free. Writing a member where the set is expected forms the slot: the
member's frozen tag in the tag word, a **copy** of its bytes in the payload. It is
an ordinary by-value formation — the source is untouched, and neither one's later
writes reach the other:

```sx
source := Label{ text = "label" };
v: View = source;   // an independent slot carrying Label
```

The same coercion applies wherever a set is the expected type: an assignment, an
argument, a `return`, a field initializer. `value.(P)` is the **explicit** spelling
of that same conversion — never required where the expected type already supplies
`P`, and accepting exactly what formation accepts.

A set value is an ordinary value of its size, so **copying one copies the slot**.
`b := a` is an independent set value; passing one by value hands the callee its own
slot. Two set values never share the member they carry, and a dispatched method that
writes through `self` writes the slot it was called on:

```sx
a: View = Label{ n = 1 };
b := a;            // an independent slot
_ = a.bump(10);    // writes a's payload
                   // b is untouched
```

What formation **refuses**:

| Spelling | Why |
|---|---|
| `v: View = .{ … }` | a contextual literal names no type, so there is no member to lift |
| `v: View = Plain{}` | `Plain` never declared itself into `View`; no conversion stands in for a declaration |
| `v: View = Alien{}` | `Alien` is a member of another set, and a type belongs to one |
| `v: View = xx Plain{}` | a cast asks for the same conversion, and is not a way past a declaration |
| `value.(View, alloc)` | not a conversion that allocates — the active member lives **inline** in the slot, so there is no allocator to pass and none is invented |

An open set sits outside interface coercion entirely: there is no `xx`-style
erasure, no heap box, and no compiler-selected storage anywhere in formation.

What may fill a set slot is decided by **membership, never by width**: a non-member
the size of the slot is still not the slot. The question is asked the same way
wherever the value is going — an annotated slot, an assignment, a **field
initializer**, an **argument**, a **return** — so a type that never declared itself
into the set is refused at each of them rather than reinterpreted into one.

#### Consuming a set value

**Dispatch.** Calling a required method on a set value dispatches on the tag word.
Each `(set, method)` pair gets one outlined routine whose switch is **total** over
the frozen tag space — there is no default arm, because the tags *are* the frozen
members — and whose arms call each member's own method directly, handing it the
payload's address as its `*Member`:

```sx
v: View = Panel{ title = "panel" };
v.render();       // the Panel arm
v.bump(10);       // writes through `self` into v's own slot
```

There is no vtable, no boxing, and no indirection through a function pointer. A
`*P` receiver dispatches through the same routine — it already is the slot's
address. Because the arm receives that address, a method that writes through `self`
writes the **receiver's** storage.

A set with exactly **one** member has one tag, so its routine loads no tag and
branches nowhere: dispatch devirtualizes completely. A set **nothing** is a member
of has no values at all, so a required-method call on one is refused.

Every member must answer a required method at the types the **set's declaration**
states — one switch returns through one slot. A member answering at its own types
is refused where its implementation is written. A required method whose signature
mentions `Self` past the receiver has no caller-side type on a set value (`Self`
denotes the member, and a set value is not any one member); call it through the
membership bound instead.

**What a set value answers about itself.** A slot is declared as the set and
carries a member, so `type_of` answers the **member**: the tag word names it, and
the set's own numbering turns that tag into the member's type. Writing another
member into the same slot changes the answer — the answer was never the
declaration.

```sx
v: View = Label{ text = "label" };
type_of(v);        // Label
v = Panel{ title = "panel" };
type_of(v);        // Panel
```

`v.(any)` is the raw polymorphic view a set has: the member's address **inside the
slot**, and the member's own type. Nothing allocates and no payload is copied — the
view borrows the slot, so it answers for the member carried there and is valid
exactly as long as that slot is. Every boxing position agrees with that spelling —
an `any` local, an `any` argument, a formatted value — so a set value is never seen
as the set anywhere `any` is. A set value is not an interface handle: it has no
`@Interface` view, and `any` is the one it has.

Because a box holds the member, **no `any` holds a set value**, and each assertion
form answers from its own contract. `av.(View)` states that a box holds one, which
nothing can make true, so it is refused where it is written — through a type
parameter instantiated at a set, through a `?any` chain, and in the consumed forms
(`try av.(View)`, `av.(View) ?? …`), which are that same assertion with a failure
channel. `av.(?View)` is a question, not a statement, so it stays total and
answers `null` for every box, as does the chained `o?.(?View)`: generic code that
probes keeps working when it is instantiated at a set. An **optional** of a set is
an ordinary value — a box of `?View` holds what it was given, and `xx` recovers it
as that.

The numbering is written at the freeze, so a compile-time evaluation that asks
what a set value is **waits** for it (§6.9) and reads the same answer the running
program reads.

**Reading a member back out.** A slot carries one member and its tag says which, so
asking a set value for a member is one compare against that member's tag, and the
answer is the member's own value — a **copy** read out of the payload, with its own
fields and its own methods. The two temperaments are the ones every checked
conversion has: `v.(Label)` **states** that the slot carries a `Label` and panics on
another member, naming the member actually carried; `v.(?Label)` **asks**, and
answers `null` on another member.

```sx
v: View = Panel{ title = "panel" };
p := v.(Panel);        // the Panel it carries
v.(?Label);            // null — it carries a Panel
v.(Label);             // panics: expected Label, got Panel
```

A target that never declared itself into the set is refused: membership is a
declaration, so no tag ever selects that type and no value of the set is ever one.
`xx` cannot spell this conversion at all — reading a member out can fail, and `xx`
states no temperament — so the spellings that do are what the refusal names.

The downcast is also how a method the set cannot dispatch is reached: a required
method mentioning `Self` past the receiver has no caller-side type on a set value,
and on the member a downcast produced it is an ordinary call on a concrete type —
the second route alongside the membership bound.

**Switching on the member.** A type switch over a set subject opens the member its
tag names: the arms name members, a capture binds that member's own value, and the
arms are read first-wins exactly as they are over an `any`. An **`else:` arm is
required** — a set is open, so a member declared elsewhere in the program carries a
tag no arm here names, and the arms are never the whole of it.

```sx
match v {
    case Label: |l| { print("{}\n", l.text); }
    case Panel: |p| { print("{}\n", p.title); }
    else: { … }                  // a member beyond these arms may reach it
}
```

An arm naming a type that never declared itself into the set is refused, and so is
one naming a **set** — a set is what a slot is declared as, never what it holds,
the subject's own set included. Over an `any` subject a set arm is refused for the
same reason from the other side: a box holds the member.

A capture is a **copy**. Dispatch writes through the slot it was called on, so a
method that mutates `self` mutates the receiver; the value an arm binds was read out
of the slot and is unmoved by that.

**Unwritten slots.** A set-typed location left `---` has an undefined tag until
formation or an `@Init.write` fills it, and consulting that tag — dispatch,
`type_of`, a type switch, a downcast, `.(any)` — is **undefined behavior**. There is
no poison tag, no default-arm trap, and no dispatch-time check; writing before
publishing is the discipline. The other way to reach a tag that means nothing is a
wrong `xx` force from an `any` (`xx a : ?View` where the box holds something else),
which reinterprets whatever the box points at — the `xx` forms that could produce
one out of a set value itself are refused.

**`free` is not part of a set's story.** The active member lives **inline** in the
slot: the payload IS the value, not a handle to an allocation, so there is nothing
for `free` to release and it refuses a set value. What a member's fields point at —
a `List`'s backing, a string buffer — is ordinary field data with ordinary
lifetimes; reclaim it by resetting the allocator or arena those allocations came
from, not through the set value.

#### Sets in signatures

**The membership bound `$V/P`.** A set carries no impls, so a bound whose head
names a set asks the set's own question: **is the binding a member?** This is the
one head in the bound grammar that is not a conformance question.

```sx
show :: (v: $V/View) -> string => v.render();

show(Label{ text = "label" });   // a member — resolves on Label, monomorphically
show(slot);                      // the set satisfies its own bound; this dispatches
```

Inside the body the parameter is the **concrete member**, so calls on it resolve
monomorphically and the bound is what guarantees the method is there. Membership is
the member's own declaration, so the answer never depends on when it is asked, and
a generic member's instantiation carries its template's declaration. A type that
declares itself into no set fails the bound — and so does a member of a *different*
set, since a type belongs to one. A set takes no type arguments, so a head spelled
with any names no set.

**`@Init(P)` into a set slot.** A `$I/@Init(T)` parameter accepts an initializer
whose `write` fills exactly `*T`. Both ways of naming `T` reach a set:

```sx
store :: (value: $I/@Init(View)) {        // FIXED target: T is the set
    slot: View = ---;
    value.write(*slot);                   // a complete slot, either way
}

store(Label{ text = "x" });               // the member is typed at expected View
already: View = Panel{};
store(already);                           // already a View — a plain slot copy
```

At a **fixed** `@Init(P)` the expression is type-checked at expected `P`, so the
allocator-free lift is part of giving it that type and the initializer's target is
`P` — not the member's. When the expression's type already **is** `P`, `write` is a
plain slot copy of a complete value: no tag recomputation and no size check.

An **open** type argument takes the expression's own type instead, and the set is
reached afterwards by ordinary expected-type formation:

```sx
store_as_view :: (value: $I/@Init($V/View)) -> View {
    item: V = ---;
    value.write(*item);   // writes exactly *V
    item                  // returned at expected View: lift + slot copy
}
```

There is **no widening arm**: `write` takes exactly `*T` for the init's own type
argument, so an `@Init(Label)` writes `*Label` and never a `*View`. A set slot is
written through the set's own initializer.

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
| 10 (highest) | `*`, `/`, `%` | multiplication, division, modulo |
| 9 | `+`, `-` | addition, subtraction |
| 8 | `<<`, `>>` | shifts |
| 7 | `<`, `<=`, `>`, `>=`, `==`, `!=` | comparisons (chainable) |
| 7 | `is`, `in` | type classification / membership; non-chaining |
| 6 | `&` | bitwise AND |
| 5 | `^` | bitwise XOR |
| 4 | `\|` | bitwise OR |
| 3 | `and` | logical AND (short-circuit) |
| 2 | `or` | logical OR (short-circuit) |
| 1 (lowest) | `??` | default: optional payload (§2) / failable success (§12); right-associative |

`try` is a unary prefix in the same tier as `xx` / `*` / `-` / `!` / `~`
(tighter than every binary operator, including `??`); `?!` is postfix
force-unwrap and `catch` is a postfix attached to a failable expression. So
`try foo() ?? try boo()` parses as `(try foo()) ?? (try boo())`. See
[§12 Error Handling](#12-error-handling).

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

### The `is` Operator

`is` asks whether the left operand's type satisfies the static description on
the right. It is a reserved infix keyword at comparison precedence, and it does
**not** chain: `a is int is bool` is a parse error.

```sx
n : i64 = 5;
n is int          // true
n is unsigned     // false
i64 is signed     // true
[]u8 is slice     // true
Wrap(i64) is Wrap(i64)   // true
```

**The right operand is a type.** It is read by the type parser: a type name, a
composite (`?T`, `[]u8`, `*T`, `[N]T`), a parameterized head (`Wrap(i64)`), or a
category word. The keyword categories `struct` / `enum` / `union` are admitted
there by the same special case that admits them as match-arm patterns; `type` is
an ordinary identifier and already in the category vocabulary. A category word
wins over a same-spelled type name — `x is int` asks the category. The right
operand is never a runtime `Type` value (`type_eq(t1, t2)` asks that question)
and never a value expression.

**`is` classifies; `==` and `type_eq` identify.** They are distinct questions.
Over the slice of right operands that are concrete descriptions they answer
alike — there is no subtyping and no fits-rule — and that coincidence is a
theorem about those operands, not the definition of either. Nothing is refused
for the overlap. `t1 == t2` over two `Type` values is the tag compare `type_eq`
spells, and it folds when both operands are static.

#### Left operands

**A type expression or a type binder** folds at compile time. The fold covers
identity (`i64 is i64`), conformance (`Point is Ord`, and `I is I` for an
interface `I`), open-set membership (`Label is View`), and category
(`Point is struct`). A constraint is a legal comptime left operand:
`Ord is interface` is false.

**A statically-typed value** folds through its static type: `5 is unsigned` is
false, because an integer literal defaults to `i64`.

**An `any`** reads its runtime TAG: tag identity, category, per-pair
conformance, and membership all answer from the tag. An `any` holding a `Type`
answers `at is type` — the tag is `Type`, and `is` does not peel it. Classifying
the held type unboxes first: `at.(?Type)` is the total form, and `av.(Type)`
panics on a value-holding `any`. (`type_name` peels a `Type`-holding `any`; `is`
reads the tag.)

**An interface handle** answers from its **static** type. With `h : I = w`,
`h is I` is true, and `h is Q` and `h is Concrete` are false — all three fold.
`type_of(h)` is the door to the referent: it is a runtime `Type`, and asking it
classifies the concrete value behind the handle. `h is C` for a constraint `C`
asks whether the handle's own interface conforms — true exactly when the bridge
`impl C for I` is visible — and folds like the rest of the family.

**An open-set value** follows the static-left-operand rule; `type_of(v)` reports
the member the slot carries.

**A runtime `Type`** takes every description: tag identity (a concrete right
operand — the same answer `type_eq` gives, and both spellings are legal),
interface conformance through the per-pair table of §6.4, constraint conformance
through a per-constraint conformer-tag set emitted only for constraints a
runtime `is` reaches, set membership, and categories. `is interface` is true for
a directly reified interface tag and false for a tag derived from an instance.

**Phase and evidence.** A static ask answers site-local impl visibility (§6.9); a
runtime ask reads program-unique pairs (§6.4), so a duplicated pair answers
false. The two differ only under the visibility-disjoint duplicate impls of §3.
With `impl C for W` duplicated that way, `h : I = w` and `av : any = w`:

```sx
W is C            // true  — site-local visibility
type_of(h) is C   // false — the pair is not program-unique
av is C           // false — same table
```

`h is C` sits outside that split: it asks `I`'s conformance, not `W`'s, and
answers from site-local visibility at either phase.

#### Categories

| category | matches |
|---|---|
| `int` | every integer type, both signednesses, every width, `isize`/`usize` included |
| `signed` | the signed integers |
| `unsigned` | the unsigned integers |
| `float` | `f32`, `f64` |
| `struct` | struct and tuple types |
| `enum` | payload-less enums and tagged unions |
| `union` | untagged unions and tagged unions |
| `slice` | `[]T` |
| `array` | `[N]T` |
| `pointer` | `*T`, `[*]T`, function pointers |
| `vector` | `@Vector(N, T)` |
| `optional` | `?T` |
| `error_set` | declared and inferred error sets |
| `closure` | `Closure(…) -> R` |
| `type` | `Type` |
| `interface` | interface types |

`signed` and `unsigned` partition `int`: they are disjoint, their union is
`int`, and both are integer-only — `f64 is signed` is false.

`bool`, `string`, and `void` are single types; a right operand naming one asks
identity, not a category.

Refinements and the umbrella compose by first-wins, so `case unsigned:` before
`case int:` splits the integers and the reverse order leaves the second arm with
no tags (the armless-arm error).

`interface` and `struct` are **disjoint**: `T is struct` is false for every
interface and every constraint, at both phases. A constraint matches no
category, and there is no `constraint` category word. Flags-ness is
`is_flags(T)`, not a category; set membership is asked with the set's own type
as the right operand.

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
match subject {
  case pattern: body
  case pattern: body
  else: body          // optional default arm
}
```
Matches `subject` against each `case`. Patterns can be:
- **Enum literals**: `.variant` — matches a specific enum variant.
- **Integer/bool literals**: `42`, `true` — matches a specific value.
- **Type categories**: `struct`, `enum`, `union` — matches all types in that category (used with `type_of` values).

`break` exits a case arm without producing a value. The optional `else:` arm matches when no `case` pattern matches — its `:` is what separates it from an `else` that chains an `if`.
```sx
match z {
  case .variant1: break;
  case .variant2:
    print("z: {z}");
  else:
    print("unknown")
}
```

#### Type Category Matching
When switching on a `Type` value (from `type_of`), category keywords match all registered types of that category:
```sx
type := type_of(val);
match type {
    case unsigned: result = uint_to_string(xx val);
    case int:      result = int_to_string(xx val);
    case struct:   result = struct_to_string_over_views(type, val);
    case enum:     result = enum_walk_over_tables(type, val);
}
```
Available categories: `int`, `signed`, `unsigned`, `float`, `bool`, `string`, `void`, `struct`, `enum`, `union`, `vector`, `array`, `slice`, `pointer`, `optional`, `error_set`, `closure`, `type`, `interface`. `signed` and `unsigned` are the disjoint integer-only refinements of `int` (§The `is` Operator), so `case unsigned:` above `case int:` splits the integers by signedness — unsigned types reach the unsigned-decimal formatter and `u64.max` prints as `18446744073709551615` rather than `-1`. Reversing that order leaves `case unsigned:` with no tags, which is the armless-arm error.

> Note: `case enum:` matches payload-less enums AND tagged enums (enums
> with payloads); `case union:` matches C-style untagged unions AND
> tagged enums — the same split as the static `inline match T`
> classifier, arm for arm. Arms claim tags **first-wins with the loud
> unreachable-arm error**, exactly like the type switch: overlapping
> categories resolve by order, a specific type — user-named
> (`case Point:`), builtin (`case i64:`), or a composite type expression
> (`case ?i64:`, `case []u8:`) — must come before the category that
> contains it, and an arm left with no tags is a compile error, never a
> silently dead arm. Unknown names and value patterns are pointed
> compile errors.

Inside a category arm the subject stays an `any` and the matched `type` a runtime `Type` — arms handle the value through the runtime reflection surface (the table-backed builtins, `any` views like `struct_field_value` / `variant_payload` / `any_element`, `raw_make_any`) with ONE compiled body per arm; `xx val` in the `int`/`float` arms width-dispatches over the arm's tag set. An EXACT-tag walk asserts with `val.(T)`.

#### Type Switch (`any` subjects)

Matching directly on an **`any`** value dispatches on its runtime type
TAG — never the payload (Go's `switch v := x.(type)` / Odin's
`switch v in x` parity):

```sx
match av {
    case i64: |v|   { print("int {}\n", v + 1); }      // v: i64 — the typed value
    case Point: |p| { plot(p); }                       // named types
    case []u8: |b|  { print("{} bytes\n", b.len); }    // composite types are real tags
    case ?i64: |o|  { print("{}\n", o ?? 0); }         // tags are EXACT — no flattening
    case struct:    { walk_fields(av); }               // categories: tag SETS, no binding
    case int:       { print("{}\n", xx av); }          // xx width-dispatches over the set
    else:           { print("{}\n", type_name(type_of(av))); }   // av stays `any`
}
```

- **Concrete arms** name one type — named, builtin, or a composite type
  expression — resolved by the same resolver every type position uses
  (aliases are transparent). An optional `|v|` capture binds exactly what
  `v := av.(T)` produces, with the tag pre-proven by the switch: no panic
  path. Works in value position.
- **Category arms** (`int`, `signed`, `unsigned`, `float`, `struct`, `enum`,
  `union`, `slice`, `array`, `pointer`, `vector`, `optional`, `error_set`,
  `closure`, `type`) are tag SETS and cannot bind `|v|` — a kind names many types;
  read the value through the reflection views, or `xx av` in the
  `int`/`float` arms (per-tag width dispatch). `string`/`bool`/`void`
  are single types and take the concrete path, so their arms CAN bind.
- **Arms overlap first-wins, loudly**: a tag belongs to the first arm that
  names it, so a concrete arm must come BEFORE the category that contains
  it (`case i64:` above `case int:`). An arm left with no tags — the
  reverse order, or a duplicate — is a compile error, never a silently
  dead arm. Value patterns (`case 5:`) are a compile error: the payload is
  never the scrutinee.
- **Subjects**: `any`, INTERFACE handles, and OPEN SET values. A handle
  subject switches through its `{ctx, type_id}` prefix view; a
  set subject switches on the member its
  tag names, and its arms name members with an `else:` arm REQUIRED
  (see Open Sets) — same arms, same captures, over the concrete value
  behind the subject. A `?any` composes through the optional match
  (`case .some: |av| { … }`).
- **`case interface:` by subject**: over an `any` or a handle subject it is a
  pointed compile error — those tags name the referent's concrete type and never
  an interface. Over a runtime `Type` subject it is an ordinary category arm,
  claiming the directly reified interface tags under the same first-wins rule.
- Division of labor: the type switch dispatches on CONCRETE types and
  binds typed values; kind-only dispatch also exists as the category match
  on `type_of(av)` and as the static `inline match T { … }` fold in
  generic bodies.

#### Inline Type Match (static pruning)

`inline match T { case <category|Type>: … else: … }` over a **bound generic
type param** selects its arm at lower time — the siblings are dropped
whole, exactly like `inline if` branch elimination. Each kind arm may
therefore use kind-specific operations that would not type-check for other
kinds (`x.len` in a slice arm, `x.(@Interface)` in an interface arm):

```sx
free :: ufcs (x: $T, a: Allocator = context.allocator) {
    inline match T {
        case closure:  { env := x.(@Closure).env; if env != null { a.dealloc_bytes(env); } }
        case slice:    a.dealloc_bytes(xx x.ptr);
        else:          @error("free expects a closure or a slice");
    }
}
```

Arms select in order (a specific type name may precede its category);
`else:` matches when nothing else does; with no match and no `else:` the
match lowers to nothing (the runtime form's skip-to-merge, statically). A
`@error(…)` arm fires only when SELECTED — the un-selected case is
the OS-match discipline. The static classifier mirrors the runtime tag
switch arm for arm, and `case interface:` claims the interface types.
A constraint matches no arm of either classifier. Inline branches lower in
statement position (like `inline if OS`), so value-producing arms use
explicit `return`. A NON-inline type match keeps its runtime tag-switch
semantics.

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
for c1, c2, ... in it1, it2, ... { }        // parallel iteration, one capture per iterable
for c1, c2, ... in it1, it2, ... => stmt;   // arrow body — a single statement
```

A `for` header is an optional comma-separated list of **captures**, `in`, and
a comma-separated list of **iterables**, then the body. Each iterable is a
collection (array, slice, string, `List(T)`-like struct) or a range:

```sx
for x in xs { }                     // collection, element capture
for i in 0..n { }                   // range, `end` exclusive; cursor i (i64)
for a in 1..=5 { }                  // `..=` — end inclusive: 1 2 3 4 5
for 0..5 { }                        // no captures — body runs 5 times
for xs { }                          // no captures — body runs xs.len times
for x, i in xs, 0.. { }             // THE index idiom: open range follows along
for x, y in xs, ys { }              // parallel (zip) iteration
for a, b in 1..=5, 0.. { }          // a: 1..5, b: 0..4 (end inferred)
for p, q, k in a4, b4, 100.. { }    // any number of positions
for x in xs => sum += x;            // arrow body
for x in f(n) { }                   // a call iterable is an ordinary call
inline for i in 0..n { }            // comptime unroll; first range bounded
inline for x, i in xs, 0.. { }      // comptime unroll over a PACK: x = the
                                    // concrete i-th element (see "Variadic
                                    // Heterogeneous Type Packs")
inline for T in TYPES { }           // comptime unroll over a `[N]Type` list:
                                    // T is a comptime Type, legal in type
                                    // position (see "Constraints and
                                    // Interfaces" §3)
```

**Range bound markers.** Each side of `..` takes an optional marker — `=`
inclusive, `<` exclusive — with defaults start-inclusive, end-exclusive
(`a..b` ≡ `a=..<b`; `a..=b` is the short end-inclusive spelling):

```sx
for i in 0<..<5 { }       // 1 2 3 4      — both ends exclusive
for i in 0=..=5 { }       // 0 1 2 3 4 5  — both ends inclusive
for i in 0<..=5 { }       // 1 2 3 4 5
for i in 0=..<5 { }       // 0 1 2 3 4    — explicit spelling of `0..5`
for i in 0..<5 { }        // 0 1 2 3 4    — explicit spelling of `0..5`
for x, i in xs, 2<.. { }  // open range with an exclusive start: i = 3, 4, …
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

**Captures are positional**: they bind one name per iterable, in
order — range positions bind the cursor value (i64), collection positions
bind the element. With nothing to bind, both the captures and `in` are
omitted. Capture names shadow outer bindings, like any inner declaration.
Use `_` to discard a position. An index alongside the elements is written
`for x, i in xs, 0..`.

**A capture may write its type**, `for x: T in xs`. `T` is the ELEMENT
type — what the position yields — and `*` is orthogonal to it:

```sx
for c: View in children { }      // c : View
for *c: View in children { }     // c : *View — the element type is still View
for x, i: i64 in xs, 0.. { }     // a range cursor is i64
for x: struct { a: i64; } in items { }  // a brace group belongs to the type
```

The type is an ordinary `type`, so a brace group in it (`struct { a: i64; }`,
`Pair(struct { a: i64; }, i64)`) belongs to the annotation, not the body.
The annotation restates the type; it never converts. It must name the
element type exactly — a range cursor is `i64` whatever its bounds are
spelled as, and an `inline for` over a pack checks the annotation against
every unrolled element. An `inline for` cursor over a type list binds a
type rather than a value, so it takes no annotation, at module scope as in
a function body.

**The iterables are ordinary expressions.** Nothing in the header is
reserved for captures, so a call iterable is written as it is anywhere else
(`for x in f(n) { }`, `for x, y in zip(a, b) { }`) — no parenthesizing and
no intermediate binding. A `(` applies arguments across any gap, so
`for x in f (n) { }` is the same call and `for xs (x) { }` iterates `xs(x)`.

**By-value captures are immutable.** This rule is not
specific to for-loop element captures — it holds for *every* by-value
capture binding: the for-loop element and the paired range index
(`for x, i in xs, 0..` — both `x` and `i`), a match-arm payload capture
(`case .circle: |r|`), a `catch` / `onfail` error binding
(`f() catch |e|`), and an `inline for` pack-element alias
(`inline for x in xs`). A capture is a read-only alias into storage the
loop/match/error machinery owns, not a fresh mutable local; assigning to
it bare (`x = v`, `i = 99`, `r = 5.0`, `e = error.Bad`) is a compile
error rather than a silent no-op. To mutate, copy the capture into a
`:=` local (`v := x; v += 100;`) — the copy is yours to change and
cannot accidentally look like it writes back. To write *through* into
the container, use a for-loop **by-reference** capture (`for *x in xs`,
below) and store via the pointer (`x.* = v`); range positions and
match/catch payloads have no container storage to write back into, so
they are copy-into-a-local only. The diagnostic is shape-aware: only the
for-loop element form suggests `*x`; the storage-less shapes get the
copy-into-a-`:=`-local advice alone. A **function-local `::` constant**
(`c :: 5`) is enforced by the same mechanism — assigning to it is a
compile error with the constant-family message, mirroring module-level
`::` consts. (Rationale: mutating a per-iteration
copy that vanishes at the next iteration is almost always a bug — the
author meant `*x`. This also matches the copy-semantics chosen for the
`xx`-erasure materialization, where a by-value capture is
likewise snapshotted into a fresh temp rather than written back.)

**By-reference capture (`*elem`)** binds the element to a *pointer* into the collection (`*T`) instead of a value — no per-element copy. It GEPs straight into the array/slice backing, so:
- Passing it onward is zero-copy — `f(elem)` where `f` takes `*T` hands over the pointer, not a copy.
- Writes through it land in the original: `elem.* = v` (or `elem.field = v`).
- In a value position the pointer auto-derefs to the element: `elem + 1` reads the value, and `match elem { … }` matches the pointee (a pointer subject matches through the deref). Where a `*T` is expected, the pointer is passed as-is.
- Range positions have no storage — `*` on a range capture is a compile error.

```sx
events := plat.poll_events();        // []Event
for *ev in events {                  // ev : *Event — no copy
    pipeline.dispatch_event(ev);     // passes the pointer
}
```

The `inline` variant requires a single bounded range with comptime-known
bounds and unrolls the body once per value, binding the cursor as a
compile-time constant (so it can index a pack:
`inline for i in 0..xs.len { xs[i].m() }`).

`break;` exits the loop. `continue;` skips to the next iteration. Both run
the iteration's pending `defer`s first (see Defer).
```sx
arr : [5]i32 = .[1, 2, 3, 4, 5];
for val, ix in arr, 0.. {
    if ix == 2 { continue; }
    print("{}\n", val);
}
```

### Closure Literal
```sx
|params| expr
|params| { body }
|params| -> return_type expr
```
Anonymous function. Produces a `Closure` value. `|` opens a closure literal
only where a primary starts; after a completed operand it is bitwise OR. `||`
is two `|` tokens around an empty parameter list. A parameter default is an
ordinary expression except that the first `|` on that default's own value spine
closes the parameter list. The value spine is the default's operator spine
together with the trailing expression of an inline `if`, a `catch |e| expr`, a
nested `|params| expr` body, `@run`, and `return`. Inside `(…)`, `[…]`, `{…}`,
or an `if` / `while` / `for` / `match` header, `|` is bitwise OR — so a
bitwise-OR default is parenthesized (`|x: i64 = (a | b)|`), while
`|x: i64 = mask(a | b)|` and `|x: i64 = if a | b { 1 } else { 0 }|` need
nothing. Parameters take the same
forms a named function's do — `$` generic type params, `..` variadic params —
and the return type annotation is optional. A closure literal may not open an
expression statement: bind it, pass it, or `return` it. In a value position — a
block tail, an `if` branch, a `match` arm — it is parenthesized.

Two brace forms carry the same `|…|` spelling as a **header** right after their
`{`: a call's [trailing block](#trailing-blocks), whose header is its parameter
list, and a [self-trailing](#struct-literals) `.{ … }`, whose header names the
value pointer. No other `{` takes a header — there a `|` opens a statement and
is refused.

```sx
n := 5;
inc := |x: i32| x + n;                        // Closure(i32) -> i32
pump := || { print("tick\n"); };               // Closure()
scaled := |x: i64, k: i64| -> i64 x * k + n;  // annotated return
add : Closure(i64, i64) -> i64 = |a, b| a + b;  // params typed from the target
```

With a return type annotation the body follows the type directly, so a bare
body that opens with `.` continues the type's qualified path (`-> Pol .a`
reads the type `Pol.a`): write such a body as a block (`-> Pol { .a }`).

### Closures

A **closure** is a function bundled with captured state. It is represented as a fat pointer `{ fn_ptr, env }` (16 bytes), unlike a bare function pointer which is 8 bytes.

#### Closure Type
```sx
Closure(param_types) -> R     // e.g. Closure(i32, i32) -> i32
Closure(param_types)          // void return: Closure(i64) -> void
?Closure(i32) -> i32          // optional closure (null = none)
Closure(..Ts) -> R            // pack-expanded params (see Variadic Heterogeneous Type Packs)
```

#### Creating Closures — closure literals
A closure literal IS the closure value — there is no wrapping
intrinsic, and `closure` is an ordinary identifier, not a keyword.
```sx
offset := 50;
f := |x: i32| -> i32 x + offset;   // expression body
g := |x: i32| -> i32 {             // block body
    if x < 0 { return 0; }
    return x + offset;
};
```

A closure literal:
1. Analyzes its body for free variables (variables from outer scope)
2. Allocates an env struct on the heap containing captured values
3. Generates a trampoline function with signature `(env: *void, params...) -> R`
4. Evaluates to a `Closure` value `{ trampoline, env_ptr }`

**Capture semantics**: capture by value (snapshot at creation time). Mutating the original variable after creating the closure does not affect the captured value.
```sx
n := 10;
f := |x: i64| -> i64 x + n;
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
    return |x: i32| -> i32 x + n;
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
btn := Button{label = "OK", on_click = null };
if handler := btn.on_click {
    handler(1);
}
```

#### Memory
Closure env is allocated via `context.allocator`. The compiler auto-initializes `context` with a default GPA (malloc/free wrapper) at the start of `main()`. Use `push Context` to override with a custom allocator. Auto-promoted closures have a null env and require no allocation.
```sx
f := |x: i64| -> i64 x + 10;   // env allocated via default GPA
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
A block after a call's closing `)` passes the block as a **closure literal
bound to the callee's last declared parameter**. The equivalence is
definitional — every other rule (duplicates, defaults, evaluation order)
follows from it; the block is not a special argument kind:

```sx
vstack(8.0) { text("a"); text("b"); };
// ≡
vstack(8.0, content = || { text("a"); text("b"); });

each(items) { |x| print("{}\n", x); };
// ≡
each(items, |x| { print("{}\n", x); });

scaffold(top_bar = toolbar) { chat_list(); };  // named slots + trailing block
scaffold() { chat_list(); };                   // defaults skipped, block binds `content`
```

- **Binding**: the block binds the last declared parameter, which must be a
  non-variadic `Closure` type — or a **build block** parameter, which gives the
  same source block a second meaning (see [`@BuildBlock(P)`](#buildblockp)).
  Otherwise a targeted error names the parameter ("'f' cannot take a trailing
  block — its last parameter 'x' is not a `Closure`", or "… its last parameter
  '..xs' is variadic").
- **One block**: at most one trailing block per call. Other closure
  arguments are named args or ordinary positional slots.
- **Header**: a `|params|` header directly after the `{` declares the closure's
  parameters, spelled exactly as a `|…|` closure literal spells them
  (annotations and defaults included). Without a header the closure is
  zero-param. An empty `| |` is a header with zero parameters. The header's
  arity must match the parameter's `Closure(…)`, and a build block takes no
  header — it is replayed against a sink, never called.
- **Juxtaposition**: `expr { … }` is two adjacent expressions, and one node
  carries both readings until **types** settle it. A head that names a type —
  a bare or qualified name, a type application, a generic type constructor, a
  `-> Type` function — constructs (`Label { text = "x" }`, `List(Move){}`,
  `Buf(16){}`, `p.Slot(i64){}`); every other call fuses its block onto the last
  declared parameter (`vstack(8.0) { … }`, `run(2) {}`, `render(*screen) {}`).
  Body shape, the gap before the `{`, and a line break between them decide
  nothing. Anything else takes no block at all.
- **Header on a construction**: a construction takes no `|…|` header — that
  header belongs to a block that becomes a closure. A positional aggregate
  element that is a closure is parenthesized: `Box(Closure(i64)){ (|x| x), }`.
- **Does not stack**: a juxtaposition is not itself a head, so
  `T { fields } { stmts }` is not one form. Written with the `;` it is the
  construction and then an ordinary scope; written without, the report names
  the missing terminator.
- **Header position**: a statement header — `if`, `while`, `for`, `match`,
  `push` — reserves the brace group written at its own `{` `(` `[` depth, so
  there `{` terminates the header and opens the statement body; bind the
  closure explicitly. Inside a group opened after the header began, the form
  is ordinary: `push .{ b = Box(i64){ 1 } } { … }`,
  `for x in .[ Label { text = "a" } ] { … }`.
- **Named aggregates in headers**: a named aggregate that ends a header
  expression must be parenthesized so the statement body keeps its `{`:
  `if (Button{ label = "x" }.ready) { … }`. A tail written on the header spine
  is at the header's own depth and takes the same parentheses — after `try`,
  `catch |e|`, `@run`, or a bare closure body:
  `if (mk() catch |e| Pt { x = 0 }).x == 1 { … }`. Push is different — named
  aggregates are legal in the context expr and the following brace is the push
  body: `push Context{ io = my_io } { … }`. Idiomatic: `push .{ … } { … }`.
- **`return` is local**: a `return` inside the block returns from the
  closure, never from the enclosing function (no non-local return).
- **Chain continuation**: after the block's closing `}`, **dot-led** postfix
  continues the chain — member access, UFCS call, and `.(T)` cast all apply to
  the call's result: `f(x) { … }.modifier()`, `emit.column(4) { … }.emit();`.
  The `.` may sit on the next line. Only `.` continues the postfix chain; infix
  reads on past the `}` like after any other value (`f() { … } + x` is an add).
  A chained call may take its own block, each one re-applying this rule:
  `f() { … }.map() { … }`.
- **Duplicate with a named argument**: a trailing block binds the last
  parameter, so also naming that parameter is the duplicate-binding error
  ("parameter 'content' is bound both by a named argument and by the
  trailing block").

No `inline` keyword exists or is needed: a capture-free block promotes to a
null-env static thunk (zero allocation); a capturing block allocates its
environment through `context.allocator` like any closure literal. A block bound
to a **build block** parameter allocates nothing at all, and captures by
reference instead — that is the difference the two parameter kinds buy
([`@BuildBlock(P)`](#buildblockp)).

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
               //   directly, or declare it `create :: ufcs (...)`)
f.create2();   // works — calls create2(f)
f.create3();   // works — calls create(f) through the alias
create2(f);    // a ufcs fn is still an ordinary fn: direct calls work
create(f);     // a plain fn is callable only this way
```

When `object.func(args)` names an opted-in function and `func` is not a
field or method of `object`'s type, the compiler rewrites the call to
`func(object, args)`. Fields and methods take priority over ufcs
functions; an interface-typed receiver dispatches its own MEMBERS first and
falls through to ufcs functions only for non-members
(`context.allocator.create(Session)` — `create` is a ufcs fn taking the
handle as its first param).

UFCS works with pointer receivers (auto-deref, and auto address-of when
the first param is `*T` and the receiver is a value) and with **generic**
functions — the receiver participates in `$T` binding and the call
monomorphizes exactly like the direct spelling:

```sx
first_of :: ufcs (xs: []$T) -> T { xs[0] }

xs.first_of();       // dot — binds $T from the receiver
first_of(xs);        // direct
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

Statements are terminated by `;` (§1
[Spacing and terminators](#spacing-and-terminators)). A statement that IS a block ends
at its `}` instead, and the last expression or declaration before a `}` may drop
its terminator.

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

**`Context` struct** — assembled PER PROGRAM, 100% from `@context_extend` declarations. The struct itself is declared EMPTY in `modules/std/core.sx` (the declaration doubles as the implicit-context mode marker); the stdlib's own capabilities are ordinary declarations in their owning modules:
```sx
// std/mem.sx
c_allocator : CAllocator = .{};
@context_extend allocator: Allocator = c_allocator;

// std/io.sx
c_blocking_io : CBlockingIo = .{};
@context_extend io: Io = c_blocking_io;
```
Before any `push`, code runs under `__sx_default_context`, a static constant holding every field's folded default. An interface-typed default like the two above is the handle over the named instance global — a BORROW: the constant's ctx word is the global's real address, never null (null ctx is the `?I` absent sentinel). The same fold works for any user global (`fallback : Allocator = my_impl_global;` — no `xx` needed, the declared type states the coercion), and a module-scope global is the only operand it accepts (see Constraints and Interfaces §6.6). Threads and fibers inherit by snapshotting the spawner's whole context value.

`push` and `context` require the `Context` type to be declared (import `std.sx` or any module that imports it). In a build without it, both error — and the diagnostic enumerates the program's registered `@context_extend` fields with their declaring modules, so the demand is traceable.

### `@context_extend` — extending the Context

Any module — stdlib or user — can declare a field the program's Context carries:

```sx
@context_extend ui: *Ui = null;      // bare nullable pointer — the default idiom
@context_extend frame_stats: FrameStats = .{};
```

`?*Ui` works too and opts the field into checked nullability (consumers must
prove presence before use); the bare spelling keeps null as an unchecked
sentinel, per the pointer contract.

- **Grammar**: `@context_extend <name> : <type> = <default> ;` at top level only — which includes a top-level `inline if` branch or `inline for` body, whose statements ARE module scope after comptime flattening. A branch that is not selected declares no field; while such a driver is undecided the Context is not final, and comptime that reads it waits (§6.9 scheduling).
- **Assembly**: the compiler assembles the program's `Context` from every declaration in the compilation — there is no builtin prefix — in a deterministic order (sorted by declaring module path, then field name). Field offsets are program-specific — never rely on them across programs.
- **Access is global and unconditional**: after assembly, `context.field` works in ANY module of the program with no import requirement. Imports gate existence only (an uncompiled module contributes nothing); there is no per-source scoping of context fields.
- **One flat namespace, loud collisions**: two declarations with the same field name (or colliding with a builtin field) are a hard compile error naming both declaration sites.
- **Defaults are mandatory and comptime-evaluable**: a declaration without a default — or with one that doesn't fold to a compile-time constant — is a compile error; the default context must be constructible before `main` runs. Defaults fold into `__sx_default_context`. An interface-typed field's default folds to the handle over a named module-scope global; any other initializer is refused there (see Constraints and Interfaces §6.6). `*T = null` is the idiom for pointer fields (`?*T = null` where checked absence is wanted); the root `push` in `main` is the idiom for wiring real values.
- **`push` semantics**: added fields patch exactly like builtin ones.
- **Comptime**: `@run` bodies execute under a VM-LOCAL copy of the assembled default context (see Constraints and Interfaces, compile-time execution): an added field's default is readable at comptime; interface-typed fields reference VM-owned instances whose mutations are execution-local and discarded — comptime code cannot mutate globals (the VM reads globals into VM-local copies and never writes back).
- **Cost guideline** (not enforced): reads are a constant-offset load and calls share the pusher's slot — the only growth cost is the spread-copy at `push` (and the per-fiber snapshot). Prefer one POINTER per concern (`*Ui`, `*Logger`) over fat inline values; a 2 KB inline field makes every push a 2 KB memcpy. Small inline value fields are fine.

There is no untyped escape slot: a module that wants to carry a payload declares its own typed field (`@context_extend logger: *Logger = null;`).

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

An **intrinsic** is a declaration whose implementation lives in the compiler.

A FUNCTION intrinsic has two spellings. A plain name is written with the
reserved word `intrinsic` in body position, where a `{ ... }` body would
otherwise go; an `@` name is written as its signature alone, because the sigil
is already the marker:

```sx
size_of :: ($T: Type) -> i64 intrinsic;
@volatile_load :: ($T: Type, address: *T) -> T;
```

The `@` form takes no body — no brace block, no `=> expr`, no `intrinsic`
keyword — and no `abi`, linkage, `ufcs`, or accessor modifier. A DATA intrinsic
is written with the reserved word for every name, since it has no signature the
sigil could stand over:

```sx
n :: intrinsic;
n :: i64 intrinsic;
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
(the atomics). Two — `type_name` and `type_info` — are
**dual**: folded at lowering when the type argument is statically resolvable, and
serviced by the comptime evaluator when it is only known at evaluation time. The
compiler-API surface (`raw_intern`, `raw_find_type`, the `BuildOptions` methods, …) is
**evaluate**: the comptime evaluator services it and there is no runtime form at
all. Calling one from the runtime call graph is a compile-time error that prints
the path from the root that reached it.

Dispatch is not the same as stage-availability. `@sqrt` and `atomic_load` are both
lowered. The evaluator interprets the atomic ops, and evaluates the `call_builtin`
that `@sqrt` lowers to, so `@run @sqrt(x)` is a compile-time constant.

Two categories are **not** intrinsics. `string`, `@Vector`, `@Array` and
`@Slice` are language primitives, resolved by name by the type system like `int` / `bool` /
`f64`. And `type_eq` is recognized bare, declared nowhere.

### Staging: functions belong to no stage

An ordinary sx function is **stage-polymorphic**. Nothing in a declaration says
whether it runs at compile time or at runtime; what decides is **reachability**.

- **Compile-time roots**: `@run`, type construction, `@insert`, module-scope
  `inline if` / `inline match` / `inline for`, and a build callback registered
  with `on_build`. A `::` whose initializer is a call is not a compile-time
  root.
- **Runtime roots**: `main`, exported definitions, and anything named by global
  data (an interface vtable, an open set's tag table, the default `Context`).
  Comptime not entangled with conformance runs after the declaration space is
  final (see Constraints and Interfaces, compile-time execution).

A function reached from the compile-time roots is evaluated by the comptime
evaluator. A function reached from the runtime roots is emitted into the binary.
A function reached from **both** does both, and must agree with itself:

```sx
shared :: (n: i64) -> i64 { return n * 2 + size_of(P); }

CT :: @run shared(10);          // evaluated by the comptime evaluator
main :: () { rt := shared(10); } // and emitted into the binary
```

Two consequences follow, and neither needs an annotation:

- A function nothing runtime-reachable calls is **not emitted**. This is what
  keeps a build callback out of the binary — not its signature, and not an
  ABI marker.
- Calling an `evaluate`-only intrinsic from the runtime graph is an error,
  reported with the path from the root that reached it:

```
error: 'intern' runs only at compile time — it cannot be called from the
       runtime call graph (use it inside @run or a comptime '::')
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
- `@sqrt(x: $T) -> T` — square root (maps to LLVM intrinsic)
- `@sin(x: $T) -> T` — sine (maps to LLVM intrinsic)
- `@cos(x: $T) -> T` — cosine (maps to LLVM intrinsic)
- `@floor(x: $T) -> T` — floor (maps to LLVM intrinsic)

### Memory
- `malloc(size: i64) -> *void` — allocate `size` bytes of heap memory
- `free(ptr: *void) -> void` — release a `malloc` allocation
- `memcpy(dst: *void, src: *void, size: i64) -> *void` — copy `size` bytes from `src` to `dst`
- `memset(dst: *void, val: i64, size: i64) -> void` — fill `size` bytes at `dst` with `val`
- `size_of($T: Type) -> i64` — size of type `T` in bytes
- `align_of($T: Type) -> i64` — alignment of type `T` in bytes
- `@volatile_load($T: Type, address: *T) -> T` / `@volatile_store($T: Type, address: *T, value: T)` — one typed access emitted exactly as written: the optimizer may not elide it, duplicate it, fuse it with a neighbour, or move it across another volatile access. For storage whose reads and writes are themselves observable — a memory-mapped device register, a buffer a signal handler touches, memory another process maps. **Volatile is not atomic**: the access carries no memory ordering, orders nothing between threads, and is not guaranteed indivisible; sharing data between threads is `Atomic($T)`'s job (`modules/std/atomic.sx`). `T` is any type with storage — integer, float, bool, pointer, enum, vector, or an aggregate, which moves as a whole rather than field by field. A valueless `T` is a compile error. Both carry the `@` sigil: they are compiler-maintained contracts (§Lexical Structure, The `@` namespace) declared by `modules/std/core.sx`, and the unprefixed spellings are ordinary identifiers a program may bind.

- `@va_start(list: *@VaList)` / `@va_arg($T: Type, list: *@VaList) -> T` / `@va_copy(dst: *@VaList, src: *@VaList)` / `@va_end(list: *@VaList)` — the C-variadic cursor: `@va_start` opens one over the tail arguments of the definition being lowered, `@va_arg` reads the next and advances, `@va_copy` forks a second cursor at the first's position, and `@va_end` closes one. `@VaList` is opaque, owned by the function that declares it, and cannot escape the frame whose tail it reads; `T` is the type the C default argument promotions leave in the slot. A C `va_list` parameter is written by value as `ap: @VaList` in an effective-C signature and passed as the place it names; sx-internal forwarding is `ap: *@VaList`. Full rules under §Variadic Functions, The C-Variadic Tail. All five carry the `@` sigil: they are compiler-maintained contracts (§Lexical Structure, The `@` namespace) declared by `modules/std/core.sx`.

### Type Introspection
- `type_of(val: $T) -> Type` — returns the runtime type tag of a value
- `type_name($T: Type) -> string` — returns the name of type `T` as a string (e.g., `"Point"`)
- `struct_field_count($T: Type) -> i64` — the number of fields of a struct/tuple (or arms of an untagged union). Scalars and other fieldless types fold to 0 (a leaf, so generic walkers can gate on it). An enum argument is a compile error naming `variant_count`; arrays/vectors are rejected — their lengths/lanes read as `.len` on the value.
- The whole field family — `struct_field_name` / `struct_field_type` / `struct_field_offset` / `variant_name` / `variant_type` — also accepts a **runtime `Type` value**: reads go through lazily-emitted master-index tables (`__sx_member_name_ptrs` / `__sx_member_type_ptrs` / `__sx_field_offset_ptrs`, `[N x ptr]` keyed by the tag → per-type arrays), emitted only when a dynamic call site exists. At runtime the kind gates do not apply, and an index ≥ the member count is **undefined behavior** (in-bounds GEP — the caller gates on the counts, exactly like the static per-type arrays). Offsets answer per kind: struct/tuple members give their field offset; a tagged union gives its PAYLOAD offset (the header size — the same for every variant); an untagged union's arms all give 0. `struct_field_value(av, i)` / `variant_payload(av, i)` on an **`any` receiver** compose these tables directly: the result is the view `{struct_field_type(tag, i), av.data + struct_field_offset(tag, i)}` — reads go through the view, so nested access chains by repeated calls with no copies, and a wrong-kind tag or out-of-range index is the same UB as the raw table reads. Arbitrary-width int fields read through an any-receiver view carry their TRUE (non-builtin) tag — dispatch consumers (`x.(struct_field_type(T,i))`) monomorphize exactly; the `{}` formatter's builtin-width int arm does not match such a tag and prints `<?>`. `type_info(tp)` likewise accepts a runtime `Type`: it loads the type's constant record from `__sx_type_infos` (one record per type, bytes matching the `TypeInfo` layout; requires `modules/std/meta.sx` in scope, which the compile-time form already does) — kind-first dispatch (`match type_info(tp) { case .struct: |si| { … } }`) works identically on compile-time and runtime `Type`s.
- `struct_field_name($T: Type, idx: i64) -> string` — the name of the `idx`-th field of a struct/tuple (positional tuple elements have no name → `""`). Kind-gated like `struct_field_count`.
- `struct_field_type($T: Type, idx: i64) -> Type` — the `idx`-th field's type. Kind-gated; also resolves in type position.
- `struct_field_value(s: $T, idx: i64) -> any` — the `idx`-th field of a struct/tuple VALUE as an `any` VIEW: `{field type tag, pointer to the field inside `s`}` — an interior pointer, not a copy. For an addressable receiver the view borrows the struct's own storage (mutations of the struct stay visible through a live view); an rvalue receiver spills to a frame temp first. The view is valid only while the receiver's storage lives. Arrays/vectors/slices are rejected — index natively (`v[i]`, typed). Enum values are rejected — use `variant_payload`.
- `variant_count($E: Type) -> i64` / `variant_name($E: Type, idx: i64) -> string` / `variant_type($E: Type, idx: i64) -> Type` — the enum / tagged-union duals: variant count, the `idx`-th variant's name, and its payload type. A struct/tuple argument is a compile error naming the `struct_field_*` builtin.
- `variant_payload(u: $E, idx: i64) -> any` — the live payload of a tagged-union VALUE at variant index `idx`, as an `any` VIEW of the payload area (same borrow rules as `struct_field_value`).
- `any_element(av: any, elem: Type, idx: i64) -> any` — element view into an array/vector held by `av`: pure stride math, `{elem, raw_any_data(av) + idx * size_of(elem)}`. `elem` may be a compile-time type (the size folds to a constant) or a runtime `Type` (the size reads the runtime table). Bounds are the caller's responsibility (same OOB rule as the field family); vector lanes are packed, so the same stride walks both arrays and vectors.
- `raw_any_data(av: any) -> *void` / `raw_make_any(tp: Type, data: *void) -> any` — the raw layer over the `any` view's two words. The `{tag, data}` layout itself stays private; these are the stable contract, and `av.(@Any)` retrieves both words as one `{data, type_id}` pair (see Raw-view retrieval, §Postfix Cast). `raw_make_any` is UNCHECKED at runtime — the caller asserts `data` points at a live, aligned value of `tp` covering `size_of(tp)` bytes — but a non-pointer `data` argument is a compile error. Three sharp edges: **tags are per-build values** (a serializer writes type names and re-resolves on load — never raw tags); **byte copies through the data pointer are shallow** (interior pointers — string/slice data, nested views — are not followed; a deep copy walks `type_info`); **a view carries no lifetime** (assembling or copying a view never transfers or extends ownership of the referent).
- `variant_value($E: Type, idx: i64) -> i64` — the `idx`-th variant's integer value: its explicit value / explicit tag when declared (custom values, flags, tagged-union tags), else its ordinal. Works on enums AND tagged unions. A runtime `Type` reads the `__sx_member_value_ptrs` tables (same master-index pattern as the name/type/offset families, same `memberValue` source as the static fold).
- `variant_index($E: Type, val: E) -> i64` — a value's sequential variant ordinal (the inverse of `variant_value`; explicit values reverse-map, an unmatched tag answers itself — the identity seed). With a **runtime** `Type` the value travels as an `any` view: `variant_index(t, av)` reads the tag word through the view (a signed backing sign-extends; a layout-struct union loads its narrow tag slot, not the wider header) and scans the value table — a typed second argument is impossible there and is a compile error.
- `is_flags($T: Type) -> bool` — returns `true` if `T` is a flags enum (declared with `@flags`)
- `vector_lanes($T: Type) -> i64` — a vector's lane count (`vector_lanes(@Vector(3, f32))` is `3`). The one vector length the flat size tables cannot answer: a vector's ABI size is pow2-rounded, so `size_of / element size` over-counts (3 lanes read as 4). A static non-vector argument is a compile error (`.len` / `struct_field_count` are the right spellings elsewhere); a runtime `Type` reads the `__sx_vector_lanes` table, where a non-vector tag answers 0 (kind discrimination is `type_info`'s job, like the count tables).
- `type_eq($A: Type, $B: Type) -> bool` — structural TypeId equality (`type_eq(i64, i64)` is `true`, distinct shapes are `false`); folds at compile time, so `inline if type_eq(...)` is comptime-decidable

Signedness is asked with `type is unsigned` (§The `is` Operator), which the `{}`
formatter reads to print unsigned integers as unsigned decimal; it lowers to
`__sx_type_is_unsigned` over a runtime `Type` and folds outright over a static
one.

The type-only builtins — `size_of`, `align_of`, `struct_field_count`, `variant_count`, `type_name`, `type_eq`, `is_flags` — strictly require a **type** argument. A spelled type (`i64`, `*u8`, `Point`) or a generic type parameter (`T`) is accepted by all of them. A runtime `Type` value (`type_of(x)`, a `[]Type` element, a `Type`-typed local) is supported by the whole scalar family: `type_name`, plus `size_of`, `align_of`, `struct_field_count`, `variant_count`, `is_flags`, and `vector_lanes` — each reads a lazily-emitted, tag-indexed table (`__sx_type_sizes` / `_aligns` / `_struct_field_counts` / `_variant_counts` / `_flag_bits` / `_vector_lanes`; built only when a dynamic call site exists, so programs without runtime reflection carry no tables) — and `type_eq`, which compares tags directly (no table). At runtime the kind gates do not apply: a wrong-kind tag reads its table row (0 for the other family) — runtime kind discrimination is `type_info`'s job. Passing a non-Type VALUE (`size_of(6)`, `is_flags(true)`) is a compile-time error — `<builtin> expects a type, got '<type>'` — never a silent reinterpretation of the value's bits as a type.

An `any` is accepted because it can hold either a value or a `Type`. `type_name` consults the `any`'s runtime type-tag, not its payload: an `any` holding a *value* reports the type **of that value** (`av : any = 6` → `type_name(av)` is `"i64"`), while an `any` holding a *`Type` value* (e.g. `type_of(x)` stored in an `any`) names the **held type**. This is the same tag the `{}` formatter reads, so `print(av)` and `type_name(av)` agree on what `av` is. `is` reads that tag rather than peeling it: `at is type` is true for a `Type`-holding `any`, and classifying the held type unboxes first (`at.(?Type)`).

### Type Conversion
- Conversions are implicit, or they name the type with `expr.(T)` / `expr.(T, alloc)`. Dest-inferred `xx expr` is the same classifier for application code; the stdlib never writes `xx`. There is no `cast(Type, expr)` builtin; runtime-typed data travels as `any` and comes back through the assertion forms.

### Vectors
- `@Vector($N: int, $T: Type) -> Type` — returns an LLVM vector type of `N` elements of type `T`

### Arrays
- `@Array($N: int, $T: Type) -> Type` — returns the fixed array type `[N]T`

### Slices
- `@Slice($T: Type, $Len: Type) -> Type` — returns the fat-pointer type `{ptr, Len}`; `@Slice(T, i64)` is `[]T`

---

## 8. Compile-time Evaluation

### `@run` Directive

`@run expr` evaluates `expr` at compile time using lazy JIT execution. It can appear in two contexts:

**Compile-time constants** — bind a compile-time value to a name:
```sx
compute :: (x: i32) -> i32 { x * x; }
x :: @run compute(5);   // x = 25, evaluated at compile time
```

Comptime globals are resolved lazily: the JIT executes only when the value is first referenced during code generation. Chained dependencies are resolved automatically.

**Side effects** — execute code at compile time for its side effects:
```sx
@run print("compiling...");
```

`@run` evaluates at compile time at every site — a module constant, a
top-level side effect, and a body-local binding. The value the evaluator
produces is the program's value (a struct, array, or optional is baked the
same way a scalar is). If the evaluator cannot complete it, or the result
cannot be serialized as a constant, the compile fails
(`error: comptime init of '…' failed: …`). There is no runtime-call
consolation. An operation the evaluator does not implement is named
(`the compile-time evaluator has no implementation of '…'`).

### `@error`

`@error("message");` emits `message` as a compile-time error and halts
compilation. It is valid as a top-level item or a statement, and it is the
compile-time rejection spelling — a compiler-maintained contract, sibling of
`@panic`.

The directive fires only when it is reached in **live** code, at every
level where code goes dead:

- The comptime conditional flatten pass drops non-taken module-scope
  `inline if` arms before the directive can fire — the idiomatic way to
  reject an unsupported target in an exhaustive `inline if OS`/`inline if
  ARCH` without a silent fallback:

```sx
inline match OS {
    case .macos: errno_location :: () -> *i32 extern libc "__error";
    case .linux: errno_location :: () -> *i32 extern libc "__errno_location";
    else:        @error("errno_location: unsupported target — add its libc symbol.");
}
```

- Monomorphization prunes non-taken `inline match T` arms per instance —
  the same discipline rejects an unsupported TYPE in generic code, firing
  only for the instantiations that actually select the arm:

```sx
free :: ufcs (x: $T, a: Allocator = context.allocator) {
    inline match T {
        case closure:  { ... }
        case slice:    a.dealloc_bytes(xx x.ptr);
        else:          @error("free expects a closure or a slice");
    }
}
```

- A bare top-level `@error("...");` always fires.

When a surviving `@error` fires inside a monomorphized body, the diagnostic
anchors at the OUTERMOST instantiation call site — the user call that
forced the instantiation — with the directive's own location attached as a
note. A library-internal anchor would read like a run-time panic's stack
bottom; the offending code is the caller's.

The message must be a string literal (it is consumed at compile time).

### `@insert` Directive

`@insert expr;` evaluates `expr` at compile time to obtain a string, then parses and compiles that string as inline code at the insertion point.

```sx
generate :: () -> string {
    return "print(\"hello from the other side\");";
}

main :: () {
    @insert @run generate();
    // equivalent to: print("hello from the other side");
}
```

The expression must evaluate to a string of valid `sx` statements (including
semicolons). If the evaluator cannot produce a string, the result is not a
string, or the string is not valid sx, the compile fails at the `@insert`.
The statements are parsed and compiled in the same scope as the `@insert`
site. Variables created by one `@insert` are visible to subsequent `@insert`
directives in the same function.

A `::` whose initializer is a call is an immutable runtime binding. Compile-time evaluation of a call is `@run`:

```sx
response :: format(...);       // immutable, runtime
response :: @run format(...);  // compile time
response := format(...);       // mutable, runtime
```

### `@is_comptime()`

`@is_comptime() -> bool` answers which machine is running the code: `true` under
the comptime evaluator, `false` in compiled code. One lowered body serves both
stages, so the answer is the backend's rather than a fold — in the binary the
call folds to `false` and a `if @is_comptime() { … }` branch is dead. It carries
the `@` sigil: a compiler-maintained contract (§Lexical Structure, The `@`
namespace) declared by `modules/std/core.sx`, which uses it in `@panic` to exit
the compiler where a compiled panic aborts.

### Build Configuration

The `BuildOptions` struct (from `modules/build.sx`) provides compile-time build configuration via `@run`. Methods on `BuildOptions` are compiler builtins intercepted during compilation — they have no runtime cost.

```sx
@import "modules/build.sx";

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
@run configure_build();
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

### `@import` Directive

The `@import` directive brings declarations from another `.sx` file or directory into the current file.

**Flat import** — splices all declarations from the imported file into the current scope:
```sx
@import "modules/std/fs.sx";
```

**Namespaced import** — wraps all declarations under a namespace name:
```sx
std :: @import "modules/std.sx";
```

**Directory import** — when the path refers to a directory, all `.sx` files in that directory are aggregated into a single module:
```sx
pkg :: @import "modules/math";   // namespaced — all .sx files merged under pkg
@import "modules/math";          // flat — all declarations spliced into scope
```

Directory imports scan only the top level of the specified directory (non-recursive). Files are processed in alphabetical order for deterministic builds. Files within the directory may `@import` each other or external files.

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
r :: @import "rich.sx";        // an ordinary declaration of `r`

// main.sx
@import "facade.sx";           // flat import carries facade's aliases

main :: () {
    r.helper();                // plain fn through the carried alias
    t := r.Thing.init();       // static method
    x : r.Thing = t;           // type annotation
    n := r.LIMIT;              // module const
    c := r.Color.green;        // enum variant
    b := r.Box(i64){ item = 3 };  // generic struct head
}
```

Every qualified shape resolves through a carried alias exactly as through a
directly-declared one: function calls, `alias.Type.method()`, type
annotations, enum variants, module constants, generic struct heads, **open
sets** (in an annotation, as a type argument, and as a bound head), and
**bound heads** generally.

Collision rules mirror ordinary declarations:

- **Own wins** — a file's own declaration of a name (including its own
  `ns :: @import`) shadows any same-named alias carried from a flat import.
- **Ambiguity** — two direct flat imports each carrying a distinct alias of
  the same name make a bare use of that alias an error; declare the alias
  locally to disambiguate.
- **One level only** — carry does not chain: a flat import of a flat import
  does not surface the inner file's aliases. (The bare `alias.fn()` call path
  does not enforce this gate.)

`@import c { ... }` aliases (`tc :: @import c { ... }`) carry the same way.

### Visibility: `private`

`private` restricts a name to its declaring **source file**. It is a prefix on
identifier-headed top-level declarations and on a named struct declaration's
fields:

```sx
private Helper :: (x: i64) -> i64 { return x * 2; }
private State  :: struct { n: i64; }
private LIMIT  :: 21;
private counter : i64 = 0;
private dep    :: @import "dependency.sx";
File    :: struct { private fd: i64 = -1; }
```

It applies to functions and type functions, structs/enums/unions/error sets,
constraints and interfaces, constants and globals, aliases (including UFCS
aliases), named
imports, `@library` handles, runtime classes, `extern`/`export` declarations,
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
- **A public same-file alias may expose a private declaration**
  (`Public :: PrivateImpl;`) — resolution follows the alias in its author
  file, where the private name is legal.
- **Privacy authority is the exact declaring source file**, not a directory
  import: two files aggregated by a directory import cannot use each other's
  private names.
- **A private field is a name.** `private fd: i64 = -1;` on a struct field is
  file-local. Another file cannot mention it (`x.fd`, `x.fd = …`,
  `File{ fd = 3 }`, `.{ fd = 3 }`, `.variant{ fd = 3 }`, `[File_const.fd]T`),
  and a mention includes `x.fd(…)` when `fd` is a callable field. Another file
  can still produce a value without naming the field: a positional init
  (`File{ 3 }`), `File{}` defaults, `File{ --- }` / `---`, and copy assignment.
  A value spread (`f(..x)`), an index (`x[0]`), and reflection (`print("{}", x)`,
  `struct_field_value`) read the layout rather than the name, so none is a
  mention. Same-file methods, free functions, and literals may name the field.
  A method whose name matches a private field still dispatches: `x.fd(…)` is a
  mention only when `fd` resolves to a field.
  Authority is the source file that declares the struct type.
- **A promoted union member answers to its payload's file.** A union whose
  variant is a named struct promotes that struct's members; a private one is
  nameable only from the file declaring the payload.
- **A `@using` promotion carries the base's authority.** A struct that promotes
  a base with a private field gains the field's storage, not the right to name
  it: only the base's declaring file may.

Placement rules — `private` is allowed on identifier-headed module-scope
declarations and on the fields of a NAMED struct declaration (a generic
template included). It is rejected on: anonymous struct fields (a field's
inline `struct { … }`, a type function's returned `struct { … }`), locals,
parameters, union and runtime-class fields, enum cases and error tags,
struct / `constraint` / `interface` / `impl` methods and requirements, flat
`@import`, `impl` blocks,
`@context_extend`, `@using`, standalone `@run`, global `asm`, and `@framework`.
Top-level `inline if` branches and `inline for` bodies MAY declare private
globals (their statements are module-scope after comptime flattening); function
and method bodies may not.

`` `private `` (backtick raw identifier) remains a legal name, and the
`.private` member spelling remains legal after a dot.

### Import Resolution

- Imports are resolved after parsing and before code generation.
- Paths are resolved in three tiers, first hit wins:
  1. relative to the directory of the file containing the `@import`;
  2. relative to the working directory (cwd);
  3. relative to each stdlib search path — the `library/` directory discovered
     from the compiler binary's location (dev: `zig-out/bin/sx` →
     `<repo>/library`; install: `<prefix>/library`), overridable with the
     `SX_STDLIB_PATH` environment variable. This is how
     `@import "modules/std.sx"` resolves from any project.
- If the path resolves to a file, it is imported directly. If it resolves to a directory, all `.sx` files in that directory are aggregated.
- Nested imports are supported (imported files may themselves contain `@import`).
- Circular imports are detected and silently skipped (each file is imported at most once).
- Generic functions in namespaced imports are supported (e.g., `std.mul(5, 2)` where `mul` is generic).

**Example:** Given this project layout:
```
project/
  modules/std.sx
  modules/math/
    math.sx
    vector3.sx    ← contains: @import "modules/std.sx";
  main.sx         ← contains: @import "modules/std.sx";
```
When compiling from `project/`, both `main.sx` and `modules/math/vector3.sx` can use `@import "modules/std.sx"` — the root file resolves it relative to its own directory, and the nested file falls back to resolving relative to cwd.

### Intra-module References

Functions within a namespaced import can call each other without the namespace prefix. When generating code for a namespaced module, unresolved function names are automatically tried with the namespace prefix.

### Example

```sx
// modules/std/json.sx
parse :: (text: string) -> ?JsonValue { ... }

// main.sx
std :: @import "modules/std.sx";
@import "modules/std/json.sx";

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
                      interface; plus the namespace tail: mem / xml / log /
                      fs / process / socket / json / cli / hash / test ::
                      @import "modules/std/<m>.sx"
modules/std/          mem.sx (CAllocator, GPA, Arena, TrackingAllocator),
                      fs.sx, process.sx, socket.sx, json.sx, cli.sx, hash.sx,
                      xml.sx, log.sx, trace.sx, test.sx
modules/ffi/          objc.sx, objc_block.sx, sdl3.sx, opengl.sx, raylib.sx,
                      stb.sx, stb_truetype.sx, wasm.sx
modules/math/         scalar.sx, vector2.sx, matrix44.sx — import the
                      directory: @import "modules/math"
modules/build.sx      BuildOptions — compile-time build configuration (§10.5)
modules/platform/     bundle.sx, uikit.sx, android.sx, sdl3.sx, ... —
                      windowing/bundling backends
modules/gpu/, modules/ui/   GPU layer + retained UI toolkit
```

`@import "modules/std.sx"` gives every prelude name bare, plus `mem.GPA`,
`json.parse`, `fs.exists`, `hash.sha256_hex`, `log.warn`, ... through the
carried namespace tail (see Namespace Alias Carry). Direct file imports
(`@import "modules/std/json.sx"`) remain available for bare access.

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

Users opt in **explicitly** from their own `@run` block:

```sx
@import "modules/build.sx";
@import "modules/platform/bundle.sx";

@run {
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
| `jni_main_count() / jni_main_runtime_path_at(i) / jni_main_java_source_at(i)` | read | `main = true` emissions for the APK bundler |
| `asset_dir_count() / asset_dir_src_at(i) / asset_dir_dest_at(i)` | read | iterate registered asset trees |

Returned strings are `""` when unset; integer counts are `0`. Accessors
that read after-the-fact (`binary_path`, `bundle_path`, etc.) return
the value that was either set in `@run` or forwarded from a CLI flag.

### `fs.sx` and `process.sx` stdlib modules

The bundler is implemented in sx; its calls into `fs.sx` / `process.sx`
work both at runtime through the dynamic linker and at `@run` / post-link
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
   - `NativeActivity` shape when no `main = true` is declared.
   - `main = true` Activity shape with `android:name="<runtime_path_with_dots>"` + `android:hasCode="true"` otherwise.
5. **Compile `main = true` Java sources** — write each entry's `java_source` to `<stage>/java/<pkg>/<Cls>.java`, run `javac --release 11 -classpath <android.jar>` to `<stage>/classes/`, run `d8 --release --lib <android.jar> --output <stage>` to produce `<stage>/classes.dex`. `javac` discovered via `$JAVA_HOME/bin/javac` then `command -v javac`.
6. **`aapt2 link -I <android.jar> --manifest <m> -o <unaligned>`**.
7. **Append archives** — `zip -q -r <unaligned> lib/`, then `zip -q <unaligned> classes.dex` (if dex was produced), then `zip` each registered asset dir at its `dest` path.
8. **`zipalign -f 4 <unaligned> <aligned>`**.
9. **Debug keystore** — `keytool -genkeypair -keystore <path>` on first use; defaults match Android Studio (`androiddebugkey` alias, password `android`).
10. **`apksigner sign --ks <ks> --ks-pass pass:android --key-pass pass:android --ks-key-alias androiddebugkey --out <apk> <aligned>`**.
11. Clean intermediates (keep `<apk>.stage/` for inspection if it lasts the build).

---

## 11. Program Structure

A program is a sequence of top-level declarations and `@import` directives. Execution begins at `main`.

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

This section is the canonical surface reference.

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
  function-type slots with an empty `!` do **not** warn. A body that
  forwards (`return callee(...)`) or `try`s an opaque channel — an interface
  or UFCS method, a closure slot, a checked assertion — carries a
  load-bearing `!` and does not warn either.
- Warnings are reported on a **successful** compile too, before the program
  runs; a warnings-only build still exits 0.

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

v := foo() catch |e| {
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

- inside a `??` chain → the next `??` operand;
- otherwise → the function's error return (propagation, like Zig's `try`).

```sx
v       := try parse_digit(s);          // propagate on failure
v2, n   := try parse(s);                // multi-value
try must_init();                        // statement form, discard values
v3      := try foo() ?? try bar();      // chain: foo fails → try bar
return try transform(try parse(s));     // nests in any value position
```

`try` works in any value-producing position (argument, struct/array literal,
`if`-condition); evaluation is left-to-right and short-circuits on the first
failure, so no partial aggregate is ever built. `try`'s body never binds the
tag — use `catch` for that.

### `catch`

Expression form. Handles the error inline. The binding sits in **pipes**
(`catch |e|`) — like a match-arm payload capture — and is **optional**. Three
shapes, disambiguated by the token after `catch`:

| Form | Binding | Body |
|---|---|---|
| `catch { ... }` | none (tag ignored) | block — braces required |
| `catch \|e\| { ... }` | `e` | block |
| `catch \|e\| EXPR` | `e` | bare expression (no braces) |

Dispatching on the tag is the bare-expression shape with a `match` over the
binding: `catch |e| match e { case ... }`.

A bare binding (`catch e { }`) is a parse error with a hint to write the
pipes.

```sx
v := parse_digit(s) catch |e| {
  log.warn("bad input: {}", e);
  return default;                       // noreturn body
};

v := parse_digit(s) catch |e| compute_fallback(e);   // value-producing body

v, n := parse(s) catch |e| {
  log.warn("parse failed: {}", e);
  .{0, 0}                               // tuple body for a multi-value failable
};

v := parse(s) catch |e| match e {       // dispatch on the tag
  case .Empty:    0;
  case .BadDigit: -1;
  else:           raise e;
};

v := (try foo() ?? try boo()) catch |e| { return 0; };  // catch over a `??` chain
```

**Body type rule.** The body (block-as-expression) must produce the failable's
success tuple type, or be `noreturn` (the `noreturn` arm subsumes `return` /
`raise` / `break` / `continue` / `unreachable` / noreturn calls). For a
multi-value failable the body must produce a tuple of matching arity and
element types. A non-diverging body that produces no value is a compile error.

**Pure-failable result.** A pure failable (`-> !E`) has no value channel, so
its `catch` yields nothing: it stands as a statement, and binding it is a
compile error in every body shape — there is nothing to bind. The result cannot
initialize `:=`, a typed mutable declaration (`name: T =`), or a body-local
constant declaration (`name ::` or `name: T :`).

```sx
must_init() catch |e| { log.warn("{}", e); };  // OK — statement
x := must_init() catch |e| { 0 };              // ERROR: nothing to bind
```

Give the callee a value channel (`-> (T, !E)`) where the handled expression
must produce a result.

### `??` (default / chain)

Expression form — the operator that defaults an optional (§2 Optional Types)
also defaults a failable. On a failable LHS the RHS shape decides the result:

- **plain value of the success type** — terminate; the chain becomes
  non-failable; on LHS failure the result is the RHS value (LHS tag discarded);
- **`try EXPR`** — chain; on LHS failure, attempt the RHS (its `try` defines
  the next fallback target);
- **bare failable** — allowed only when its error path hits a marker
  downstream (see the path-marker rule).

`??` is **right-associative**; operands are attempted left-to-right with
short-circuit.

```sx
v := parse_digit(s) ?? 0;                        // value terminator → non-failable
v := try foo() ?? try boo();                     // chain, propagate if both fail
v := foo() ?? boo() ?? 0;                        // bare operands, 0 absorbs all
v, n := parse_pair(s) ?? .{0, 0};                // tuple terminator (multi-value)
```

A **void** failable (`-> !`) rejects a plain-value RHS (no success type to
fall back to); `must_init() ?? must_other()` (chain) and `must_init() catch {}`
(absorb) are the legal forms.

`or` / `and` are logical operators over booleans; a failable operand is a type
error there (`parse(s) or 0` names no bool).

### Path-marker rule

A failable expression `X` may appear **bare** (no `try`) iff its error path
passes through at least one explicit marker before reaching the function
boundary. The markers are: a `try` keyword, a `catch` handler, a `??` value
terminator, or a destructure binding (`v, err := X`). Otherwise `try` (or one
of the other markers directly on `X`) is required.

```sx
a := parse(s) ?? 0;          // OK — terminator on the path
a := parse(s) catch |e| {...}; // OK — catch marks
v, err := failable();        // OK — destructure marks
a := try foo() ?? try boo(); // OK — each try marks its own exit

a := foo() ?? boo();         // ERROR — no marker on the way to the function
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
- A contextual **`.X` shorthand** is accepted wherever the destination supplies
  a named set — declaration, argument, field init, `raise` / `return` into a
  channel, comparison against an error-set operand. It names the same tag as
  `error.X` and is membership-checked identically, exactly as an enum literal
  types itself from an enum destination. Against a bare `!` channel it mints
  into the inferred set, like `error.X`.
- An error-set **value** crossing into a differently-typed named set follows
  the same subset rule as the error channel: `A` coerces to `B` only if
  `A ⊆ B`, in declaration, argument, and field-init positions alike. Each
  escaping tag is diagnosed; `xx` forces a narrowing.
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

Value slots may be discarded (`_, n := parse(s) catch |e| { return; }`). The
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
  onfail |e| { log.warn("init failed for {}: {}", path, e); sys_close(h); }
  ...
}
```

**Ordering with `defer`.** Both run in reverse declaration order, interleaved.
On block-error exit both kinds run (newest-first); on block-success exit only
`defer`s run.

**Restrictions.** `raise` / `try` / `return` / `break` / `continue` are
rejected inside an `onfail` (and a `defer`) body — a cleanup body has no
control-transfer target. A failable call in cleanup must be absorbed locally
(`close(h) catch {};` or `flush(buf) ?? 0`). `onfail` outside a failable
function, or at top level, is rejected.

### Closures with `!`

- **Explicit annotation required.** A closure literal's value type is inferred
  as today, but if its body raises or `try`-escapes, the `!` channel is **not**
  inferred — declare it (`|x: i32| -> (i32, !) { ... }`). This keeps
  adding a `raise` from silently changing a closure's type.
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
- **Mode.** On by default in debug; release no-ops the push points.
  **Comptime (`@run`) is always traced.**
- **Formatting** lives in `library/modules/trace.sx` (`trace.print_current()`),
  rendering `func at file:line:col` per frame plus the source line and a `^`
  caret. DWARF line-info is emitted (debug, strippable) so `lldb` / `gdb`
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
end             = ';' | EOF   // §1 Spacing and terminators: a line break is
                  // ordinary space; EOF ends the last declaration of a file
top_level       = decl | import_decl | context_extend
import_decl     = '@import' STRING end
                | IDENT '::' '@import' STRING end
context_extend  = '@context_extend' IDENT ':' type '=' expr end
decl            = const_decl | var_decl | fn_decl | at_fn_decl | enum_decl | struct_decl | union_decl | error_decl
error_decl      = IDENT '::' 'error' '{' IDENT (',' IDENT)* ','? '}' end
const_decl      = IDENT '::' expr end
                | IDENT ':' type ':' expr end
                | IDENT '::' type 'intrinsic' end
at_fn_decl      = AT_IDENT '::' '(' params? ')' ('->' ret_type)? end
                  // a compiler-implemented function; the sigil is the marker,
                  // so no keyword, body, ABI, or linkage follows
var_decl        = IDENT ':=' expr end
                | IDENT ':' type '=' expr end
                | IDENT ':' type end
                | IDENT ':' type 'extern' linkage_tail end
linkage_tail    = IDENT? STRING?    // `[LIB] ["csym"]`; the declaration's
                  // `end` closes the tail
fn_decl         = IDENT '::' '(' params? ')' ('->' ret_type)? block
                | IDENT '::' block
ret_type        = type ('!' IDENT?)?    // trailing `!` = failable; channel as last `-> (…, !)` slot
enum_decl       = IDENT '::' 'enum' '{' (IDENT ';'?)* '}'
struct_decl     = IDENT '::' 'struct' '{' struct_members '}'
struct_members  = (struct_member (';' struct_member)* ';'? )?
                  // members are `;`-separated; a trailing `;` before `}` is optional
struct_member   = field_group | '@using' IDENT
field_group     = IDENT (',' IDENT)* ':' type ('=' expr)?
union_decl      = IDENT '::' 'union' '{' union_members '}'
union_members   = (union_member (';' union_member)* ';'? )?
union_member    = IDENT ':' type | 'struct' '{' struct_members '}'
params          = param (',' param)* (',' c_tail)? ','?
                | c_tail ','?
c_tail          = '..'              // the C-variadic tail; binds no name and no
                                    // type, is the last entry, and needs an
                                    // effective-C signature (`abi(.c)`,
                                    // `export`, or `extern`)
param           = IDENT ':' type ('=' expr)?
block           = '{' stmt* '}'     // the LAST expr may drop `end`; written or
                  // not, that expr is the block's value — `;` only separates
stmt            = decl | assignment end | multi_assign end | return_stmt | defer_stmt | insert_stmt
                | push_stmt | break_stmt | continue_stmt | raise_stmt | onfail_stmt
                | scope_stmt | expr end
scope_stmt      = block             // a statement, so it never continues a postfix chain
return_stmt     = 'return' expr? end
break_stmt      = 'break' end
continue_stmt   = 'continue' end
raise_stmt      = 'raise' expr end
onfail_stmt     = 'onfail' ('|' IDENT '|')? (block | expr end)
defer_stmt      = 'defer' expr end
insert_stmt     = '@insert' expr end
push_stmt       = 'push' expr block
assignment      = lvalue ('=' | '+=' | '-=' | '*=' | '/=') expr
multi_assign    = lvalue (',' lvalue)+ '=' expr (',' expr)+
lvalue          = IDENT | postfix '.' IDENT
expr            = if_expr | match_expr | while_expr | for_expr | closure | binary
while_expr      = 'while' expr block
for_expr        = 'for' [for_capture (',' for_capture)* 'in'] for_iter (',' for_iter)* (block | '=>' stmt)
for_iter        = expr [range_op [expr]]
range_op        = '..' | '..=' | '..<' | '<..' | '<..=' | '<..<' | '=..' | '=..=' | '=..<'
for_capture     = ['*'] IDENT [':' type]   // the type is the ELEMENT type
binary          = binop_expr ('??' binary)?         // `??` is right-associative
binop_expr      = catch_expr (binop catch_expr)*
catch_expr      = unary ('catch' ('|' IDENT '|')? (block | match_expr | unary))?
unary           = ('-' | '--' | '*' | '!' | '~' | 'xx' | 'try') unary | postfix
                  // right-recursive, so prefixes stack (`xx try f()`, `!!ok`)
postfix         = primary ('(' args? ')' | '[' expr ']' | '.' IDENT | '?!')* juxt? self_block?
juxt            = brace_group       // `expr { … }` — two adjacent expressions;
                  // types settle construction vs trailing block. An if / match /
                  // for / while value, a block, a `.{ … }` primary, and a
                  // juxtaposition itself never take one, and it does not stack
self_block      = '.' '{' ('|' IDENT '|')? stmt* '}'   // writes into the value
brace_group     = '{' ('|' params? '|')? brace_item* '}'
brace_item      = IDENT '=' expr (';' | ',' | &'}')    // a field init or a store
                | stmt                                 // `,` ends an item here too
                  // the label is an IDENT — a keyword label is backticked
                  // (`` `push = 7 ``), bare it heads the stmt alternative
primary         = INT | HEX_INT | OCT_INT | BIN_INT | FLOAT | STRING | BOOL | IDENT | '---'
                | '.' IDENT | '.' '{' field_init_list '}'
                | '(' expr ')' | block | '@run' expr    // bare parens = grouping ONLY
field_init_list = field_init (',' field_init)* ','?
field_init      = IDENT '=' expr | IDENT | '..' expr | expr
                  // the label is an IDENT — a keyword label is backticked
                  // (`` `if = 2 ``), bare it heads the expr alternative
if_expr         = 'if' expr 'then' expr ('else' expr)?
                | 'if' expr block ('else' block)?
                  // the 'else' of an if is any 'else' NOT followed by a ':' —
                  // one token of lookahead separates it from an else_arm head
match_expr      = 'match' expr '{' case_arm* else_arm? '}'
                  // the subject is a header expression: the `{` that closes it
                  // opens the arm list, so a named aggregate there is parenthesized
case_arm        = 'case' pattern ':' arm_capture? arm_body
arm_capture     = '|' IDENT '|'         // payload binding — a LONE identifier
arm_body        = 'break' end
                | '=>' expr end         // the last arm's expr may drop `end`
                | stmt*                 // every form ends as a statement does
else_arm        = 'else' ':' stmt*
pattern         = '.' IDENT | INT | BOOL | IDENT
closure         = '|' params? '|' ('->' type)? (expr | block)
args            = expr (',' expr)* ','?
type            = '$' IDENT | 'i32' | 'f32' | 'f64' | 'bool' | 'string'
                | 'any' | 'Type' | '..' type | '[' expr ']' type | IDENT
                | '(' type ')'                               // grouping (bare parens never form a product)
                | '(' fn_type_list? ')' '->' type ('!' IDENT?)?  // function type (params optional; optional error channel)
                | '!' IDENT?                                  // pure failable (`!` / `!Named`)
fn_type_list    = type (',' type)* (',' c_tail)? ','?
                | c_tail ','?       // a C-variadic function type needs `abi(.c)`
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
  use a closure ('x := || …') to capture it"). Capturing enclosing locals is
  the CLOSURE's job — spell it `x := || …` (`:=` + a `|…|` literal), which captures by
  pointer. (Enclosing local consts are rejected too rather than comptime-folded:
  a static nested fn's frame cannot carry them, and the closure spelling captures
  them uniformly.)
- **Operator overloading**: Not shown — presumably no.
- **Top-level expressions**: Are bare expressions allowed at the top level or only declarations?
