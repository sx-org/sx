# Error Handling in sx

A guide to writing fallible code in sx — declaring error sets, raising
errors with payloads, propagating them, handling them, and cleaning up.

---

## The mental model

In sx, errors travel on a **separate channel** from return values, not
wrapped around them. A function that can fail adds a trailing `!` to its
return type:

```sx
parse_digit :: (s: string) -> (i32, !ParseErr) {
  if s.len == 0 raise .Empty;
  if !is_digit(s[0]) raise .BadDigit{s[0]};
  return s[0] - '0';
}
```

The `(i32, !ParseErr)` says "returns an `i32` on success, or a `ParseErr`"
— `ParseErr` being a declared error set (next section). The `!` is one
more slot in sx's normal multi-return: the error rides alongside the
values, it doesn't replace them.

Three things to know up front:

1. **An error belongs to a set.** A member's identity is the pair
   `(set, tag)`, so `ParseErr.Empty` and `IoErr.Empty` are two
   different errors that happen to share a spelling.
2. **You can't ignore an error by accident.** Every failable result
   must be explicitly propagated, handled, or absorbed — the compiler
   rejects code that silently drops an error.
3. **`try` marks every place an error can escape.** Reading the code,
   every point where an error leaves a function is visibly a `try`.

---

## Declaring what can go wrong

### Named sets

A set lists its members like an enum: `;`-separated, each optionally
carrying a payload type.

```sx
ParseErr :: error {
  Empty;                                 // no payload
  BadDigit: u8;                          // one scalar
  Overflow: struct { at: i64; got: u64 } // a struct
};
```

Use the set in the signature and the contract is fixed:

```sx
parse_int :: (s: string) -> (i32, !ParseErr) { ... }
```

A member that isn't in `ParseErr` is a compile error at the `raise`, so a
typo like `.BadDgit` never reaches a caller.

### Inferred sets — just write `!`

A named function may leave its channel to the compiler. Bare `!` is the
merge of the sets its body `try`s and `raise`s that reach that function:

```sx
read_line :: (r: *Reader) -> (string, !) {
  b := try read_byte(r);            // read_byte is `!IoErr` → merges IoErr
  if b == 0 raise ParseErr.Empty;   // static type ParseErr  → merges ParseErr
  return collect(r, b);
}
// read_line's channel is IoErr | ParseErr
```

There is no minting: every member comes from a declared set. The
contribution is the **static type** of what you tried or raised, so
`raise ParseErr.Empty` brings all of `ParseErr` along.

> **Tip:** Use a named set when the error contract is part of your API.
> Use bare `!` for internal helpers where the errors are an
> implementation detail. A function-type slot — a parameter, a field, a
> `Closure`, a lambda — always writes its channel out.

### Composing sets

`|` builds a set from whole sets and from individual members:

```sx
Both :: ParseErr | IoErr;
Soft :: IoErr.Canceled | ParseErr.Empty;
```

A channel can name one member directly — `-> !IoErr.Canceled` promises
that a call fails only by cancellation.

---

## Raising an error

`raise` ends the enclosing failable body — the function or a `try { block }` —
with an error, like `return` ends a function with a value:

```sx
if denominator == 0 raise MathErr.DivByZero;
```

Where the destination channel is already known, the `.Member` shorthand
names it:

```sx
parse_int :: (s: string) -> (i32, !ParseErr) {
  if s.len == 0 raise .Empty;    // resolves in ParseErr
  ...
}
```

Inside an inferred channel — a named function's bare `!` or a
`try { block }` — the channel is what the `raise` is *building*, so there
is nothing to resolve against; qualify the member:

```sx
helper :: () -> ! {
  raise .Empty;              // ERROR — inferred channel
  raise ParseErr.Empty;      // OK
}
```

`.Member` resolves when exactly one member of that name is live in the
destination channel. Where a composition carries two, the shorthand
refuses and the qualified form says which (`raise ParseErr.Empty`,
`case png.Error.Empty:`).

`raise` is a statement — it can't appear inside an expression. Inside a
closure, `raise` ends **that closure**, not the function the closure was
written in.

---

## Payloads

A void member is written bare; a member with a payload carries it in
braces:

```sx
raise .Empty;                       // void
raise .BadDigit{s[0]};              // scalar
raise .Overflow{ at = i, got = v }; // struct
raise .Overflow{};                  // struct — every field takes its default
```

`.BadDigit` without braces and `.BadDigit{}` are both rejected: a member
with a payload needs one, and an empty brace group only makes sense when
the payload is a struct with defaults to fall back on.

