# Error Handling in sx

A guide to writing fallible code in sx — raising errors, propagating
them, handling them, and cleaning up.

---

## The mental model

In sx, errors travel on a **separate channel** from return values, not
wrapped around them. A function that can fail adds a trailing `!` to its
return type:

```sx
parse_digit :: (s: string) -> (i32, !) {
  if s.len == 0 raise error.Empty;
  if !is_digit(s[0]) raise error.BadDigit;
  return s[0] - '0';
}
```

The `(i32, !)` says "returns an `i32` on success, or an error." The `!`
is one more slot in sx's normal multi-return — the error rides
alongside the values, it doesn't replace them.

Three things to know up front:

1. **Errors are tags, not data.** `error.BadDigit` is a lightweight
   name (interned to an integer), not a struct with fields. To attach
   context, log it; the tag itself is just an identity.
2. **You can't ignore an error by accident.** Every failable result
   must be explicitly propagated, handled, or absorbed — the compiler
   rejects code that silently drops an error.
3. **`try` marks every place an error can escape.** Reading the code,
   every point where an error leaves a function is visibly a `try`.

---

## Declaring what can go wrong

### Inferred sets — just write `!`

The simplest failable function uses a bare `!`. The compiler figures
out which error tags it can produce by looking at the body:

```sx
read_byte :: (r: *Reader) -> (u8, !) {
  if r.at_end raise error.Eof;       // mints error.Eof on use
  return r.next();
}
```

Callers see `read_byte`'s error type as exactly the set of tags it can
raise — here, `{ Eof }`.

### Named sets — when you want an explicit contract

For a stable, documented error contract, declare a named set and use it
in the signature:

```sx
ParseErr :: error { Empty, BadDigit, Overflow };

parse_int :: (s: string) -> (i32, !ParseErr) {
  if s.len == 0   raise error.Empty;
  if overflowed   raise error.Overflow;
  ...
}
```

With a named set, `raise error.X` is checked against the declaration —
a typo like `error.BadDgit` is a compile error, because `BadDgit` isn't
in `ParseErr`.

> **Tip:** Use a named set when the error contract is part of your API.
> Use bare `!` for internal helpers where the errors are an
> implementation detail.

---

## Raising an error

`raise` ends the function with an error, like `return` ends it with a
value:

```sx
if denominator == 0 raise error.DivByZero;
```

`raise` is a statement — it can't appear inside an expression. You can
raise a literal tag (`raise error.X`) or a tag held in a variable
(`raise e`), which is handy for forwarding:

```sx
v := parse(s) catch e {
  if e == error.Recoverable return default;
  raise e;                  // forward everything else
};
```

Inside a closure, `raise` ends **that closure**, not the function the
closure was written in — a closure is its own failable function.

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
cfg := Config.{ port = try parse_port(s), host = try parse_host(s) };
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

## Fallbacks and chains with `or`

`or` provides a value when a failable call fails, or chains to another
attempt.

### Fall back to a default value

```sx
port := parse_port(s) or 8080;     // if parsing fails, port = 8080
```

The error is absorbed; `port` is a plain `i32`.

### Chain attempts — first success wins

```sx
v := try fetch_local(key) or try fetch_remote(key);
// try local; if it fails, try remote; if both fail, propagate
```

Each attempt is a `try`; if all fail, the last error propagates (and the
trace records every attempt). Mix in a terminator to never fail:

```sx
v := try fetch_local(key) or try fetch_remote(key) or default_value;
// try both; fall back to default if both fail — never propagates
```

> `or` is the same operator sx uses for optional fallback. It binds
> looser than `try`, and chains left-to-right.

---

## Handling with `catch`

`catch` handles an error inline and produces a value (or diverts
control). The bound name (`catch e`) is the error tag:

```sx
v := parse_int(s) catch e {
  log.warn("bad input '{}': {}", s, e);
  return -1;                       // bail out of the enclosing function
};
```

The catch body either produces a value of the success type, or diverges
(`return`, `raise`, `break`, `continue`, `unreachable`).

### Ignore the error

Omit the binding entirely (the body must be braced):

```sx
flush(buf) catch { };              // attempt it; ignore any failure
```

### Dispatch on the tag — the `catch e == { }` form

When you want to handle specific tags differently, use the match form —
it's sugar for `catch e { if e == { ... } }`:

```sx
v := parse_int(s) catch e == {
  case .Empty:    0;
  case .BadDigit: -1;
  else:           raise e;         // forward the rest
};
```

### Multi-value catch

If the function returns multiple values, the catch body produces a
tuple:

```sx
v, n := parse_pair(s) catch e {
  log.warn("parse failed: {}", e);
  (0, 0)
};
```

### Comparing tags

Error tags compare with other tags and `error.X` literals — never with
raw integers (tag ids are an internal detail):

```sx
if e == error.Empty { ... }        // OK
if e == 42 { ... }                 // ERROR — compare against a tag
```

---

