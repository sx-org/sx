# issue 0282 — qualified function re-exports lost extern parameter types and missing namespace members fell through to a bare global

## Status

Resolved. The original symptom was real, but the initial diagnosis was too
narrow: `clib.read` inside the failable fiber loop was not the miscompile.

## Symptom

Removing `std/socket.sx`'s duplicate local `read`/`write`/`close` externs and
routing its internals through the canonical `std/c.sx` declarations made:

- `examples/http/1704-http-bind-ipv6-unix` exit 13; and
- `examples/http/1677-http-fuzz-smoke` fail liveness at iteration 0.

Keeping the local externs made both pass, which initially implicated the
internal `clib.read` / `clib.write` calls in `read_nb` / `write_nb`.

## Root cause

The local externs also formed `socket`'s public `socket.read` / `socket.write` /
`socket.close` namespace surface. Once removed, existing calls such as:

```sx
socket.write(fd, req.ptr, xx req.len)
```

named a member that `socket.sx` no longer authored. Qualified call lowering
then incorrectly fell through to the process-global bare `write` extern from
`std/c.sx`, while call-argument typing found no `socket.write` signature and
returned an empty parameter list. The ambient expression target consequently
leaked into argument lowering. In a function returning `bool`, LLVM showed the
request length truncated from `i64` to `i1`, then extended back to `i64`, so
libc received a count of one byte.

The same gap affected legitimate function re-exports such as:

```sx
write :: clib.write;
```

Namespace member discovery recognized direct function declarations and
const-wrapped function literals, but not const aliases whose chain terminated
at a function.

## Resolution

- Namespace function-member discovery now follows function alias chains in the
  target module's own source context.
- Qualified call argument typing uses that selected namespace member before
  consulting global qualified/bare maps, including extern re-exports whose C
  symbol intentionally remains unqualified.
- A genuinely missing qualified function member now diagnoses
  `namespace 'x' has no member 'y'`; it never falls through to a same-named bare
  global.
- `std/socket.sx` re-exports `read` / `write` / `close` from `std/c.sx` and its
  own nonblocking helpers call `clib.read` / `clib.write` directly. There are no
  duplicate local extern declarations.

## Regression coverage

- `0848-modules-qualified-extern-reexport` proves a qualified extern re-export
  retains its parameter types even under a conflicting ambient `bool` target.
- `0849-modules-qualified-missing-fn-no-bare-fallback` proves a missing member
  cannot borrow an unrelated bare extern.
- The original HTTP regressions `1677` and `1704` pass with the socket externs
  consolidated.