The payload is copied by value into the error channel. A static string
placed in a payload stays live for the whole program, so it is safe to
carry one out of the function that raised it.

Read a payload by capturing it in a `match` arm:

```sx
v := parse_int(s) catch |e| match e {
  case .BadDigit: |c| { log.warn("bad byte {}", c); -1 }
  case .Empty:    0;
  else:           raise e;
};
```

---

## Propagating with `try`

When you call a failable function and want its error to bubble up to
*your* caller, prefix the call with `try`:

```sx
two_digits :: (s: string) -> (i32, !) {
  a := try parse_digit(s);        // if this fails, two_digits fails
  b := try parse_digit(s[1..]);
  return a * 10 + b;
}
```

`try parse_digit(s)` means: run it; on success, `a` gets the value; on
failure, `two_digits` returns immediately with that error.

`try` works anywhere a value is expected — arguments, struct fields,
conditions:

```sx
v := combine(try parse(a), try parse(b));      // short-circuits on first failure
cfg := Config{ port = try parse_port(s), host = try parse_host(s) };
if try is_ready(conn) { ... }
```

**The rule:** a failable call must be marked. If you write a bare
failable call with nowhere for its error to go, it's a compile error:

```sx
v := parse_digit(s);          // ERROR: parse_digit can fail — handle it
v := try parse_digit(s);      // OK: propagate
```

This is the heart of sx error handling: **every escape point is a
visible `try`.** You can grep for `try` to find every place your
function can fail out.

---

## `try { block }` — a local boundary

`try` in front of a block turns that block into its own error boundary,
with its own inferred channel. `raise` and inner `try`s inside target
that block rather than the enclosing function, and the block's last
expression is its success value:

```sx
cfg := try {
  f    := try open(path);
  defer close(f);
  text := try read_all(f);
  try parse_config(text)
} catch |e| {
  log.warn("config unreadable ({}), using defaults", e);
  Config.default
};
```

The enclosing function need not be failable at all — the boundary
handles everything raised inside it.

---

## Defaults and chains with `??`

`??` provides a value when a failable call fails, or chains to another
attempt.

### Fall back to a default value

```sx
port := parse_port(s) ?? 8080;     // if parsing fails, port = 8080
```

The error is absorbed; `port` is a plain `i32`.

### Chain attempts — first success wins

```sx
v := try fetch_local(key) ?? try fetch_remote(key);
// try local; if it fails, try remote; if both fail, propagate
```

Each attempt is a `try`; if all fail, the last error propagates (and the
trace records every attempt). Mix in a terminator to never fail:

```sx
v := try fetch_local(key) ?? try fetch_remote(key) ?? default_value;
// try both; fall back to default if both fail — never propagates
```

> `??` is the same operator sx uses for an optional's default. It binds
> looser than `try`, and attempts operands left-to-right.

---

## Handling with `catch`

`catch` handles an error inline and produces a value (or diverts
control). The bound name (`catch |e|`) is the error:

```sx
v := parse_int(s) catch |e| {
  log.warn("bad input '{}': {}", s, e);
  return -1;                       // bail out of the enclosing function
};
```

The catch body either produces a value of the success type, or diverges
(`return`, `raise`, `break`, `continue`, `unreachable`).

`catch` is a `try` fallback of the same class as `??`, and the nearest
fallback wins — so `try foo() catch { 0 }` and `foo() catch { 0 }` are
the same expression.

### Ignore the error

Omit the binding entirely (the body must be braced):

```sx
flush(buf) catch { };              // attempt it; ignore any failure
```

### Dispatch on the member — `catch |e| match e { }`

```sx
v := parse_int(s) catch |e| match e {
  case .Empty:    0;
  case .BadDigit: -1;
  else:           raise e;         // forward the rest
};
```

Covering every member of the channel is exhaustive; `else` is available
either way. The binding keeps its full channel type inside an arm.

### Multi-value catch

If the function returns multiple values, the catch body produces a
tuple:

```sx
v, n := parse_pair(s) catch |e| {
  log.warn("parse failed: {}", e);
  .{0, 0}
};
```

### Comparing errors

Two live errors compare when one channel is a subset of the other;
otherwise the comparison is a type error rather than a quiet `false`.
Comparing against a raw integer never works — an error is not a number.

```sx
if e == .Empty { ... }             // member — tag only
if e1 == e2    { ... }             // tag AND payload
hit := e == .BadDigit{'x'};        // tag AND payload
bad := e == 42;                    // ERROR
```