## Cleanup: `defer` and `onfail`

Both register cleanup that runs when a block exits. The difference is
*when*:

- **`defer`** runs on **every** exit — success or failure.
- **`onfail`** runs **only** when an error leaves the block.

### Use `defer` for unconditional cleanup

```sx
process_file :: (path: string) -> ! {
  f := try open(path);
  defer close(f);                  // always close, success or fail
  try process(try read_all(f));
}
```

### Use `onfail` for "undo on failure" — when ownership transfers on success

The classic case is a constructor that hands the resource to its caller
on success, but must clean up if a later step fails:

```sx
make_handle :: () -> (Handle, !) {
  h := try sys_open();
  onfail sys_close(h);             // close only if a LATER step fails

  try configure(h);
  try register(h);
  return h;                        // success: onfail is skipped — caller owns h
}
```

If `configure` or `register` fails, `sys_close(h)` runs and the error
propagates. On success, `onfail` is skipped — `h` belongs to the caller
now. Using `defer` here would be a bug: it'd close the handle you just
handed out.

`onfail` can bind the in-flight tag and is block-scoped — it fires when
an error leaves *its* block, even if a caller later catches that error:

```sx
v := (try {
  h := try open();
  onfail close(h);                 // scoped to this block
  try use(h);
  42
}) catch { default };
// use() fails → close(h) runs (cleanup happens) → catch absorbs → default
```

### Cleanup that can itself fail

Cleanup routines are often failable too. Inside a `defer`/`onfail` body
you can't `try` or `raise` (cleanup can't propagate — you're already
unwinding), so absorb the error locally:

```sx
onfail {
  close(h) catch { };              // ignore a failed close
  flush(buf) catch fe { log.warn("flush failed: {}", fe); };
}
```

---

## When something fails: error traces

In debug builds, sx records a **return trace** — the path an error took
from its `raise` site up through every `try` that propagated it. Print
it from a handler:

```sx
v := parse(s) catch e {
  log.error("parse failed: {}", e);
  trace.print_current();
  return default;
};
```

```
error return trace (most recent call last):
  parse_digit at parse.sx:12:5
        c := s[i] or raise error.BadDigit;
                     ^
  parse_int at parse.sx:34:13
        try parse_digit(s);
        ^
  handle_line at main.sx:21:8
        try parse_int(line);
        ^
```

Traces are on by default in debug builds and compiled out in release
(re-enable with `--release-traces`). They cost nothing on the success
path. Each frame's location comes from `Frame` metadata
(file/line/col/func) baked in at the trace point — the trace resolves
itself with no debug info. Separately, sx emits standard DWARF, so
`lldb` / `gdb` work on sx binaries too.

Interpolating a tag with `{}` prints its **name**, not a number — in
every build, including release:

```sx
log.warn("parse failed: {}", e);     // → "parse failed: BadDigit"
```

For human-readable context, use `log` on the error path — the tag tells
you *what* failed, the log tells you the *details*:

```sx
parse :: (s: string) -> (i32, !) {
  onfail e { log.warn("parsing {}: {}", s, e); }
  ...
}
```

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
and the tag to stderr and exits with code `1`.

For explicit, shell-friendly exit codes anywhere in the program, call
`process.exit`:

```sx
process :: #import "modules/process.sx";

main :: () -> ! {
  if bad_args process.exit(64);    // EX_USAGE — immediate, bypasses the error system
  try run();
}
```

`process.exit` is a final stop: it does not run `defer`/`onfail` and does
not propagate. Use it for deliberate termination, not for recoverable
errors.

---

## Patterns

### Resource acquisition

```sx
open_db :: (url: string) -> (Conn, !DbErr) {
  c := try connect(url);
  onfail disconnect(c);
  try authenticate(c);
  try select_schema(c);
  return c;                        // caller owns the live connection
}
```

### Selective handling, forward the rest

```sx
load :: (path: string) -> (Data, !) {
  return read(path) catch e == {
    case .NotFound: try read(fallback_path);   // recover one case
    else:           raise e;                   // forward the rest
  };
}
```

### Fallible pipeline

```sx
// `|>` threads a value through stages; mark each fallible stage
n := try parse(s) |> try validate() |> try normalize();
```

### Validate-and-collect

```sx
parse_config :: (src: string) -> (Config, !ParseErr) {
  return Config.{
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
  contracts, bare `!` for internal helpers.
- **`raise` to fail, `try` to propagate, `catch` to handle, `or` to
  fall back.**
- **Every failable call needs a marker** (`try` / `catch` / `or` /
  destructure). If you forget, the compiler tells you exactly where.
- **`defer` always runs; `onfail` runs only on error.** Reach for
  `onfail` when success transfers ownership.
- **Cleanup can't propagate** — absorb failable cleanup with `catch` /
  `or`.
- **Tags are identities, not data** — log for context; compare tags to
  tags, never to raw integers.
- **Traces are free in release** (compiled out) and automatic in debug.