A `{` directly after an `if` condition opens the body, so a payload
construction there is parenthesized: `if e == (.BadDigit{'x'}) { ... }`.

To ignore payloads, compare discriminants with `@tag`:

```sx
if @tag(e) == .BadDigit { ... }    // any bad digit, whatever the byte
```

`@tag(x)` works on error sets, enums, and tagged unions, and yields the
discriminant — the payload dropped. A discriminant is not something you
can `raise`, and it has no written spelling of its own.

---

## Reading an error

An error value carries the member it was raised with. `.set` is the error
that declares that member, `.name` is the member's spelling, and
`@errorName` composes the two:

```sx
v := ParseErr.BadDigit{'x'};
v.set.name;         // "ParseErr"
v.name;             // "BadDigit"
@errorName(v);      // "ParseErr.BadDigit"
@errorPayload(v);   // the payload as an `any` view — `void` for a void member
```

The set named is the one that interned the member, not the alias you
reached it through: an imported `png.Error.Bad` still answers
`Error.Bad`.

Interpolating with `{}` writes that name plus the payload as the payload
constructs — nothing for a void member, braces around a scalar, the
struct's own braces for a struct — in every build, including release:

```sx
log.warn("parse failed: {}", e);          // → "parse failed: ParseErr.BadDigit{120}"
log.warn("parse failed: {}", @tag(e));    // → "parse failed: ParseErr.BadDigit"
```

`print` and `format` walk a value's `@typeInfo` and write the pieces to a
`Writer`; an error is one arm of that walk, the same path every other
value takes.

To read the members of an error as a type, match its `@typeInfo`:

```sx
match @typeInfo(ParseErr) {
  case .error: |ei| for m in ei.members { print("{}: {}\n", m.name, @typeName(m.payload)); }
  else: {}
}
// Empty: void
// BadDigit: u8
```

`m.tag` is the interned `(owner, name)` pair — the member's identity — so
a composition's `BadDigit` and `ParseErr`'s own carry one tag. `m.owner`,
`m.name`, and `m.payload` are lookups through it.

---

## Cleanup: `defer`

`defer` registers cleanup that runs when the block exits — on every
exit, success or failure.

```sx
process_file :: (path: string) -> ! {
  f := try open(path);
  defer close(f);                  // always close, success or fail
  try process(try read_all(f));
}
```

### "Undo on failure" — when ownership transfers on success

A constructor hands its resource to the caller on success, but must
clean up if a later step fails. Guard the `defer` with an ordinary `if`:

```sx
make_handle :: () -> (Handle, !) {
  h := try sys_open();
  keep := false;
  defer if !keep sys_close(h);     // close unless the handle is handed out

  try configure(h);
  try register(h);
  keep = true;
  return h;                        // success: nothing to close — caller owns h
}
```

If `configure` or `register` fails, `sys_close(h)` runs and the error
propagates. A plain `defer close(h)` here would be a bug: it'd close the
handle you just handed out.

To log the error that ended the block, destructure it and read the
snapshot at exit:

```sx
v, e := attempt();
defer if e != null log.warn("attempt failed: {}", e);
```

### Cleanup that can itself fail

Cleanup routines are often failable too. Inside a `defer` body you can't
`try` or `raise` (cleanup can't propagate — you're already unwinding), so
absorb the error locally:

```sx
defer {
  close(h) catch { };              // ignore a failed close
  flush(buf) catch |fe| { log.warn("flush failed: {}", fe); };
}
```

---

## Passing failable functions around

Two different rules apply, and the difference matters:

- A **value** widens. `try`, `raise`, and `return` accept any error whose
  members all live in the destination channel — `ParseErr ⊆ Both`,
  `IoErr.Canceled ⊆ IoErr`.
- A **slot** is exact. A `Closure` or function-pointer field holds
  exactly the channel it declares.

```sx
Both :: ParseErr | IoErr;

parse :: (s: string) -> (i32, !ParseErr) { ... }
mixed :: (s: string) -> (i32, !)         { ... }   // infers ParseErr | IoErr

slot : Closure((string) -> (i32, !Both));

slot = parse;   // ERROR — `!ParseErr` is not `!Both`, subset or not
slot = mixed;   // OK — mixed's inferred channel IS Both

f :: (s: string) -> (i32, !Both) {
  return parse(s);   // OK — a returned VALUE widens into Both
}
```

There is no adapter behind a slot assignment: the channel matches or the
assignment is rejected. Wrap the callee in a lambda with the slot's
channel when you need to bridge:

```sx
slot = |s: string| -> (i32, !Both) try parse(s);
```

A generic bound written `$F/(string) -> ($R, !)` accepts any failable
callee — it asks for callability, not for a particular set. Naming the
set (`$F/(string) -> ($R, !Both)`) is exact, like a slot.

---

## When something fails: error traces

In debug builds, sx records a **return trace** — the path an error took
from its `raise` site up through every `try` that propagated it. Print
it from a handler:

```sx
v := parse(s) catch |e| {
  log.error("parse failed: {}", e);
  trace.print_current();
  return default;
};
```

```
error return trace (most recent call last):
  parse_digit at parse.sx:12:25
        if !is_digit(c) raise ParseErr.BadDigit{c};
                        ^
  parse_int at parse.sx:34:13
        try parse_digit(s);
        ^
  handle_line at main.sx:21:8
        try parse_int(line);
        ^
```

Traces are on by default in debug builds and compiled out in release.
They cost nothing on the success path. Each frame's location comes from
`Frame` metadata (file/line/col/func) baked in at the trace point — the
trace resolves itself with no debug info. Separately, sx emits standard
DWARF, so `lldb` / `gdb` work on sx binaries too.

---

## `main` and exit codes

`main` may be void or return an integer, and may be failable:

```sx
main :: () { ... }                 // exit 0 on success
main :: () -> u8 { return 42; }    // exit code 42
main :: () -> ! { ... }            // exit 0, or 1 + trace on an unhandled error
main :: () -> (u8, !) { ... }      // exit code on success; 1 on error
```

If a failable `main` exits via an error, sx prints the formatted trace
and the error to stderr and exits with code `1`.

For explicit, shell-friendly exit codes anywhere in the program, call
`process.exit`:

```sx
process :: @import "modules/process.sx";

main :: () -> ! {
  if bad_args process.exit(64);    // EX_USAGE — immediate, bypasses the error system
  try run();
}
```

`process.exit` is a final stop: it does not run `defer` and does not
propagate. Use it for deliberate termination, not for recoverable errors.

---

## I/O errors

The runtime's I/O channel is one set:

```sx
IoErr :: error { Failed; Canceled }
```

`Io.suspend_raw` is `-> !IoErr.Canceled` — it fails only by cancellation,
and its channel says so. `await` is `-> ($R, !IoErr)`: a cancelled future
raises `.Canceled`, a failed one `.Failed`. An async worker is a lambda,
so it writes its channel out:

```sx
f := context.io.async(|| -> (i64, !IoErr) try compute(a, b));
v := try await(f);
```

---

## Patterns

### Resource acquisition

```sx
open_db :: (url: string) -> (Conn, !DbErr) {
  c := try connect(url);
  live := false;
  defer if !live disconnect(c);
  try authenticate(c);
  try select_schema(c);
  live = true;
  return c;                        // caller owns the live connection
}
```

### Selective handling, forward the rest

```sx
load :: (path: string) -> (Data, !) {
  return read(path) catch |e| match e {
    case .NotFound: try read(fallback_path);   // recover one case
    else:           raise e;                   // forward the rest
  };
}
```

### Fallible pipeline

```sx
// every fallible stage is marked at its own call site
n := try normalize(try validate(try parse(s)));
```

### Validate-and-collect

```sx
parse_config :: (src: string) -> (Config, !ParseErr) {
  return Config{
    name = try field(src, "name"),
    port = try field_int(src, "port"),
    host = try field(src, "host"),
  };
  // first failing field short-circuits — no partial Config escapes
}
```

---

## Rules of thumb

- **Add `!` when a function can fail.** Use a named set for public
  contracts, bare `!` for internal helpers; a function-type slot always
  names its channel.
- **`raise` to fail, `try` to propagate, `catch` to handle, `??` to
  fall back.**
- **Every failable call needs a marker** (`try` / `catch` / `??` /
  destructure). If you forget, the compiler tells you exactly where.
- **Put the context in the payload** — a member with a payload carries
  the offending byte, offset, or path with it.
- **`defer` runs on every exit.** For "undo only on failure", guard it
  with an `if` on a success flag.
- **Cleanup can't propagate** — absorb failable cleanup with `catch` /
  `??`.
- **Values widen, slots don't** — a `Closure` field holds exactly the
  channel it declares.
- **Traces are free in release** (compiled out) and automatic in debug.
